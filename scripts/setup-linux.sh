#!/bin/bash
# setup-linux.sh - Zabbix patch management on a Linux server without Ansible: setup, check, updates
#
# Paste the whole file into a root shell (sudo -i), or run it as a file: sudo bash setup-linux.sh
# or straight from GitHub (no terminal = menu choice 1, settings kept / defaults):
#   curl -fsSL https://raw.githubusercontent.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux/main/scripts/setup-linux.sh | sudo bash
# A menu asks what to do (or MODE=update bash setup-linux.sh):
#   1 monitor  = like ansible/check-linux.yml: checker zbx-patch-linux.sh, zabbix-sender, debsecan (Debian), cron (check every
#                12 h and after a reboot, automatic update every 15 min), patch settings /etc/zabbix/zbx-patch.conf,
#                UserParameter patch.config (host macros {$PATCH.CONF.*}), first check. Running it again updates an installed server and keeps the settings.
#   2 check    = run the update check now (pending updates -> Zabbix) and show the patch settings
#   3 update   = install updates now in the maintenance window,
#                without EXCLUDE packages, reboot when needed and REBOOT="true", result to Zabbix
#   4 force    = like 3, also outside the maintenance window
#
# AUTO_UPDATE="false" in zbx-patch.conf (default) = the checker only checks; "true" = it installs the
# updates itself in the maintenance window (once per window, like 3).
#
# The checker zbx-patch-linux.sh is embedded (no internet needed); a copy in /tmp/zbx-patch-linux.sh wins.
# Supported: apt (Debian / Ubuntu), dnf / yum (RHEL / Rocky / Alma / Oracle / CentOS).
# Docs: README.md (https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
(
MODE="${MODE:-}"                  # monitor | check | update | force, empty = menu
INTERVAL_HOURS="${INTERVAL_HOURS:-12}"

CHECK=/usr/local/bin/zbx-patch-linux.sh
CRON=/etc/cron.d/zbx-patch-linux
CONF=/etc/zabbix/zbx-patch.conf

warn() { echo "WARNING: $*" >&2; }

# ask <question> <default> -> REPLY (default without a terminal)
ask() {
    local a=""
    [ -t 0 ] && read -r -p "$1 [$2]: " a
    REPLY="${a:-$2}"
}

# Value from the patch settings JSON (zbx-patch-linux.sh --show-config)
json_get() { printf '%s' "$CFG" | sed -n "s/.*\"$1\": \(\"[^\"]*\"\|[a-z0-9]*\).*/\1/p" | sed 's/^"//; s/"$//'; }

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo -i)." >&2; exit 1; fi
PM=""
for p in apt-get dnf yum; do command -v $p >/dev/null 2>&1 && { PM=$p; break; }; done
[ -n "$PM" ] || { echo "Unsupported package manager (apt, dnf, yum)." >&2; exit 1; }

# ---------------- Checker ----------------
# The checker is embedded before the menu (no internet needed); a newer copy in
# /tmp/zbx-patch-linux.sh is used instead
get_check() {
    local tmp="$CHECK.new" src="embedded"
    if [ -f /tmp/zbx-patch-linux.sh ]; then cp /tmp/zbx-patch-linux.sh "$tmp"; src=/tmp/zbx-patch-linux.sh
    else printf '%s' "$CHECK_B64" | base64 -d 2>/dev/null | gunzip > "$tmp" 2>/dev/null; fi
    if ! grep -q -- '--auto-update' "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "ERROR: the checker ($src) is damaged or old - copy zbx-patch-linux.sh to /tmp/zbx-patch-linux.sh and run again." >&2
        return 1
    fi
    install -m 755 "$tmp" "$CHECK" && rm -f "$tmp"
    echo "Checker: $CHECK ($src)"
}

checker_ok() { [ -x "$CHECK" ] && grep -q -- '--auto-update' "$CHECK"; }

show_config() {
    CFG=$("$CHECK" --show-config)
    local next
    next=$(json_get maintenance_next)
    echo "Maintenance window: $(json_get maintenance_window | sed 's/^$/- (any time)/')$( [ "$(json_get maintenance_active)" = true ] && echo ' - open now')"
    [ -n "$(json_get maintenance_error)" ] && echo "  ERROR: $(json_get maintenance_error)"
    echo "Next window:        $( [ "$next" != null ] && date -d "@$next" '+%Y-%m-%d %H:%M' || echo -)"
    echo "Auto update:        $(json_get auto_update)"
    echo "Excluded:           $(printf '%s' "$CFG" | sed -n 's/.*"exclude": \[\([^]]*\)\].*/\1/p' | tr -d '"' | sed 's/^$/-/')"
    echo "Reboot allowed:     $(json_get reboot_allowed)"
}

