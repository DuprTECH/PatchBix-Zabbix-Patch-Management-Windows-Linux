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

# Embedded check script: patchbix-linux.sh from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux 69f8750 (embed-check.sh)
CHECK_B64='
H4sIAAAAAAACA6xb/VvbuJb+PX+FJqSTONj5gNv2btL0DgPMlp0CXaDtzKUMj5M4xNvEzlg2lAH+
933PkWzLjtN29xnaB2JZOpLO53uOlK0fumM/6I5dOa9tCedv/AG5lRtP5mP/i7Pwg+RLh6fYn3uT
z1KsvGDqBzfoMvns3ngiWU3d2JMiDMRb6izcYCokOkkRzz0ReTJZxCIOxb/dMSiKOz8man/x0zV1
9CKb3lPv03Pho4Hm8AKM8parBaiL5jta0M8Y7gj+KJZugNmX1MtdLDCwCaKtz969VIvvtG2mKN2l
J7jZlfm27jBLeCc7K9mnhX9Uj1antgUq58lqFUYxRqxi0Trwxr4biK54P06COLF4f9Nghpb7ZCla
Z28O3+LzWTj5fI+/e4uliz+nkTtZePjwizcNI2rZx1JPz/UUH9xF4hGD3FhMw6AZC++LL+Ocia2p
N/MDP/bDwAY3o1t/4jHLpa05LqJwsUhWeJ5G/q0XSRt0k9VN5E49iVVGHkkhpm33OoUJJy5NOPbE
1Iu9aOkH3lS0xsnNDOztCi+Yu8FEcRbLAQ9oAZjAj+/RgEkUI0QY0XvNHpJqmGAz3lh6mMCG4Feh
9OMwuhfuresv3LG/IBJ3cy8QQRhj/WGs1klPtFbwRpxmJFl66cSTcInlz6JwmU0hWviT0FsnBrc/
e1FnyiM7YXRjDXh8Et14wQTrnvEjduhNSZU/HEpqc1MttsXcv5mLkdgHPX/iLmyx9KY+5DsSR0vS
BjcAHxbhHRrehndKimdJIHzmMO1FrW4SgSmtyMOCl6TFU8sWM7DK++JCl6ERXjzpUqfOtJuq4wC0
hOiJdndXtPkf0+smMuouQqyGLX3NJsXr7tS77QYJ9H/n9Y99pbxeHMM8pWh5wa2PeViQt27ku+MF
FEPN9e+9n38++u36/PDk4PAMz6A9JxssWKXIfkgbXZjxoNjBMmntn578wp3BTsw4CYOZf8N6Id6E
Mg7IDrtYXgSJ7k1iqCyPLv+sTcXkdjpED+PNxqlq9APFVPXK5ge7krbBUOojuuEq1sNUA+REaqLX
rpUmSoKAHB7POawknGo/lFLtfowH3rpe7yoKv9yr5RJJ2K8rbkLiuA8/o5hiFSVz9oElgyXCB7iL
1H1K7gtOMEnR8gMZe+6UFmvytkDs3enZBa8zI0YaTUOKs+W87/d6z/sFGm9Oz0s05pCqYLFCAnp1
orCgVO5DoQmLhPs7QTUXyTMY/J/DsIIwo1K0o7T1CDFiJO8x57Iz121q4W+Ozi9Oz36/fnt0cniO
5yBZjsE5rAsGBGfiq8m0N53D/ZKv8kHIYMTzniL2bu9i/02u4yqSQBja2LSqMEvywYZaZtbLSmCx
qb4r0mjlc9gZl40gNvOxbbBg6cZmzFIGfbx3dHJxeLJ3sn94/fHo5OD046g+gS/bho+EP+ntDHo9
p7eL3zYeXwj+6PRe4He9UhhaHBTs7uY+1pnG+RicEhK0ERxJ1oi+krTYW8xEy3HcJA4dzdPMIepF
rv/UL1/F9ytPvr4Sr6bu/Wvx6s2bwfHxa0f/revYA3WT3sqNQHUqxhwOlq4cCh48wI6gGQQDRvR7
w1zpBlruQoaZyTIF+GhiFoZPtP+HFLMQnwWhPDioELVhoixAcUzRIWiYhk2Hwt0cErdobxPMmYYx
GzglCjzahf6go5O0N840Q2etCVCKxX3Or/8JObCzF9qGBbr3MGvnJfofh4FzjtAFnuFjp4PPNl49
h2bYYqeziy47EPtHbwozwbhNs6czoYssTidaF4m3fTFPQAqfiAhrEloieiAUVEnyAspOGgQd9yeZ
xAIPlF2hQBsT2nt/cXr9/t3B3sXhqB5HiVdXFA9/23/7/gBtioHYzzQkZOBMvLoxTcpXhYdSCKKm
Axa68xfTiRsBwUKbwjvEcCZ+dvjz6emFnk9s/Im8MUVvdwZwlW1BoR7sg+jPoIEeWEMQifww5KZm
WN9W5QxxJZe0P9NcIhSSel2ejwHRBrZX279WK9LkMUExEPIjGbMA4iQicWMWwucA8Oz6YJn0lzYD
Sd7nIDSH/y2FzpeuH8ReQEiTkLpq9L5MFsnUSx/1xtLmqZ0mJh3F4o6WTtqfWKLGdFQEUVg9omiE
lRFztMOCto5Fay+QPjCRpZTWceQ8vHPUyE42VU5UtHpi6kuCUZiyT7lKarna9HaoDeRtsasDhJGl
wDUJY9eavZinWp9t8Q8xhqOwxXO4oRdi768EzHyvVnLMZMH1l3j3T3G+v3+s9rrGCEB8YG8kUgsK
2HeZspBkNDPItlJlwuN9p4gj2YmnwmMpL134dCkeGhywOhSwOirmPNnFVmNb5VfaUp9IqIUXysqe
OGSwojOg4rCsdqfRQes9oNA7hISlxwqY7waydhz96PBwJ9WHO0jLkzq1IMujh9BMeGm7zl/jLw5t
1eGtdibuBAMC7wsrciGSm1H7+nhv/+zU6ogjYDpOOSFjEcJJGhPwKFvHVJ98G8G5CXKuGyzdYHau
gloliVDkT5Uh57Ahc2FoscXl+RU0jclkgIQ3gVf79KqwDkqZ2SyYu3BHUTjxpCS0S8bAjFpSfiPv
l+NwIYu5DDsTmlCp8kDF0HaKLZ4z2KBZlbkOlB9Sfnq5gtWM0lBIax8Q1lvzanbqTg0HamfDUs+g
VPaUMZNUWKNgzuTyI5/80NwrQzfs7r/OT0/I66vwwvgZU9zZSuSqvToI8gIkzZou1OY96OUro0Rq
H+dhn4Q+oVIKuc+I3aNesHYz+id1VTlGJTR8B/gC4NXNKxB2BmW0SUFI5I4oHsBzhyuvGqes+yJe
rBoKBWZgRIgOEp9A6WgtmVAYQmFOCX1kHEMhoaLaU53iKbXWG+y0rSoh82IKEZehcKB4pzlmgk3B
qqnSb7Kpe9F/LpY+sKfy71UuNmdRFTumoScrN5CJKqTeK9ivHtEixul3KbCE1L3ozkfAJz2QIgIo
hMHeuffVzFmEN8gckLAjU73Jk37tz9Embn1XoWrNBZVhpKpef6UW8/rxlaGJeNLGgk+K26+rgf9M
J8HK7xa9bMEhgbG37sJXm8UAdjPURIUmzhvI2VbOkXfnpKbFSnenpMuO0Boqg5Xi9Feo+eHZ2elZ
tjLyVqmNQ/FyG2c1ZFoVdm5AEGT0KkgUOacB1Bjg8CYKk2BauXaF61y90kLmpwIjzCHUWb6cj0PG
keSLqFSUCz8VXlWc+qpcsKFkhT1Q9WwgNosn3Y6S41HAwgeVBdVbv0cqJD4COyl2YkJkqliwqh4Y
agJuIZgqGfqEOH1EC/bKewm8UyQG4iCRMLZ3ke9N5uFUfib9Pw8TOBe8nMfxSg663RuYajLGFpbd
g2QVXRzuv+mmtV9Hyc/hZ+c4g1aOToAcLp1SeS8MYrjxAVgwC3+agk6MOTuS3MZbf+IFhIaPjy7+
7ro56LH/ocIFqyEXnMZ+MKBfCAFynsRYKdItOHGAi+izze5OOpqrFB803tbikzRSSU3WgDXejIwq
lmTahTKhesxf8AeZrqHxQCQG2wNCXG+eat4XzkDogVb/AZMgmCnZ5ml+y0Bfqqlzq3rCv/3+e+f4
uHNwcNkJrkSrExDQDdjppSaSVTAo8wMXdLOvS2TKWRfNSc1SO98/O3p3cf3h8Oz86PRkVN950en3
O/2X9VqtUMEc1RsPhYaBUyhUPtVrhWoQ9S80DJznPXTyZ+JSOH+JesMoatbF1ZBDTy01w0mp5tit
KlVueD39+mv19lOtWLfMO2+ao0C8PLxQ9qwktLnHBpLFymklza90UUSHiLAZWfB9Br5PwG3x449m
UXnErWgbI5P7zAPI19RmPmG+LLp+o3ALJDMRr8ixvaaslSIxF5EQMagcaH2P7CejRmslheMBqEY3
ciR2jAr8IzzzVDgw80PRlN0/Lv8QV21z062dx6nFraLTxmoenTQtuRSjq+0Wvdq2Ou3up93uqgl6
c0pcQbBv1TSHAoND32CYYs9JmLptqki7aQRUteMwUFZOsWugMZyKXMVas2anGpRFqJYqN49sfbIS
8fGVN1TkVGEjEpdH725fXPGjZRsl41F+KFBBnuJTjpvSonFH7Ok4GwZ0sORlab0aq4qQA87sCoXt
UX/nZaeHf/3ORjFrlhov1Njvt36jxm8qvNlcaWZ5h40G8fhIjEF0SLzsvYQyljTuciBXLrD61VVb
CcdsGZkPUDZ7mD1vab3rk97xlI+Cywa58hkKKDetaOJCWPzeDwru4tNl+9PVoG2VpNJ4kM/Q/DRc
ay88b13mPegkg8ZtbbWvBk9iOCzM0x60aRZRpicrOlr8YX1B5nqM2Soms/SHr03mSXdi8s9QLzpQ
KdoutXxVqKnJfE2s/w+hfs+iUhvMB657Yxjtm9TASyeFmPkzsoLM5rMChXlYqJyUnx5QAxKFCz4l
NM96ROu7T4E64qPOjLN5ffOAiZwYaFEoyOCxT2ekeT6bOqgSaVtVXeA7M9+07lgMXmrL2RhYuHr0
y9FbRiZmr8zp+AG7nUw7SDX0okddJWFznFV2JVN0AA29Hnwa8XO3Xc96FRaRPwgelwuaPmwByXqL
BafiaU10dL6/0/vnC35/E3kr4cz/lKL5R8r7UVOYVOFANmkYqRJJoGWJBybHLlOF3FYhFpZcuKC9
UbftEUX7EksqBmYu3hy4HgKqhpJvWJtzVXpfNTBVi8JAWXqvBhrrIFBbR8MDjbj86eqJHn6q157I
6v47CencglPvLE8s2p8frJKY1bv2J/FVpdcz0aw/k3XSnlba8EzSY7+uAQ0U7dMn/Mevm6GQ3To+
17s3Tas+FDy5OsWkEx6+UJEEAA6xv6R8ZrkqntnudC6wwBYdLqWnQjr4I6LHc6vGKQaaS5KfKu2D
knCxgZT5J1rh9jNnqjhFKSVtoiVaMA/4N9EVL8W26AvL6jRab/ev996+He2L8njX0iws53Jrh7PF
81tRcWfqlHI0oRMjjKAiMo/KLmxYxdKtbWTcfGkq5kNTckFc0F2Gt14GydIkGBORoUhVAVAk0nMe
4pa6MZQXVNiLeXQe5HFBK79rdO/FJup9yAvZA+cpc1xgqg+WJlYduPdP0VuDQ3wBI9srs2dQLJHn
jNhYXB98R/29lILkVM1znyKx8psKgGUCucbD7BkBgGzzP2DPa10IDOgey9tNBCoHFZ0oe2VV6PPH
3Ww7hbmz1+mWsnkrBq51Jk+aS3VUkvHG2wlP9bXzHyMp2HgE1H6yuWYUe0GhZFSqIZaONexyGQ6h
y6XTE4bxlANwPVbyOUrp9KJ89FLcoWobOPAafsTBpd7I39at7rd1DpxIL+uRp/r18PdRnb1sXd8i
aPJTkzId5X23hLr4FVtsJmLhqrSI92CXS2z0tkZbub7x4pLTu4VlsS9IY15mbIVtFJ7Uluuk5qRe
EV7OtKoyKYQaamF0kGlh42GLX1JUSW2cRkQeHfKKHne7LQDTegmYNvobISnACcetbIoKHKoTh9tC
4vCpDoSNaR9utz7Vgcn547NnaC5A8U/NvFvT6NYsdmO0rt9t5a8yfF6MfrccFeLIX3KsVAJBwtUf
0m8kBHVKFZ5d/mBs9IkWWSSDPnWVPpg90VHFzoo7O40WTUpON9WKips9FuBBetGhYkB6DIRe6vyE
Yt/px8ODUb+mOb0+SPW0WDiRaF4OktXKiwZXTfpMp+z02SIBiSB85IO8x95jOEMoLE3SA28VX7n2
WzzOUwFQ4cbyHSLjMpY6e0qxwfrJjL5u5FMdh1B84STI0tGPaovfuDRSuiJBxcn8CsX6zQd9WF99
/eKrNyJqxtzXpyej3mZJGD2/Sxz3nnykzTz2H8PAEqWJ+pk0zN33ahqTriuXEfiLpFT876vXJrE+
2PIrnXYTn7TjN4JEjX3SNXznObQ1dUtrPkvR3Zz7ti73nH9fI6cteBojwV2nqAADYCzVopwEn1bw
t8B/coqok+Nbu2sLQrT5eQQjWQ3TBuJctNZin2WL/TVQCAedHvK21J3mWGtUqmbuarXwkWEqpy+j
ScnpzzZ7eh3Ozosef7BfL4OaiN2tgWNUNvYn3PbXnHbdGIZBDymmBnZh8DLUAYFcV4ZjntRNn023
ETwEUWWIlGRLZu5A31FYY+nfc0MB2r5+t4BP39dtloivXSzJ7lnYCOWLZBnQcZJRVc5P9awaSeDo
P6/P3x8f750BG9SVXN1pOXeVHDhaqdQ5wcJSSxW1QsQt0t4mbFNsGmzb4umyIa9EY2cgGrsUs9Lp
K6JG6glBZ/3lwAkIpLSquGQ95dsyDV/UjfNl0p7Wt7wGaxT5KtosPyi3++2ROkfZ6K6YWJPXr7dZ
uG+R3Q2y4DTzzehImV4jIdbopoHjmLtWIS69pZDutBj4vmunjCcPs0sjA3UGYdxtTb9VwzkeXe0o
3UTkwE+I8OiX81HTbqrbbU7kimvahXj16hVWpndRr5EnWSlP8sAdGIExPlzl2GFl6OJKc5RIMFxc
ZXCx5svr9MZNSb9Xmd9KZ6Px2WSZe9pYOHq+m7swQNK+GI1EYyWu1pFohlx1a18l8AdpAWIdLgzE
Lrnmj3T1sq/uv1LpodPpCLoOe57QIxy6KyI+g+w7dOWObsn+Evl0FNFOb5SofnRFtovfTLBwU7ZY
zhhW38XNLsdaxCpe7rWH7KF2sIcQ2VrSsQwU545y/3mC/MsXEk5VJoFVwxzXQbIscd83UXSfUcFl
33l5ZaU+vJ95b5HDs6y0SP170Nwd8Okf4rl4ofMHSJGWdNnwCbWP6Llv22lU0QGCai6+rrTkkyBI
DCsltUU8vF5yvko3voVceZPX6iOYd+d5n+mWct7CrHw9wAJ5EF28hJHrzztYOt9BYTK1jHS5cijG
axzK1K3Zblomc3I9hB5cddpWoezgchGKhcD82Gp3nuqW4bx3Ct2JiTvKM9QbboatuFDV2C1XqnS/
h/6zZx0Vvc0MxvnGUp457a8tZby2cudr3bkwxGt2FsS0cVaxzjZ14xU2pRqzzgVqHl14Xh+HydfG
DYG1i5nbV3bd/z/x3kz62Gm8L6UbbuYxit8oyC++bf6awCC/DexOb32ATp8RBhv92lcIhvorBIPs
u2jmlwUIRqffIvieLw5gmo1fHdBfEsi/TyhFy/zGgBEp028fbvJcxWouf71EzVZjDl4HYVR2TTHd
EgQwEl+MRscVseRnjmLbRhQDTFQhTLmazEnFOqzEcj2oaLOO184dYdqPkJ52g3gaVho608BmHsHP
R7WhR7DL0oS3G9jCNnvVNh7wsW2RE8Vv3lvjAX8GqtcTrUI72IoDw9QRVh4RmoVB2ivomehGNSi9
PV5Pib/1TRqb4h2VrQJBh1ucQxJa17eM+ErXSFeLv8TkpYdaebNvyRRtwepQjVAqpHm9t39x9OGQ
rsh34dNs3Xp+sXd2IVqFC2N821It2iLFVT0vfn93iDyrKv83BrSkldE+OfytTNq8rpsfRFg6bVfD
+CphLY+6mb6a+xghgBk7gP4OjVmNR6ZmPPM2KA8wjlY3gtYCrFGWcSdmfTHbEbNdmFkMe6C4pmGJ
YgpdAR6TXk6FuqO6JFn1hBRIkmAm05UWJqRcNDmuohI9qXpIwV/SvlN0pytqMkZE3qj5R+uy17/6
12XP+Y+rxx382b2yBmhDYOQ2y/lWh0Yzt3MTrfJilKVX8Ccz+ztt9tR93fA1tTLPFNm7evmMe9bX
jF+7uZCfgsx28zjHjBmx2yC2jUBgqGSBj3ms4dim+gJRZ45QTcjhSb0kLdF0dnI6uxTvTHz87S9V
WTBEXVLW3/ThPFsZwTKjpSSKXGHIkJo1Cai6vU2oGqta871qgGYfdTc52HjYUu/LZWLeUj3vSmKb
plnA//Z25V1tXFn+fz5FuSxaKlBJCDs+MwKRJjaOOcHgA3anuxHmCCSwDtqsQhBH0J997vbWeiVk
Z2bSnVCqevt61981WZjpMMRfXOoCq9GIGsh5lH6mEjedEi0C0p0jGk5NPtAraq1+g1XTUpBXz2gA
eBe1/gNPPRgCS43lrRNra8uCcTa7IjkDcsmyZqnu46QcuzeMv+isaaf92EKqsLHxvDT/Zffk3fnx
3nuU8pw2YLjXolcbSCPmPm7Cx8QQSLChC0p5saiUl24pi2bQ6RIdJsQkdolL5KOEXvAcISFBRw29
o0d8h+cOvYGH2NSrp1s/wGGnlL7rqyjbwZPPvHlrFCNdZR3xNUob0avNJHhQOCcmr3OjUi7RsVrq
4tc4Kq+vzqJVeL+aoczAs4Eyl4FF/mKpSN7ehhIYcxmH74IRfkbDGB5he7/MOR1zY1Db+J7/DOOg
NZayEatwb9dlJk77Z7wQkF3r2d9xVqyvOVq6p6j0TJEllBsmIvqvVy83cnmEgxhhO5nmz6zB4teD
Wy44tBtzlzIcFXN3j9LtbDESmSrS/QzcqNnFfKOXsoK6+Ab3DvK59Q0oPesXUHxzXvY8Me4QWFvc
GpFMLRIaA2GmnX6pdRPulnwlHpsuKos0KWXOfeJuqUeL7llZeX/0Zq9Fkpit6O3R8Wuiev79yz/P
/7F78ImpmPsvqKWEs/M5tZiU/7JCg7y043SVWEOLVZEPhEX4plpf480DJhZC0Enu6Hjc5CSJdBKT
15JftPSz4SZ11c9OufzJHZbSfDPFrZp96V/duiWFnQ65hfiKzCGcHJYDS2684JMYNPvaSqp6heb0
9opUlKc8F0+LIMVqJ2fvspS+v5IbrIAdzPFM6/+liCddiaoowSf9HyQRyyVxy8W34lPEBA7UsMAB
9aHQ//Qh6H76EPI9RdfL311P0coIySzULCTKazTydTOe2Y3yaehueS6jfRQLOH6ftWhfiAruatMW
XotNRVX7PkXXyHfFRI40ia2riRqGBxqW/kUfKPu1CK6xqBRtRQ8Rs0DaLWPauYQ50D7jMsCVT6Os
c9Vz5ilrbaC8YcxelUo84ktGhDnBOhhjQMtLHUAQdPWLUdMQk35Gu83ZageqR/GYW0o234xWIYsS
hzul0ECtiLkbrydPCHEfdeCamgp7gDclDhN66AJ1zGggysiCiOIHTRR7WZlkaDA5cN+yqb0tkkzJ
704sl6v87uHvqfk9lXuCadoRlZC7A+WEnd+TzJUU76PeQ2cEK/AeJSq2HFcKY0L3Honcz8h/7ab/
7qR/tqNatbmenq2VNNkrIgVZQoqinbcDOwqI2vuypf2zbpeQAcP9li3Sdon3UY64DrUm2Ipm5OQM
NgcnFMjKgMHEFk8y0pyBNrdh+NuxTImUZxrcKZ6ZjsyMc8l7+nhYFnQIe8Ig34ii02JQiLzMaImZ
so85mK5OOapQnXWlddJyryLTdBk62/bAGjNb2w+D1SkerAApR3qEHo1Ui5awIh4tnlEv3V5+6Z6v
N6ur37141fkOw9ErWL2wP+e9en21vvboj4MyobHGQBncQP97xf2fFi+W6TKLZbrUYpn+lcUidxwM
zPSH14lYC1nDI57aMDpTf3TkvG3FS6EspL4NoUNDBIANMq9/a49BtX41j2mYI/1q0RvG4uv20Q+h
ib4IfbY8VI1iUCSuGd096f7OanT7EuSDMlgM2CtuobM5WyewDeCg17nrZT51AGmurnqXt7XYGOjR
OLPkhelwJcaCQVlvlcrtUdm24IafuOR0LpkQsUWYDYed6TcmJPkZbia8+Kpb2ugD+3K6hjm3TKK5
PNXJZOYx8AXtCJy5Adrp0dojV8WmP2RqfNm5DaVIWP0oHc7vMW710W8o9RWSCi4MaZNe1d6WfcZc
131Bk4BqnmsT4OJGU/6ghalpO7Nqj8FGy17N5SNsEIREsLywxRR7hHZq6MMeWtEhFkQhFAZHwl81
epB3gt2mYXGaji1EUjXfBfQC73VzlkNmtmRXWXMl7iUnyCsq03VtXGRw5owfPZsHXaEHJlsVwMBk
Qn42NqMvOFY5x/6q8mIZW2bKyjr+vtO/pe8VnFkkBGF4b3jtbuB0urAD28YF1MNjjP4WJcBzC9eP
PB0uYz5yNOnj0K3o8aE5zXiLkUM26NYiN6h7c/ZpYCmlockjHlSOTqLhuNuLNtJNRi0lMKCqYAll
MF7d2aAnqEHkKUuYB5wMqf7OnfGxtIa48pIPfgLu6AjgjjUmbGt48pEMLZ82v/at9MlIBl/CqAwv
oKImmR2J1VGdfrzZ+7i7f8D3wdEJjm0V/vJb6OC/Px3v4R9Jpqw23QFClmZZSCejAQ5AO1XCWCpo
AJs3OU3DCHo2zAvZtSaIAAWVr+fqQ63ZT0FAqKiyO70MTCyUFUaQCpS+Yo+8ZqTMBLRKPN5b1jzg
O35aseRcVue1ZMI7A62UOqESNNH2sOp9ucWqFuuVqzyx2hN/WGaOygHdUxkuvJIpKc7RedBaXF1L
9Cjcd7v9r/Jd+kl3Sf4IZanWcmwMcFVf9bdAy7WOUaQ+1i5tFkKlVJbAOMnjpyT+SWcJsOxRmlva
rpyBuBH6OCd/hc/vzPIcJc8KcyglHq85VZNAx5AWsyq+Xq1h81sNoXpDs2z/VAkeo22vbMczCakC
oNm4AsXObJ6VxJYNv1HR8qlxVgoro+xt6NrS0PWZ5vHp7G20VA6FDleqfJUeydKxFB42w1RUjEyy
s+gLcnk2tlK1a9hqV+/mdnH/It8CsyCXjTUoO5+rDRrCpo9K3M/0zXpUsUUPyWO8hDqouAFko2Bn
KGi0skmVltp2qVL/I1mww82W9qOUCSsiF8QVOyfhLaANxY9waqS2hDAUFO0uRhvqsFOTAwzk4g7x
PsbhUFAdBIbG2Hd4GqHJiUAICfqvKWDKxuVcEtxoOXIzCFjE/WsK1bXx6tVLsjoJohhR1dkYekfU
kBbfakdKl1CkEqpMa2ppLQMh1VZkrBn6wxdLhtwqA5R1wYwRYhAT9NHO3zY1095QBHbYOzpfvsNa
q8IRyBxpZCBU3OnGL9qQuqBm4TDROYdLze7Qb/0SSEByYZ9N2O8NzjQix2cTNcqtjeh6ymbEmL0V
oLxtvVMFLwOhKh0vb7bTYiCatYRb0XLgabawUfKKB3ZTzLnyibv5xI7c9bm3wJsWGIpyz9/mTzv1
NUGMxIE0q2kzmgxm1zCwDlbctkyHyrtNiXdqbNPDI6okaKylUxcVfAtZx5Hzvyd9qpMhWxjVwjVa
wE5jb6e9QYfgEcUr+X48vcGFL9vb3k1hAdKC1qzVZSBqXWyYVbWXrL0m/jbWUJTm8LCqPgGrTfr2
fF6ne27ewkzukOTAFOa6HBp6KgOphCIbPyAftheAfMiy+RGMjzzcAe8xtVCMCQ23OC9IUQvLZtqc
UuslhqnqmntL1WEnrGmZ1kXnxiS9nEQ2RoJyYOUSTDIlkmiPgELsdpkHzQs7FmETtkdq+61msvFY
vKF6vrMTBaA2zD2ssksGtXk71BxY/eG86jBr2BT88AaPP+q41C5nx7KIAZDb7WrFjmwiLmZyhY1n
g66+nBIl6CBYOuSCHddL9NOa9ghmwJPRSadNg1AxO1H101DkF890+B2Zl0rmrh6emOOe4CJAn91R
Ufai9qg2o6Was3gCaVDswB3eRIk55/CpZJowtPtAUxNu+oKyYtdR0AsVkl9IrpASb1jYy/lkcQiC
6sqS0MLzs5Yqwe43fQp30F5yBXN05WEjMJ3Q0ovEwKAWzB1SFK3YWQ8t+0A4XTurUqNzqJ/tuF1q
PLRLm/DvC/j3Zds+LbVMmlsU25BvCY/FslgJnpaC5JIWZHU+5FIJOxVSqNFwqwaxKkAOVvVSPbkb
SJ2rP4bu8GSD2yMlQ+aG75gGWftrOO5Gr16+DHzjpVN8qMM6yRcX2K5sC2FgFpoOUKljYcJGHiLv
BfoTyM7rHlkHoKB4ooS1lmBXLXH5omxrCI51xZqeApWCmYL/I12YO2c4HUE5PtPSX8b3wCgQg1SC
3gfBJGh58ay9ellYFM9dfllZbQspOSq6biw9cTaezK2HOyM17do8i1b6xLYHml4Nx8Lr6VWwpZlM
xcoh90tCr3t0tqwSFyeHFyn4RJZG5ZC9FbRRwUemdwIPdnmbUwFIm813xXfCCXp3iUZkg15vEr3Y
spL0s1QwyNP066zfU4lzBoskOlSxwTiNLh/NqLlofJywC/gfaM5wzcod3U4cKMW+Qa+kgMBgyxdW
rVHj1clvnTWGmgtMhavxQtYwN/4KRZw6kdpTQNQKc9fEfHoUi90GtVSGd6H2yRkiole3D/GWJ3aV
zmjYHUqrXgYISNV0dS4U9rZ311Ndxk4hE2V3NpVrs39rOmu5UXqSVmNcqLoeEj+IPqn0MyuUfGkt
qtzsu0YdVfOYs8fNaBW2hvw6JyGBemdJuM5ZxBb6wstavpQtsWnMUi5bPUQO5TmwiPgJ9+p8mQHv
Ei779koL7ti+WMnVNDKa3XQU24W61JtOx1P1QWR28PO0bKyGUcrXTHGrkd22aZXYMkm1WW9CTg+F
TtSWppbhZSCHLnASo/UGlQENsVwnVKYzeM3i03MRn6pWk6BZvPjzr86zXrDjbOCvP8ABf+4uE36H
dgTewlGqXnxLF5QzZzQtnlzXmjBbxBx+jdABiTfQZKodh5ZHSF2vsyrcEutlWFLtCV7tsAQVou+9
gAQ2QE1eL1XV1xMan0x6hOfmBBpYOfm4+/5DKwf4VUeliF197qBAO2l7kxfpqhS972wQ/RF3HXdZ
SzOZSqZ2xS4usuzQjUS5AXi2+5sedWUKthhni3nhOhIiTJRrCBE5/MG6aVoIIsAOHuX11X+lq8N0
tRutvmuuvi8nOaALZSawrKKQa7Ks1XH+g1aOhi/6fff4cP/wV4cU8kwb6bj3A6SKzNdHTEVQ6yTS
gQEIrbmS/ok2D5ZdwFBbE2tAo9HtXwRCLpYj1x0kZ0ueXMmDhFcD8Ryr+ZiJ2B8L1JnA7LYxZOWO
o3uLYSBcMN5thWA95UbtoP9r1wEe3Q6EMdzxYnYq1FjcycLayJVMi7UhG/9o1GNCBpG20fMUNj9e
4jpiKwlgsBCcB1SBDTqTrcjEc6E4Z6TbHMPVfzseJytzqKJ3Gf33Th1KNjB9mABljN7esUjSKyoj
Z5HyN/mQ3keN/9rYiP6bsDPEFd2Eeb1y7BG8sKsUvRJBcYvDryL61Wg8m2YU2IGnMqpDVRTngX8n
NQwGgTE+4m3xVt+JtlUbYGppCtCz0bCdCh5Fzk6K54oe9DpawgwYOrTrUI703xfWtcoGqsDUpzHb
9FFfUUmFDFmXmvQK+jYj23moJ38Em3EinrAG7AeSbRkcnOpYDwbgxY3CE4GtMIF00VdgHHUuEfZI
id1lwBVemZ63fsbU36jeqa2oEuAIufMBQ7poQH457pIKhZ6xf60FvYGzZEUDTJFgaoxRKwY9FOgr
OTh6H9ZyX40H+/4btCfU9S5OLFEfYLu/gYP3/R5mfdQXTr8bE6oBhQq2QZZV6drXV28J3Rd/VxgE
iYYj+fE1dFwJYvWynZJTb+UK7grzKR0OMeTHi1cbnsjIF+cghoC6PjmvQNpirCw30cHu4a+t13S0
4NEOG9j0KU1p7TsDkKZIaKS8S8glakhAMkR/Oc3KDQFzzjFsrXRzY/Nl2th88ZJokSwbRBUqsUqy
49sekDK9PyaDMStfqw6QhaUqJ6yE5/kG6/a6zS28t1fyhq6ElPAQde5vovLh22inFW3ixJQa0bP/
RPXPz+uWzQlJF3mH+755ldJGBOnt9tcTTqzOD8U1mtRynnjp9eGSz4CHjZcaTh63MRysrLQZAd0J
SR7LBsXOMT4Ir1GLbJrTikITdyKXggO3oxfeIrNQGWMWJNxF5c/PywEDo319UjOOBsbBm6hYmMrh
r6nse3qZhODrjy4HNSdmB6GRtfTPdZhRYPEGyHknK7/t7X0Awvz4cO/gpPUiaOwgDTFBX423YcCu
4aB/wwFEJCRkNBl0vgGvdNOE/l0BT/+lqkKr+9HWON4ba1FCccwEfEJ4ri07Str1uKdPdC8kGvl5
ZTUgKZxAbouCtkFFfvQxZD76FL79UseWhQtsDQ5ScZA09of2YNnR3TQmDlwoiif0wb+GeINgd1sb
0fQS/gNcMV0qIsy4BPrvVvW6O+ZBwrT0gFbC8GMSjaIvvUH3HBEuZHFwLxBIceBiWWBC9N36Q/lt
iaOXC0OGQZYQUhNpq2+zITHR1n1QmoToozn2pzQxilyLmTY082RY4L2kY8NlswmeARm2okpNwGqh
GTnTCde6kFxUfZtBDUUhV4Ni60LcmZPFZoDtvMXIJEEr9ZPf9j982HvTZOyt3BpMC+KK6jiEgUw1
vUdxwiUEKy3KWmw57lvATs6N6LVLrdbvYeCesPNywj8Ck1YptPayUOXtb7m7S/PCafL9vZdVgl6H
wxs4HeAYFvD7bNSZ6C1prSRcoy29CUI2ht3JzXX6dYayifT3KL1qwZh0L5ont53bWZbuXsAWuHuM
SvOL/gidOz4w9Y1vJFIYyW/k5oXrFm/bfh+uW3WBodzkxWPZwUpxWjCdDKP0awdF3XjZzJHQe6yt
znePX797jFbnex+OXr87/PT+sbk6F4LwMV2dH+8d7O2e7GH1lqWi3JJsHaeHhi64+/pFD4a354sH
ZBbwjtFXBQwcMIASWlywHgVzpIUoUhZD37EEHBr0QuR2G2eI0KkAE6Ekfr129vjo6DkWT5NEaHuz
98v+7uH52+MjXMVvWsCn4CKfskhVp1alyBmUfmWrLziU4ZyhU9lLoV00Hi2yDzlSMb/T7rdfxgPm
TVWHTBBtFXFCbki8BZmWZ2xWrVZx12dp/lyJN12bb2d9qBsBVr0KmUeSamyOh7XwJPiknXLEeCGh
DaBWOdM9k9iP8iV0WLDoEOWkumDIp6+oiBmJL43uFo0wvXeZesxPaCkjwwE5m3jsGQjnXtBgYzG+
Bxmv23fwxZpEJtFKc8qALmAhW2BZu9NLjzvyd0rIsFlWYApjPo7ewAw0myp0b7MlpyBp5xG57okk
OGbdfnabKvKsnRufoh3gZAvsA33LWp0MdOc5E2lMxMmOEPmJHCEM1kdClI7xL2HuBzGufFlGRfFI
Yr5jahL0wVwOHz5Ql1AVkQLHmK8WogR69SAsOgoTbJxAd7fZwgU5YOEpJ/ltWt9cZJrewDC0ekVk
NN29ixnM9+H4YHyJxoWthjtV7nbEqwdoOeAt13nprcf4+2aK1iPMI5yjt0Y5ty4wDhFeNwiKtXv8
6z9OG2ewUC7veqelBuJQw3ohrm0TExgOMKFZMGmISMjvSgzPlKFgb046QUhb2kCHyYsKhgasnK21
K/VqFMccUBU2NgbOLG1KkmZtTb6OkuAhY3GtlVu8d9vrMB/t9TpuwwrVCC9PT7IzWW91nA469aCH
CTH8KiP2R3JyAvidBDZSfl+pEng1SRkwYP/B8YdKNB/7WDZLJLUO0Tw8DsN59QbFmEB8aB2O9YVt
7zYgQ+hvGUUqjN6oVgXaBVNf15WjdJkZJNycaivloDglQKslt3C2VFmZAydxDvA01/Knwmb9n56S
Kp64SFnUbsKxLpjrooOzoKTAEepdGtZj4ZWkr8PZSC7EuUpmX4wLLqLgGW2YdDj6epPM+D7pKKEq
5BuznnJAVtbZXg3t1YmAjJChxkaSlo2K7AySplcd1uGULsWpSmwJhiMJqfSHcB5X0W9zNkB3QwwC
ikgtsshV3F2nPs0WY7WKI3Y/3tzliKWbO6aBYJIl9tp0KxpkiJ9WR768fjdEy64/07VAnNNy9vDZ
TfXwUC5aR1pqBOfSJSrtZf//wwoFg4e1GRNcRSZAQ3raSf88gyOxjhHI2rV6G/69Lj9FjOFoYHA1
tGD58BFuFBSTo8cZWyfCHvlMpmtpbS0t3dxV4G/yc7vkYXjlqCl7Z35lX/nehNentcoCS9VZ/mgq
itJ2VOuwHAQW09dZH6Oa0kYgeUojz/g+V/sPV/D5oD+kA6yfE7wVyNT8F+hmTlBEYghsOv8HEp3o
MXg7nty2cpW23Alz4QPDBgxSonAQLQta3hZpMj+EAhNmruEBxnnYuemxVZwns/FPgifpzxKynN+0
PA9a+YfEJfLOO0y4kD70jniLEnQovwAutAaSDnwrQIyu5o6YMCm3BPGWQ/7EO4CxjXj0cmeFgl+G
hMV8VSEOsyH6LpPADOAak1FYbjKsDGZefLcNG9k54eVB9aZyhHqHmnBmfVxvPxVQHv4/uX7IJH5L
ZfZgNlsaKny5vlVU+qToQg2ZAX5/U2EEVSu/tV5/XxuLci/ZYBff3T2xcSknxVu0zCnWygvbJzti
8dpw3JJyB71zVuf4XGkfHEvBE989l54zBZmKaSAevOm0KaYDsH9FZ6BPf4SUT8UVCqi3aY/x5dPZ
bX+QJS5mkiXNzlUSkG0/02YGbnNSILEmYdvV3NGpqT+5/irWoQ3NtAQLutFaROb3LIkLR82VNXxH
P0X8HRjzfEqNPNzI3blaAvDdI1aQY+nqfQCA59Fb0Xw5ijP/xleAMd4Fb0sasfwiMplLBZ78r1GA
S9F6+ZjiXLsNDysvyNlExQaeJnFunmSQLEEvCRyVgTspoFB4SLrhY2Tl38KfeXQhHDyy3B4LP486
+uOKx2uXGngTXiRY0IZicGMly49iVDqj0tbJqTXAXOkzLFjn/SSHlsnLqWCidqggq2V7h2+gdXgh
V26kHdQq+tHxGsVULpZ7I8XenClGXITh1njxlKA19PTKoKeT5q7lBweWYTUCzcuolqwUnJXuwrNM
CxeET9I6wobCAxJIE1Gf0oFJXrZVheEj2sXbHioz77/0COmyf0sequLeJqHELJigzjW6otuG51hy
M/q7VEF+yuheZTliKdOYxN5ZqsFOL54Buz+77aKPBez+9U2cEirWVKiMRHO+NGjN6+xPozbdsvWm
jQA+CU0ANNz4TPDgtOK3u/sHqC0rwZUZa9ZCf0ZIJuWNX2KlraIq5ZgP9pNlKUr5DedOWUX0Cs67
W8ZGqAx9GeqSTJcDVaPAi7Kp/lnjnlCkascBAfU+x9Tl2Db116v6LGQqob7a4aanViGMxHDjKfJ1
IGyU0MQWlHlOlhHOn5EmTjKHdheb1uoLtrFswTy7VC49LpltgIGjKddcBqSZHo4N7yGr53HJ4mTT
ptZg+hmLNpi3PdzyBSdEk1QpjlGAI1fOirJucatvoon2jPSAl6hBHtir6TKxtLOWobK3//JrNWQp
YB9lRKlGFXvd6r2g3agwligQQZb16SB3sVv7LCcS822QO6oGoBzUUFWji5mKBttqx+RW0SbZqeOF
QRYM0mvRUlOFedcUOeF8m/Ol0C8kbw7vgklnE4hSzFLykSSsKTJbXxCw6BqIyXRXIOHN7lz5/ej4
N1fRfjsFAqOs70dMEJejvX/uf1xZ2T85P8bxwrCqYZMslaKxsnJ0co5ah5amaqC6YqNKk3qRqeT8
w/Hex4//oqTNtERaDWU/ieCPUIr8alnE1MrB7slHmmihj+qfL/DAsvT3QC7UMeRmHQ+iZIUivXrS
BpGG11WYKhapkRgzXatGx+/2DhSFWpcHxdXIr1nvBlGs0a5L1DUYeYbLYXnog0hBH0Qs+nDdGwHv
efmQ9a9Hve7DXX96O+sMHgbjewy+O7r8JnGcEvW3cpqe1zCa28+lMnaDwdAQLa0eBEaraZLDgsdz
MMTYvn027aDAPWF6gvXjkAIFDBjbqI+Oj+Or29oJ/Oe+M+1xLe81LlmNAm4dZfx+T+Vtki0XQVxx
PfXt0U5Nw2F9Ebh0qBTBTonJ+AgzB9c35Mn6V8COkx7g41hwDKrRsPNHfzgbvpEWq+NFuWwi3B9d
NlwT3zuGsEKE8V2ybhdLa2rbi584Tk0rBCYIp4r4MVYI8KrVSNimegJTN+72LyNoai/LCJ6NLYUy
Z8xef4DJrL2GtcKjRJhueohEC6qLeI9IhxpP7JdvmBktXmsczD5jQC8VoYoDQit8wIqJGUtrgtwR
ktpKB1fGOVppX5rw7NwZIMNUdgWvIcEGIT/yExiKBCMtwZTA4XURdWdTiczEGLLXbCilLo5F/p9f
+sNu1rV5MDnQoa4WulWNoH29buwYeHWj+nhyW+/8eTlkx4wzDhOiGWnzJczGUuGcAPlK4SkdstH3
7/xDMZBdYxh/36Ey6j+8F/LcZxFDCUPeMmZa6LHHh+ggk5912UwBdhayIBJLu0Jxq+g/a+2krfdc
SVBWVPWjfPUGBhoaktdfZtrMG5qiWoJJdR0uukAuOpDLhBH7ZVpeW4v1MRA3Y+jH5xh7ECt8GFMe
LMglSis6SeJm+xRLP6PxOdPwMxSpHCa+HJft0NrrFFlbm3tdLFGzezA90RnYVksU6R1+0Ad3nvPl
kiyEuVvgMGI+EONmFJ8yMvnZWlyWqZRzk6eS03kL7AsJ2jHwnx6Z2hqUxQqtuFSvWzXjqdAqVez2
a1kPHYGvkWBvt6ExBb34/naZ2vFwatlRkThqU8CYMbhWO9ccFagSWeRUlEaBEtFtL+woGGFQ1FxM
IStYArTRkhVBnRyaCK6jkMJHbh/vnTq7i3FUS3ACJs3A1Vbl2w9vQ2pLVAF2aACsEMzRo6bbS/Pp
RTP9GV6U5rBK8RF5C/yZ3eIvxJ2Cp/WqJcsr4eOjDYDoS/e/o+Vwm5nGY2tRclSakwkn3dsV6kdp
jp3AFuVxH+k2Ed1IBvvAvW9hbwZuXNgYC07/xbd6uqZOxjV9LHpT6g8AdrgiPfYGo4jSiPNq1eJS
tVvE48rK7sEB3vwne68/He9//Bc+M9GKT0DpvgEe4DV82X+9e0De3L98+vXt/j/pce/wHVofv987
xAiStipPUR8Bv7Aq3b3ksHmy949zp2x8sf/+w9Hxx93Dj/oNMl7HhDcsLw6OfkcK5WD/hBO9g4cj
ila/pRi9DfUEtPfuCXAJkP5478MRpfnw26/vfz1uxbPRzQh403jLhqvdcGCAYwRLzkG6jq+uIuQ6
EMmk2+sqg5GMvR5Tk4H1HChnQ5kNcicKOpmaevLp4CMKqWLCLrApGdHIFyswnket8D+Rz74UpKNS
1EhAfY4Fr3B3CyCBc3a5XwuILhr1hjgN0Y+NvD6A5M2RcZo83UZLGdFr7pxFlW0Ez1W/o20yNcRk
sJy/7JzJiv5fML6jg6HMlm4MNIN8cR3PMBtxLnM+5MaHVqawoK6j1uTmWkT02MFWFAd8tl6Q1Xn7
tI6wLJys9GIruiY7utOz0zMxpEODYU8xuZxhXjYZ9G/JpK4aXVVRlO5q05Gma4Vt7pLo5yhWuuo4
ghtfcBYC3l7xaUxFxSj6x46jzL6CHUIdSAwlkTkUawWgpDiJrk4bJsw2SfbNKJs24plVqtxfwhVJ
yMWhNHKIqUmw2H9n5rS8fy+yjSsTd3nKllrXNnMoair23M1sq1jZIBoF2nZJRpZ4OBaWSVx8b9li
Nj5VJZxFp0offaYdFjFGFsanFNctbcvn1ABXMFyJo3pHrdycjSuNBNowhhewLzLG19ov0TWpmI0u
kQ7FKLA3lSwhI1FipjLX2BRm/SVMNr81ToXw+oV+jd6D8KIBLza8BR42ccVt80w0WVN2/cRmoE5q
J5qi8okaJDow9Q2RULVaDL2iAoavh29JBQW5Ax/nS5u4YgNH0rq5bM32KRmBrbfPIsoG7VH7Rk89
7Jfp6egMerGBGy+CHQVthhfxmdoypJvbyBko0HHL5Zk1z9aqpnH68i2eaqUOK0N7VbOgxW29Jttn
FqXv3Ogl9eR8Nvf7D1SqF0yuVk0kbDivkVT4gXpgBeoaXPgkzkqUuqaZvrcCKZioq4AXSNCOhxSS
DkJUsbGdt5mFJGp4LzRl5OWPl7Ppq8GJnvFAuEaSXunifEKOR2Lc+ESZxHdjACC4gcuGWFWHZJ7s
apLViRPnghWj3d5VB9Ux42lf8Ig3KcifaFhTTc/Rd31KBlxo2IEMdlKI6gvaXUVlZVcyvjHskGVR
KqbBgirSnQ0n4YL2YPWQtecHof2bzU+mEUrZHlcaD53BPRz4SVz2+QtD3TZc6jY4mN7VlVkMhrIW
farR2OZ8I5vNyhHPRPoBv01HD7vsRZzK+8S3uLVGIU2jspqxMvu1Wh3b/J6OmciRxptaBWjUxl5m
yb0DenEMq4EcXpgRHF/XYRzqX/hLDX4rw2pmpMewXmArwntCwR50kZYi/T5Tqke/nijLFFjsRWX6
ckIlnnvhi+ewvDwZuox1/p9IocE2pyICnijuNV//fIKijvQNelShJ0iXL0+8hOBWy26nQL5Wo0Y1
+sknTeufK2JU8iDL4eENMF/8xJYdDx+QAoIfsl2Spo9zQOvvkkjchrp1S3Lpwvu8Z0nmUsMi6Vpv
RpIpy2fBO50p5AxDrE1v4U+9DbNYT4KOd5W+uNZE261oBH/X15NAs4kuhpQTiVktbWonqv2TsF8M
6bYgm6SP2hVDZsCncKY7K4fHA9wl8r5qGNuS/rZS5JNDo97Sxj1kTqne6XkEckSKxgKJsC8slGkT
pP/h/1gSPTAiFvzvLpfJXU6PFneGOyb2pGqZ8zEoRVNig1LFmOzLu/OD/cO9k9gtA/ffpdsZi6O3
5YG6wIZfwiUQ6+llI228SnLywsQXVTnBGNGLyFQX4DntphByixZZ4YUG/M7VGJqE41teI7OHcpRq
uuXj3/G+DWklHLWA6kG3BmdGQ9NHKyRUs4FpRlchTBorBRpW/oh0g7SvV51hH+74RZKNJ9sj4gkl
AYEUCtlEvUJkAy2qENlCXOKvMd7wdLAqnb5ejfDbkUpT9uPXrdLP1LHGxoY2IgBG8Q6GllFmNiSa
aJWoGYJhtEUyx6+LpDEsVLF+slhJx+GjBruNFUPivNCQpTWecGYbV81OjYUt0bYRw8DVPN6Jq8J1
MgMYH11k40GPrE8U7RcjT5zd9CcTMVwT5bxJCgc9mjY8CsP1wka7qZzIvd18OIDLNfEvhZF9HbRr
p59rZ2slzYkprmokVowWO0QzpecNOOsuqQOl27vGf0FFgVCTpaZPUka4vl6ysK8ZbSubeRggdD5A
j1jFktehKzV4P+rdTTs7dvafmtIbP7uNIKYyRtv9LJv1ujv2AlELEw7krgVmH33aB0b5pFXhNtMx
wEZPqe5PIiu/IGmycBfEpTnnY4P2RSQEQxnpyYWWHhKs0zwvBNskP0wcr3bt5xKJwmgwW5b4CeFB
72wO3KSX272Ht53I3F54N4hBMaK6PldUuQ8Xs+ur/h8PvdEXtItAGfvDqHcv8p6H2Sib9C77V/1e
N6GG5W4qaahjMWu6xoPwEwkCuPkvdBtfRo/cLvUN5cQF7ZeUKJdwHZFxJNLTz+nZOv9XExg314kx
4Id1hBc0bu2A7I7EdW24sqgv9AQNWgndvsbPR2+dEyWBQlEL7h4jLWuRLypSw74gLOA4pM+K9G25
DfeVBY3xvylvQsXPFIWY8HbzKSlUUAIVWr8te6nybF+6jtgsiHqxQEj1whFSwQpYsIaxPl65UBs8
qLoWZrDWOOSCX8FczhqzzMrddUc0c2lDy5TZA9wR6TqyMOU8BRumgyvclXuxnEtJikOir3DHqGjo
fqJL5UE5ixekh46b9NaYhDJ5e10y8ZF5FpKDYxKW0gVE29bu8S8is8UGROCG9A+D/gL9A9tmmHRP
SNC9NGEJesM0XbdzGSG6JSwrEIoFmmHJJ5eRQwZKWCCQ9IWRSwkdC6rQ0scFxahTprgUFlY+IZQM
5BWVrJuVV304g624dXNZaz+fVU53QUpiTNeKIX1Y+/lT4gVyQRtPeK9iYdWFfMTcbH1NKSC/pKAw
Od1cskVxXESSWqGHaD3SfbpDQZQTa+r5QykpU9ZEmWJoNzkTFQfbazcA+OTBE1XR8LVPlRlp+wzH
r7Awqnzlh53p2Akt50V3eGwFxvpuDzNDph0bJJOQ25fNs+Z9vhxxszboLqBOg3WKg/RfrNo1YedP
xSyULbPOy/MPj10DrM/RWnstWqtrMzEtri4SsrMdB4FmOV+aadbrhbr66Au+iywLPOm3LbSNKiL8
JHB7yCMI+JfDrs6gheIDh6s5OkFxqrCV2mHaaUNq+4RMnf3p2H72RhSOmnmF29iHeJaaGu5eDFfJ
VdEx47/8sfpdaTO0xhK62+dGZzIZfBOr/Kw4kt23XvaAURweGom1+U1LKaLFwvrDoyGLmD8WLeJi
abgzhk17rg29UtBxewEV9lutpR/s83yBhsJr+jLL3GwGR5gfMku2lobaTuGm/tWV8Q11FvqiU3Xl
xmbpGTWb//smU23/4iWsueBhf9QfdgYamSBZpgPfN7mmF4Xzqs+rglkNqWjIyH8yJKhzCrFdUao4
wrAXaY66qZOqckA2+hkfxHH/8OQj0Mwf99/vIYYjYTpGQfxGhfToi1PNuCjB6nRk2avmJM8B4fZS
gm1HDGysdENi6C7eWFqM60rE3QiswJ2T4PjOO2ZdcMDIAkuO4Ke6PCsWmuhtFjC8pWAkDPAdl+6U
q7MVXdRuveYqtNzSE3iijSgj1Vrw+kOxn5TADQrBtorbPokl3MGx8l1j53S6gy7Gt19Y3txHFeIP
uKsHCBDXWf1w7/c94tf+/xzVjeaQK7dsj9UL8lM3blbxd5sVHLtAUVZZ1cIhVLWrOeZ5+cCMpj4b
hsohR8UQZ69uKAbpXbSl6HW1Vw9yGGgMwOZQOvIFZgCqWUpAK9ciDE8LEV+MP6yBEE4bY3mkV5bJ
Oe4eBKXRWwgdr3N7R2IV5MFpyGQgKqlMGohmfEOei+1TinOMgXw57MAcvqyuNtesiL8EB7KVB3sy
U2/FFOhn5xoFVT44HpbUkqii0iRKVWJ9NaoSs3EJgIcGTfhONdpLWMxYtZWArMaVoLRgxgSHTYDR
X9ddIrFKKyea4hOVobDG2ou+qIuDgn+pbM5Sjm3mQi/vNF55/W7v9W/nR7/BHpAJ4qOI5ohOI5gg
nWhDx9lemVsOnKl4+I6z6MDEQfW/1ej85YhN4kGpQzX5SRUckE6ttnAwA4cxNZlOXh/vf/io84Ry
jGcItK5YOts6CtVHTnggN0/NaFA4aaB00lNZbua2i3lh8q64wUTImbt+GuQKC9x2cWbx2ebhkhkM
JvedsNWZ7tiHiQdqcBTQNoQ9KXQypWzK2ZhXKGQZMPEXsLkShtknYqYvIQjwoEDcolFXzHFYWm45
+AkjRwGdSoYK24J3QoGVDDWmHZl92+8QdgAXGtMTZ8dnckvhB/VyR0XjgmlArXWYJDIBOSmMakEG
7p81KoEpws+ys60exwtT1mC08HrkBWBGJLwIrHxiBeWEGwutMkpWw/BIU0R0Xxh3LbTgJNRC5AOM
BHJY/rw1QYrn6uZ5uPhmmj4+gRivmlWEE19cOZnL2hkCjZUDXrVQ3ebQrNgOnKr3VZHpQ36TyQRZ
p4iV/+l89KIL1EKpoh+dJiRxQMSkTvoi/tytTvY5Ti6soIOD+Il0mkMqKVH6UzkUTcUS+adSIyZp
VEKp5lMpNaVQUvd57KMfKUE7LhO1w8OFaTA5k8cvjMXbuqgFhbHMO1I5/IIssTeXVliQJQaPnGx+
kbZ+gcosLFKpO60eO5lDJWv1RHC75UruK0VF5OUOla1UFku2eijai8jNHCr5gKJuPDVXumQMH6Tz
WbaLNtoj+pH0ro1OWCO+koSwd9Uf9en6l9jByPWpwDHT8WAwm2RRd9pHGkdB6mU5YjzczNJNtOHy
o9p5zvDod53BDIlOxmzp+68RAwAojH5KVPQtnoz8iYKLoCscxjnt4PAOvq0UAL90Mugf4cq4xKmX
XtGzlFJRvyvB44lCKjuZVacNKA7R2isrQucL5dnU5DYeXFElfzQxGiiv8rla4s10VO88ash2OZdM
QAlzniQ52KSmuvyqAt9AL4hUk8a9z8VIQVn74luPAtnCpceXVWXZqCcJhlLRcSSci0s3XO7spn9p
s9WlCUpg0Q7YKhWgFX1oSZblhhs3CR6h34wF8z8g1yKPN+kAAA==
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
