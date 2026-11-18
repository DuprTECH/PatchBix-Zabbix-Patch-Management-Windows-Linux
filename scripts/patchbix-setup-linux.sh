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

# Embedded check script: patchbix-linux.sh from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux 30ee778 (embed-check.sh)
CHECK_B64='
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
ekqamQwBAA==
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
