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
#                without EXCLUDE packages, reboot when needed and REBOOT="yes", result to Zabbix
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
            ask "Reboot after updates when needed (yes/no)" "$reboot"; reboot=$REPLY
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

# Reboot after updates when needed: yes / no (no = the reboot is only reported to Zabbix; default: yes)
$(setting REBOOT "$reboot" no)
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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux f4e8a9d (embed-check.sh)
CHECK_B64='
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
HDT4vwOchgVoqQAA
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
