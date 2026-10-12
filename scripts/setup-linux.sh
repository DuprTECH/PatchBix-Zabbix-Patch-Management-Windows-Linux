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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux 99dea19 (embed-check.sh)
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
