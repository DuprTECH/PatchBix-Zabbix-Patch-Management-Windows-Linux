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
        # fresh package lists, without the recommended packages (exim4 - a mail server)
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends debsecan >/dev/null 2>&1 \
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
            echo "  1-5 or Mon-Fri, Tue+Thu = Tuesday and Thursday, * = every day, 2.3 = 2nd Wednesday. Examples: * 3 03:00-05:00 = everything on Wednesday,"
            echo "  crit+sec * 02:00-03:00 = critical and security updates every night, all Tue+Thu 03:00-05:00"
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
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5 or Mon-Fri, * = every day, 2.3 = 2nd Wednesday of the month,
#        several days joined with + (Tue+Thu = Tuesday and Thursday)
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   MAINTENANCE_WINDOW="* 3 03:00-05:00"                         = all updates every Wednesday 03:00-05:00
#   MAINTENANCE_WINDOW="crit+sec * 02:00-03:00, * 6 03:00-06:00"  = critical + security every night, all on Saturday
#   MAINTENANCE_WINDOW="all Tue+Thu 03:00-05:00"                 = all updates on Tuesday and Thursday 03:00-05:00
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

# Embedded check script: patchbix-linux.sh from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux 798a364 (embed-check.sh)
CHECK_B64='
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
SX6lWZsMAQA=
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
