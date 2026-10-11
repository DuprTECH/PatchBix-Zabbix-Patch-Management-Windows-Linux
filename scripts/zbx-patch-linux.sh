#!/bin/bash
# ----------------------------------------------------------------------------
# zbx-patch-linux.sh
# Checks pending package updates on Linux and sends the result to Zabbix with
# zabbix_sender, to the OS independent template 'APP Patch management all OS'
# (keys patch.*, the same keys as zbx-patch-windows.ps1 on Windows).
#
# Supports apt (Debian / Ubuntu) and dnf / yum (RHEL / Rocky / Alma / Oracle / Fedora / CentOS).
#
# Values that don't exist on Linux (definition, service packs, update rollups, drivers,
# upgrades) are sent as 0. Values that can't be determined (severity and bugfix /
# enhancement on apt, repository availability when not root) are not sent.
#
# Run it as root from cron (recommended), for example /etc/cron.d/zbx-patch-linux:
#   0 */3 * * * root /usr/local/bin/zbx-patch-linux.sh >/dev/null 2>&1
#
# Settings (environment variables):
#   ZABBIX_SENDER   path to zabbix_sender          (default: zabbix_sender)
#   ZABBIX_CONF     agent config with Hostname / ServerActive
#                   (default: zabbix_agent2.conf / zabbix_agentd.conf in /etc/zabbix, /etc,
#                   /usr/local/etc, /opt/zabbix/etc, or the config of the running agent;
#                   without an agent but with zabbix_proxy.conf the data go to its Server)
#   ZABBIX_SERVER   optional Zabbix server / proxy (instead of ServerActive)
#   ZABBIX_PORT     optional port of ZABBIX_SERVER (default: 10051)
#   ZABBIX_HOST     optional host name in Zabbix   (instead of Hostname; default uname -n
#                   when the config has no Hostname, for example HostnameItem=system.hostname)
#   HISTORY_LINES   number of lines in the update history item (default: 50)
#   PATCH_CONF      patch settings of the host (default: /etc/zabbix/zbx-patch.conf)
#
# Patch settings (PATCH_CONF, optional, the same file format on Windows):
#   MAINTENANCE_WINDOW="crit+sec * 02:00-03:00, * 6 03:00-06:00"
#                     when and which updates this script installs itself (--auto-update from cron):
#                     "[<types>] <day> <HH:MM>-<HH:MM>", several separated by commas; types: * or all = all
#                     updates (also without types), crit = critical (dnf / yum severity Critical; apt has no
#                     severity - nothing), sec = security, kernel = kernel packages, def = Windows only,
#                     several joined with +; day: 1-7 = Mon-Sun or Mon..Sun, 1-5, *, 2.3 = 2nd Wednesday.
#                     No window = no automatic updates (only --update --force installs).
#   EXCLUDE="kernel*, docker-ce"           packages that are not updated (wildcards allowed)
#   REBOOT="true"                          reboot after updates when needed (false = report only)
#   AUTO_UPDATE="false"                    legacy (older installs): blocks the automatic updates
# They are sent to Zabbix (patch.maintenance.*, patch.exclude, patch.updates.excluded,
# patch.reboot.allowed, patch.autoupdate.config) and read by the install job (Ansible) with --show-config.
# patch.autoupdate (0 disabled, 1 OS security only, 2 OS all, 3 patch management = a maintenance window
# is set, 4 both) and patch.autoupdate.detail tell how updates are installed automatically.
#
# Settings from Zabbix (host macros {$PATCH.CONF.WINDOW}, {$PATCH.CONF.EXCLUDE}, {$PATCH.CONF.REBOOT}):
# the agent item patch.config (UserParameter, installed by --install-agent-config) writes the set ones to
# zbx-patch-from-zbx-host-macro.cache next to zbx-patch.conf (PATCH_CONF_MACRO). Its keys win over
# zbx-patch.conf, which is never changed from Zabbix.
# patch.config.override: the settings that are set, [S] = from the host macro, [C] = zbx-patch.conf
# (the item preprocessing shows them as symbols), for example
#   [S] window: crit * 03:00-05:00, [C] reboot: false
#   Empty = nothing set: no automatic updates, reboot when needed, nothing excluded.
#
# Options:
#   --show-config   print the patch settings as JSON (window active now, next window,
#                   exclusions, reboot, auto update) and exit - nothing is checked or sent
#   --update        install the updates now (apt / dnf / yum, without EXCLUDE), only in an open
#                   maintenance window and only its types (--force: all updates, also outside), send the result to Zabbix
#                   (patch.install.*), reboot when needed and REBOOT="true", then check
#   --auto-update   for cron (every 15 min): in an open maintenance window does --update once per
#                   window (its update types), otherwise exits right away
#                   (log: /var/log/zbx-patch-update.log via cron)
#   --zabbix-config "<window>|<unused>|<exclude>|<reboot>"
#                   for the agent (UserParameter patch.config): validate the macro values and write
#                   the macro file (only when changed); prints OK / ERROR for the item
#   --send-config   send only the patch settings to Zabbix (run by --zabbix-config in the background
#                   after a change of the host macros, so the dashboards show it right away)
#   --install-agent-config
#                   for the setup (root): UserParameter patch.config in the agent Include folder,
#                   the macro file writable by the agent, restart of the agent (undone when it fails)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
# ----------------------------------------------------------------------------

# cron has only /usr/bin:/bin - shutdown, apt-mark, needs-restarting can be in the sbin folders
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
export PATH

# Version of this script (item patch.script.version), YY.MM.DD[.n] (.n = another change the same day) - change it with every change of the script
SCRIPT_VERSION="26.10.11.9"

ZABBIX_SENDER="${ZABBIX_SENDER:-zabbix_sender}"
HISTORY_LINES="${HISTORY_LINES:-50}"
if [ -z "$ZABBIX_CONF" ]; then
    for c in /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agentd.conf /etc/zabbix/zabbix_agent.conf \
             /etc/zabbix_agent2.conf /etc/zabbix_agentd.conf \
             /usr/local/etc/zabbix_agent2.conf /usr/local/etc/zabbix_agentd.conf \
             /opt/zabbix/etc/zabbix_agent2.conf /opt/zabbix/etc/zabbix_agentd.conf; do
        [ -f "$c" ] && ZABBIX_CONF="$c" && break
    done
fi
# Otherwise the config of the running agent (-c <file> on its command line)
if [ -z "$ZABBIX_CONF" ]; then
    c=$(ps -eo args= 2>/dev/null | sed -n -E 's/^[^ ]*zabbix_agent(2|d)[^ ]* .*(-c|--config)[ =]+([^ ]+).*/\3/p' | head -n 1)
    [ -n "$c" ] && [ -f "$c" ] && ZABBIX_CONF="$c"
fi
# No agent, but a Zabbix proxy on this host: send to the Zabbix server of the proxy config
# (Server=, the first one; host:port or [IPv6]:port), host name = Hostname of the proxy config,
# otherwise uname -n. A host monitored by the proxy itself: set ZABBIX_SERVER=127.0.0.1.
if [ -z "$ZABBIX_CONF" ] && [ -z "$ZABBIX_SERVER" ]; then
    for c in /etc/zabbix/zabbix_proxy.conf /etc/zabbix_proxy.conf /usr/local/etc/zabbix_proxy.conf; do
        [ -f "$c" ] || continue
        s=$(sed -n -E 's/^[[:space:]]*Server[[:space:]]*=[[:space:]]*([^,;[:space:]#]+).*/\1/p' "$c" | tail -n 1)
        [ -n "$s" ] || continue
        case "$s" in
            \[*\]:*) ZABBIX_SERVER=${s%]:*}; ZABBIX_SERVER=${ZABBIX_SERVER#[}; ZABBIX_PORT=${s##*]:} ;;
            *:*:*)   ZABBIX_SERVER=$s ;;
            *:*)     ZABBIX_SERVER=${s%:*}; ZABBIX_PORT=${s##*:} ;;
            *)       ZABBIX_SERVER=$s ;;
        esac
        [ -z "$ZABBIX_HOST" ] && ZABBIX_HOST=$(sed -n -E 's/^[[:space:]]*Hostname[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' "$c" | tail -n 1)
        [ -z "$ZABBIX_HOST" ] && ZABBIX_HOST=$(uname -n)
        break
    done