# ---------------- 1. Monitor: checker, cron, patch settings ----------------
monitor() {
    echo "=== Update checker for Zabbix"
    get_check || return 1
    if ! command -v zabbix_sender >/dev/null 2>&1; then
        if [ "$PM" = apt-get ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zabbix-sender >/dev/null 2>&1
        else $PM install -y -q zabbix-sender >/dev/null 2>&1; fi
        command -v zabbix_sender >/dev/null 2>&1 || warn "zabbix_sender is not installed - install the package zabbix-sender (Zabbix repository)."
    fi
    # Debian: debsecan for the severity of the security updates (Critical / Important / Low, window type crit)
    if [ "$(. /etc/os-release 2>/dev/null && echo "$ID")" = debian ] && ! command -v debsecan >/dev/null 2>&1; then
        # no daily report mails of its own cron job
        echo "debsecan debsecan/report boolean false" | debconf-set-selections 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq debsecan >/dev/null 2>&1 \
            || warn "debsecan is not installed - the severity (critical updates) stays n/a. Install the package debsecan."
    fi
    # Check every INTERVAL_HOURS (shifted by a per-host offset of -30..+30 min) and after a reboot,
    # automatic update every 15 min (installs only with AUTO_UPDATE="true", in the maintenance window)
    local offset minute shift hours h keep win auto excl reboot
    offset=$(( $(uname -n | cksum | cut -d' ' -f1) % 61 - 30 ))
    minute=$(( (offset + 60) % 60 )); shift=0; [ "$offset" -lt 0 ] && shift=-1
    hours=""
    for (( h = 0; h < 24; h += INTERVAL_HOURS )); do
        hours="${hours:+$hours,}$(( (h + shift + 24) % 24 ))"
    done
    rm -f /etc/cron.d/zbx-patch-linux-afterboot
    cat > "$CRON" <<EOF
# Zabbix patch check (template 'APP Patch management all OS') - installed by setup-linux.sh
# check every $INTERVAL_HOURS h, check after a reboot, automatic update (AUTO_UPDATE="true" in $CONF) every 15 min
$minute $hours * * * root $CHECK >/dev/null 2>&1
@reboot root sleep 300; $CHECK >/dev/null 2>&1
*/15 * * * * root $CHECK --auto-update >>/var/log/zbx-patch-update.log 2>&1
EOF
    chmod 644 "$CRON"
    echo "Cron $CRON: check $minute $hours * * * and after a reboot, auto update every 15 min"
    # Patch settings: only the values that are set are written, the others stay commented out
    # (nothing set = check only: no automatic updates, the defaults apply); the values already in
    # the file are kept, the file is written every time, so new comments / settings are added
    cur() { [ -f "$CONF" ] && grep -qE "^[[:space:]]*$1[[:space:]]*=" "$CONF" || return 1
            sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$CONF" | tail -n 1 | sed 's/[[:space:]]*$//'; }
    UNSET="(not set)"
    win=$(cur MAINTENANCE_WINDOW)  || win=$UNSET
    [ -z "$win" ] && win=$UNSET
    excl=$(cur EXCLUDE)            || excl=$UNSET
    [ -z "$excl" ] && excl=$UNSET
    reboot=$(cur REBOOT)           || reboot=$UNSET
    auto=$(cur AUTO_UPDATE)        || auto=$UNSET
    keep=n
    if [ -f "$CONF" ]; then
        echo "Patch settings $CONF:"
        printf '  MAINTENANCE_WINDOW: %s\n  AUTO_UPDATE:        %s\n  EXCLUDE:            %s\n  REBOOT:             %s\n' "$win" "$auto" "$excl" "$reboot"
        ask "Keep them? (y/n)" y; keep=$REPLY
    fi
    case "$keep" in
        [Yy]*) ;;
        *)
            echo "Enter = keep the shown value, - = not set (commented out). Automatic updates need a window and AUTO_UPDATE=true."
            echo "Maintenance window = when and which updates are installed automatically: '[<types>] <day> <HH:MM>-<HH:MM>',"
            echo "  several separated by commas. Types: * = all (also without types), crit = critical (dnf / yum only),"
            echo "  sec = security, kernel = kernel packages; several joined with +. Day: 1-7 = Monday-Sunday (or Mon..Sun),"
            echo "  1-5, * = every day, 2.3 = 2nd Wednesday. Examples: * 3 03:00-05:00 = everything on Wednesday,"
            echo "  crit+sec * 02:00-03:00 = critical and security updates every night"
            ask "Maintenance window" "$win"; win=$REPLY
            ask "Automatic updates in the window (true/false, not set = false)" "$auto"; auto=$REPLY
            ask "Excluded packages, comma separated, wildcards allowed" "$excl"; excl=$REPLY
            ask "Reboot after updates when needed (true/false)" "$reboot"; reboot=$REPLY
            ;;
    esac
    # KEY="value" when set, otherwise the commented example
    setting() { case "$2" in "$UNSET"|-|"") echo "#$1=\"$3\"" ;; *) echo "$1=\"$2\"" ;; esac; }
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<EOF
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-linux.sh (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-linux.sh (update). Written by setup-linux.sh -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {\$PATCH.CONF.*} win over this file (zbx-patch-from-zbx-host-macro.cache).
#
# Maintenance window - when and which updates the checker installs itself (with AUTO_UPDATE="true").
#   "[<types>] <day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   types: * = all updates (also without types), crit = critical (dnf / yum severity Critical; Debian: CVEs
#          of high urgency by debsecan; Ubuntu: nothing), sec = security, kernel = kernel packages; several joined with +, for example crit+sec
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   MAINTENANCE_WINDOW="* 3 03:00-05:00"                         = all updates every Wednesday 03:00-05:00
#   MAINTENANCE_WINDOW="crit+sec * 02:00-03:00, * 6 03:00-06:00"  = critical + security every night, all on Saturday
$(setting MAINTENANCE_WINDOW "$win" "* 3 03:00-05:00")

# Automatic updates: true = the checker installs the update types of the window itself in it (cron every
# 15 min, once per window, log /var/log/zbx-patch-update.log); false = check only (default) - the windows
# can be set first and the automatic updates turned on later
$(setting AUTO_UPDATE "$auto" true)
# Updates that are not installed, separated by commas: package names, wildcards allowed (default: none)
$(setting EXCLUDE "$excl" "kernel*, docker-ce")

# Reboot after updates when needed: true / false (false = the reboot is only reported to Zabbix; default: true)
$(setting REBOOT "$reboot" false)
EOF
    chmod 644 "$CONF"
    echo "Saved $CONF"
    # Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} -> zbx-patch-from-zbx-host-macro.cache),
    # the agent is restarted only when its config changed (undone when it doesn't start)
    echo "=== Zabbix agent: UserParameter patch.config (settings from the host macros)"
    "$CHECK" --install-agent-config || warn "UserParameter not installed - the host macros {\$PATCH.CONF.*} don't apply on this host"
    run_check
}

