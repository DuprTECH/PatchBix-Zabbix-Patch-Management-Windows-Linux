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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux f5829c8 (embed-check.sh)
CHECK_B64='
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
H0k36Ve+Sxs8wA5yHo//AXOuopk+ywAA
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