fi

# Host name: zabbix_sender takes Hostname from the agent config, but it can't resolve
# HostnameItem (for example HostnameItem=system.hostname). Without Hostname in the config
# (or its Include files) send the name of system.hostname, that is uname -n.
if [ -z "$ZABBIX_HOST" ] && [ -n "$ZABBIX_CONF" ]; then
    CONF_FILES="$ZABBIX_CONF"
    for inc in $(sed -n 's/^Include=//p' "$ZABBIX_CONF"); do
        [ -d "$inc" ] && inc="$inc/*"
        CONF_FILES="$CONF_FILES $inc"
    done
    # shellcheck disable=SC2086
    grep -hqs '^Hostname=' $CONF_FILES || ZABBIX_HOST=$(uname -n)
fi

send() {
    local args=()
    [ -n "$ZABBIX_CONF" ]   && args+=(-c "$ZABBIX_CONF")
    [ -n "$ZABBIX_SERVER" ] && args+=(-z "$ZABBIX_SERVER")
    [ -n "$ZABBIX_PORT" ]   && args+=(-p "$ZABBIX_PORT")
    [ -n "$ZABBIX_HOST" ]   && args+=(-s "$ZABBIX_HOST")
    "$ZABBIX_SENDER" "${args[@]}" "$@"
}

# Quoted value for the zabbix_sender input file
q() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# Patch day of a unix timestamp, for example 2.Tue (2nd Tuesday of the month)
patchday() {
    local d
    d=$(date -d "@$1" +%-d)
    echo "$(( (d - 1) / 7 + 1 )).$(LC_ALL=C date -d "@$1" +%a)"
}

# ---------------- Patch settings (zbx-patch.conf) ----------------
PATCH_CONF="${PATCH_CONF:-/etc/zabbix/zbx-patch.conf}"
# Settings from the Zabbix host macros {$PATCH.CONF.*}, written by the agent (UserParameter
# patch.config, --zabbix-config); a key set there wins over zbx-patch.conf
PATCH_CONF_MACRO="${PATCH_CONF_MACRO:-$(dirname "$PATCH_CONF")/zbx-patch-from-zbx-host-macro.cache}"

# Value of KEY="value" (also 'value' or value # comment); the last one wins, the macro file last
conf_get() {
    local v f files=()
    for f in "$PATCH_CONF" "$PATCH_CONF_MACRO"; do [ -r "$f" ] && files+=("$f"); done
    [ ${#files[@]} -eq 0 ] && return 0
    v=$(sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${files[@]}" | tail -n 1)
    case "$v" in
        \"*) v=${v#\"}; v=${v%%\"*} ;;
        \'*) v=${v#\'}; v=${v%%\'*} ;;
        *)   v=${v%%#*} ;;
    esac
    printf '%s' "$v"
}

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

MAINTENANCE_WINDOW=$(trim "$(conf_get MAINTENANCE_WINDOW)")
EXCLUDE=$(trim "$(conf_get EXCLUDE)")
REBOOT_ALLOWED=1
case "$(trim "$(conf_get REBOOT)" | tr '[:upper:]' '[:lower:]')" in no|false|0|off) REBOOT_ALLOWED=0 ;; esac
# Automatic updates: on when a maintenance window is set - the check script installs the update types
# of the window in it (--auto-update). Legacy AUTO_UPDATE="false" (zbx-patch.conf of older installs)
# still blocks them, AUTO_UPDATE="true" is not needed any more.
AUTO_UPDATE_OFF=0
case "$(trim "$(conf_get AUTO_UPDATE)" | tr '[:upper:]' '[:lower:]')" in no|false|0|off) AUTO_UPDATE_OFF=1 ;; esac
AUTO_UPDATE=0
[ -n "$MAINTENANCE_WINDOW" ] && [ "$AUTO_UPDATE_OFF" -eq 0 ] && AUTO_UPDATE=1
# Keys set by the host macros
MACRO_KEYS=$( [ -r "$PATCH_CONF_MACRO" ] && sed -n -E 's/^[[:space:]]*([A-Z_]+)[[:space:]]*=.*/\1/p' "$PATCH_CONF_MACRO" \
    | sort -u | paste -sd, - | sed 's/,/, /g')
# Source of a setting: S (Zabbix host macro), C (zbx-patch.conf) or nothing (not set - the default applies)
conf_src() {
    local f
    for f in "$PATCH_CONF_MACRO:S" "$PATCH_CONF:C"; do
        [ -r "${f%:*}" ] && grep -qE "^[[:space:]]*$1[[:space:]]*=" "${f%:*}" && { echo "${f##*:}"; return; }
    done
}
# The settings that are set, each with its source: [S] = Zabbix host macro, [C] = zbx-patch.conf
# (the item preprocessing shows them as symbols); empty = nothing set - no automatic updates
# (item patch.config.override, column Config of the dashboards)
CONFIG_SUMMARY=""
conf_add() {
    local s; s=$(conf_src "$1"); [ -n "$s" ] || return 0
    CONFIG_SUMMARY+="${CONFIG_SUMMARY:+, }[$s] $2: $3"
}
conf_add MAINTENANCE_WINDOW window "${MAINTENANCE_WINDOW:-none (no automatic updates)}"
[ "$AUTO_UPDATE_OFF" -eq 1 ] && conf_add AUTO_UPDATE "auto update" "off (AUTO_UPDATE=false)"
conf_add EXCLUDE exclude "${EXCLUDE:--}"
conf_add REBOOT reboot "$( [ "$REBOOT_ALLOWED" -eq 1 ] && echo true || echo false)"

# Exclusions: comma separated package names, wildcards allowed
EXCL=()
IFS=',' read -ra _excl <<< "$EXCLUDE"
for p in "${_excl[@]}"; do p=$(trim "$p"); [ -n "$p" ] && EXCL+=("$p"); done

is_excluded() {
    local p
    for p in "${EXCL[@]}"; do
        # shellcheck disable=SC2053
        [[ $1 == $p ]] && return 0
    done
    return 1
}

# Day of a maintenance window: 3 or Wed (1 = Monday ... 7 = Sunday), a range 1-5 / Mon-Fri,
# * (every day), 2.3 / 2.Wed (2nd Wednesday of the month)
DAYS=(mon tue wed thu fri sat sun)
day_num() {
    local i
    case "$1" in [1-7]) echo "$1"; return 0 ;; esac
    for i in 0 1 2 3 4 5 6; do [ "${DAYS[$i]}" = "${1,,}" ] && { echo $(( i + 1 )); return 0; }; done
    return 1
}
# day_match <day spec> <day of week 1-7> <day of month>: 0 match, 1 no match, 2 invalid spec
day_match() {
    local a b
    case "$1" in
        '*') return 0 ;;
        [1-5].*)
            a=$(day_num "${1#*.}") || return 2
            [ "$2" -eq "$a" ] && [ $(( ($3 - 1) / 7 + 1 )) -eq "${1%%.*}" ] ;;
        *-*)
            a=$(day_num "${1%-*}") || return 2
            b=$(day_num "${1#*-}") || return 2
            if [ "$a" -le "$b" ]; then [ "$2" -ge "$a" ] && [ "$2" -le "$b" ]
            else [ "$2" -ge "$a" ] || [ "$2" -le "$b" ]; fi ;;
        *)
            a=$(day_num "$1") || return 2
            [ "$2" -eq "$a" ] ;;
    esac
}

