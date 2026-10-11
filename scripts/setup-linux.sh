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
    [ -z "$win" ] && win=$UNSET
    excl=$(cur EXCLUDE)            || excl=$UNSET
    [ -z "$excl" ] && excl=$UNSET
    reboot=$(cur REBOOT)           || reboot=$UNSET
    # Legacy AUTO_UPDATE="false" of older installs blocks the automatic updates - kept until it is removed
    blocked=n
    case "$(cur AUTO_UPDATE | tr '[:upper:]' '[:lower:]')" in no|false|0|off) blocked=y ;; esac
    keep=n
    if [ -f "$CONF" ]; then
        echo "Patch settings $CONF:"
        printf '  MAINTENANCE_WINDOW: %s\n  EXCLUDE:            %s\n  REBOOT:             %s\n' "$win" "$excl" "$reboot"
        [ "$blocked" = y ] && echo '  AUTO_UPDATE="false" (older install): the automatic updates are blocked'
        ask "Keep them? (y/n)" y; keep=$REPLY
    fi
    case "$keep" in
        [Yy]*) ;;
        *)
            echo "Enter = keep the shown value, - = not set (commented out). No maintenance window = check only, no automatic updates."
            echo "Maintenance window = when and which updates are installed automatically: '[<types>] <day> <HH:MM>-<HH:MM>',"
            echo "  several separated by commas. Types: * = all (also without types), crit = critical (dnf / yum only),"
            echo "  sec = security, kernel = kernel packages; several joined with +. Day: 1-7 = Monday-Sunday (or Mon..Sun),"
            echo "  1-5, * = every day, 2.3 = 2nd Wednesday. Examples: * 3 03:00-05:00 = everything on Wednesday,"
            echo "  crit+sec * 02:00-03:00 = critical and security updates every night"
            ask "Maintenance window" "$win"; win=$REPLY
            if [ "$blocked" = y ]; then
                ask "Keep the automatic updates blocked (AUTO_UPDATE=\"false\")? (y/n)" y
                case "$REPLY" in [Yy]*) ;; *) blocked=n ;; esac
            fi
            ask "Excluded packages, comma separated, wildcards allowed" "$excl"; excl=$REPLY
            ask "Reboot after updates when needed (true/false)" "$reboot"; reboot=$REPLY
            ;;
    esac
    # KEY="value" when set, otherwise the commented example
    setting() { case "$2" in "$UNSET"|-|"") echo "#$1=\"$3\"" ;; *) echo "$1=\"$2\"" ;; esac; }
    if [ "$blocked" = y ]; then
        auto_section='
# Legacy (older install): AUTO_UPDATE="false" blocks the automatic updates in the maintenance window.
# Remove the line to install the updates in the window.
AUTO_UPDATE="false"
'
    else auto_section=""; fi
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<EOF
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-linux.sh (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-linux.sh (update). Written by setup-linux.sh -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {\$PATCH.CONF.*} win over this file (zbx-patch-from-zbx-host-macro.cache).
#
# Maintenance window - when and which updates the checker installs itself (cron every 15 min, once
# per window, log /var/log/zbx-patch-update.log). No window = check only, no automatic updates.
#   "[<types>] <day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   types: * = all updates (also without types), crit = critical (dnf / yum severity Critical; apt has no
#          severity), sec = security, kernel = kernel packages; several joined with +, for example crit+sec
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   MAINTENANCE_WINDOW="* 3 03:00-05:00"                         = all updates every Wednesday 03:00-05:00
#   MAINTENANCE_WINDOW="crit+sec * 02:00-03:00, * 6 03:00-06:00"  = critical + security every night, all on Saturday
$(setting MAINTENANCE_WINDOW "$win" "* 3 03:00-05:00")
$auto_section
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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux b784543 (embed-check.sh)
CHECK_B64='
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
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
