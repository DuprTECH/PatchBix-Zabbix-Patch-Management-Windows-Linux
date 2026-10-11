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

# Embedded check script: zbx-patch-linux.sh from DuprTECH/Zabbix-Patch-Management-Windows-Linux b1c5fa6 (embed-check.sh)
CHECK_B64='
H4sIAAAAAAACA6xcfVvjtpb/P59CNaGxQ+wk0JnedSZzS4FZ2A4wC0ynLTA8TqIQ7yR2ajlkKLCf
fc85km3JcRh69zJ9IJalI+m8/M6LlG581x6EUXsQiEltg7n/xh8g99fgqzsP0uHEnYbR4qtHc+xN
+PCLYHMejcLols2D4ZfglrPFfBSkXLA4Yu+xMwuiERPQSbB0wlnCxWKasjRmfwSDQfiVLcMUqf1F
TzfYkSctfI+9T89ZCA04B49gFJ/Np0CdNXY/fGAfcEVsFkQw7QxfB9MpjGgANfsLv4elYQev2SJS
IphxRs2B0Da0BPrxUnhz0cUlf5KPjlfbADLni/k8TlIYMk+Zvc8HYRCxNvs4WETpwqGdjaIxtNwv
Zsw+Ozx4D5/P4uGXe/i7O50F8Oc0CYZTDh/e8VGcYMserPX0XE3xazBdcGRNkLJRHDVSxr+GIi3Y
Z4/4OIzCNIyjFvAxuQuHnJgtWorXLImn08UcnkdJeMcT0QK6i/ltEoy4gFUmHPmf4r47njHhMMAJ
B5yNeMqTWRjxEbMFBxphek/bGyxuxyCkNlDk0SSIhpLTsDpgSQukOY9FmMYJ9L4LwmkwCKc4dDnh
EYviFJYWp3IJ+ITLkNs+W0QspCVhDzZO4hkbJkDWTvgwns1Q4COnxcZxAgwJQOzAQp4O29jJG7VL
GukDScY6rNneYU36R2TbC5G0p/EwmJJxrKoxe9se8bt2tADN2X77fVdKnacpaLRgNo/uQpiPtnwX
JGEwmAJH5WR/7P7889FvN+cHJ/sHZ/AMhCeotoYis/wHxRiA5vtmB0entXd68o46g0LDjMM4Goe3
ZCDsMBZphBrchuUlIKDdYQqyptHln5WpiNy2h/RgvN44ko1hJJkrX7XooVVJW+Mo9mHteJ6qYbIB
5IXWptYej6XRL6IIMYLm7FUSxl3GC9CISO1+AA+0dbXeeRJ/vZfLRZKg+AG7jZHjIRioZIpjSubs
V5IMLBGMJ5hmiCOoL3CCSDI7jETKgxEuVuetQezD6dkFrTMnhsCAQ8zZCt53O51XXYPG4el5icYE
pMpIrCABtTpmLCiTe48pwmxB/d2omotodxr/J2BgUZxTMe0paz0CWO2Le5hz5k1Um1z44dH5xenZ
7zfvj04OzuE5WswGwDlYFxgQgEgoJ1MwNAHcQiQIgZDGiFcdSezD7sXeYaHjEp1BGMrYlKoQS4rB
mloW5kta4JCtfjCJ2MUkrZzNGv6PQ9g38GAWpDraS4s+3j06uTg42T3ZO7j5dHSyf/qpb+2wzo7f
6bidV/DbKniceblZcI/4iRID7wPwiaCZ7yPhA4AhPqqU1ZofexTcg/a4P7I+O44j9xyQEoQGHz0P
Prfg1asWA6e27e1Al22Y7xMfgTRgnGT07seL05uPH/Z3Lw761jiYCm5VTZQmCw4EUhAbE8MkBBen
tiE0qQo0Lz4dK1n/nZ3MgjBKeYROg0k3y2zXDRZp7CqNyWEfkR4XCusZYlgBwpne01wHv+29/7gP
G/nCk4hPYd8j8K88cYfGrlT0ofxa5m/kNODTluF0NAwSiEFge/ESXAsRPzv4+fT0om8hK6xndiLl
yIIxeMmcL9LHcT7CCbLVo0NEXIDl4xQXE35fOOAi6LGlHmscwjBFNvKvw+lixLNHNV3WPEJclm/k
qjy1o6w/8leO8SQIyDglQUAZ3JNklZjZ/8QDZu9GIgS35kiwdV0xiZeuHOnlUxVEmd1ho1CgJ4Qp
uxihCT5cUMCAuwa9xDYg32I7ysaLEK3FfmCDOJ3QmiqoexCIQBgBgd4U0XGZMxt5qBkZDAATDsEN
Te8902mTTmVsJiucBaBigj3UCRw8BAdP2vdTy2zVLOcJ+Wy8VJpYHiN16MnxibXSdxECFlAFQGx/
BK/zIUgAhFKMb4u9DO4pXlcNLhFwM8ktga9cmiNgHDAYH2ItfMXduviIO3Vpp94wABsCzfyaGn1p
KRgbFxh5c7y7d3bqeOwIXCjFxmCnLEbvaA5rgbaHIEmAigjDQ7DSILqF1WvcLrRFaQ/SScIR97P1
SwHlFgotLWYxm1btWGA9RC1HT2o3XBYZrYQShMhXOjhndFqkHUpxfEI5CSSzOahoH3FhgrEIzO6j
b8x1KdM1IBCBnYToLpXha6beyglkBin175ScjZCexLAiRKckRPOf8LLTA/f8X+enJwhQhI8BRR4w
xbIlBSjbq2MxWoDAWbOFGnuXdg/ZRMrcfNEgQAJYEB2wFVFJLVhZt/rJEEL3AxHiNyZC7SLpaeVx
m7IOYD+iwHPeosotKOwBUUMjQGnMgKYA3XFalDtWpo7Vwa9UQbUBr+lUCZE4Y4A/xQiR5I3iiO6o
GGmhTFBQ/+9Z9xWDfAmsnpZuuFzpTXAKCGZjyF31La8JfokNoxjYnIsiRgbNwdaUDjAQIU+WIfgZ
FCpkTuHtBCxpGdxXc2Ia30IABXkLBOy3WvKjoBYa2V0YSP+r9iwjrUxxrTdy6rePbzS9giel+vBJ
8vatVbmCsUoGJCiaEGhABbDxLpiGtG0cQJaMTZipIiMJByvnKLpTbGeT9i2lLAminJ40P8FOfwGl
PTg7Oz3LV4ZArbZeBcDP7gqMeDGHfBUzXJ+t31wWJUsuHEXEOqAyxULHS/aEm0d/m7lvIoRqDQuW
OYjG5AUILOKSA2D5Y/CmQobKuwuw1IT5bH8hQDE/JCEfTuKR+ILqcx4v0PR8NknTufDb7VtQ68UA
tjBr7y/mycXB3mFbmp1LMbd7nDt1V4XRLhUssDIURykgmQ87H8c/jWB4ClN5Ai3rfTjkkQBgPj66
+HcXqoAemShmPaQHlK1C5u/jL0BBMVmksFIIogHHwFsmX1qECMJVzESIHAJzKKSXUsaRUliiBp7z
sK+lwIJoG0UG+Vi8oA8iW0P9AUn4Wz5GEIdPNf6VwkV8wNX/CpMAnkuRFmG5rcUTssm7kz0B3X7/
3Ts+9vb3L73omtleBC4uiAgqlAUU2Q9mCMAF1Ryq/FrimWpUyiRnqZ3vnR19uLiBxPb86PSkb22/
9rodr9v1frBqNaMA0rfqD0aD7xp1jierZiST2N9o8N1XHegUjtklc/9iVl2riVjsukf4XMvsb1gq
WbSrKh1rXo+efy3fXtXMskfRed0cBvHycKNqUklofY81JM3CSyXNZ7pIoj1wOTlZ4PsY+D4EbrPv
v9drUn1qhbYBZBFfaACCTG0cYuCTe6Vv1H0g+RuyN4hobzH3Rg+GlT6Ed6wmOC+R/bBft+fgIznE
bcmtgPRXK+A9AiSPmAuGfsAaov358jO7buqbtrcfRw61Mq8Jq3l0s0D7kvWvt2x8teV4zfbVTnve
AHoTTJqAYNepKQ5FGoe+wTDJnpM4w2ssaAVZZiJLT3Ek7RzDXV8FOrLwbZaqFDvloNw12bJa1Zf1
jXGYUNmY9yQ5mYcm7PLow93ra3oEtCgqTv2iplhBHh1TEW9kNSeP7arQPI6w6svzlFKOlaUCn3IV
oy7W727/6HXgX9dbK2bFUu2FHPty69dKhLrC682VZlZ0WGsQj4/IGPAPkE1k7wUoY0njLn0xD4bc
v75uSuHoLX39AZSt1cufN5TedVHvaMpHRolwoXyaAop1KxoGICx6H0YGXFxdNq+u/aZTkkr9QWxC
81Nvpd143rgsemAhFMdtbDSv/SfW6xnzNP0mzsLK9ERFR4c+rC5IX482W8Vkjvrw3GRcBEOdf5p6
YT3WtF1seVaomck8J9Z/QagvWVRmg8XAVTQGoz3MDLx00AAzf4FgOrf5PNXWzxokSIXZwRAERfGU
Dhn0UjGzX1xE9tgnlR7m84Z6fRpBDGihK8jj4hCPWIqkLwOoEumWLCMAdubYtAosGi+V5ax1LFQN
eXf0niITvVcOOmFEsJNrB6qGWnS/LSWsj3PKUDKCDkBDrQc+9em53bTyXsYiigdG4wpB44cNiGX5
dCqLpaoe1z/f2+784zW9v034nLmTPwVrfM54328wnSoAyDoNQ1VCCdgOeyByBJnS5dqGLyxBOMO9
YbetPnr7EksqBuYQrw9cdQFVQxEbVuacl95XDczUwhgoSu/lQG0dGNRa0PCAIy5/un7Ch5+s2hNa
3X8vsMwvM9Y8QTTtL4zmYAeo3rU/ka8yKx2zhrUpLNQeO2vYFPjYtVRAA4p2dQX/wa/bHhNtCz5b
7duGY/UYTS7PQCC4RzsJwCAgcMDyFWQ0s7l55LPtXcACbTw0gA9CjaF8E3zJxKlRkgHNJcmPpPaB
klCOjsr8E65wa9MdSU5hLombsJkN5gH4Brn2j2yLdZnjeHX7/d7N7vv3/T1WHh84ioXlbG7laKd0
/LMyoFbUNTG7KJ58d/0p0pO1UjvWwq+15ePmU4vS8hSybD0rLxU5ShXRVrnCAiARYN2VAiaMtqgi
JqoqsLVy1dbco2zzXRBQmJAdW/XireW0X1AyBl5kFxJQK345+L1vkUZbzKaaXIOeGhhVSk3fYPKs
PnUIStk0kCEo7aJVrmPg2xru5eaWpyUFu2NjCf0ZvqDW0qGTsQ/jSe7ZQqBFC0/g5VghCZECs8YW
QmIFm5es/rBBL9GCIY/4k3XkiISniyRiHep2ZwQBVikIqHfXun9wBIQR+RQVPl8FaXdGkHZlQTQD
0z7cbVxZEP/Qx81NaDbCnqtG0a2hdWuY3SgyUu82ild5LGQizR1ZYJqEM8IlKRAIbrs9/A3Bl4Vh
2ebld9pGn3CRJhnoY8lQTe8JHSVOVZyu1m2cFFEj04qKM1gHoDg7BKwYkNWdoZcs6CLOnH462O93
a4rTq4NkT4eEk7DGpb+Yz3niXzfwM56m4WcHBcSi+JHO9h47j/EYUKc0SQd4K/mql4A766fWur1o
/nsuHrGg/Nh9jCPHKDR387k32C94eIMootBIQ64amckNmPM5MDCzlBUzkmawPvS1L3fdP24gpDWU
X4tvVynKkgV4MUxF3QV8mgMEAPyLEUBh4d5a7RZDh1bUIcmRKej3FYbYK6AM+SxldSuuAbAjO/Cw
5b0jPAOhayPqFkUwn09DCDQlHolkWMKj8XoQUlBLKzAByUdiVjnwSwgQMK1RPJax2Z8ALM/BiqUN
g0EPmYd9GFMyBNNIyELjykPDJ3nmXH3YVuYTsslg5rfO4kDbzEM0mI0O8TTOCmLtvVGzLJ0HotSm
i1mEdWKtWDQKxGQQ4yG9U0NuHv3nzfnH4+PdM3BDlpRTMCqHpIIwys6kSHETAH4pUTbA3aS9hX7U
bPK3Wuypvu2z+g7ZC9HpKy0kCUpR5NyiECZbYAWEZec7MNPqS9/Njhufil3qds4s7fAFtUKuSeth
kSPramujux2wcXog/HI04hLDsnOxjKCJbH+XpsLh7FQU96qafNeVkcVBfl7py8ofKM8cQiWMnLPb
oxi6CDxVLN3XIBeAscHRu/N+o9WQ9xncJGA3OCN78+YNTKlmtGpouHNpuA/UgXwxRQrzwovMNVWZ
K+NEEhQ4zPPAoRaKm+ywt6R+8xwmstlwfD5ZDgNr07VXOwVUQHDSZf0+q8/Z9WpMkscwqrUrw+b9
LOxfPVb12Q6a+Ce8n9KVt4kw4Pc8j+HlovMFPuJ5OUuo9o8H6m26c/QuCbEA2MwOO2U/vHDUht9E
0Lh3VEoi9nfB1dgzrG6CyoD04OUCACVkAtBILCDDhEE30WJWYmeoB0hd8n+XXffHaycDv24Oe6zw
vHmGjv07oLPbsPEf2Cv2WoWGIBZc0mU9xICsj8/dViuDY4WsmLqEKmEpJgF07VWyfgOZcjOjHOUN
skDM+fCt/AjcWHL+BS9xFS3Em7c+LJAG4d2ZKM4+b8PS6QSUyNRy0uUEnA1WOJTrT6PZcHTmFIoF
gr32mo5RPAsolyMhED82mt6T5WhguW10RyZuS0yw6kFeVKF8r75TTvhUv4fu5qYn3Z4enLrfWMqm
23xuKYOVlbvPdaeqEK3ZnSLTBnnhJ9/ULTc2JRvzzgY1jte8VsfB5CvjepCFmEH5M7vu/i3e6/E8
ocDx6p0KCxUP1O/w0D8+fuuqvy00f8znIoYVNoo1MUhQh510oNyXhTe8fqLuFEKCLKRfu9nduzj6
9QBvgbVB5i3Ven6xe3bBbONAmm4+yMXk/U4Ofit1A+r6RZeieiGvr8hhdGhfI4S74WAnuVnoa+qD
sWqrgaChp82qPRI1jCm06uuqX7Yq8kJphUsyUgWasHZwQng3ZoBGOWLyIscMWddhgnEFanKoG8gE
HwkIyW6BghBan4T3G5/ty073+p+XHfc/rh+34c/OteNDGxgytTnutzrUG0RyxV3S9NJbVuw5x9Kl
cmfYfdWdKWqrfJCEl1a5uI0dFUNXDi0KHM36dVkX/XL9n6Tz2yozgVeZ0HK7NoiTEZIzp8Wopu/I
scpF9v8XPnHwrlrlt7RSTUXUgg2lyWC64hJTI48rlpbTsAziK5seh8UxEuoChRy0kQIlpHrAG0TZ
bmej/vDz7vnhzdnBMWYcl93rJ/DQrzuIuSsvt+Gl4xS0UMfWUtp5jtIPGqXcEYK+Z7XArU0B/hKV
v2h5V9RwRlnR/E/mdtnrbadSkQyjkUpUVBrrZFn1Eb61WGNrc8E2oX1TQIpcPhorDF6Dc6SKcJ1W
dShOUYw4AnT/O5LMqvaXlfZB9pPRBcwWL+WfmVV5SJcdHdpyt1tKzpfhtRQChh9cf4+y096u+Aae
eR2htiRHgyDYP17/0KkcE+EipQMTGqdk8zSVVFV4ZIBs1wTZusjyz5K/FRnDiaSiZNhYJgPlO0U2
sfGW4i9y1hqU46SaAeVaqVLgwk/Uasen+wd9Crt77N3p2R55iT9+/u3m1933H/GcxaotJ1icBIzY
oBV3cFIl7co4y7jc6RQbp6nwle70s9t8TumKF3VWF/2M7tqtwzJtSgONznRfskxa7bNrdjXrzgZd
+cpkS/1h20W1F5NwnJqUqm8qyxViE5UWyhVHolMjAaVjKjNeSsZ+O8tUpxwr5wMvqtrbKzuv+Hoj
fhlN1c0UiW/eWGzh1V26HSuwVE+j1BV6bFVXF/MQ55kr6I9rb6A/Vl4/f6y6fY53rz+Zd8XtCPIv
qtc4+b3xchFLXdbNvjWU3QIb9UqHDywUFKdpN789dqRcodyrr18xVkcjrfyOJbvFCNIiJ+pTCOqp
SpXkNCjyIIRsv8kA4Fmd9dgj5MwYAOY32ZJgCELIv3OkOGx/jEQw5oagRL+D14Zjv3RdHJPePJ81
vmWFt4StILq36PKcrMb0slKGzzahOatIQEdgLLe0Ipg655OKUcrYlpCzcZao8Ah9AW4Xr9r3oSd9
iyo78aBQ7TEP1UpDpVPsSoe37OuxRo9yCfUcWMp9qGeOz0nxnKgAQ4ZPEVFg5XiIUuYlpciSIWSf
y1L4JSOrJUZVnzHo3HX/CNy/rpjX8t3rZj0Ps1TyroSfRVAPVxXGAEHUsqGVNjWUrzo/WPaYBvZm
ZBitBHNVq6lchc+MkZXLQRFCQFVxXtGTYsWIrmLNV8DwK0sJQdErFhysykL5oIeAxFG611M6HQBF
IPwsXZQpn2EEffl1pdX7NC+QlI5QIK6gwWyas53VBPPiybpbOIp1+kmIxjP9hAOYFaxnFl+juFwp
LtppFhBVaS5f1dybLb+1+beVN4NmYAdfo71gkQ+83d5sN5/KfMhOsDQeZOddsH++fv/JemVJXqIs
yYuUJfn/KItyT8CY5F/WE3VYp7FHfXMDuJOUuaMQtm9tvOhLUm75FN/w/xVHIKK0wSZWAlfPOloV
/8uElSDMY/vyC/+jEC9d+XjxKpSH/9mqyDMHcmq83U6+V3jkOen7WtmdgaorAz38/ok8sZFnF1Me
3HGx4tuh03jMh6lnFWfk/9fbkza1kWT5Xb8iXZZXKqxCyHZ37IjDw9i4TRgDIXD3TCBMCElgBUKS
deB2A/vb951ZmVVZArtjd3q6KVXlnS/f/V7SWrONnHliFd1hXZ5vlivtUcV1WIGfCHa2lmyK2GgW
19ed6XfmA/kZ6BGSu9q6tWrhbE5WsOZ6WuhWnupkIrwPfGkmo7G3PcD63Dvn5KLY1HlCdtnOPFQi
ZjWxTDh/znjUBx9QXyUMERANGZOF7MyxfcIS0LeCIQHTi9+fAEu8bNBUP+jlkY6dxab74KDlvObq
UWwfhkk50SblKpzoZDHCqIEpMMlBoA7JA5rYIbgUWbCxq7wVnDetizd2HCJymvk5YLhLv5ezjabb
JQfL2SwQGEVkRREG951PqeUXPPYOPcKsmBStc3jdGqH6kIxSsDoUNFSjJRW8Q8FEQeFkeWBRh11r
vBggP8QI0C654UBhrTaz4ZsSZq3RQpIuIG1gygZkbgmY5NyCB2OTeH5NWce1X399FaM5KRiwRF3P
xjA7Eh6sAGIzGXAxDI1DXEkt1JiNt+IGxzytlmSt2dk/y4/TcSdwjiPr+JOHrYIdoyghBmmz9V8v
LO1qKIiF/SHz7XsERhvHDChjmAUcM3+78YsNFS7oWZAsxuhzq7Mb9FTtAoogp9XFhL2vADeb8073
ajHRVd5cM5dTNmFidUDKKHtAwStGnGuR57FURT2cYB3Pr5MMdSscegJ8AT1segEp6zgoecUL+wLN
d8HCvXxhz9T3NAPgTSf8QR1yN/jTVn2FaRx5gaTQ9MJMhotLWNjYjarckO3QuhtUeGuVnR95RZWR
ZKWRimrwzdMQyoKRu2+GCavDnIv82H1dMU4aZzvtDzsUFSyhId/G0ysEfDne7mkK81FLRrNSl4VY
7eHAnK4zxdor4lrjLEX5Fh6e6SegNqRKzdf1pufXLazkL0nOffrWtkNLT23AeQiykhQPuWE2lrj1
C9j8jFd/3sGZz5gCSmqm4BHneQkFLJeoe63WyxyY1ktlGO3DLbia8nXnnau0bHdiXLdo9aPkJtJi
SpXbo6dmu9fj0J4AwV8Wxtse6QF8NpOjxyRe5761ZQLu9SmJ1upSQY9vh8YD8B+uq+is4XIZ11eI
AGnm0ju9Zmy4qS/dsGiY10TnRf1yDUScm5E360131sC11sqEfrPx0+2oXW7ctcsv4N+X8O+rtgsU
lvvkIUVuLBug1CfAgD7WNTkjkgAZcfNLhNK3lXFWIfmZEL+OiLl+gR99qU8+lCn4/Jw39cMjbo+U
XeSRb6UjcuDgetwzv756FfjG8FUMu8AR5psLgBVrLVOv5qYXfO0pg1kfO5hLQAY6Hl32Sf93OR0D
FRb+yIlgVCW4fFE1OIWYl5z9KRAf0j34v5J9/V3D/Qjy7Mw1fBl/A5aIWMEyTD/ovE0Axtv266vC
pnjz8oDljC0k0VRt39h67J092VzLCnranm2XO7MSXuS6BVlwaAlXa8Fg3bLTyrQin0+5g76hS1uN
+FWOgmJ5XnyLqB2yjcAYNTQ2uZHQp+58mM1WJ2NOvyuHHZWBg0LrzbDfn5iX606RwSyRJCNJ8nUx
6GvhUi67CCp9NN8gl7Htozmem8bHCTu0/on6y0sW5Ow4caGUUYVZSQOBxZYvLEfT4KfXLjIibJOS
rcBW+OItMsG59dc0IjSJxN0C8pFlOYLY7IwKwR2Dgsr1TWh8gkTWef38OUR2rCItyGQYz2p7+jJA
KHXoihgKZwvykU4ZJ4XsojvZRLJsDebpZB3ftow8nFr1dOohQUtk4fJrFoYzbZBd1KU2iqtuI64e
Nc0zOBry64zEIX3nOFucsTkn9IXBWr5UnHh5ILRfM+Ew5Eab84SPHvB2zbcZcKHhtucX1vzAhvNI
0I+N+nKHjh5QoSn1p9PxVD+IOQp+nlSsKzEZxJsJHjVyPkhHJcYL6XbWn5AHVKGrqqOV4XAOqGEb
nESorqU2YCCOQ6RWOoXX7E58Jg67Omo0Wp+J77KdISDsM3/b+R0qAekNkRZvtWlBMy7KzlK73tBx
lN/yVDdm10iDInSJWJVTUk2Om/6nSmlFMol/2HQazv5TI93MyPWBq2UT+pSOjrc/Hm5ygp7BecqJ
1jFQyu0/dyDREcA9TMv8wU+ygGg/InTznK1+hBlSGljk51aQk7AWq9uI4wWC5+ZFho1JG3YYcUfC
4T5iYgDUj4iYCf7gYPRNdIlmb6DK82f/SZ5dJ8965tn75rOPlTiXvkvtw0EHrfxxFT8txx1D/UQa
CAlBO2IaAfDHdmt/d/83j/fIGA8Jv2bzG4s6KRt+jRkyYmPTC1Hqh2ryF2pfNc0WfLm2lnbJVENZ
vP5eVoViFVXdSwvhqKqq+YwjtUBu2Vo+fyvOx8kQQQGbG5g+d8vFsCaChfAj+zc0HcaUB7WFfqw9
L4p5I5BSdSuTR1hD0PFMizAhNJCgtiEo4GDUZ84B03agRwCgAaSaNu0y9k2N4D6g/WXYmaybNEMa
bjKHRY6B1s7H47h0C130u+YfW3VoOZePGMuhFiNzlhxW8IKayrCBFPBIH5JvpvHfa2vmH0Fl9K4k
ddOEbtXUOSmgd94bXHFKF0kQaSbDznfA8FdNYBUugBP5UtMk09kkcJyGbtq/hkUJpV8rsWuHUIp1
N7nb5Zg9VWyuvDSTGzmSzEo9JSfZUIxrIHDUweaamXbhP0A98ZUyPV0A27n20xvzsLAsPaDlAH5M
zMh86Q97Z+jRO+p/A4bLd9/Fj+i68ae6bYifhx8IgumlMNoPweD74poIrLON5UloD29xDuVJqs5y
CG16vCfXBa4MNnHczMlaXqMhYLcwjJwCOWdSLnSDDlAROB4OiSGkad8GLU9HH3YPD3feNjW33w/h
aeV3eLLPTdXFsvG9ly4RUHC10CHUCUB3v+VIiyV5CebHlKODUOHmKlyNHFdWx3VfFhb9dK6vMGu9
0Tj52agzsZDryKO4rZsWbkIOyr3J1SWIbMiDJH+AqLAJa9I7bx7NO/PFLNk+B6i5uTfl2/PBCA2j
hxxRhW8krRgxVXem8+0Klrhh/sfUPw8GdXPL2SkxxCAqv7yvlFwJ0BvBdALizNcOSo7IKN7ub3/c
uV99drvdevP+3jy73Tk8ePN+/9PH++azW8kZdp88u23t7O1sH+1g947/s8SF0pt7uzTEAnyrn/dh
eftZLkB2AUmfxWGwcLGwsmunGLmnkVoABPx65fT+3hP9ly+1pGR7u/Ov3e39s3etA4TEt5uj8QgB
dcpShi2trcjRS76yyQfwDxwvQkCZEtZCee8EhyHNENubdTr7Mh4y9dAJpTmONcGEoF9EscN+hzNw
XTuaBh/GyrdPleNPHV1zUKbIDyBXc+SR8IbD8d2IH456c0uO2A88BMQKqazem0TZpF4cPRwHmw7Z
k3UKGF4tsbaomxiJKdlOi1aY3vv0FuuTP/4InRHuc31apFz4ghYbm8l6UDAsv4cvziZyotryLVVA
F4hQlIDA7rSb0Vj5MUUCawms7ti8hbVuNjUxbXNTcBZpp3v9i4eK4Or0BiCJKJVv51aiCNa9agGI
d+ZVuFR2mxYj2ahbLeZumOf65ayONqHL8dXhScLVkwtOloqcGfMEybT/dTHALGfUHPEWrAz2UGOx
TP0nglGSyAnedGJK3VEzPkI6zQQKHmC4152rPitqs3dUaN0youPvlgmD3v+UlBOZbcGCS3YjsHLS
dNGq+eN4ms+hmUybwkxTTnRiAO1iVmGGidgdAdKmfc4lnCzmlKvU89NzmKZcJwEW6ollvP3hJAA6
k7D61ANqnLfmPub5a3Q0bxLe85IeZDtoyytkZxZHhavmn+0fmKfwfoE1z5e0QVSNHAgzGEPXP7xi
BTUe3b3lO60O/R2sN6o9mxJ5iGy3YxDi1P/qoOQmlvTYY0DY/ZxG386VWwWyBtuVNEwdYbJ+c42S
11/JSiCRZGV299kvdXdXsSTlBiWJLuoIhUD9vjRlH/fuRtrICzTz2dRb0zjK7ZMsksMcEYFXGwvJ
Nkiskavbb2H8+Dv4c2vOT8qNUwDZMnD8xBunBx5ooP1Y8iJ3qlVgDAGTncfY0Fosmcsj5X9NhDHq
Ef5xa5KuG6tzp0+wYVv3k2CetC6Xgo3aooackQGnBaNDhFq9knHQqOhHJzOoFqMlaONKmr06NfcV
l4F01ou3BBXy04s0RpGEws1s7i1Z1pSB6JrVuFSAK33Ac0SiJQkVrPjZkBNwBIi+txj2RRYmhEku
LRjI4GU/7+P9HCBMU1wE5vAdT6/6PWmmylp+1O3DEQEJ8BL9vlzbB7bcNP+ULsgpSJNphq9Wit0D
puP2JvPE5lVGJPD8Be6Mc1+Gc0NMNW/XRcWyd05TyXzdFc0bOR9o2QiYQGq+40XajN5t7+6hpFkG
+hdZim0/oyegusCVWS+gzLWg++BECcVXVKMB+KcSS/Hg/vttrIXasETRtpROOdA13o5F1XR+zsLH
lBDOs4WhzNSiKUde/lqFbmo5540pX92sblOnEcrMmFxltDM23xxylZETGprj1cL1ZyTFSuXQKWPt
syW0jcc2zLtL7dLjI6sN8Q42qnUrC9JM9sepCCbQc//I5uTwJs5iZisWnbDM8fDblytgLGuV4BoF
uFvex5bCLR75F2jGWJAM3UXty9CFpm7saDYcXX7m/OVhNaSYclEacZ+m6sKtPQvWon/+HaThUc/R
yw5zBN45ZzmZKKud72gPwEHoUnGqUxtJQBa+NjkyegZBUpjJrEXDQx3mraSC4rJmmUe5nErdnJMp
s9BphqczNVFkg+OdLUqP/idulcgBZaMuScxuejpLfxy0PvhKqvkUGI2KpZNYIKqYnX/vHpdKu0dn
LVyvtVJwajAQLdEolQ6OzlBBlCYWhe7I5ErEZozMI2stqGJaejVXwArO5dvD1s7x8X+oaDMp4x9T
VlUTkHhoRZPVO0xVaW/76Jg2Wvik+udzRFiO7gvYhvpkOu7WERHFJcqoRkynPfHZ6x8NUbBkcA1f
k5WaodsfhVOty4NKN/Jr0b/C2Me49GGntb+zd9bawUwP3E6VGrrDjOP96ezueozcwOzusj/qTwfd
u9ngctTv3d0MpvNFZ3g3HH/DezBH3e933Hasf6snydkqZnt5Xa6USphzE+jo0c6bT63d4//gM/eN
TzDgt7CVb+DL7pvtPbIP/+vTb+92/02PO/vvUQH7cWcfk2ekzN5TmwUscH1kzd7zWDra+f3Maxtf
7H7EtKzb+8f2DZ6fFllO5cUe3rsWlfZ2j7iQXBNAz3Je1/QJlnD7CG8miEqtncMDKnP44bePv7U2
o8XoagQoBt6gaVQz8/GvtzvHQEGBETjK3/9jxhcXeI9GB32jev2eKjJmbNZJ0gosttL9KdALApka
gWmoR5/2jpHXiMgbwpHwVC9RLI8+BU43+D+ThcKCctSKrgT05ylA5ZAWkRgolVNrfi0QBWnVG+Lt
Qj/W8uIdiQ9mQ47SljnZQIWOXGGxdWqqGyAN2d9mY7YYzKlYZ9r9snUq9vm97f3fNt+kSh3iFmA5
FpfN5v54b9xFr+jNhq988sU6YuYrn2k47LqG6K2OVNr11p15H3LrQ5ApmOTWUx9Mri5F4sIJgmQX
ZVMjYLIkVLy3T+ro6MXFyi/XzeVscV6tn5yenNZrUK+Gn+KM8hGlbSy+hoFQUPrzyefq6Uq7KjXw
M0ZPTYaDeRV/1MwFJvWLfL0t2vg3DRXAoZwczU7lAjcY0msT6XVukWmaSDw3Sjl9q4lOImoqQkkO
J44iWBUnhCJtBC2R1o6FPGgpis3FSSPNpkSCWrrK6RgRZ5Wr37omGZqNgjIWoeWD0HB3XMGtAmut
U2qfVtI2BBHqRjqUwNt929IOvLeI2486JEwaUJiHwI9lSc+/rFjtmIE8QX+NzAuLBTP1o8dpN1dh
92ZMhX0Vb6Z10dOjq2VVU3oub5PTm+K+wD9yjJEPYbQQQLFNUhh6FwqyTKt5O8fTgcRtvEAbzlCE
48TibvquqxuyNrC9DHY5hOFD+/XVVFQlOL5KtVKOf5KomsVForcATirY0A4A4/bhcbN5CDR93Bt0
m81P6SBUTxJVG3ed4bfOdxCeKhkAcChZw6dkwcW0C5leyj38HnnGq4cGjWPOD7LZrB7wTuBtUED8
R3fbbM1P5H1cyQCTswpJYiq6YxW2fDsTe/EjE0tTRKReDfIUWyV3CnLv5Ypa8iC2V6PBOtTl8lq6
Fa36PM1mPR3PKUElvKdooWEP8SapZpgqHfx2pEpFAPaiNrMKRtUUvsxmY8D28iTnoXT/+L+/EBvD
MacmMt0RivPjkD4foeY2eYvGJ2CEDRGiF4TFgbjM5lMgVTXTqJlfsmSo/rkq+sA7AYe7t8Bo8RMr
5e4OF9NL/CHHJcYucuajTpfIWUPIWbMshAzex7nCM5/yccj+6fOmkUqzfBW8C4up4QxvR53O4U+9
DbtYj4M2yuoAKsBoBmZj04zg7/PncWDYRAOh5ETSNsmY2rGOfxIH68i1OxMpb9rV1RWpwVcuhyrd
ODUy9P4mlve1lIkt22/B1pADoVXftHpZMhfpO7uPQK2laWyQiHhho0w5kdbD/7ElemA/P/jnJlfJ
B6d7hxPDE5NN8TbzPgbtnioilKt6rqKyd7tY5LeB56/rT8bh3t3UY7bBRraF7gJOW7eRNH6NI3Je
dMN3slYez9EGvXjS7gL8pTuUiwFgOOsjigStjrfqwZBwfSsrpKmqmMSyQcf/RHobMqGPXAuFzqC3
CjijYbmZEqlaHFkFbT1ZQxtlNbMl0Cb2M5IMCcwXnesB0PhlUsyD4xFRRKWdHuXgJoFEX6HvkxVL
RI6Iyvw1QgpPiFXVMBYa4bfnjEDVW282y69pYo21Nav3mZnODSwt4uWaWZPkIzXiZsiJ2xW/Wm+K
JC8WoJyfLELakH0asD9YsefmrdIsmWUEsQ2Emq1VFqzMRipy4b3VW5HclN7voj+AiQ7OZ+NhnxSG
yvtFqEObXQ0mE7E5iD4lLQqIHrVR92b/HaIUihApN8wTlHqqR0K3m3d7QFzjLFEYueSgvXryefV0
RTHaSC/yhFKR2I0q3k7ZfZsAuwAjiZTqb/duBnAEBjYjV7pZun1S0iB8vWLBvmk2OlwR06jOv0/6
fGUuLBrKSjCVVXg/6t9MO1tu9V+aMptsdZRspbataDYGs9mi39tyAUQBExAyArNVa37a3W4Bt1Hl
MRMaYD11YucTC+QXFI2XnoKofMv12I1gGQsBm7vlbC6MdB8gK8rsJwm8L1DKbON6tVdfl0nspcXc
dERNDC64EdGZN9+WF+reR2on8vXLDAWx5kfu63NV2707X1xeDP6864++oIobbyq5G/W/iSLibjHC
zI2Di0G/F9PAcpRKBlp+UQpRUl6EX3BGMvyXdoyvzD2PS7+hTqhg/FISrbR+lkhcieTkc3L6nP9r
GYwrTeFHWdmmHSTQeLQDcjqJ5m0gWTQXeoIBlULUt2PPiT06RwKwmOX1ihONa6r2TfNlcPkFuWGF
avyOd3ml3Llt0OKK5F2lDfTK8QRcjBjdYA/VGS6mKNpnxJK8wWQf3c4QNQqvTFPe7l6jl14H7Tmv
AQz19cdxrz+lNPmvQUDUt3voC/Ya8C1m306XHq/BIg0ylAGo//2kcRqG300XVHm3u2JAR24RCtHY
yy9jWMspfqFZSBH9hmkN1OwOELAEhrE/hlzoDR60r6UVHBiHWvArWMuDMccjwIc74pnLa1Z/tE6Y
2VPf6PKQXx+sh8DjvIMQHlmNy2lkqjDt0anVCkXmJDL8KjoVzVB4YtQ0TD+2rfKinEZLysPE0/LO
moQqZc66VGKUeRrSeWERoj1rATWWc3qyhCg9YkNicEO6xuFgia6R43LScg9oyzJlwpquRjp0O87H
KLsc3VuBji0wDGsIKKpk2id60sMteOaEsj7ZT6lhYUkPFmsUd2HNEUuaUSxT3Moe3W5U2AAgpHBd
Mb/4VRnqwxVcI41fy4H9fFXB7nrfNAWPVFPWhy0dv2Ru4iKzHLzXnCF1YR+xNhvMqQTUlxKoW1rt
5YqFLlnVi7tEk1qlB/Pc2DndoCLKy8nx9K4cV6hqbLL5qVnfqeN1BwBy8vCBrmj52idq+Wuf4voV
Nkadl37aD5L9B3MOkPstJ4HIDzsHpmxaC2YorF7IY8+VWfPuep662drgC7jTYJ/iy/o3u/a9DvhT
sQjl6qzz5oH9VpReFI15YMxKe8Ws1PnCZ1ddXaRkZ7M6xRd4X5rJrN8PTfU+q/gusiJmtN+u0tZU
Rfl5RmxcXT6eda97toJVig89qebgCNWpIlaS1zkeZm8MievGM/XOp5c5oD9CGaPHssI8ygaqSU8N
/yyGu+SuCM1kX/5c/7622b1my8cbdD2VOFLMijP+pMkyY+fwpyOlePil/YdXQ4CYPxYBcbE23FvD
prvXKb9SMHEXgArnrbD0k3O+XWKhyAz9MWCeHgZPmS/rWAQaepzCQ/27kPEdbRaW0GlfubV59I6m
h//HNlOPfzEIWyn4ejAaXHeGiV3Mx0zgxzY3nUXhvlp8VbCrIRMNuY5N8F6IeYdugaiqKY4CcvXi
eqHUcU19x1P7TDZmbXf/6Bh45uPdjzsYskYhbCYYrqaBbVl1arouqlidomb1C+WCC2ieA8rtRym2
PTWwth5WQ/eQYlk1rq8R9zPVgXROiuObDJr146iMhtrBgTLwU4mne/vvfBYImqT8CiPSBEXlG/VS
d7KwuaO3UoXVW2YUnqOxxrI6N8QBJwR/phqFrjGuNTz2cSSx2y11N+S4AqJB5+P5F9Y3D9CE+BOR
BgEGxI8z2N/5Y4fktf+/GIPUcsidOyEG+oJCDFLPuOiH3QpasgayOk5btcIl1N51j3lfDlnQtLiB
rlDBF3pXIDvkQzPI76IvRb+n8fokYVTpmgLo63t6kzxUmNk7YtGjrSjc0bkInr1E3IUQSZuuCr2w
K8GnB3MV2yOEPvO5s0P3q2fcfYjxIZcBU9ZKmowR3pOzafuE8kFiwkNqonwLX57hrZ9pZkRKZbie
jzJMt55PHF8sn95VqB88p1gaialqmVhNJc7XKHe7itw+QIsmcqeu9iMccJzeyhW+XF6tYLsWYNnd
D12sfRCJtKxgNJUT1SlwX2/GNF+UcFDqIK3mgXLkChcWvJOo9Ob9zpsPZwcf0kuDGRXRHhE2gg2y
hdKrB0u3js9tIk7Z45nZQ5/OKPhtlfAvJ6ERp1ebgSZbVGTNtLQe4WCFWXc6mMzTSkdvWruHx7ZO
qAbftqsinRskgOYjL9eJX2c1taBw0UDrZKdyIgPcqIDC4r3FtDPnOVfdGiYxfMlcvKSyuNnzcskO
Botn/eYVp7sroE7DwVVA3xAiMWkxNTZl/UlR6SwuGz20CB4c+Q5OKLWhH2rK/dXMS+5GiN21pnZ9
aqr5XEMIopmU7pjaDO10BBCKm2dOJA6ySq+w1+fhjoTShXIK5Z1FtaQt6AaXuzzjK8E1zquXHq5x
OcrDzLi8qefnXFuaPSJeN+W08cgVJPx9RQFF8Ik7p6UlV3t9IsoMdk438QP1xPfKW+YQbPvXJ0s/
/p3FS8FcEq2YbERaoIaTjmNVFpS7C95cnNw/kJZDh1WUjKO4cwpZdCsEBqt3DcsI3fuG3WSP9jQX
OVzkj7ZskIO7nPoP16MXeMkQUEd99IYQRwHFltKXoqPmdycHGTcXIGhvL3qgnMU5ZVXgP1RDOTm2
AzxUGoPzTRl1qQ+VtPyJ3tf8NneNn6r3EUxU/Aw31hWjgUnrZBtjpbptakljrGk3WiPbkKNs59YK
G3KU78arlm3StWpQm4VNqpHVmbFXOdSyNYoEj1uu5YGaR0ymdqhtNZQ8ctTXYjMxfuVQy3ucdeiB
vbItDxFHaT3HY/IPQl+if+hCncvUEq3sOTHnvf7FYDQgpkPynaKsORNSOR0Ph4vJzPSmA+SsNJHC
LCcChIdZvjJrUf6qQjj596lmgC8zi0oc3DfIvsYLfoGvGSTEu88RM8r1Z5i1dEY5/+Um9eH3UkGE
YGcG86MARJ8lzpRXLppKKs9dCqInSgPrVdZJp9GTxOGXSiJdCL/btEw+Ii5TzaOmmkmh/FZBvJmM
6p37mvHxUprxJ8UncS6+tqnEryZBwPSCGEQZ3MfA/ekPUT1KvglEj4lV9bGppWLMV2UT/XiEyw5c
aHYzS7TZ1zPNGuPwDjgqTWqJmZBIg+anSE4L3MO8OWjwfwEVfUycOqoAAA==
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