# Update types of a window: * or all = all updates, crit = critical (dnf / yum: security advisories
# with severity Critical; apt has no severity - nothing), sec = security, kernel = kernel packages,
# def = definitions (Windows only - nothing on Linux); several joined with +, for example crit+kernel
types_norm() {
    local t out="" x
    local -a ts
    IFS='+' read -ra ts <<< "${1,,}"
    for t in "${ts[@]}"; do
        case "$t" in
            '*'|all) echo '*'; return 0 ;;
            crit|sec|kernel|def) case "+$out+" in *"+$t+"*) ;; *) out="${out:+$out+}$t" ;; esac ;;
            *) return 1 ;;
        esac
    done
    [ -n "$out" ] && echo "$out"
}

# Maintenance window "[<types>] <day> <HH:MM>-<HH:MM>, ..." (an end lower than the start = the next day;
# without types = all updates). Sets MAINT_ACTIVE (0 / 1), MAINT_START (start of the open window),
# MAINT_TYPES (update types of the open window(s)), MAINT_NEXT (start of the next window, unix time)
# and MAINT_ERROR
maint_eval() {
    MAINT_ACTIVE=0; MAINT_START=""; MAINT_NEXT=""; MAINT_ERROR=""; MAINT_TYPES=""
    [ -z "$MAINTENANCE_WINDOW" ] && return 0
    local w f1 f2 f3 extra spec range types now base d dow dom day0 s e i t
    local -a wins specs starts ends wtypes
    local re='^([01]?[0-9]|2[0-3]):([0-5][0-9])-([01]?[0-9]|2[0-3]):([0-5][0-9])$'
    IFS=',' read -ra wins <<< "$MAINTENANCE_WINDOW"
    for w in "${wins[@]}"; do
        read -r f1 f2 f3 extra <<< "$w"
        [ -z "$f1" ] && continue
        if [ -z "$f3" ]; then types='*'; spec=$f1; range=$f2
        else types=$(types_norm "$f1") || types=""; spec=$f2; range=$f3; fi
        day_match "$spec" 1 1; [ $? -eq 2 ] && spec=""
        if [ -z "$types" ] || [ -z "$spec" ] || [ -n "$extra" ] || ! [[ $range =~ $re ]]; then
            [ -z "$MAINT_ERROR" ] && MAINT_ERROR="invalid maintenance window '$(trim "$w")'"
            continue
        fi
        specs+=("$spec"); wtypes+=("$types")
        starts+=($(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} )))
        ends+=($(( 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} )))
    done
    now=$(date +%s); base=$(date +%F)
    for d in $(seq -1 62); do
        read -r dow dom day0 <<< "$(date -d "$base $d day" '+%u %-d %s')"
        [ -n "$MAINT_NEXT" ] && [ "$day0" -gt "$MAINT_NEXT" ] && break
        for i in "${!specs[@]}"; do
            day_match "${specs[$i]}" "$dow" "$dom" || continue
            s=$(( day0 + starts[i] * 60 )); e=$(( day0 + ends[i] * 60 ))
            [ "$e" -le "$s" ] && e=$(( e + 86400 ))
            if [ "$now" -ge "$s" ] && [ "$now" -lt "$e" ]; then
                MAINT_ACTIVE=1; { [ -z "$MAINT_START" ] || [ "$s" -lt "$MAINT_START" ]; } && MAINT_START=$s
                MAINT_TYPES=$(types_norm "${MAINT_TYPES:+$MAINT_TYPES+}${wtypes[$i]}")
            fi
            if [ "$s" -gt "$now" ] && { [ -z "$MAINT_NEXT" ] || [ "$s" -lt "$MAINT_NEXT" ]; }; then MAINT_NEXT=$s; fi
        done
    done
}
maint_eval

MODE=check; FORCE=0; ZBX_VALUES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --show-config)          MODE=show ;;
        --update)               MODE=update ;;
        --auto-update)          MODE=auto ;;
        --force)                FORCE=1 ;;
        --zabbix-config)        MODE=zabbix; ZBX_VALUES="${2-}"; shift ;;
        --install-agent-config) MODE=agentconf ;;
        --send-config)          MODE=sendconfig ;;
    esac
    shift
done
tf() { [ "$1" -eq 1 ] && echo true || echo false; }

# ---------------- Settings from the Zabbix host macros (--zabbix-config) ----------------
# Run by the Zabbix agent (UserParameter patch.config, as the user zabbix) with the values of the
# macros {$PATCH.CONF.WINDOW}|(unused)|{$PATCH.CONF.EXCLUDE}|{$PATCH.CONF.REBOOT} (the 2nd value was AUTO_UPDATE,
# it is ignored - the maintenance window turns the automatic updates on).
# Writes the set (non empty) ones to PATCH_CONF_MACRO, only when they changed; zbx-patch.conf is
# never changed. Invalid values: nothing is written, the item gets "ERROR: ...".
# The agent forbids * " ' $ ; | # and other characters in the values (UnsafeUserParameters=0), so:
#   window: all = all update types and 1-7 = every day (instead of *), "none" = no window (no automatic
#   updates); exclude: % = wildcard, "none" = nothing
zabbix_config() {
    local w e r extra content keys=() lines=()
    IFS='|' read -r w _ e r extra <<< "$1"
    w=$(trim "$w"); e=$(trim "$e"); r=$(trim "$r")
    if [ -n "$w" ]; then
        case "${w,,}" in none|any) w="" ;; esac
        if ! [[ $w =~ ^[0-9A-Za-z\ .,:+-]*$ ]]; then echo "ERROR: invalid {\$PATCH.CONF.WINDOW} '$w'"; return; fi
        MAINTENANCE_WINDOW=$w; maint_eval
        if [ -n "$MAINT_ERROR" ]; then echo "ERROR: {\$PATCH.CONF.WINDOW}: $MAINT_ERROR"; return; fi
        keys+=(MAINTENANCE_WINDOW); lines+=("MAINTENANCE_WINDOW=\"$w\"")
    fi
    if [ -n "$e" ]; then
        [ "${e,,}" = none ] && e=""
        if ! [[ $e =~ ^[0-9A-Za-z\ ._+:,%-]*$ ]]; then echo "ERROR: invalid {\$PATCH.CONF.EXCLUDE} '$e'"; return; fi
        e=${e//%/*}
        keys+=(EXCLUDE); lines+=("EXCLUDE=\"$e\"")
    fi
    if [ -n "$r" ]; then
        case "${r,,}" in
            yes|true|1|on)  r=true ;;
            no|false|0|off) r=false ;;
            *) echo "ERROR: invalid {\$PATCH.CONF.REBOOT} '$r' (true / false)"; return ;;
        esac
        keys+=(REBOOT); lines+=("REBOOT=\"$r\"")
    fi
    content="# zbx-patch-from-zbx-host-macro.cache - written by the Zabbix agent from the host macros {\$PATCH.CONF.*}
