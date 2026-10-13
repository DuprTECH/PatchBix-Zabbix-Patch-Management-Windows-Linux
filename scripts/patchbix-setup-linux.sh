#!/bin/bash
# patchbix-setup-linux.sh - Zabbix patch management on a Linux server without Ansible: setup, check, updates
#
# Paste the whole file into a root shell (sudo -i), or run it as a file: sudo bash patchbix-setup-linux.sh
# or straight from GitHub (no terminal = menu choice 1, settings kept / defaults):
#   curl -fsSL https://raw.githubusercontent.com/DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux/main/scripts/patchbix-setup-linux.sh | sudo bash
# A menu asks what to do (or MODE=update bash patchbix-setup-linux.sh):
#   1 monitor  = like ansible/check-linux.yml: checker patchbix-linux.sh, zabbix-sender, debsecan (Debian), cron (check every
#                12 h and after a reboot, automatic update every 15 min), patch settings /etc/zabbix/patchbix.conf,
#                UserParameter patch.config (host macros {$PATCH.CONF.*}), first check. Running it again updates an installed server and keeps the settings.
#   2 check    = run the update check now (pending updates -> Zabbix) and show the patch settings
#   3 update   = install updates now in the maintenance window,
#                without EXCLUDE packages, reboot when needed and REBOOT="true", result to Zabbix
#   4 force    = like 3, also outside the maintenance window
#
# AUTO_UPDATE="false" in patchbix.conf (default) = the checker only checks; "true" = it installs the
# updates itself in the maintenance window (once per window, like 3).
#
# The checker patchbix-linux.sh is embedded (no internet needed); a copy in /tmp/patchbix-linux.sh wins.
# Supported: apt (Debian / Ubuntu), dnf / yum (RHEL / Rocky / Alma / Oracle / CentOS).
# Docs: README.md (https://github.com/DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
(
MODE="${MODE:-}"                  # monitor | check | update | force, empty = menu
INTERVAL_HOURS="${INTERVAL_HOURS:-12}"

CHECK=/usr/local/bin/patchbix-linux.sh
CRON=/etc/cron.d/patchbix
CONF=/etc/zabbix/patchbix.conf

warn() { echo "WARNING: $*" >&2; }

# ask <question> <default> -> REPLY (default without a terminal)
ask() {
    local a=""
    [ -t 0 ] && read -r -p "$1 [$2]: " a
    REPLY="${a:-$2}"
}

# Value from the patch settings JSON (patchbix-linux.sh --show-config)
json_get() { printf '%s' "$CFG" | sed -n "s/.*\"$1\": \(\"[^\"]*\"\|[a-z0-9]*\).*/\1/p" | sed 's/^"//; s/"$//'; }

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo -i)." >&2; exit 1; fi
PM=""
for p in apt-get dnf yum; do command -v $p >/dev/null 2>&1 && { PM=$p; break; }; done
[ -n "$PM" ] || { echo "Unsupported package manager (apt, dnf, yum)." >&2; exit 1; }

# ---------------- Checker ----------------
# The checker is embedded before the menu (no internet needed); a newer copy in
# /tmp/patchbix-linux.sh is used instead
get_check() {
    local tmp="$CHECK.new" src="embedded"
    if [ -f /tmp/patchbix-linux.sh ]; then cp /tmp/patchbix-linux.sh "$tmp"; src=/tmp/patchbix-linux.sh
    else printf '%s' "$CHECK_B64" | base64 -d 2>/dev/null | gunzip > "$tmp" 2>/dev/null; fi
    if ! grep -q -- '--auto-update' "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "ERROR: the checker ($src) is damaged or old - copy patchbix-linux.sh to /tmp/patchbix-linux.sh and run again." >&2
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
    # A run of the checker moves the settings of an older version (zbx-patch.conf) to the PatchBix names
    "$CHECK" --show-config >/dev/null 2>&1
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
    rm -f /etc/cron.d/zbx-patch-afterboot /etc/cron.d/zbx-patch-linux   # older versions
    cat > "$CRON" <<EOF
# PatchBix check (template 'PatchBix - Patch management all OS') - installed by patchbix-setup-linux.sh
# check every $INTERVAL_HOURS h, check after a reboot, automatic update (AUTO_UPDATE="true" in $CONF) every 15 min
$minute $hours * * * root $CHECK >/dev/null 2>&1
@reboot root sleep 300; $CHECK >/dev/null 2>&1
*/15 * * * * root $CHECK --auto-update >>/var/log/patchbix-update.log 2>&1
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
# patchbix.conf - patch management settings of this host
# Read by the checker patchbix-linux.sh (sent to Zabbix, template 'PatchBix - Patch management all OS')
# and by patchbix-setup-linux.sh (update). Written by patchbix-setup-linux.sh -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {\$PATCH.CONF.*} win over this file (patchbix-from-zbx-host-macro.cache).
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
# 15 min, once per window, log /var/log/patchbix-update.log); false = check only (default) - the windows
# can be set first and the automatic updates turned on later
$(setting AUTO_UPDATE "$auto" true)
# Updates that are not installed, separated by commas: package names, wildcards allowed (default: none)
$(setting EXCLUDE "$excl" "kernel*, docker-ce")

# Reboot after updates when needed: true / false (false = the reboot is only reported to Zabbix; default: true)
$(setting REBOOT "$reboot" false)
EOF
    chmod 644 "$CONF"
    echo "Saved $CONF"
    # Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} -> patchbix-from-zbx-host-macro.cache),
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

# Embedded check script: patchbix-linux.sh from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux f9de157 (embed-check.sh)
CHECK_B64='
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
JHiEfjMWzP8AZmBHdd3jAAA=
'
#
# ---------------- Menu ----------------
if [ -z "$MODE" ]; then
    echo "Zabbix patch management - $(uname -n)"
    echo "  1) monitor - install / update the checker for Zabbix (cron, patchbix.conf incl. AUTO_UPDATE)"
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
