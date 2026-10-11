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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux b0c12ff (embed-check.sh)
CHECK_B64='
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
j6Sb9CvfpQ0eYAc5j8f/APgb7ao+ywAA
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