# (item patch.config, zbx-patch-linux.sh --zabbix-config). Don't edit it: it is overwritten when a macro
# changes. The keys here win over zbx-patch.conf; an empty macro leaves zbx-patch.conf in effect."
    [ ${#lines[@]} -gt 0 ] && content+=$'\n'$(printf '%s\n' "${lines[@]}")
    local summary
    summary=$(IFS=,; echo "${keys[*]}"); summary=${summary//,/, }; summary=${summary:-no host macros set}
    if [ -f "$PATCH_CONF_MACRO" ] && [ "$(cat "$PATCH_CONF_MACRO")" = "$content" ]; then
        echo "OK, unchanged: $summary"; return
    fi
    if ! { [ -w "$PATCH_CONF_MACRO" ] || { [ ! -e "$PATCH_CONF_MACRO" ] && [ -w "$(dirname "$PATCH_CONF_MACRO")" ]; }; }; then
        echo "ERROR: $PATCH_CONF_MACRO is not writable by $(id -un) - run zbx-patch-linux.sh --install-agent-config as root"; return
    fi
    printf '%s\n' "$content" > "$PATCH_CONF_MACRO" || { echo "ERROR: writing $PATCH_CONF_MACRO failed"; return; }
    echo "OK, written: $summary"
    # Show the new settings in Zabbix right away (the full check runs every 12 h) - in the background,
    # so the agent doesn't wait
    ( "$(readlink -f "$0")" --send-config </dev/null >/dev/null 2>&1 & )
}
if [ "$MODE" = zabbix ]; then zabbix_config "$ZBX_VALUES"; exit 0; fi

# --send-config: only the patch settings (after a change of the host macros, by --zabbix-config)
if [ "$MODE" = sendconfig ]; then
    {
        echo "- patch.autoupdate.config $AUTO_UPDATE"
        echo "- patch.config.override $(q "$CONFIG_SUMMARY")"
        echo "- patch.reboot.allowed $REBOOT_ALLOWED"
        echo "- patch.maintenance.window $(q "${MAINTENANCE_WINDOW:--}${MAINT_ERROR:+ ($MAINT_ERROR)}")"
        [ -n "$MAINT_NEXT" ] && echo "- patch.maintenance.next $MAINT_NEXT"
        echo "- patch.exclude $(q "${EXCLUDE:--}")"
    } | send -i -
    exit 0
fi

# ---------------- --install-agent-config (root, run by the setup) ----------------
# UserParameter patch.config in a file of the agent Include folder (the main config is changed only
# when it has no Include for that folder), PATCH_CONF_MACRO writable by the agent (root:zabbix 0664),
# restart of the agent when something changed; when the agent doesn't start, everything is undone.
install_agent_config() {
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: --install-agent-config needs root" >&2; return 1; }
    [ -n "$ZABBIX_CONF" ] || { echo "ERROR: Zabbix agent config not found - UserParameter not installed" >&2; return 1; }
    local self agent svc incdir inc upfile line backup changed=0 grp
    self=$(readlink -f "$0")
    case "$(basename "$ZABBIX_CONF")" in *agent2*) agent=zabbix_agent2; svc=zabbix-agent2 ;; *) agent=zabbix_agentd; svc=zabbix-agent ;; esac
    # Include folder: the first Include=<folder>/*.conf (not the agent 2 plugins), otherwise <config folder>/<agent>.d
    incdir=""
    while read -r inc; do
        case "$inc" in
            /*) ;;
            *)             continue ;;   # relative to the working folder of the agent
        esac
        case "$inc" in
            */plugins.d/*) continue ;;
            */\*.conf)     incdir=${inc%/\*.conf}; break ;;
            */)            incdir=${inc%/}; break ;;
            *)             [ -d "$inc" ] && { incdir=$inc; break; } ;;
        esac
    done < <(sed -n -E 's/^[[:space:]]*Include[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' "$ZABBIX_CONF")
    backup=""
    if [ -z "$incdir" ]; then
        incdir="$(dirname "$ZABBIX_CONF")/$agent.d"
        backup="$ZABBIX_CONF.zbx-patch.bak"
        cp -p "$ZABBIX_CONF" "$backup"
        printf '\n# Added by zbx-patch-linux.sh (UserParameter patch.config)\nInclude=%s/*.conf\n' "$incdir" >> "$ZABBIX_CONF"
        echo "Include=$incdir/*.conf added to $ZABBIX_CONF"
        changed=1
    fi
    mkdir -p "$incdir"
    upfile="$incdir/zbx-patch-userparameter.conf"
    line="UserParameter=patch.config[*],$self --zabbix-config \"\$1|\$2|\$3|\$4\""
    if [ "$(cat "$upfile" 2>/dev/null)" != "# Settings from the Zabbix host macros {\$PATCH.CONF.*} - installed by zbx-patch-linux.sh
$line" ]; then
        [ -f "$upfile" ] && cp -p "$upfile" "$upfile.bak"
        printf '# Settings from the Zabbix host macros {$PATCH.CONF.*} - installed by zbx-patch-linux.sh\n%s\n' "$line" > "$upfile"
        chmod 644 "$upfile"
        echo "UserParameter patch.config: $upfile"
        changed=1
    fi
    # The macro file: the agent (user zabbix) writes it
    grp=$(getent group zabbix >/dev/null && echo zabbix || echo root)
    [ -f "$PATCH_CONF_MACRO" ] || printf '# zbx-patch-from-zbx-host-macro.cache - written by the Zabbix agent from the host macros {$PATCH.CONF.*}\n' > "$PATCH_CONF_MACRO"
    chown "root:$grp" "$PATCH_CONF_MACRO" && chmod 664 "$PATCH_CONF_MACRO"
    echo "Settings from the host macros: $PATCH_CONF_MACRO (root:$grp 664)"
    if [ "$changed" -eq 0 ]; then echo "Agent config unchanged"; return 0; fi
    # Restart the agent; when it doesn't run afterwards, undo the changes
    restart() { if command -v systemctl >/dev/null 2>&1; then systemctl restart "$svc"; sleep 3; systemctl is-active --quiet "$svc"
                else service "$svc" restart && sleep 3 && pgrep -x "$agent" >/dev/null; fi; }
    if restart; then echo "Agent restarted: $svc"; rm -f "$upfile.bak" "$backup"; return 0; fi
    echo "ERROR: $svc doesn't run after the restart - the changes are undone" >&2
    if [ -f "$upfile.bak" ]; then mv -f "$upfile.bak" "$upfile"; else rm -f "$upfile"; fi
    [ -n "$backup" ] && mv -f "$backup" "$ZABBIX_CONF"
    restart || echo "ERROR: $svc doesn't run even after undoing the changes - check it" >&2
    return 1
}
if [ "$MODE" = agentconf ]; then install_agent_config; exit $?; fi

if [ "$MODE" = show ]; then
    printf '{"config": %s, "config_found": %s, "maintenance_window": %s, "maintenance_active": %s, ' \
        "$(q "$PATCH_CONF")" "$([ -r "$PATCH_CONF" ] && echo true || echo false)" \
        "$(q "$MAINTENANCE_WINDOW")" "$(tf "$MAINT_ACTIVE")"
    printf '"maintenance_next": %s, "maintenance_error": %s, "exclude": [' "${MAINT_NEXT:-null}" "$(q "$MAINT_ERROR")"
    sep=""; for p in "${EXCL[@]}"; do printf '%s%s' "$sep" "$(q "$p")"; sep=", "; done
    printf '], "reboot_allowed": %s, "auto_update": %s, "auto_update_blocked": %s, "maintenance_types": %s, "macro_config": %s, "macro_keys": %s, "config_summary": %s}\n' \
        "$(tf "$REBOOT_ALLOWED")" "$(tf "$AUTO_UPDATE")" "$(tf "$AUTO_UPDATE_OFF")" "$(q "$MAINT_TYPES")" \
        "$(q "$PATCH_CONF_MACRO")" "$(q "$MACRO_KEYS")" "$(q "$CONFIG_SUMMARY")"
    exit 0
fi

# --auto-update (cron every 15 min): only with a maintenance window, when it is open, once per window
STAMP=/var/lib/zbx-patch/last-auto-update
if [ "$MODE" = auto ]; then
    [ "$AUTO_UPDATE" -eq 1 ] && [ "$MAINT_ACTIVE" -eq 1 ] || exit 0
    [ "$(cat "$STAMP" 2>/dev/null || echo 0)" -ge "$MAINT_START" ] 2>/dev/null && exit 0
    mkdir -p "$(dirname "$STAMP")" && date +%s > "$STAMP"
    echo "=== $(date '+%Y-%m-%d %H:%M') automatic update in the maintenance window '$MAINTENANCE_WINDOW'"
    MODE=update
fi
[ -n "$MAINT_ERROR" ] && echo "WARNING: $PATCH_CONF: $MAINT_ERROR" >&2

