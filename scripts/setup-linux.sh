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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux 2743b7c (embed-check.sh)
CHECK_B64='
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
SevmX82RFXiAFeRAw/8FDaLmt927AAA=
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