# ---------------- 2. Check now ----------------
run_check() {
    checker_ok || { echo "The checker is not installed (or old) - choose 1 (monitor) first." >&2; return 1; }
    echo "=== Patch settings"
    show_config
    echo "=== Update check (sends to Zabbix)"
    "$CHECK"
}

# ---------------- 3. / 4. Install updates now (the checker does it: --update [--force]) ----------------
update() {
    if ! checker_ok; then
        echo "The update checker is not installed (or old) - installing it first."
        monitor || return 1
    fi
    echo "=== Patch settings"
    show_config
    if [ "$1" = 1 ]; then "$CHECK" --update --force; else "$CHECK" --update; fi
}

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux f2e60c3 (embed-check.sh)
CHECK_B64='
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
dtoWuId5c0Se/wfDL41e4tkAAA==
'
#
# ---------------- Menu ----------------
if [ -z "$MODE" ]; then
    echo "Zabbix patch management - $(uname -n)"
    echo "  1) monitor - install / update the checker for Zabbix (cron, zbx-patch.conf incl. AUTO_UPDATE)"
    echo "  2) check   - run the update check now"
    echo "  3) update  - install updates (only in the maintenance window)"
    echo "  4) force   - install updates now (also outside the maintenance window)"
    ask "Choose" 1
    MODE=$REPLY
fi
case "$MODE" in
    1|monitor) monitor ;;
    2|check)   run_check ;;
    3|update)  update 0 ;;
    4|force)   update 1 ;;
    *) echo "Unknown choice: $MODE" >&2; exit 1 ;;
esac
)