# zabbix_sender needs the agent config (-c) or the server (-z) - without them nothing can be sent
if [ -z "$ZABBIX_CONF" ] && [ -z "$ZABBIX_SERVER" ]; then
    echo "ERROR: Zabbix agent / proxy config not found (zabbix_agent2.conf, zabbix_agentd.conf, zabbix_proxy.conf) - set ZABBIX_CONF=<path>" \
         "or ZABBIX_SERVER=<server or proxy> (and ZABBIX_HOST=<host name in Zabbix>), for example in the cron line" >&2
    exit 1
fi

# One run at a time (check, update and cron can overlap; apt / dnf need the lock too)
{ exec 9>/run/zbx-patch-linux.lock; } 2>/dev/null && command -v flock >/dev/null 2>&1 && flock -w 1800 9

# ---------------- Install updates (--update) ----------------
# Like the Ansible playbook: refresh, upgrade without EXCLUDE, autoremove, reboot when needed
# and allowed; the result goes to the patch.install.* items. Only in an open maintenance window and only
# its update types (crit, sec, kernel or *); --force installs all updates also outside a window.
do_update() {
    local pm="" need=0 rc=0 err="" changes count result doreboot=0 rebootfail=0 p n held_now newest types t sel
    local -a held=() x=()
    local w
    for p in apt-get dnf yum; do command -v $p >/dev/null 2>&1 && { pm=$p; break; }; done
    if [ -z "$pm" ]; then echo "ERROR: --update supports apt, dnf and yum" >&2; return 1; fi
    if [ "$FORCE" -eq 1 ]; then types='*'
    elif [ "$MAINT_ACTIVE" -eq 1 ]; then types=$MAINT_TYPES
    elif [ -z "$MAINTENANCE_WINDOW" ]; then
        echo "SKIPPED: no maintenance window - updates are installed only in a maintenance window. Install now with --force."
        return 2
    else
        echo "SKIPPED: outside the maintenance window '$MAINTENANCE_WINDOW'${MAINT_ERROR:+ ($MAINT_ERROR)}, next window: $( [ -n "$MAINT_NEXT" ] && date -d "@$MAINT_NEXT" '+%Y-%m-%d %H:%M' || echo -). Install now with --force."
        return 2
    fi
    w=$(mktemp -d)
    snap() {
        if [ "$pm" = apt-get ]; then
            dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' | awk '$1 ~ /^ii/ {print $2" "$3}'
        else
            rpm -qa --qf '%{NAME}.%{ARCH} %{EPOCHNUM}:%{VERSION}-%{RELEASE}\n'
        fi | sort
    }
    snap > "$w/before"
    echo "=== Installing updates ($pm), types: $( [ "$types" = '*' ] && echo all || echo "$types")${EXCL[0]:+, excluded: ${EXCL[*]}}"
    if [ "$pm" = apt-get ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q || { rc=1; err="apt-get update failed"; }
        # apt has no exclude: hold the excluded packages for the upgrade, release them afterwards
        if [ ${#EXCL[@]} -gt 0 ]; then
            held_now=$(apt-mark showhold)
            for p in "${EXCL[@]}"; do
                for n in $(dpkg-query -W -f='${Package}\n' "$p" 2>/dev/null | sort -u); do
                    printf '%s\n' "$held_now" | grep -qx "$n" || { apt-mark hold "$n" >/dev/null && held+=("$n"); }
                done
            done
            [ ${#held[@]} -gt 0 ] && echo "Held for the update: ${held[*]}"
        fi
        if [ "$rc" -eq 0 ] && [ "$types" = '*' ]; then
            apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade \
                || { rc=1; err="apt-get dist-upgrade failed"; }
        elif [ "$rc" -eq 0 ]; then
            # Only the packages of the types: sec = from a security suite, kernel = kernel packages
            # (apt has no severity - crit selects nothing; def is Windows only)
            sel=$(LANG=C apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | awk -v t="+$types+" -v kre="$KERNEL_RE" '
                /^Inst / { rest = $0; sub(/^[^(]*\(/, "", rest)
                           if ((t ~ /\+sec\+/ && rest ~ /[Ss]ecurity/) || (t ~ /\+kernel\+/ && $2 ~ kre)) print $2 }' | sort -u)
            if [ -z "$sel" ]; then
                echo "No updates of the types '$types'$(case "+$types+" in *+crit+*) echo ' (apt has no severity: crit selects nothing)' ;; esac)"
            else
                # shellcheck disable=SC2086
                apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install --only-upgrade $sel \
                    || { rc=1; err="apt-get install --only-upgrade failed"; }
            fi
        fi
        [ ${#held[@]} -gt 0 ] && apt-mark unhold "${held[@]}" >/dev/null
        [ "$rc" -eq 0 ] && apt-get -y -q autoremove >/dev/null
        [ -f /var/run/reboot-required ] && need=1
    else
        for p in "${EXCL[@]}"; do x+=("--exclude=$p"); done
        [ "$pm" = dnf ] && dnf -q makecache >/dev/null 2>&1
        if [ "$types" = '*' ]; then
            $pm -y upgrade "${x[@]}" || { rc=1; err="$pm upgrade failed"; }
        else
            # Only the types: sec = security advisories, crit = security advisories with severity Critical,
            # kernel = kernel packages (def is Windows only)
            IFS='+' read -ra sel <<< "$types"
            for t in "${sel[@]}"; do
                case "$t" in
                    sec)    $pm -y upgrade --security "${x[@]}" || { rc=1; err="$pm upgrade --security failed"; } ;;
                    crit)   if $pm --version 2>/dev/null | grep -qi dnf5; then
                                $pm -y upgrade --advisory-severities=critical "${x[@]}" || { rc=1; err="$pm upgrade (critical) failed"; }
                            else
                                $pm -y upgrade --sec-severity=Critical "${x[@]}" || { rc=1; err="$pm upgrade --sec-severity=Critical failed"; }
                            fi ;;
                    kernel) $pm -y upgrade "${x[@]}" 'kernel*' || { rc=1; err="$pm upgrade kernel failed"; } ;;
                esac
            done
        fi
        [ "$rc" -eq 0 ] && $pm -y -q autoremove >/dev/null 2>&1
        # needs-restarting -r: exit 1 = reboot required (dnf-plugins-core / yum-utils)
        if ! command -v needs-restarting >/dev/null 2>&1 && ! dnf needs-restarting --help >/dev/null 2>&1; then
            $pm install -y -q "$( [ "$pm" = yum ] && echo yum-utils || echo dnf-plugins-core)" >/dev/null 2>&1
        fi
        if command -v needs-restarting >/dev/null 2>&1; then needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && need=1
        elif dnf needs-restarting --help >/dev/null 2>&1; then dnf needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && need=1; fi
    fi
    # Fallback: the newest installed kernel is not the running one
    if [ "$need" -eq 0 ]; then
        newest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | grep -v rescue | sort -V | tail -n 1)
        [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ] && need=1
    fi
    snap > "$w/after"
    changes=$(awk 'NR == FNR { b[$1] = $2; next }
        { a[$1] = $2
          if (($1 in b) == 0) print "Install  " $1 " " $2
          else if (b[$1] != $2) print "Upgrade  " $1 " " b[$1] " -> " $2 }
        END { for (k in b) if ((k in a) == 0) print "Remove  " k " " b[k] }' "$w/before" "$w/after")
    rm -rf "$w"
    count=$(printf '%s' "$changes" | grep -c .)
    [ "$rc" -eq 0 ] && [ "$need" -eq 1 ] && [ "$REBOOT_ALLOWED" -eq 1 ] && doreboot=1
    # Schedule the reboot first, so the result tells whether it worked
    # (the check runs again after the reboot: @reboot line in /etc/cron.d/zbx-patch-linux)
    if [ "$doreboot" -eq 1 ] && ! shutdown -r +2 "Reboot after the update (zbx-patch-linux.sh)"; then
        doreboot=0; rebootfail=1
    fi
    if [ "$rc" -ne 0 ]; then result="FAILED: $err"
    else result="OK, changed $count packages$( [ "$doreboot" -eq 1 ] && echo ', rebooting')$( [ "$need" -eq 1 ] && [ "$doreboot" -eq 0 ] && echo ', reboot required')$( [ "$rebootfail" -eq 1 ] && echo ' (reboot FAILED: shutdown -r)')"; fi
    echo "=== Result"
    [ -n "$changes" ] && printf '%s\n' "$changes"
    echo "$result"
    send -k patch.install.timestamp -o "$(date +%s)" >/dev/null
    send -k patch.install.status -o "$( [ "$rc" -eq 0 ] && echo 0 || echo 1)" >/dev/null
    send -k patch.install.count -o "$count" >/dev/null
    send -k patch.install.list -o "${changes:-No packages changed}" >/dev/null
    send -k patch.install.result -o "$result" >/dev/null
    if [ "$doreboot" -eq 1 ]; then
        send -k patch.reboot.required -o 0 >/dev/null
        echo "Rebooting in 2 minutes (cancel: shutdown -c)."
        exit 0
    fi
    if [ "$rebootfail" -eq 1 ]; then echo "ERROR: the reboot failed (shutdown -r), reboot the host by hand" >&2
    elif [ "$need" -eq 1 ] && [ "$rc" -eq 0 ]; then echo "WARNING: a reboot is required, but REBOOT=\"false\" in $PATCH_CONF" >&2; fi
    return "$rc"
}
if [ "$MODE" = update ]; then
    [ "$(id -u)" -eq 0 ] || { echo "ERROR: --update needs root" >&2; exit 1; }
    do_update; [ $? -eq 2 ] && exit 0
    echo "=== Update check"
fi

START=$(date +%s)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

OS_NAME=$(uname -s)
[ -r /etc/os-release ] && OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME $VERSION}")
OS_VERSION=$(uname -r)
LASTBOOT=$(awk '/^btime/ {print $2}' /proc/stat)

# Kernel packages (Debian / Ubuntu linux-image-*, RHEL kernel / kernel-core / kernel-uek ...)
KERNEL_RE='^(linux-(image|headers|modules|generic|signed|virtual|lowlatency|kernel)|kernel)([-_.].*)?$'

# Azure Arc / Azure Update Manager. Scheduled patching (maintenance configuration) runs the extension
# Microsoft.SoftwareUpdateManagement.LinuxOsUpdateExtension: its last config/<n>.settings has the run
# (startTime, classificationsToInclude, maximumDuration, rebootSettings), status/<n>.status the result.
# A run in the last 35 days = scheduled patching is active (AZURE=1). The periodic assessment only is
# Microsoft.CPlat.Core.LinuxPatchExtension with assessmentMode AutomaticByPlatform.
# Sets AZURE (0 / 1) and AZDETAIL (empty = no Arc agent).
azure_detect() {
    AZURE=0; AZDETAIL=""
    local arc ext seq s st cls rb dur start when age inst
    if systemctl is-active --quiet himdsd 2>/dev/null; then arc="connected"
    elif [ -d /opt/azcmagent ] || command -v azcmagent >/dev/null 2>&1; then arc="agent not running"
    else return 0; fi
    ext=$(ls -d /var/lib/waagent/Microsoft.SoftwareUpdateManagement.LinuxOsUpdateExtension-* 2>/dev/null | sort -V | tail -n 1)
    seq=$( [ -n "$ext" ] && ls "$ext"/config/ 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.settings$/\1/p' | sort -n | tail -n 1)
    if [ -n "$seq" ]; then
        s=$(cat "$ext/config/$seq.settings" 2>/dev/null)
        start=$(printf '%s' "$s" | sed -n 's/.*"startTime":"\([^"]*\)".*/\1/p')
        cls=$(printf '%s' "$s" | sed -n 's/.*"classificationsToInclude":\[\([^]]*\)\].*/\1/p' | tr -d '"' | sed 's/,/+/g')
        rb=$(printf '%s' "$s" | sed -n 's/.*"rebootSettings":"\([^"]*\)".*/\1/p')
        dur=$(printf '%s' "$s" | sed -n 's/.*"maximumDuration":\([0-9][0-9]*\).*/\1/p')
        st=$(grep -o '"status": "[A-Za-z]*"' "$ext/status/$seq.status" 2>/dev/null | head -n 1 | sed 's/.*: "//; s/"$//')
        inst=$(sed -n 's/.*installedPatchCount\\": \([0-9][0-9]*\).*/\1/p' "$ext/status/$seq.status" 2>/dev/null | head -n 1)
        when=$(date -d "$start" '+%Y-%m-%d %H:%M' 2>/dev/null)
        age=$(( ( $(date +%s) - $(date -d "$start" +%s 2>/dev/null || echo 0) ) / 86400 ))
        if [ -n "$when" ] && [ "$age" -le 35 ]; then
            AZURE=1
            AZDETAIL="Azure Update Manager (Arc $arc): scheduled patching, last run $when (${cls:-all}, reboot ${rb:-?}, ${dur:-?} min, ${st:-?}${inst:+, installed $inst})"
        else
            AZDETAIL="Azure Update Manager (Arc $arc): no scheduled run for ${age} days (last ${when:-?})"
        fi
    elif grep -qs '"assessmentMode":"AutomaticByPlatform"' /var/lib/waagent/Microsoft.CPlat.Core.LinuxPatchExtension-*/config/*.settings; then
        AZDETAIL="Azure Arc ($arc): Update Manager periodic assessment only"
    else
        AZDETAIL="Azure Arc ($arc)"
    fi
}

ALL=0; SECURITY=0; KERNEL=0; HELD=0
CRITICAL=""; BUGFIX=""; ENHANCEMENT=""          # empty = can't be determined, not sent
SEV_CRITICAL=""; SEV_IMPORTANT=""; SEV_MODERATE=""; SEV_LOW=""
LIST=""; HISTORY=""; REBOOT=0; REBOOT_REASON=""
REPO=""; PKGMGR="unknown"; AUTOUPDATE=0; AUTODETAIL="OS automatic updates off (unattended-upgrades / dnf-automatic / yum-cron)"; LASTUPDATE=""; RESULT="OK"

if command -v apt-get >/dev/null 2>&1; then
    # ======================= Debian / Ubuntu =======================
    PKGMGR="apt"
    if [ "$IS_ROOT" -eq 1 ]; then
        if apt-get update -qq >/dev/null 2>&1; then REPO=1; else REPO=0; fi
    fi
    # "Inst <package> [<old version>] (<new version> <suite> [<arch>])"
    LANG=C apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ' > "$WORK/inst"
    if [ -s "$WORK/inst" ]; then
        LIST=$(awk '{
            pkg = $2; old = ""
            if ($3 ~ /^\[/) { old = $3; gsub(/[][]/, "", old) }
            rest = $0; sub(/^[^(]*\(/, "", rest); split(rest, f, " ")
            cat = (rest ~ /[Ss]ecurity/) ? "security" : "update"
            print "[" cat "] " pkg " " (old != "" ? old " -> " : "") f[1]
        }' "$WORK/inst")
        ALL=$(wc -l < "$WORK/inst")
        SECURITY=$(printf '%s\n' "$LIST" | grep -c '^\[security\]')
        KERNEL=$(awk '{print $2}' "$WORK/inst" | grep -cE "$KERNEL_RE")
    fi
    HELD=$(apt-mark showhold 2>/dev/null | grep -c .)

    if [ -f /var/run/reboot-required ]; then
        REBOOT=1
        REBOOT_REASON="reboot-required"
        [ -f /var/run/reboot-required.pkgs ] && \
            REBOOT_REASON="Packages: $(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')"
    fi

    # unattended-upgrades: 1 = security only (the default origins), 2 = also the -updates origin
    if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed' \
       && apt-config dump 2>/dev/null | grep -qE '^APT::Periodic::Unattended-Upgrade "(1|always)"'; then
        AUTOUPDATE=1; AUTODETAIL="unattended-upgrades: security updates only"
        apt-config dump 2>/dev/null | grep -E '^Unattended-Upgrade::(Origins-Pattern|Allowed-Origins)' \
            | grep -qE -- '-updates' && { AUTOUPDATE=2; AUTODETAIL="unattended-upgrades: security and other updates (-updates)"; }
    fi

    # History from /var/log/apt/history.log (+ the last rotated logs), oldest first
    LOGS=$(ls -1tr /var/log/apt/history.log* 2>/dev/null | tail -n 3)
    if [ -n "$LOGS" ]; then
        # shellcheck disable=SC2086
        zcat -f $LOGS 2>/dev/null | awk '
            /^Start-Date:/ { d = $2 " " substr($3, 1, 5) }
            /^(Install|Upgrade|Downgrade|Remove|Purge|Reinstall):/ {
                act = $1; sub(/:$/, "", act)
                s = $0; sub(/^[A-Za-z]+: /, "", s)
                n = split(s, parts, /\), /)
                for (i = 1; i <= n; i++) {
                    p = parts[i]; sub(/\)$/, "", p)
                    name = p; sub(/ \(.*/, "", name)
                    v = p; sub(/^[^(]*\(/, "", v); sub(/, automatic$/, "", v)
                    if (act == "Upgrade" || act == "Downgrade") sub(/, /, " -> ", v)
                    print d "  " act "  " name " " v
                }
            }' > "$WORK/hist"
        if [ -s "$WORK/hist" ]; then
            HISTORY=$(tail -n "$HISTORY_LINES" "$WORK/hist" | tac)
            LASTUPDATE=$(date -d "$(tail -n 1 "$WORK/hist" | cut -c1-16)" +%s 2>/dev/null)
        fi
    fi
    if [ -z "$LASTUPDATE" ]; then
        LASTUPDATE=$(find /var/lib/dpkg/info -name '*.list' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1 | cut -d. -f1)
    fi

elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    # ======================= RHEL family =======================
    if command -v dnf >/dev/null 2>&1; then PKGMGR="dnf"; else PKGMGR="yum"; fi
    LANG=C "$PKGMGR" -q check-update > "$WORK/upd" 2>/dev/null
    RC=$?   # 100 = updates available, 0 = none, 1 = error
    if [ "$RC" -eq 1 ]; then
        REPO=0
        RESULT="ERROR: $PKGMGR check-update failed"
    else
        REPO=1
    fi
    # "<name>.<arch> <version> <repo>", the section "Obsoleting Packages" is skipped
    awk '/^Obsoleting/ {exit} NF == 3 && $1 !~ /^(Security:|Last)/ {
            n = $1; sub(/\.[^.]*$/, "", n); print n " " $2 }' "$WORK/upd" > "$WORK/pending"

    # Advisories of the available updates
    #   dnf4 / yum: <advisory> <type or severity/Sec.> <nevra>
    #   dnf5:       <advisory> <type> <severity> <nevra> <issued>
    if [ "$PKGMGR" = "dnf" ]; then UIARGS=(updateinfo list --available); else UIARGS=(updateinfo list); fi
    LANG=C "$PKGMGR" -q "${UIARGS[@]}" 2>/dev/null | awk '
        NF >= 3 && $1 != "Name" {
            if ($2 ~ /\/Sec\.?$/) { type = "security"; sev = $2; sub(/\/Sec\.?$/, "", sev); pkg = $3 }
            else if ($2 ~ /^(security|bugfix|enhancement|newpackage|unspecified)$/) {
                type = $2
                if (NF >= 5) { sev = $3; pkg = $4 } else { sev = ""; pkg = $3 }
            } else next
            sub(/-[^-]+-[^-]+$/, "", pkg)      # nevra -> name
            print pkg "\t" type "\t" sev
        }' > "$WORK/advisories"

    # Severity rank of a package = highest severity of its security advisories
    awk -F'\t' '
        function rank(s) { return s == "Critical" ? 4 : s == "Important" ? 3 : s == "Moderate" ? 2 : s == "Low" ? 1 : 0 }
        FILENAME == ARGV[1] {
            if ($2 == "security") { sec[$1] = 1; if (rank($3) > r[$1]) { r[$1] = rank($3); sv[$1] = $3 } }
            else if ($2 == "bugfix") bug[$1] = 1
            else if ($2 == "enhancement") enh[$1] = 1
            next
        }
        {
            split($0, f, " "); n = f[1]
            if (n in sec)      tag = "[security]" (sv[n] != "" ? " [" sv[n] "]" : "")
            else if (n in bug) tag = "[bugfix]"
            else if (n in enh) tag = "[enhancement]"
            else               tag = "[update]"
            print tag " " $0
        }' "$WORK/advisories" "$WORK/pending" > "$WORK/list"

    if [ -s "$WORK/list" ]; then
        LIST=$(cat "$WORK/list")
        ALL=$(wc -l < "$WORK/list")
        KERNEL=$(awk '{print $1}' "$WORK/pending" | grep -cE "$KERNEL_RE")
    fi
    SECURITY=$(grep -c '^\[security\]' "$WORK/list")
    CRITICAL=$(grep -c '^\[security\] \[Critical\]' "$WORK/list")
    SEV_CRITICAL=$CRITICAL
    SEV_IMPORTANT=$(grep -c '^\[security\] \[Important\]' "$WORK/list")
    SEV_MODERATE=$(grep -c '^\[security\] \[Moderate\]' "$WORK/list")
    SEV_LOW=$(grep -c '^\[security\] \[Low\]' "$WORK/list")
    BUGFIX=$(grep -c '^\[bugfix\]' "$WORK/list")
    ENHANCEMENT=$(grep -c '^\[enhancement\]' "$WORK/list")

    # Version lock (dnf4 / yum / dnf5)
    for f in /etc/dnf/plugins/versionlock.list /etc/yum/pluginconf.d/versionlock.list; do
        [ -f "$f" ] && HELD=$(( HELD + $(grep -cvE '^[[:space:]]*(#|$)' "$f") ))
    done
    [ -f /etc/dnf/versionlock.toml ] && HELD=$(( HELD + $(grep -c '^\[\[packages\]\]' /etc/dnf/versionlock.toml) ))

    # needs-restarting -r: exit 1 = reboot required (dnf-utils / yum-utils)
    NR=""
    if command -v needs-restarting >/dev/null 2>&1; then
        NR=$(LANG=C needs-restarting -r 2>/dev/null); [ $? -eq 1 ] && REBOOT=1
    elif [ "$PKGMGR" = "dnf" ]; then
        NR=$(LANG=C dnf -q needs-restarting -r 2>/dev/null); [ $? -eq 1 ] && REBOOT=1
    fi
    if [ "$REBOOT" -eq 1 ]; then
        REBOOT_REASON=$(printf '%s\n' "$NR" | sed -n 's/^ *\* *//p' | tr '\n' ' ')
        REBOOT_REASON="Updated: ${REBOOT_REASON:-see needs-restarting -r}"
    fi

    # dnf-automatic / yum-cron: 1 = security updates only (upgrade_type / update_cmd security), 2 = all updates
    OSAUTO=0
    for t in dnf-automatic-install.timer; do
        systemctl is-enabled -q "$t" 2>/dev/null && OSAUTO=1
    done
    for t in dnf-automatic.timer dnf5-automatic.timer; do
        systemctl is-enabled -q "$t" 2>/dev/null \
            && grep -qE '^[[:space:]]*apply_updates[[:space:]]*=[[:space:]]*(yes|true|1)' /etc/dnf/automatic.conf 2>/dev/null \
            && OSAUTO=1
    done
    if [ "$OSAUTO" -eq 1 ]; then
        AUTOUPDATE=2; AUTODETAIL="dnf-automatic: all updates"
        grep -qE '^[[:space:]]*upgrade_type[[:space:]]*=[[:space:]]*security' /etc/dnf/automatic.conf 2>/dev/null \
            && { AUTOUPDATE=1; AUTODETAIL="dnf-automatic: security updates only (upgrade_type = security)"; }
    fi
    if systemctl is-enabled -q yum-cron 2>/dev/null \
       && grep -qE '^[[:space:]]*apply_updates[[:space:]]*=[[:space:]]*yes' /etc/yum/yum-cron.conf 2>/dev/null; then
        AUTOUPDATE=2; AUTODETAIL="yum-cron: all updates"
        grep -qE '^[[:space:]]*update_cmd[[:space:]]*=[[:space:]]*(security|minimal-security)' /etc/yum/yum-cron.conf 2>/dev/null \
            && { AUTOUPDATE=1; AUTODETAIL="yum-cron: security updates only (update_cmd = security)"; }
    fi

    # History from the rpm database (install time of the packages), newest first
    rpm -qa --qf '%{INSTALLTIME} %{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null \
        | sort -rn | head -n "$HISTORY_LINES" > "$WORK/hist"
    if [ -s "$WORK/hist" ]; then
        LASTUPDATE=$(head -n 1 "$WORK/hist" | cut -d' ' -f1)
        HISTORY=$(while read -r ts name ver; do
            printf '%s  Installed  %s %s\n' "$(date -d "@$ts" '+%Y-%m-%d %H:%M')" "$name" "$ver"
        done < "$WORK/hist")
    fi
else
    RESULT="ERROR: no supported package manager found (apt, dnf, yum)"
fi

# Reboot fallback for both families: the newest installed kernel is not the running one
if [ "$REBOOT" -eq 0 ]; then
    NEWEST=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | grep -v rescue | sort -V | tail -n 1)
    if [ -n "$NEWEST" ] && [ "$NEWEST" != "$OS_VERSION" ]; then
        REBOOT=1
        REBOOT_REASON="Running kernel $OS_VERSION, newest installed kernel $NEWEST"
    fi
fi

# Pending updates matching EXCLUDE: counted and marked in the list (they stay in the counts)
EXCLUDED=0
if [ ${#EXCL[@]} -gt 0 ] && [ -n "$LIST" ]; then
    LIST=$(set -f
        while IFS= read -r line; do
            name=""
            for tok in $line; do case "$tok" in \[*) ;; *) name=${tok%%:*}; break ;; esac; done
            if [ -n "$name" ] && is_excluded "$name"; then echo "$line (excluded)"; else echo "$line"; fi
        done <<< "$LIST")
    EXCLUDED=$(printf '%s\n' "$LIST" | grep -c ' (excluded)$')
fi

[ -z "$LIST" ] && LIST="No pending updates"
[ -z "$HISTORY" ] && HISTORY="No update history found"
[ -z "$REBOOT_REASON" ] && REBOOT_REASON="-"
CHECK_OK=1
case "$RESULT" in ERROR*) CHECK_OK=0 ;; esac

{
    echo "- patch.os Linux"
    echo "- patch.os.name $(q "$OS_NAME")"
    echo "- patch.os.version $(q "$OS_VERSION")"
    echo "- patch.script.version $SCRIPT_VERSION"
    echo "- patch.source $PKGMGR"
    [ -n "$REPO" ] && echo "- patch.source.available $REPO"
    echo "- patch.check.timestamp $(date +%s)"
    echo "- patch.check.duration $(( $(date +%s) - START ))"
    echo "- patch.check.result $(q "$RESULT")"
    echo "- patch.reboot.required $REBOOT"
    [ -n "$LASTBOOT" ] && echo "- patch.lastboot $LASTBOOT"
    # Automatic updates: 0 disabled, 1 OS security only, 2 OS all updates, 3 patch management
    # (a maintenance window is set - this script installs the updates in it), 4 OS + patch management,
    # 5 Azure Update Manager (Arc scheduled patching), 6 Azure Update Manager + patch management
    if [ "$AUTO_UPDATE" -eq 1 ]; then
        if [ "$AUTOUPDATE" -gt 0 ]; then AUTOUPDATE=4; else AUTOUPDATE=3; fi
        AUTODETAIL="Patch management (maintenance window '$MAINTENANCE_WINDOW'); $AUTODETAIL"
    fi
    azure_detect
    if [ "$AZURE" -eq 1 ]; then
        if [ "$AUTO_UPDATE" -eq 1 ]; then AUTOUPDATE=6; else AUTOUPDATE=5; fi
    fi
    [ -n "$AZDETAIL" ] && AUTODETAIL="$AZDETAIL; $AUTODETAIL"
    echo "- patch.autoupdate $AUTOUPDATE"
    echo "- patch.autoupdate.detail $(q "$AUTODETAIL")"
    echo "- patch.autoupdate.config $AUTO_UPDATE"
    echo "- patch.config.override $(q "$CONFIG_SUMMARY")"
    echo "- patch.reboot.allowed $REBOOT_ALLOWED"
    echo "- patch.maintenance.window $(q "${MAINTENANCE_WINDOW:--}${MAINT_ERROR:+ ($MAINT_ERROR)}")"
    [ -n "$MAINT_NEXT" ] && echo "- patch.maintenance.next $MAINT_NEXT"
    echo "- patch.exclude $(q "${EXCLUDE:--}")"
    if [ -n "$LASTUPDATE" ]; then
        echo "- patch.lastupdate.timestamp $LASTUPDATE"
        echo "- patch.lastupdate.patchday $(patchday "$LASTUPDATE")"
    fi
    if [ "$CHECK_OK" -eq 1 ]; then
        echo "- patch.updates.all $ALL"
        echo "- patch.updates.security $SECURITY"
        echo "- patch.updates.kernel $KERNEL"
        echo "- patch.updates.held $HELD"
        echo "- patch.updates.excluded $EXCLUDED"
        [ -n "$CRITICAL" ]      && echo "- patch.updates.critical $CRITICAL"
        [ -n "$BUGFIX" ]        && echo "- patch.updates.bugfix $BUGFIX"
        [ -n "$ENHANCEMENT" ]   && echo "- patch.updates.enhancement $ENHANCEMENT"
        [ -n "$SEV_CRITICAL" ]  && echo "- patch.updates.severity.critical $SEV_CRITICAL"
        [ -n "$SEV_IMPORTANT" ] && echo "- patch.updates.severity.important $SEV_IMPORTANT"
        [ -n "$SEV_MODERATE" ]  && echo "- patch.updates.severity.moderate $SEV_MODERATE"
        [ -n "$SEV_LOW" ]       && echo "- patch.updates.severity.low $SEV_LOW"
        # Windows only categories
        for k in definition servicepacks updaterollups drivers upgrades; do
            echo "- patch.updates.$k 0"
        done
    fi
} > "$WORK/values"
send -i "$WORK/values"

# Multi-line text values are sent separately
send -k patch.reboot.reason -o "$REBOOT_REASON"
send -k patch.history -o "$HISTORY"
[ "$CHECK_OK" -eq 1 ] && send -k patch.updates.list -o "$LIST"

echo "$OS_NAME: pending $ALL (security $SECURITY, critical ${CRITICAL:-n/a}, kernel $KERNEL, excluded $EXCLUDED), reboot required: $REBOOT, result: $RESULT"
echo "Maintenance window: ${MAINTENANCE_WINDOW:--}${MAINT_NEXT:+ (next $(date -d "@$MAINT_NEXT" '+%Y-%m-%d %H:%M'))}, exclude: ${EXCLUDE:--}, reboot allowed: $REBOOT_ALLOWED, auto update: $AUTO_UPDATE$( [ "$AUTO_UPDATE_OFF" -eq 1 ] && echo " (blocked by AUTO_UPDATE=false)")${MACRO_KEYS:+, from host macros: $MACRO_KEYS}"
exit 0
