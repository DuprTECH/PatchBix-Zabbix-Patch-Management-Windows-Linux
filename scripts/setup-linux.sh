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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux 33d9103 (embed-check.sh)
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
