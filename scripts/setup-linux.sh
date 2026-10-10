#!/bin/bash
# setup-linux.sh - Zabbix patch management on a Linux server without Ansible: setup, check, updates
#
# Paste the whole file into a root shell (sudo -i), or run it as a file: sudo bash setup-linux.sh
# or straight from GitHub (no terminal = menu choice 1, settings kept / defaults):
#   curl -fsSL https://raw.githubusercontent.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux/main/scripts/setup-linux.sh | sudo bash
# A menu asks what to do (or MODE=update bash setup-linux.sh):
#   1 monitor  = like ansible/check-linux.yml: checker zbx-patch-linux.sh, zabbix-sender, cron (check every
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
    [ -z "$win" ] && win=any
    auto=$(cur AUTO_UPDATE)        || auto=$UNSET
    excl=$(cur EXCLUDE)            || excl=$UNSET
    [ -z "$excl" ] && excl=$UNSET
    reboot=$(cur REBOOT)           || reboot=$UNSET
    keep=n
    if [ -f "$CONF" ]; then
        echo "Patch settings $CONF:"
        printf '  MAINTENANCE_WINDOW: %s\n  AUTO_UPDATE:        %s\n  EXCLUDE:            %s\n  REBOOT:             %s\n' "$win" "$auto" "$excl" "$reboot"
        ask "Keep them? (y/n)" y; keep=$REPLY
    fi
    case "$keep" in
        [Yy]*) ;;
        *)
            echo "Enter = keep the shown value, - = not set (commented out). Nothing set = check only, no automatic updates."
            echo "Maintenance window: '<day> <HH:MM>-<HH:MM>', several separated by commas; day 1-7 = Monday-Sunday"
            echo "  (or Mon..Sun), 1-5, * = every day, 2.3 = 2nd Wednesday; any = any time. Example: 3 03:00-05:00 = Wednesday"
            ask "Maintenance window" "$win"; win=$REPLY
            ask "Automatic updates in the maintenance window (true/false)" "$auto"; auto=$REPLY
            ask "Excluded packages, comma separated, wildcards allowed" "$excl"; excl=$REPLY
            ask "Reboot after updates when needed (true/false)" "$reboot"; reboot=$REPLY
            ;;
    esac
    # KEY="value" when set, otherwise the commented example
    setting() { case "$2" in "$UNSET"|-|"") echo "#$1=\"$3\"" ;; *) echo "$1=\"$2\"" ;; esac; }
    [ "$win" = any ] && win_line='MAINTENANCE_WINDOW=""' || win_line=$(setting MAINTENANCE_WINDOW "$win" "3 03:00-05:00")
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<EOF
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-linux.sh (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-linux.sh (update). Written by setup-linux.sh -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {\$PATCH.CONF.*} win over this file (zbx-patch-from-zbx-host-macro.cache).
#
# Maintenance window - when updates may be installed and the host rebooted (default: any time).
#   "<day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   empty = any time
#   MAINTENANCE_WINDOW="3 03:00-05:00"   = every Wednesday 03:00-05:00
$win_line

# Automatic updates: true = the checker installs the updates itself in the maintenance window
# (cron every 15 min, once per window, log /var/log/zbx-patch-update.log); false = check only (default)
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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux d8e0212 (embed-check.sh)
CHECK_B64='
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
PY+FJqoAAA==
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
