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

# Embedded check script: patchbix-linux.sh from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux cd6cefe (embed-check.sh)
CHECK_B64='
H4sIAAAAAAACA6xcfVfbxtL/359iryC1ZCQZk5u0R8Q5pUBveBpCHiDNbQmXI9trrBtbcrUShALf
/ZmZ3ZV2ZZmkzynpAb3szu7O6292Vt34R3+UpP1RLGadDRb8jT9AbhkX49ko+RLMk7T8EtIQ+zM+
/izYkqeTJL2GJuPP8TVn5XISF1ywLGVvsTGL0wkT0EiwYsZZzkU5L1iRsd/jEVBkt0mB1P6kuyts
yHMf32PrkzOWwAMcg6fQiy+Wc6DOuu9xQj9B94DRJVvEKYy+wFbxfA4du0DU/czvhJx82POJoogX
nNHjWNTLuoVRslsRLsUAJ/5R3nphZwOonJXLZZYX0GNZMPeAj5I4ZX32YVSmRenR+ibpFJ7clQvm
nr45fAvXp9n48x383ZsvYvhzksfjOYeLn/kky/HJPkz15EwN8Ws8LzkyKC7YJEu7BeNfElHUTHQn
fJqkSZFkqQ/czG+SMSeWC19xnOXZfF4u4X6SJzc8Fz7QLZfXeTzhAmaZc5RCgcveDq0BxzEOOOJs
wgueL5KUT5g7Kq+nwN4+4+ksTseSszAd4AFOAAZIijt4AINIRrAsx/eKPSjVrITF8JHgMIAPgl9m
Iimy/I7FN3Eyj0fJHEncznjK0qyA+WeFnCfe4VyBN+ykIknS0wOPswVMf5pni2oI5sKfEt8GBXD7
M8/DCfUMs/zai6h/mV/zdAzzntItrJBPUJV/PRT4LNZa7LNZcj1jQ7YP9JJxPPfZgk8SkO+QHS1Q
G+IU+DDPbuHB2+xWSvG0TFlCHMa1yNmNc2CKm3OY8AK1eOL5bAqs4l9i0GXQCF6M+9gonPS1OkZA
i7Ft1us/Zz36R/T6pcj78wxmQ5a+YpPsdX/Cb/ppCfq/8/q7gVReXhRgnoK5PL1JYBwS5E2cJ/Fo
Doohx/p976efjv59dXb47uDwFO6B9gxt0LJKVv2gNsZgxpHdwDNp7Z+8+5kaAzthxHGWTpNr0gv2
JhNFinbYh+nlING9cQEqS72bPytDEbmdEOlBf/PhRD5MUslU+cqnG7+VtsFQbMP62bJQ3eQDkBOq
iZq7Upq8TFN0eDTmbithrf2glHL1I7ihpav5LvPsy52cLpIE+43ZdYYcT8DPSKZ4tmROfyXJwBTB
B8Rz7T4FtQVOEEnmJqkoeDzByZq8tYi9Pzk9p3lWxFCjsYs9Ws37wfb2i4FF483JWYPGDKTKSKwg
ATU7Zk1Iy32XKcKspPZB2s5F9AwG/2dgWGlWUbHtSD89ghgxFHcw5iKcqWdy4m+Ozs5PTn+7env0
7vAM7tNyMQLOwbzAgMCZJHIw5U1n4H7RVyVAyGDEi21J7P3e+f6bWsdlJAFhKGNTqkIsqTsballZ
LymBR6b63qbh1mP4FZeNIDZNYNnAgkVcmDFLGvTx3tG788N3e+/2D68+Hr07OPk4dMbgy7bAR4I/
2d6JtreD7efw24fbl4wug+2X8NtpFYYSBwa721kC89RxvgBOMQG0ITiirCH6CtRiPp8yNwjissgC
xdPKIapJrv44F6+KuyUXry/Zq0l895q9evMmOj5+Hai/joo9oG6CL+McqE7YiMLBIha7jDpHsCLQ
DIQBQ/y9Ziy9ADeei6wyWaIAPhqZBd3Hyv+DFKsQXwWhOjjIELVmoCpAUUxRIWhXh80Aw90MJO7h
2sYwpg5jPuCUPOW4CnWhopPw1440hcZKE0Ap5nc1v/6bUWAnL7QFFhjfgVkH30P74ywNziB0Ac/g
Mgzh2odXL0AzfLYTPocmOyD2j3wCZgL91o2uR4Imwh6Ouecl3zqflUAKrpAIaRI8yfEGUVAryXNQ
dtQg0PFkXEks5UA5ZhK0EaG9D+cnVx/eH+ydHw6dIi+5Iyke/nv/7YcDeCYZCOuZZIgMgjF3jGE0
XyUe0hBEDgdY6DaZT8ZxDggWtCm7hRhOxE8Pfzo5OVfjsbU/OR9h9I6nAK6qJUjUA+tA+lPQQA6s
QYiEfhjkJkdYXVbrCEUrl5Q/U1xCFKK9Lo1HgGgN29vtX6kVavIIoRgQSnJRkACKMkdxwyiIzwHA
k+sDy8S/cjFyHVfv9/Z/2fsXrCcDVC8EGM88GcHf52ptZB+a+cqRCl6JSOK4lH8pmO1cXEJaqIJ3
f2VVgxcMEK8HegEsCxSxQCczWYowG+R2g3hZuQpwEyKZcIO7/l8Z0XI3hoS9XYz/gC5qFy9Hja/j
BCwS8oc4R3xJXDdZqhWR5Op8RQNtMZiKCKwFFUM9BD8FzW/B1JnSzb+yQKV4JKMFTL3gKWYQWhO1
Gu5CC4QuQ1J4rfwJaQvY/V2dstTJoitzOYMq5nXyIf8ynpcTrm+VGejHE1+nsaFkR6hsWbdHXZJ9
Qok3ZGaXI3YBPcYVqfAGvm3E3L1UJICgPenigkDMsttA9gyroWqizN1mk0Qg6IYhB5jZaj+vHPUO
PgPyPnuu4ISR00Iga+EljNPu/Xz2TzaCsOKzFxC0XrK9P0tg5gc5k2MiCzb6Pbz7gZ3t7x/Lta4w
AhJCyNQg7Z4jvLutXAtKRjEDPbF2PXB7F9pZB4V8LTzyCYsYDFWw+02CNyHCm1AilEfffmosq/lK
+fVHFKr1QprCIwEMcovkTAjEydUpLOl+AOD8HgDEgpO7qlcDsg4CdRtQ90Drwy1IiwuViKKfxpvM
3B7B5QZ/jr4EuNSAlhqO47G2BlBkC/eZGO/qeG//9MQL2RFkALRBATJmGViIMQD18hUCS4SyoDFk
6NcwdYPZtQoqlURCOXitSE9fyqcKePDEZxdnl6BpRKaCr7QIeLWPr6x54AYLmQVxF+w3z8ZcCMyN
0BiIUQvMhsXdYpTNhZ35kkfBAaUqRxJx9TQSfUHQFEeV5hpJTySj+mIJVjPUwAnnHmFmsBIDfe36
DC/nV920Z5Aqe0IIW0hkapkzAoQ8QT80402gD6v7n7OTd4gRJBihbAuGuPWlyJ8KEDQBgaPqifq0
BjV9aZT8C7ClAoko9DFuvGGwzck9qgkrN1P5YOmq6owGcydwvriH1a/3q/wqEimTAiGRO04Q6zOM
0a1Tb/HrOFnZFRSYYDTif5D4GJQO51IJxYyihHoRQLTsDbZvCEi1VgsMe16bkGkyFj6jxCmVvLM4
VsV659Xy8/XrC5/+sDAML9szIY1McKkSm9TOowKSktdqXXoDc5xI73FHs/RsRrSOFa9jtAQRKkG+
Uw5Zy7AFsUasK2FWr+u1KyOaJkhcwS/c+4P5U4jr24wK7xZz2hppIIkRh5EQxNSSvM60h1z9aYhR
yYfSfZQRAiERstMV0UYgOSXwvg2AlFjVS5T6A/mMB/KSrZNo0xxCSZU99VcU5SmYZGKfb7WbRpIs
p6QyBDB9gsmevwYsfWXPTDKGZKuX4dtMs97pJXqKlea8pIbI7UxC2Ro6RxIBtYGQ2om0LRwhd+v8
K+ZX8FuzCl2LeqcTdfCLPL9NgPvoKYUhlXbezLPriPVvYtz5u643URXigWfsJonlLoXigtyx0cHA
eSUn8/rhleGr4U6FE7iSInztrLWzGpnYOMQK2cBYwP+JXCx0oEAsUwIh92EQjrSOUTenTSKXdOZW
+j+CCmCmFNIEO/kFVPzw9PTktJoZxnMdBcFv1VGQHLX2e81IaIB0zGEIRtmcU7YxAh27zrMynbS7
PLK/WM3U2kmT0BECRqZ2TcVslJGXw2iNxlILXwuvDck9KRdYULmENWA1ImLrxaOXI+V4lJLwgcoc
61ffIhUUH6YDOrsgQhjMYMJyN9ZQE+AWwM3KKUwBlgu5a7hXQvzOWcQOSgHG9j5P+HiWTcRn1P+z
rITwCy9nRbEUUb9/DaZajmAJi/5BuczPD/ff9HUtLZDyC+g+OK6Sj0BtKAVUisJySZYWAHQiYME0
+3ECdAoYMxQYWN8mY/BX4CSPj87/7jok0CP/gxvBpIa0gT9K0gh/AUgSs7KAmUKyDDAH4Hf+2Se3
LgLFVURQav9CiU9gTyk10QE0/mZoVAUE0bbKLvK2fkEXQs9h8x5JRFsR5iRvHjv8C/lpvMHZ/wqD
ANyTsq23TV0jP5GPwhvZEvzbb7+Fx8fhwcFFmF4yN0wxFUzJ6WkTqbYLcCcNuKAeJ6rkIJ21bU5y
lM7Z/unR+/OrXw9Pz45O3g2dnZfhYBAOfnA6HasiNHQ2760HUWAVfh6djrW7ju2tB1HwYhsaJVN2
wYI/mbNpFIkcdkmgIe1oMxw3ajj9ttLPmteTp1/Lt586dh2obrxuDIt4s7tVRmoltL7FGpJ2JaqV
5hNNJNFdiLAVWeD7FPg+Bm6z774zi3RDegrPRjmPP1MH9DWdaYJZURVdv1IIAxgzZq/Qsb3GXUCM
xLQpDxEDyyvet8h+PNx0l4IFHFK5/FoM2Y5R0XwAzzxhAZj5IeuK/n8u/sMue+ai3Z2HiUdPWdiD
2TwEOnG/YMPLLRdfbXlhr//peX/ZBXoz3NoBggOvoziUGhz6CsMke95l2m1jhS/WEVDW4rJUWjnG
rkhlOTJy2bU7xU7ZqYpQrizfDX1Vqc7pOADfleTkRnHOLo7e37y8pFvPN0pww7rI2kIe41ONm3QR
LmR7Ks5mKRbqebXxJfvKok5Eex9WoXA42Pk+3IZ/g3CtmBVLjRey77dbv1EzNRXefNxqZnWDtQbx
8ICMgehQ8uq9AGVsaNxFJAAg8+jysieFYz4ZmjegbP5udb+h9G6AekdDPjDaWKuVz1BAsW5G4xiE
Re+T1HIXny56ny6jnteQyua9eAaPH3dXnlv3Gxd1C6wMY7+Njd5l9Mh2d61xelEPR2FNeqKloUcX
qxMy52OM1jKYpy6eGoyLeGzyz1AvLFDbtotPnhSqNpmnxPr/EOq3TErbYN1x1RuD0b7RBt44eQEj
f4asoLL5agvPPHwhnVSiD/wAJMrmdOrCrJ0z95ur6iH7qPaOqnETs2CPTizLKRRU8DjBMyf1jo92
UA3SvtyXBN9Z+aZVx2LwUlnO2sBC+6s/H70lZGK2qpxOkpLbqbQDVUNNetiXEjb7eU1XMoEGQEPN
B66GdN/vOVUraxL1DaN+taDxYgOQLJ/P5UaIqhoMz/Z3tn94Se+vIf9nwewPwbr/0bwfdplJFRzI
Og1DVUIJuB67J3LkMmXIda1Y2HDhDNeGzbaGGO0bLGnpWLl4s+NqCGjrir5hZcxl431bR60WVkfR
eC87GvNAUOvAg3vscfHj5SPe/Oh0HtHq/rfMsA4sq3E6T7TtL0mXZUHq3fkD+SrT6ynrOs+Eg9rj
6gfPBN4OHAVoQNE+fYL/4Nf1LhN9B66d/nXXc3YZDS5PhWDFnA6olSkAhyJZYD6zWNpnYHbCcyxS
YrFeV9lV8IeIXsy8DqUY8Lgh+YnUPlAS2mxAZf4RZ7j1LJhITmFKiYtwmQvmAf6N9dn3bIsNmOeF
m+7b/au9t2+H+6zZP/YUC5u53MphF/s8DGs5g3qCORpTiRH0wDIL9aoOwHl2ccM3Mm46hFrQIRR0
QbRhushueAXJdBIMA6GhCLkD4Kv9W1k3R27JE5j1horc7cP6OqcNrfrs5h0vTNR7X5d6ouCxclzA
1ARYWnoO4N4/2PYKHKIDbdVaiT2RXUSqGbG2/BR9Q4WqkYLUVM3KqE2s+aYFYJlAbvN++gwBQLX4
f8CaV5ogGFAtFjfrCLR2sp0oeWW50ZeM+tVyrLGr13pJ1bgtHVcaoyetpTpsyHjtaa9HZ6VCaiQF
a4ukvUef9owKnlpbRo09xEbhz29uw0HoirG+SDAecwDajxVUaWzU95rFSXuF8lkUgNdIcgouzmb9
1vH6X9c54IQ+/Iye6pfD34YOeVlHHbXo0l0XMx3pfTeYPEhbqELDPJZpEa3Bb26x4dsOLuXqmhcN
p3cDlkW+QMe8ytisZVh3cskOqjmqVw4vp0pViRSEGnxC6KDSws37DXqJUUXbOPbIOR6aYdvU7MYC
pk4DmG4O1kJSACcUt6ohWnCoShxurMThkwMIG4a9v9n45AAmp8tnz+CxBcU/detmXaNZ125GaF29
26hfVfjcjn43FBWKPFlQrJQCgYRrsIu/ISFwMFV4dvEPY6GPOEmbDLRxZPpgtoSGMna2nIHcdHFQ
dLpaK1pOSnoAD/TBsZYOulAKrWQJBWPfycfDg+Ggozi92km29Eg4OeteROVyyfPosovXWKHDaw8F
xNJMla22H7IphMLGINvAW8lX2vu1C96RUUBrnsk0DrfK6qzGBquVGXV8M0llhcmuUHkq+uHe4lcO
4TWOnOHmZH1oavUkmTrO0n6c7ckTZh1j7KuTd8Pt9ZIwT1x9izjuuHigWuLgIUs91hhoUEnDXP12
R2HSVeUyAr9NSsb/gXxtEhvgJxayKmt/YwOO36rA+uR1ZOXFrNzZh9jkqQKqlMmDFYh4sLaGi/T8
qtRGEvMr7BN85ViXhz46zZgr65TByqEuOdrVIpvwyhNrIbVg46+IpXI8lngeUpyIecICcSuuznBV
jvNgm9iDXkHVQ/HA6ESr8tadeFPDNByicvADyxk+dhrnIFtU1G6BjsY+6LfpGsxsVXKrPRBwPEwI
bSrVETJVY9dFibxMI2ASG+rqsavrsVa1Fbna15zqk+h17b1RYq785PEJHsVF9PMLnm9Cu1dAxgA9
HYqxV4AFzmChOsyuxGBpJ+v3ctyLveD3q8stz4qcxobNKkUJgCEtQ5UNSrhaAn6AfEZMAEXV+Zrf
9xlmaHV9jTIzlXZE7Iy5K1gOWLe/kuSQxchjPa785qlQHlJbXbxczhMuPAliRD5ugJjpeuSi4NmZ
jWCifacJ0nOCDwYul7sLfwAMeQqEOEY36HSvc0TA4gTGd5X+YyiucPmjPNu57vwZB1AoAwv6J0HM
jdSptBWW/j1n0sB7r54mo/NWqzEIia8cJaxO1vkATeflIsXyqFElqavUXgclcPSvq7MPx8d7p7+h
KZBc40lzL0YQEHK11MkpwlQbO8QWgrRpbyFWtx9FWz57vNgUl2xzJ2KbzxGD6eFbUJA2baCz+jIK
Ugw1bhuXvMd6WWYgY45xXgK1x/1aFCSNosM2sFi6kTDi6z1Vzr02/BKxLs1fLdM6YVcd6PIg2tSL
0cer1EkPZI16FAWBuWrlONXpIr1SG8h900oNmo3TVo4K7goSkDXaTRpzsk/9ONZpI5KGCsZWOwVI
ITZKjtEUXeOURRfxj46fso08CuUquNCCFKhPTzenyNrVMMqjjPCwOhgZySqi8bWPxkC0S4NwpXHS
jaA75nRHP58Nu35XnuAO8phdodzYq1evYJVKbk4HfedS+s57akA5FGV4yzo2Lw3rWyodQhKU8C2r
hK+TiCt9qrRh0cvKU+vRsH81WOWQ1279vnheO21IKgdsOGSbS3a5mktWuacGIHIL7kBvIa6KJGLP
MRh9xI9RBvKLINw8DMOQ4QdCZyXe4nlFltMpgkGAx8rxu6Gf8wSLiT19Jky2w4+G+vCbCFrfDtkb
krvtXydVnwt5yCqa7hUH8No52ANQ4C6wsAp6eIu7d7OSTfOECQgjoky9DoxxlZaLBvcTE24OSKsv
BsH3l56OWoMqXrE6waqKA9h+G2x1B/j0T/aCvVQ7ACBFnNLFZoJ59xDvB76v46gKibhrmqi90noQ
CIu7rZLaQB5eLWjHCb+BY2LJx6/lJTDvlvPP+N1W/YRY+TqCCVIn/LgA3Jq63oGp0ykyItOpSDf3
/tlohUOVunV7Xc9kTq2HoAeXYc+zNg5j2kYmIRA/Nnrho4SfisSO1RyZuCN9obMZV9kRbTVvPm/u
Nat294Nnz0KJV0zIHXxlKs+C3lNTGa3MPHiqOW3t0pyDOTJtVNWcqkXhqWJjUfJh1diixtFprvaD
wVf67UK2bKcaT6x68Jd4b2cqmHg2NgziymPY31jWh7vXfzgZ1V+8xJObBGB2QpiKjH7lo8pd9VFl
VH2db34+iYmD/q7yWz6lhGHWfkypPpus/w8LgrnmN5QGNtD/P4Z1nsuux/xfcV/f1caR9Pu/PsVk
LFYa0EgIOz67wiIPa5OEYxtzwE42D2COQMLWQW/RSBBHsJ/91lu/To8kO7n3ZjdhNNPvXd1dVV31
K3K45dpKNIKXo/HU35pmaAAOrGD0h/Uy7USzjH7TKbZlnWLAGPMRxluN3qRmcqzMsvyhIst6lrMc
gKX9ALOnzuLNym5woVMZ0JkHGM8H7tADDFciBW+VoQtbtKtuwg94hNOdz3jqW3kBf1qc6hFbIRts
4Mrfl5kdJaKt2se+Qnk2P8cvmG7f5pVaq3yLa3jeoeJ5FOH1NKkbUD4RO0EyymwbFQgUsSvEq/2G
3bWQ1FHLnzFvfbn/8v3hLwfoBtaAPa0mb0/f75+AhO2YfJK9tPBKSLic8v1vxwcgWYY0eFaGapbo
so8O/uMXbbukmKvERBRvnI2MgUvm1NX0avejDQeY1QOg312rVusnlWb9pm6g5GMZRxSy6Q5bwyvj
PrppRjc70c1TWGYzWA94rglbwoOCiokrpMtuxFbmQ5yr7SiLQCyEZdKdyGTCLLtLju5BsLyMU2QR
wdbcc7ndCb6yckx77crH6tl28+KHs+30XxcPO/Dn6UXSgndwMNK7JF2VoFwx69zmVqkxvNID46OX
/b0se0yeX/hSmj9mXOx97Fup3DRl4HO2R+Ye8+apOedoYNq0beCwtaGAXZ4LeDRnDZ1tnBY4ar0R
coV0PPFHpBIpZ8eU8xTPO5s/Xu1mnpCfhO37TJoFXgRDXRbPKMgKu8RSEyUBV725hVw1tCq393IG
GT5Mbo9gefGEv/sXPdSl2CTFaesqKcBkYaHDMH9xuQuiRjNqouRR/oFK3HFKtBhId45oODX7QK+o
tfoNVk2kIK++owHgVdT+Lzz1YAisi2iPTqylLQTjLHbFcgZuFipapLqPk0rsnjA+0VnTTuuxjVxh
c/tJefHv/dOfQUR9i3qtsyYM92b0fBt5xNzHHfiYGAYJFnRBKU+XlfLMLWXZDDpdos2EhMQuSYm8
ldALniNkJGiroXf0iO9w36E38BCbevV06wfY7JTZxtYGarNw5zNvfjRXm11l3/R7lDaj5ztJcKNw
dkymc2MUUqZttdzFr3FU2dqYRxvwfiNDLYlnxWgOA4v9xVKRvZ2FEhiDN0fughH+joYxPML2ellw
OpbGoLbxPf8ZxkF7SmXlWeXebslMnPUvmBBQXOvZ33FWrK85XrqnuPRMsSWUGyYi+ufzZ9u5PCJB
jLCdzPNn1mDx68GMCw6txtyhDFvFwl2jdDpbgkSminQ/gzRqVjGf6OWsoC4+wb2NfGF9A07P+gUc
34LJnifGHQJriVsjkikioTEQYdrpl6KbcLfkK8nYdFBZrEk5c84Td0k9WnxPqUT3FaSJ2Y1+fHfy
krie//33fy5/2X/zgbiY3ej49U+nqG26/4wGB7CJPqGmkx2PkGpQqHY8jK2LJaqT3JksDlhfwPgT
gomFIwwk1+58+eSqQ0AxzHlEtqJsokSMnfRR+ki70eJyQqsQd63P/ZuZWynrEv022nc//sUVlU8M
gLo+oBOkVezFGUd7/wDegJyimzS/gYY4l9XuYJEK2klMDsq5mz0ZHTepa0fjlMufXOpQwxdoYRhf
gFuIr8iuy8lheeLlqAU+iWeGb3ZBVZeItGc3ZGtxxpS4Wvcs5oc5w721DJequcEKGPSdzLUhkxSx
0ieyhlc3ZMgAScQEUxA48K04RzKfBzUswZp4KISaeAgiTTyEYCagCve9q4F/DH6UvHxPRfZLs/ux
wDwS9A9iN/zqQk1UR8jD4kVVomAnIv+qz7NKVC5f3V0Pc6KPOhcHOKIeHQrHxgPYsu9CxOSspl1D
o08o1KqVijJzXW71ePpgQV31QWzajIBHiMrRbvQQsXypvdamnWuYWQ1RJNNW/TDKOjc9Z/az9jYq
c8YMy6B0T77aSSQ/rIMhrbQy2sGfQ6yAGC+uYrru06YO9i0W1aME+F111dOKNiCLumtwSqGBKok1
MFOpp+G5jzrAAyD2UzSfigSGzAgOFgJ9wPHBEHTKEo125Ae9IQcL4A26yXzXfdtmq3dJBSi/O7Fw
MfK7h7+n5vcUf8+tq445MapzK8l8Koc2CxgjqiXHkMgpt7gnBThdG416D50RUOw9qrdspboUxlLH
PUocH1EY3k//t5P+eR7Va62t9GKzrGUQ93BQ4sXiPLCuQcK4r1iXz9ZRH7IHu9+17xdcSWqUk3RC
rQm2ohU5OYPNwamHUzVgf7bL5IBHbqDN5zD857FMiZRnGtwpnpmOzIzDcXnmTUA6dBR4mjnfJq3T
5lu+vAJvjZmyN1uYrk6FbY+ihrr01ErIIk8fGToXPEuPmW08BYPVKR6sAF9Nlzo9Gqk2kbDi5C0B
XpNuL0+6l1ut2sZXE686ZWA4egXUC2t40Ws0Nhqbj/44KItEawyU/SL0v1fc/2kxsUzXIZbpWsQy
/SvEok7LSnn6zXQiZkjW8IgJFIzOtHh05hNLGlvMJzQi3ymq8MZN0wRs0n8TUXjMBAzBfFJAHLiB
QwvD5OGZk1nD4JminWOfl4xHgFz4hJsbndp8mOPy8fwI8PhLO22mfa7n3UZcUURgIFcChgY5GyTG
F2xrW4f50DNwEHJ2LRoU9WqKZeZJWSwUDHee6FzzOxzsHPEJW9CO18IUS31/AIeNDsB4Zd5gbz4G
TZpqebz3nPRTj14xTnm3j/adLfQr7LMXgWoUA8ZyzQjdQMxmVidWkQDOlPNBwPdgF4Fj2DKL7fkH
vc5dL/NZWUhzc9O7ntVjY2xP4806WBbElUIbBmWrXa6cjyq2xSn8xOWtc8mEiB3WfDjsTL+wLMXP
QD3In9V2tcEb9uVsU8RilWghTw0yF3wMfEEbKmdugNF/tJbcTbHZ4xnb68xCKRI2RJAO51cst/rd
a7z/Ef4fuBVpk14x3g7wHetf7guaRItbufMUN5ryB71FTNtZafMYbLRsHLl8hISHME4Wooq4VY3Q
5hzxaEIUHZLCFXp7cCR8qtGDvBfsdn7PwxaiXJXvAiK69Lq5HcvMlqwqa67EVfQUlUXKDU0bVhoM
bmvTJJHzBtEUDMaWyErNnehzYqy8DUhPTXmkji2XI+Xpdt/pz+h7FWcW5RUY3lum3W2cThdC6IWB
c/Cw6qN/REnpsST6P1RrIBnzlqP5bkfIQu9NrWyJRSW0TaciuTTfm71Pg+6qu9o8elH13WlEx9V2
usMRHQj6sibImRmMV3fOCG+Qj1AvCL+Ik6GI2rkzeAnWEFef8QFAMHUdgZe0xoT9Bk7fk9PEalcq
3+OOzOXwJYzK8AoqapHJpVhcNujHq4P3+4dv+Dx4d4pjW4O//BY6+L8fTg7wjyRTHhjuAKH8vS6A
qbEFCQCZVsOAdujMkncfScPo4jaoIfmoJIh3CpVv5erD+/Pvg/CnUXV/eh2YWCgrjJcaKL1kj7yW
+s0EtMs83rvWPOA7fipZGm+r81o5l+cwVUqdUGmaaXlY9T7b5UtX65V7jWq1Jz5eZ44qgVvoChx4
ZVNSnGMbobVIXWv0KNx3u/3P8136XndJ/gijqmg5Ns40qq/6W6Dl2tpAFJ/WKm0Vwp5V18Ary2Oh
Jf5OZ+lw7VFaWPfeOWcvo/d0dv4q79+ZhQJBWkazKSWeomOqJoG2IX3hotRPiobNbzWE6g3Nsv1T
JXiMXnhlO17GyBUAz8YVKLFp56IsVq34jYqWT82Lcvha2l6GpZxjTpzm0ZjtZbRWDoWFXK7+Lj0S
0rGuPm1pvagYmWSH6Atyef4FUrVr1G9X7+Z2Ua4j3/q8IJeNrC0rn6sNOgGkj+rij/mbrahq672S
x3iNi+HiBpC1kp2hoNHKHl9aatvkS/2P5L0DJ1vaj1JmrIhdEFiV3CVHAW8omABTc3FBaIHB243l
yIEddlB2QP5cDEFexzgcCnaLoH8Z6Rl3IzQ+EzhAiYxiCpiyYw2XBCdajt0Mgg9y/1rCdW0/f/6M
7M+CiIRUdTaG3hE3pO8aNCiCyyhSCTXmNfXVAoMa1ksy1gzj5evQQxAJwRvD4IwR+h8z9HxzqAwM
FYMdRjrJl++I1qpwDPKEPDIwKu504xftRFJQs0iY6GjLpWZ3iEFzDSwgwdHMJ+zD3h8xOz6fqFFu
b0efpuxQgNnbAc7bca/Ew0C4SgexhS02GVRuM+FWtB2ouV1slLzigd0RRUg+cTef2FH6P/EIvGUB
mymonRf8aa+xKfjoOJCGmnaiyWD+qT9ycV9fyHSovC8o8V6drft4RJX6lq/p1UEF30J2sgTk46k+
G2TSGkaocs2XsNPY22lv0CEwcEEYuR9Pb5HwZXnbqymsvVzSms2GDES9iw2zqvaSnW+Kr6E1FOUF
PGyoTyBqk+VNPm/iBnWw8xZmcockB4y00OXQ0FMZyCUUWfsC+/BiCWCXkM234HXloYt4jSlCMcZ0
3OK8IkURli20OaU2ygw52TXnlqrDTljXOq2rzq1Jej2JbLwjBUbBJZhkSiVxPgIOsdtlGTSv7FiG
M3w+UstvI5OFx+oN1fO9vSgAm2XOYZVdMqjF26HmAPWH86rNrGlz8MNb3P6o41K77B3rov9Abrer
VTvqo7jXyhE2ng+6+nBKlKKDIGZRCnZgFNBHddojyCBPRyedNg1C24SJqp+GIk880+FXZF4rmUs9
PDEnPcE4gj67o6Isx+1RbUVrNWf5BNKg2EENvYkSw+7hqmSaMbT7QFMTbvqSsmLXSdoLo5gnJFdJ
iScsrOV8sjgEJ3ljaWhv6LZISrD7TZ/CHbRJrmCObjycI+YT2ppIDKR5wdwhR9GOHXpo2xvC2eZF
jRqdQ/A+j8/LzYfz8g78+xT+fQb/fg//Pj+3d02tm+aWxTaMa8Jjsi7+kXdbQfpJK1BLPixtGTsX
utWlYVcN4isB2WDVS/XkLiS1v34bYtPKBp+PlC6ZG75nGmSts+G4Gz1/9izwjUmoeHNvRYHiAsuW
DXgMdFLLAR93jK3YMkn0vsCHAvv5qUfGLKgwniilraXgVaQuX5SZGUGsl6zpKbhaMFPwf+lOzJ0z
nI6gPp956s/jexAYSFAqQ++DAFFEXjxrz58VFsVzlycrq22hy46qrhtLT5yFJ3PrYclJTfu27KIv
f2LbJ1VTw4nIfJoKdrWwqUQ6lIJJ+XWP7tc1kuZkE6OLPtGpUTlkeghtVJDQ6Z1Afl7PclcB0mbz
XcmfsJPeXaM95aDXm0RPd60k/SyVyDtp+vu831OJcybMpEJU8ZM5jS4fHSu4aHycMAzGH2hT84kv
eXQ7caCUGAe9kgICgy1f+IqNGq9OAGuvMVxdYCrcmy8UEXPjryKuUCdSewqIa2Epm4RQj3Ox26BI
ZXgXap/sIaKCdfsQ73rqV+mMhtKjtOplgJFUTVf7QmFve3c91WXsFApTdmdTOT77M9NZy7Ha07ga
O1vV9ZAaQu6Vyj/wxZKvtcWrN/usUVvVIubscSvagKUhvy5JWaDeWZquS1a1hb4wWcuXiqU+jVnb
ZV8TEYxDDjAnXgExkS8z4G/GZc9utAKPPQ6Ufk2jndpNR/VdqEu96XQ8VR9Edwc/zyrGjwC1fa0U
lxp5cphWiUGdVJv1JmSEXwirYN3YMrYU5NAFTmK0EKEyoCGWM5XKdAGvxZRF1Kiq1aRwFiST/KvL
rBfsOLv8yAdJqvA73LcCy6HLgLPg0qUofoemBx6NqdthfEtnmTO9NIOeKtiaW1srHX6NSCuJNyfk
5xGHKMk1MLIyuigjoawh4wBdq0KIsl6G9eKemrcgYKgJZWRD2+VvwWr6EERTl0mPkGCdEEWl0/f7
b4/bOajQBl7B2NWjhthFdCF9B6tuoXSGu2woDJlB72amoYcLI2u6Fka8vkvHr3+6XNoq11lEgXUV
ZeEGpf1RKj3291X0sLD3xCdRs74ugN0yY3qYHTvilotqp4R3FV81H6OVQyblw64iHCqFVtUIzxYs
IYVe9fRBHk0XivZ63IUSB65wZD4H5KOVlVh6EttmQJeZEA/q26v4pe7lm2l4jjYCzLDzX2Vr47d0
Y5hudKONn1sbbyuJP5MVr+yKP7c6TB+c62tBDZm5DmAMFdr8VYrt9Ez/8h5P6OEkJvXeGFmOUpb7
lBKd4P+ryX8HA2uE1nEIiMcJ+8b6b32lQoIBFwTEOux1RqTOTjy2zl7AcdGle7VzfxtVGh+vEACg
ES04wmV557ESNRA0rYFo2Ynyw0MUAeAtr6ON3/wKkrBvoloFTlrLI1wNm81MFJgJrC5uXaKVSSik
nrCVg7rj59t/m+yT2PdeVBGokAnb2kHlzooaqzmVADIlQVdPvsC8de93pz2Qd3DvSscg8JmNpBTE
qJT20P3bKNrBQ2+O0jysSGjToGW1/zqpxzmEmoJShWFnOYQ6zOZsUdUaDxOoU9MyorfCtmzY9QK3
UDnFva9aWH1aDxhHFA65vlUM2Z0o3V2QLolzNk2xNvP8Rq657O1EOfd6Hrk7nobEFBze3O2NXTl8
0w5uHzJrLAIfsO9rlwPXZG+GMBFBdxmj4/x1/+To8OgnR53h+cgQDQBX5MZV4PtbP5IJBpsi+Ey+
gqcoStX0T7RftGz8htqNTZ/oo9lfDFBUfCfccCIsWXfD1XzwrlqUj9al35l4RdgfK9gSgcy/gNX/
ec+xo4lhINwgOS9UZKkpN2qPY9HaAUFemFhR2lR0z43QrKO5IJ8s6klZp+x/K2z1u1GPlREYAQuP
E9hOUBCvKQKjyxQsBOcBzVkGncluZCIR4ySzndIYxPfZeJyUFlBF7zr6114DSjbw+ZgA7wu9tWOp
lW6ojJx16T/kQ3ofNf+5vR39ixDxBGBKY0+Jxl1tIaSRUyhTES6oDgWrEbPHdDaF06A3rXepnPp4
+glRqUfj+TSjgIs8lVEDqqL4i/w7qWOQRoy9Gb+Q42QveqHaAFNLU4B4Jbm4wkoyuen/AS9f/nKg
oxjO+7Me2mgqeCzCymprMK0acAvd/nwIrw6HCMncwZhlINLCizcUqxqFD2A805jt86mvaHCCStUu
Nek59G1OTptQT14uMONEel0M3Yuqlww2TsXTcNyhK4S3hfN0SMgtxOHwRGAr9HDXCJY66lwjfKu6
QpcBVzjiet76GWtwRo1OvaRKgC3kzocB7KIn4vW4S+YQ9Iz9ay/pDewlJQ2US5dMY4wmCQJD1tN3
2ogpUs99NbhUh6/QN0DXuzyxRGOE5f4KNt63B5j1UR84/W5MWGU4YE7wI1W6RvDRS0L3xV8VBheu
6dze+NY2XAnG0GGbY6fe6g2cFeZTOhxiKM6nz7c9scbn6hAZTB2fnFdCzdhsBid6s3/0U/slbS24
tcMCNn1KU6J9ZwDSFMX4lFcJefgPCR6SFCNOs3JDwAxFDEsr3dneeZY2d54+Y148G0RVKrFG98Cz
3uAL7FGTwZgNqWoOPJ3FGBIC2pN8g3V73eYWntulvNMK4Z89RMTJH/0Y7bWBo4OJKTej7/4bNT4+
aVj2o3RTyCvc51mr5e0I0tvtbyScWO0fSvNrUst+4qXXm0s+A242XmrYedzGKCEkiuF/8+ixYtC4
HUPCMI1abNOCKAqd4YJyMA3cnia8ZS4eMsZ8GXAXVT4+qQSMhQ/1Ts3oeBn8RaMBJ5Z4S9nq9jhm
CW6l14O6E0uTUJXb+ucWzOgNFIza86T0+uDg+PL1wcnRwZvT9tOg4aI0RB9hBrs9ZKP4pn/LKpJ9
jvQeTQadL8Ci37agfzfTXvYZz/BP0063pxkrsa6sER/JFhG1QBx1gZQTvWkoKryxpjZR4AlgIKsD
SwGra3n08M5Im0H6UcFRtdefEQZkTaE9wgG2CRup4H0YXwJ7sBzNkUK6hANF6XV9SN8hniDY3fZ2
NL2G//SmUzpU5ELiGvi/mep1d8yDhGnpAUUk+DGJRtHn3qB7ibh1QhzcCwSEH7gIdZgQ4QL+UFAB
gjDgggtj8GOMAoC81Zf5kBTh1nlQnoT4owX2pzwxRlmWQtzwzJNhgRu8jtmezSe4B2TYiho1Aav9
gq6Wnhmklt98vBrL2h43yK4F1enp8xQid5d8EREt/4s7YJNbCmoHgi6BwKthow6VF09Q72O7Cnpn
lH2voJLmIajU0BRh5znuweIdzK7BCABoHutbl63NH9ZwE7YhsEFGm1SKhtacaDlWMmOEYHWHRkVV
NZh2QhG0GekDP4NEcM3SQhbCa0KqaGuyK4KqGiEuGUxI+vscde7pr1F6066UF92r1umsM5tn6f4V
EN/dI8zMMbfykTfhiSda85EH5xwec/2+q74yR8Zq9QU2aToZRunvHbw5xn1/gTxXUb3BkkMYVkQR
I+talenP4IUrKtktgMAKDqkF0TRS6GyMMT1CrRESu+A0jRROE53C+gNVHUK/0t6z0lDff5bp8Mg2
awb5faFSo/erLkcBsPveQIXrTcE/KtLEkimlLlbrC0kZ63sJaRjK0rq6RYVGad1f2XmLUUmDfqmn
rw+Pjw9etRh3O3dSpeaAmfaslThWh1wgU12f5HgskNgnR5ellXNAnR369tpl34asq+ZZ4dlRs7Fk
Uadf6N9hxYS0v+U4XK0xS5Ov773QGQLhDG+BhwBmTUJXZqPORB/cX7VnrbtXXfVH6M6ttix48wsb
69EusmSzwrvLp4+VUuEWFdya6huL/ZOXPz9GG4uD43cvfz768PaxtbEQsfEx3VicHLw52D+lTczS
mcr2xf4wemiIDb5vXPVgeHu+ElFmAQ8JzVDCwMHpQOtHpl3jjbYRQdraLzqWGlQDXsoN/fYFxiNR
wRJwxdNrWPGPjkXT8mkCAQx35FcH/z7cP7r88eQdUvGr9mg8QiKfsvGETq1KEU4l/Z39PIB1gyOT
eDcvhXbKfrSEQzwYxeFGo0N9Hg+6clByh8wxqy57hI9GXpklfo5Eow2oXPqEvVIZMhTwJviP4huB
6rHlIN7ekk0KNsc7o1YGnrBTjhgrNLQAVhzM6oAMFh2Sr1QXjJD1+x98dNLc6G7RCNN7V/WH+elo
Gxk9ibOIx55LYO4FDTYWEz7zfoYv1iSyIFdeUAbn2LOOVaHd6bWnQ1nNcdoEgKf2iqQ2Vadf8A7o
FeRqtd5NCMe+1WrLvkkWvIhzvyIJjrKcUEovoQRAoBzVotgPFiv/FC2nghKlQBjF0ErzPSoHRaPq
7z8hB9G/e4y6fTKc4H7kB6NoIJxsgT6HOhnozhMWkK0LSY0FLxszhz8gBXbH+Omz5glRw309clXp
p8QNwtQk8RxyOfyADLqEmqhzGcywVhh3wasHQ0WiIteOvODuYbZiV44teMrdurWsby7Wb29glIma
IjKa7t7VHOb7aPxmfI1OWu2mO1V56QPk6Fkbgx0QoHOMv2+naIXP+plL9Hqv5OgCY7PjIY4w4/sn
P/1y1rwAQrm+652VmxjLDOiFNGY7mMBo3xKaBZOGWK/8Xoch6zO8VFmQTSWkLW8j8MxVtfHx7GP1
YvO82qhFcVyjz7BdjjDJjiRp1Tfl6ygpRcX/YAOrM+RmzrdgPs63GrgMq1QjvDw7zS6E3ho4HXSW
QA8TUraqjNgfyckJ4HdSsKu460qVwNQkZcCA/RfHHyrROsTHiiGRtEh2M+w+UEcxyrISfzQbZK82
YO7ob0UZthiqQP9K6uuWjnfFyilcnGop5YKb1OTa0+iMnSVVCZi0FEq4hfGk/vn8/9tJgmP995wg
q48N67HwoNdMxnwkbMZCJYtDJhVP+NbK1e6uVF6R9CdG98nXsQpLDgKjhYX9tTfJTO1Kh6wAXUS3
KLtwdYudi9C5mHj/CDWmOBJkpEhFdgZJy6sO63BKl+JUJbaK2lF1V/tDGIQaguzMB6jJ+9yDCZzq
lST+Te7q1Go8rFapFNyPt3c5Pvf2jtlXoKQ5X7BMd6NBhrD3DVS8Nu6GaGvzZ7rpM68U3/Pho5vq
4aFSRKz6WgA2v2u0rJZN5hcrBjeeCGZMkFRNJNH0rJP+eQH7bgP24MZ5vXEO/36qrOKjcTSA503R
zeD4PRxbeA+KFjDsSgYL8SMZE6X1zbR8e1eFv8kP52UPej3HCNvL/3cGNusx3rdNZYH14Kwx9OvD
61S8txdbUW2jRLRNCvNmXmehlZRIwZeD/pB2yX7uZqXg0sR/gZhgZP8nXpum83+gvIDwLrPxZNbO
Vdp2JywprZShVIki/LWtiID2nRWLsqgRZ70IPMA4Dzu3PXZd8pTyOYHw7xcdyqhf+BJZHP4fPN8O
r+/vyZjrr7HwK/n1woYta0uQn/aORItzdjjlQGQyHcos8K0gZlktt1uGWd81mN1c7Bk8M1nly6OX
2/ZUADBIWCzdF0YCM0zydRKYAVwuMgrrTYaVwcyLDxdgxxZLmHyp3lROA29/Fv1AH5fO9wUkvYLE
01Qm8Usqswez2dbB6tbrW1WlT4qIPuR29vVNhRFUrfzSfvl1bSzKvWaD3QiD7uGDpJwUL9EKp9is
LG2frIjltOHAYeTOLOfYWY+FIlmBGw5bb/BUc/feJ8yKp+KjhodLOm2J/Rsi0vLFtz7hMNphKtgc
wAZPexz6MJ3P+oMscdGCrSvZXCWBC9rvtK2c25wUeNVJ2Ikyt6dqNlqO+Kp1MEEzLb2XbrTW4Po9
S+LCUXNVYV/RT7mdCYx5PqUOitXM8RX6sPnqESvIsXb1uznj5B/FfMOx/vC5GoVg6jExtiIcyy/S
CXGp7XL1r3G5a/GzzcRH9OLa7chF8oI8WaqKB0/i3DzJIFn3ECRTKU9rsqJoi6vC0QnqRH6EP4vo
SlQhqLvwdCGLqKM/ljylRbmJR+RVggVtK01BrK6aohgtp9DyyMmpzZi40u+wYJ33g+xmJi+ngona
o4Kslh0cvYLW4UldvZV2UKvoR8drFHPyWO6tFHt7oTQacldjjRdPCfpITG9MYD8yP2nbZmMV7SKe
GX37dVRPtNc3e+jEuB9IpHBjQYT2megCp6Nm3BvXFHlp3OI0OpPr0JJqkw8nSA/eOYx3c7I0EN0t
cEtu6PL5aIAmoTpEENT5qX8nq0EiMyKUa7tshR6KBh2EudiOplde8ElKGy/R0DNuBxXoNKS0THy3
12uzCGRfqvY4sThO9Jm2JGS8tidq5vH37xM+LItSKGeqNS7KTSGlMGPjxcoIhfEMRg1cwb+FfSB8
zyMofDaeU/A31+sJPvCMh5vtsjcm2LfatE8FFtZxaUGksprCQRarrlkPjciAxim0TX9GKF8CEfSE
hVILapncCR2nfV5v/6O8wxDrDSFqLDAbZZKc2PSmZsWhiO+KvI9MhcrvcrXTkTFX27Xt1Tysn4KW
FHtrFbVf2bdcoWPeVDkpeQYdy5aUJKFJD5Qa11Y6f32LCUPkW+kGXNxklbfVHhnqq8VAFtmQSEJx
mUpcq4FwYZXdHI+sZ9KdLxig8vQqksAN0Y/7h2/QbsT23gqh+9K2ByS7bRko4bJox6qEMjD+cck0
Uz4joLnCsiyzmaSSjaEdNqJE0YYsBZVlHVZdxzzbgshYKbHNwWiJEdNj4ptAnFD5sY1voU/Qi5Bt
sfpqlSONVJgFthefsnxF23Z4QruVsY65iRE9cwrocP6MjFIkc+hIYl80zcw31y2YJ4fKpcc1sw36
meRayIC00qOxUYDI5D+uWZzMcmoNpp9x+c5S+mtOlH/JedLy7POWT341hsw+/7pbZXgHVZxKjnlx
+CKnRdqPrxMZ7kuNXi26ms8iHd6E4AfO6Q7MQSMhU1UZCLHhojbkIVrktLKncG00WMmbw3/VkSMF
RO1SxcP0Yyxbs2Z2A0GEpyM9Jvc3CZZqFmzp13cnr10ztNkU5JuKZs8xQVyJDv5z+L5UOjy9PMHx
2i4VuTWoFM1S6d3pJd4et7VQBdUVOyaZ1MvcjRbHJwfv3/9GSVtpmW6nlQ8SBkOBUuRX25LlSm/2
T9/TRK/pSY7eCq99LajcajaiD1ewtcwjvrWgm6J0sxad/HzwRgnIDXlQShX5Ne/dYghC9I2Qa3eM
yc7l8JXTg1w0PcjN08On3qg37V8/ZP1Po1734a4/nc07g4fB+B6Zh9H1lwdRcam/1bP0sn6Bdyjl
CnaDgwNg9IBGMFBAXbOPVrgIB1OffUTn0w5enCbMG7L1GKRAxSfU8raPAGDjm1n9FP5z35n2uJa3
Gqe/TjEj32X8/kDlbZE/BEG+cz2NF6O9uoaH/ywRNKFSDP5DOo73MHNwIEOerH/Tv6ZmZe/HgutZ
A4bkj/5wPnwlLVY7joIuw/AXdP5wTXwUGSYZw0Puk4eo8F7UtqffcwT3dii4BuwqgudVJQD4djNh
v8QJTN2427+OoKkgBVK4ArajzZwxe3kMk1l/CbTCo0QxDvQQiTWLLuItRv7QLuT//oKZ0WsMW36K
NvCMQl/dhhlvJnTZqeNlVDlKEQWURJogl96kXuogZVyip+P1zISGoM4AS62yK2GU5dYO5Ed1Bgbp
ziKcQBAugC/rzqcMUioxlT6xGbE6S5bhoH3uD7tZ11YByYYOdbURM2gE7et1HTNr4HQb48ms0fnz
esjOzRccQFvr8cyXsBaNCucEyG6JSsthBH2csz+U/qprnEvvO1RG45vXQl75VaTPgiFvGwkAkat4
Ex1k8rMhiymgTYMsiEx8Xj0jhw78z+Z5cq7XXFlQh1X1o3z1RoqGhuSl40y7SkJTVEswqa7DRZEx
GZFqcjog0v6Yltc3Y70NxK0Y+vExxh7ECi/ZlAcEuUZpRTtJ3Do/w9IvaHwuNBwzDMcUJ74SV8zl
eK2x1fhkVQ1Cyuqa3Y1pRWe6FAtuVZHe5gd9cOc5Xy6pYlm5NoY+8YYYt6JYfH0uNuOKTKXsmzyV
nM4jsM90AQiEYkamvgllsc1AXG40rJpxV4C67fZrUYe2wJfIw5+fQ2MKevH17TK14+akWCEC/iaq
Cpn6B2kVljLkrkbVyGKnQPINlIjQF2GwjSiBPfqfz59tb0dJEgjoim20VNUIvRalgx4eRyGVlJw+
3ju1dxfHFSrDDpi0AkdbjU8/PA2pLVEVJKQBSEcwR4+alS8vplet9Ad4UV4AleIjihv4M5vhL8Rh
hycQZ81VQhkfHx0VhHfr+BUth9PMNB5bi4rr8oIcHOjcrlI/ygvsBLYoHweFThO5s81gHbjnLazN
wIkLC2PJ7r/8VE831c64qbdFb0r9AcAOV6XH3mAUcRpx3nKluFStNHkslfbfvMGT//Tg5YeTw/e/
4TMzrfgEnO4rkAFewpfDl/tvCNXw3x9++vHwP/R4cPQzqlXfHhy9RwdTy8RAcR8BbAVWdRDoyenB
L5dO2fji8O3xu5P3+1Qkv0HB64Tib8mLN+9+RQ7lzeEpJ/oZHt6d/EbPIuhtqyfgvfdPQUqA9CcH
x+8ozfHrn97+dNKO56PbEYir8a4dvmnbCYsVY/CwHIrP+OYmQqkDEX27va4y/MsYOSQ1GfiaFXWm
qMpE6USFEqOmnn548x7VTjFheNqcjBg9Fd+fPona4X8iX3wpSEelqJGA+hxNqEh3S9SaOa+V3wuY
Lhr1prj80Y/t/HUkXXdFBnjk7AVaPIq9xd5FVH2BwaTU7+gFmYxjMiDnz3sXQtF/gxE1bQwVtlhm
wGWUixu4h9kRGDLnQ258iDJFBHXBDia3n+SGEDvYjuIA7sFT8sk6P2sgPDEnKz/djT6RPfTZxdmF
GESjO41nMLGegXU2GfRnZBpdi25qeJPnWvkgT9cO204n0Q9RrGxo4qilsEFDiAnxWUxFxXjziB3H
K8MqdgivYGMoicxa+VKyRTdMN2fNC10SXSyaUTZtxD2rXL2/hiOSInmF0sgmpibBEv+dmdPXjQeR
bSSfuOQpS2pL2z6jqqkY/SazvRtkgeioaDasD4rEw7GITAKTM2PPh/hMlXARnSk7mQsN+lGv19Ga
T8EfaJtspwY4guFIHDU6inJzvgo0EmiLHiZgX4uMrzW2h2vqNR9dIx8aTTuj22qWkLE/CVOZ6zQA
s/4MJpvfGmAOeP1Uv0YEDnjRhBfbHoGHXRVw2XwnF+lThk/BZuCV+F40xbtvapBcwatvGBlI38oj
skDAgeHoR7oBh9yBj4u1XRWwgSNp3UKW5vkZ2dlunV9ElA3ao9aNnnpYL9Oz0QX0YhsXXgQrCtoM
L+ILtWTINGA7ZzjFHtZUnqF59jowjdOHb/FUq9v4CrRXNQtafK5p8vzC4vSdE72snpzP5nz/hko1
weRq1UzCtvMaWYVvqAcoUNfgwohzVuLUNc/0tRVIwcRdBXwkg/aFZA/hQGoW2zN7i1lYoqb3QnNG
Xv54PbPpOprY8kC4duhe6cfGfb4q9uMryiS5GwNiwwlcMcyq2iTzbFeLjN6cuK98yd3t3XTwhmY8
7Ut8rh102x3IbXmq+Tn6rnfJgIMpu1fDSgpxfUF7UISDZROe8a0RhyyjfXHxEGS+7nw4CRd0ANRD
BvXHwvu3Wh9MI5StT1xtPnQG97DhJ3HFly8Md9t0udvgYHpHV2YJGMogf1Wjsc35RrZa1Xc8E+kx
fpuOHvYZiSeV94nv1GCNQppGFTVjFcaGsTq28zUdI5Qeso0wiETylGgjVENyPwO/OAZqIMdFFgTH
nxowDo3P/KUOv5XvCgvSY6AXWIrwnqLCDbrIS5GtBnOq7346VYZxQOxFZfp6QqWee+qr57C8PBu6
jpfVn8ihwTKnIkJ4Jm68uY+nqOpIX+FtNnr0dfnwxEMITrVsNgX2tRY1a9H3Pmva+FgVm7YHIYeH
VyB88RMblj0cIwcEP2S5JC0fK4zo75pY3KY6dcty6ML7vIdg5nLDounaakWSKctnwTOdOeSsBkze
dAZ/Gucwi40k6JZe7YuLZPSiHY3g79ZWEmg28cWQkko8619Im84T1f5J2L+R7rYgm6SPzquGzYBP
4Ux3Vg5PBrhL5H3NCLZl/a1U5FtJo97WtoVk5q3e6XkEdkSKxgKJsS8slHkT5P/h/1gSPbBFFfzv
LpfJJadHSzrDFRN7WrXM+RjUoim1QblqvKLk3eWbw6OD09gtA9fftdsZS6K39YG6wKZfwvUcAaub
afN5ktMXJgVQwsYb1FQXkDntphD6oVZZ4YEG8s7NGJpE4EybZAlRiVLNt7z/HzxvQ7cSzrWA6kG3
DntGU/NHJVKq2eCOo5sQrqOVAu26v0W7QbevN51hH874ZZqNle0R9YTSgEAKhQ6oXiE6mFZViG6B
kOnha4wnPG2s6k5fUyP8drTSlP3kZbv8A4cd2N7WRgQgKN7B0DJS4zbd1o16NeJmKByJrZI5eVmk
jWGlivWT1UoqXg032G2sODjklYasrfGUMy+QavbqrGyJXhg1DBzN4724JlInC4Dxu6tsPOiRQYri
/WKUibPb/mQiRohyOW+SwkaPpg2PInA9tREjq6dybrce3sDhmviHwsg+Ds7rZx/rF5tlLYkpqWok
RtSWOEQzpecNJOsuXQdKt/eNX5WKiqomS02fDu8A1POMlX2t6IXy5YEBQqcoNCNWInkDulKH96Pe
3bSzZ2f/viW98bPbKLwqY/Sin2XzXnfPJhBFmLAhd63gjtGHQxCUT9tVbjNtA2wHler+KESugqTJ
0lUQlxecjx1tlrEQDAeqJxdaekTQqIu8EmyH/OlxvM7rP5RJFUaD2bbUTxgm586WwE16Od17eNqJ
zu2pd4IYJFCq62NVlftwNf900//joTf6jHYRqGN/GPXuRd/zMB9lk951/6bf6ybUsNxJJQ0t75RC
JykPwvekCODmP9VtfBY9crvUtzgubL+kRL2ECyiBI5GefUwvtvi/msG4/ZQY/yGgIzygcWkHdHek
rjuHI4v6Qk/QoFLo9DX+h3rpnCoNFKpacPUYbVmbMAWQG/YVYQGHRr1XpD9WzuG8soCj/k59E178
TFGJCW93VmmhghqoEP22bVLl2b52ATVYEfV0iZLqqaOkAgpYQsNYH1Mu1AYPqq6lGSwah1zwK5jL
oTHLq8WlO+KZy9tap8xIHo5K19GFKadOWDAdpHBX78V6LqUpDqm+wh2joqH7iS6VB+UiXpIeOm7S
W2MSyuStdcnEW+ZFSA+OSVhLF1BtW6vHP4jMEhsQgxu6fxj0l9w/sG2GSbdCg+6lCWvQm6bpup3r
KNEtZVmBUizQDEs/uY4eMlDCEoWkr4xcS+lYUIXWPi4pRu0yxaWwsnKFUjKQV65k3axM9eEM9sWt
m8ui/XxW2d0FR5DjIlQN68O3n98nXmBjtPGE9yo2fEPYR8zNBtmUAvJLCgob3c0lWxbXWDSpVXqI
tiLdpztURDmx1588lJMKZU2UKYZ23zVRorG9dgNATh6sqIqG7/xMmZGeX+D4FRZGlZe+2ZeXfWBz
TrxHJ1ag+K92cDVs2olBpAp5ndoya97l1FE3axvvAu40WKdgUPzFql2rdhXOq0iEsnXWeX3+0Ylr
gPUx2jzfjDYb2kxMq6uLlOxsx0GeHc6XVpr1eqGuPvqK7yLLAk/7bStto6ooPynII+SRQI7Xw67O
oJXiA0eqeXeK6lQRKzWQg9OG1HYTmTrr07H97I1QxuiyrDCL/TApUlPTXYvhKrkq2mb8l99Wv6tt
htZYSnd73yAQb7HKz+wPbWd3+dLLHjCa6UMzsRa/aSlFdl1af3g0hIj5YxERF2vDnTFs2XNt+JWC
jtsEVNhvRUvf2OfFkhsKr+nrkLlZDI4yP2SWbJGGWk7hpv5VyviCdxb6oFN15cZm7Rk1i//rJlMt
/2IS1lLwsD/qDzsDjZiSrNOBr5tc04vCedX7VcGshq5oyMh/MqRwQVfoV1JVV3EUB0q0OeqkRg9y
xj8w9zM+xPHh0el74JnfH749QIRjQjyOgujGCgfZV6eacVGK1enIslfNaZ4Dyu21FNuOGthY6YbU
0F08sbQa19WIUwhHBfMTgXROiuM7b5t1oXMjK+BIBD/V4Vm1HFVnWcDwlsLlcpCcuHynkBbUBmgE
lM+Gg4WZ13pLT+GJNqIc7cEKUTUU+0kJfqaiQNRw2SexhAw7Ue5sjI1BZ9DVePaZ9c19vEL8BrSM
AAPiYmUcHfx6QPLa/zucDHNzyJVbtsfqBcFkGDer+KvNCk5cLD6rrFrhEKrarUimMC/HLGjqvUHH
iJBAGy0GlYBikN9FW4peV3v1oISBxgBsDqWjx2EG4JqlBLRyLUK4tqJKifGHNRAiaWM8vPTGMjnH
1YNgWXoJoRN9bu1IvK88aBaZDERllUkDZI1vyXPx/GwzkZCyHLprAV82NlqbjxIoRWFx7ubx9MzU
W3G5+tmlxgiXD46HJbUkqqo0iboqsb7GuRAOAgxGgyZypxrtNSxmrNrKwFYjJahbMGOCwybA6MLr
kkis0sqOpuREZSisMVOjz+rgwI1BZ3NIObaFC03eaVx6+fPBy9eX717DGpAJ4q2I5oh2I5ggnWhb
TUqptLAcOFNx+h1nEVmPx8Fvddp/Oaa4eFDGSUFSBVOmU6slHMyQXU/7k5nJdPry5PD4vc4TyjGe
Y7AiJdLZ1lF4feSE2HTz1M0NCicNlE73VJbnue11Xpi8K24wEUrmrp8GucKCtF2cWdy4ebhkBoPJ
fb9stac79mHigRocBbQNYU8KnUxdNuVszKvI9V6CEH8FiyvhUFXEzPQljBduFIinNuqKOQ5ryy0H
PxHkKChq2XBhu/BOOLCy4ca0I7Nv+x2CE+BCY3ri7PhMbin8oF7uqYi2MA14ax1miTA+0efhuBs9
f/asOAP3zxqVwBThZ1nZVo/jpSnrMFp4PDIBmBEJE4GVT6ygnJC9ISqjZHUMMTrFeCdcD7qdH/50
efrh7dt92KCWEZyEK4t84J1ADsufty4gHVzdIo+D00rTxxXxVFSziiBIiisnc1k7Q6CxssGrFqrT
HJql6rUsnJaYPuQXmUyQtYtY+Vfnoxdd4BbKVf3oNCGIO6J2+iL53K1O1jlOLlDQmzfxinRaQior
VfqqHIqnYo38qtSILR2VUau5KqXmFMrqPI998DWlaEcyUSs8XJgGuTR5/MJYva2LWlIY67wjlcMv
yFJ7c2mFBVlq8MjJ5hdp3y9QmYVFqutOq8dO5lDJ+noiuNxyJffVRUXk5Q6Vra4s1mz1UG4vIjdz
qOQ3DLG1Yq50yRiCU+ezbBdtFFr0I+l9MnfCGlSbNIS9m/6oT8c/RpjuX/dQ6lPBF6fjwWA+yaLu
tI88joL6zHLMeLiZ5dtoO85HJkPnOSOj33UGc2Q6Gcal779GDADgMPopcdEz3Bn5E4Gvoysc/GfS
weEdfCkVYMF0MugfQc24zKmXXvGzlFJxv6Xg9oRz42ZWnTY4OcRrl0rC5wvn2dLsNm5cUTW/NTFK
MVP5QpF4Kx01Oo869IbsSybcktlPkhxoVEsdfjWBb6AXxKpJ497m4KlQ17781MODCQ89Pqyq68YE
SzDQmI6y5BxcuuFyZrf8Q5utLg0glMU7YKtenry7fH3w2yn60JIui6Bzhh30NaXQ9CrBI/SbsWD+
D721PPRjCQEA
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
