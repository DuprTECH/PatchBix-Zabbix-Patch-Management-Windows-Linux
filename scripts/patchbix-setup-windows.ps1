# patchbix-setup-windows.ps1 - Zabbix patch management on a Windows server without Ansible: setup, check, updates
#
# Paste the whole file into PowerShell as administrator, or run it as a file:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File patchbix-setup-windows.ps1
# A menu asks what to do (or set $env:PATCHBIX_MODE = 'update' before):
#   1 monitor  = like ansible/check-windows.yml: checker patchbix-windows.ps1, scheduled tasks (check every
#                12 h and after a reboot, automatic update every 15 min), patch settings <Zabbix agent folder>\patchbix.conf,
#                UserParameter patch.config (host macros {$PATCH.CONF.*}), first check. Running it again updates an installed server and keeps the settings.
#   2 check    = run the update check now (pending updates -> Zabbix) and show the patch settings
#   3 update   = install updates now (security, critical, rollups, definitions,
#                updates) in the maintenance window, without EXCLUDE, reboot when needed and REBOOT="true", result to Zabbix
#   4 force    = like 3, also outside the maintenance window
#
# AUTO_UPDATE="false" in patchbix.conf (default) = the checker only checks; "true" = it installs the
# updates itself in the maintenance window (once per window, like 3).
#
# The checker patchbix-windows.ps1 is embedded (no internet needed); a copy in %TEMP% or C:\Temp wins.
# Requires the Zabbix agent 2 (zabbix_sender.exe). Docs: README.md (https://github.com/DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
& {
$Mode          = "$env:PATCHBIX_MODE"     # monitor | check | update | force, empty = menu
$IntervalHours = 12
$TaskName      = 'PatchBix check'
$AutoTaskName  = 'PatchBix auto update'
#
function Ask([string]$Question, [string]$Default) {
    $a = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { $Default } else { $a.Trim() }
}
#
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Warning 'Run PowerShell as administrator.'; return }
$AgentDir = @('C:\Program Files\Zabbix Agent 2', 'C:\Program Files\Zabbix Agent') |
    Where-Object { Test-Path (Join-Path $_ 'zabbix_sender.exe') } | Select-Object -First 1
if (-not $AgentDir) { Write-Warning 'zabbix_sender.exe not found - install the Zabbix agent 2 first.'; return }
$ZSender   = Join-Path $AgentDir 'zabbix_sender.exe'
$AgentConf = (Get-ChildItem $AgentDir -Filter 'zabbix_agent*.conf' | Select-Object -First 1).FullName
$Check     = Join-Path $AgentDir 'scripts\patchbix-windows.ps1'
$PatchConf = Join-Path $AgentDir 'patchbix.conf'
#
# ---------------- Checker ----------------
# The checker is embedded before the menu (no internet needed); a newer copy in %TEMP% or C:\Temp is used instead
function Get-Check {
    New-Item -ItemType Directory -Force (Split-Path $Check) | Out-Null
    $tmp   = "$Check.new"
    $local = @("$env:TEMP\patchbix-windows.ps1", 'C:\Temp\patchbix-windows.ps1') | Where-Object { Test-Path $_ } | Select-Object -First 1
    $src   = if ($local) { $local } else { 'embedded' }
    try {
        if ($local) { Copy-Item $local $tmp -Force }
        else {
            # gzip + base64 -> original bytes
            $in  = New-Object IO.MemoryStream(, [Convert]::FromBase64String(($CheckB64 -replace '\s', '')))
            $gz  = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
            $out = New-Object IO.MemoryStream
            $gz.CopyTo($out); $gz.Close()
            [IO.File]::WriteAllBytes($tmp, $out.ToArray())
        }
    } catch {}
    if (-not ((Test-Path $tmp) -and (Select-String -Path $tmp -Pattern 'AutoUpdate' -Quiet))) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        Write-Warning "The checker ($src) is damaged or old - copy patchbix-windows.ps1 to $env:TEMP and run again."
        return $false
    }
    Move-Item $tmp $Check -Force
    Write-Host "Checker: $Check ($src)"
    return $true
}
function Test-Checker { (Test-Path $Check) -and (Select-String -Path $Check -Pattern 'AutoUpdate' -Quiet) }
function Invoke-Check([string[]]$Extra) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Check, '-SenderPath', $ZSender, '-ConfigPath', $AgentConf, '-PatchConfig', $PatchConf) + $Extra
    & powershell.exe @a
}
function Get-PatchSettings {
    if (-not (Test-Checker)) { return $null }
    try { ((Invoke-Check '-ShowConfig') -join '') | ConvertFrom-Json } catch { $null }
}
function Show-PatchSettings($c) {
    $win  = if ($c.maintenance_window) { $c.maintenance_window } else { '- (any time)' }
    $open = if ($c.maintenance_active) { ' - open now' } else { '' }
    $next = if ($c.maintenance_next) { [DateTimeOffset]::FromUnixTimeSeconds([long]$c.maintenance_next).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }
    $excl = if (@($c.exclude).Count -gt 0) { @($c.exclude) -join ', ' } else { '-' }
    Write-Host "Maintenance window: $win$open"
    if ($c.maintenance_error) { Write-Host "  ERROR: $($c.maintenance_error)" }
    Write-Host "Next window:        $next"
    Write-Host "Auto update:        $($c.auto_update)"
    Write-Host "Excluded:           $excl"
    Write-Host "Reboot allowed:     $($c.reboot_allowed)"
}
function Invoke-CheckNow {
    if (-not (Test-Checker)) { Write-Warning 'The checker is not installed (or old) - choose 1 (monitor) first.'; return }
    Write-Host '=== Patch settings'
    $c = Get-PatchSettings
    if ($c) { Show-PatchSettings $c }
    Write-Host '=== Update check (sends to Zabbix, the update search can take a few minutes)'
    Invoke-Check | Out-Host
}
#
# ---------------- 1. Monitor: checker, scheduled tasks, patch settings ----------------
function Install-Monitor {
    Write-Host '=== Update checker for Zabbix'
    if (-not (Get-Check)) { return $false }
    # A run of the checker moves the settings of an older version (zbx-patch.conf) to the PatchBix names
    Invoke-Check '-ShowConfig' | Out-Null
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$Check`" -SenderPath `"$ZSender`" -ConfigPath `"$AgentConf`""
    # Check every IntervalHours (shifted by a per-host offset of -30..+30 min) and 5 min after a reboot
    $hash = 0; foreach ($ch in $env:COMPUTERNAME.ToCharArray()) { $hash = ($hash * 31 + [int]$ch) % 1000003 }
    $offset   = ($hash % 61) - 30
    $times    = foreach ($h in (0..23 | Where-Object { $_ % $IntervalHours -eq 0 })) { (Get-Date).Date.AddHours($h).AddMinutes($offset) }
    $triggers = @($times | ForEach-Object { New-ScheduledTaskTrigger -Daily -At $_ })
    $boot = New-ScheduledTaskTrigger -AtStartup; $boot.Delay = 'PT5M'; $triggers += $boot
    Register-ScheduledTask -TaskName $TaskName -Force -Principal $principal -Trigger $triggers `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg) `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)) | Out-Null
    Write-Host ("Scheduled task '{0}': {1} and after a reboot" -f $TaskName, (($times | ForEach-Object { $_.ToString('HH:mm') }) -join ', '))
    # Automatic update every 15 min: installs only with AUTO_UPDATE="true", in the maintenance window, once per window
    $every15 = New-ScheduledTaskTrigger -Daily -At '00:00'
    $every15.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition
    Register-ScheduledTask -TaskName $AutoTaskName -Force -Principal $principal -Trigger $every15 `
        -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$arg -AutoUpdate") `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)) | Out-Null
    Write-Host "Scheduled task '$AutoTaskName': every 15 min (installs updates only with AUTO_UPDATE=`"true`")"
    Unregister-ScheduledTask -TaskName 'Zabbix patch check after reboot' -Confirm:$false -ErrorAction SilentlyContinue
    # Patch settings: only the values that are set are written, the others stay commented out
    # (nothing set = check only: no automatic updates, the defaults apply); the values already in
    # the file are kept, the file is written every time, so new comments / settings are added
    $unset = '(not set)'
    $cur = @{}
    if (Test-Path $PatchConf) {
        foreach ($l in Get-Content $PatchConf) { if ($l -match '^\s*([A-Z_]+)\s*=\s*"?([^"#]*)"?') { $cur[$Matches[1]] = $Matches[2].Trim() } }
    }
    $win  = if ($cur.ContainsKey('MAINTENANCE_WINDOW') -and $cur['MAINTENANCE_WINDOW']) { $cur['MAINTENANCE_WINDOW'] } else { $unset }
    $ex   = if ($cur.ContainsKey('EXCLUDE') -and $cur['EXCLUDE']) { $cur['EXCLUDE'] } else { $unset }
    $rb   = if ($cur.ContainsKey('REBOOT')) { $cur['REBOOT'] } else { $unset }
    $auto = if ($cur.ContainsKey('AUTO_UPDATE')) { $cur['AUTO_UPDATE'] } else { $unset }
    $keep = 'n'
    if (Test-Path $PatchConf) {
        Write-Host "Patch settings ${PatchConf}:"
        Write-Host "  MAINTENANCE_WINDOW: $win`n  AUTO_UPDATE:        $auto`n  EXCLUDE:            $ex`n  REBOOT:             $rb"
        $keep = Ask 'Keep them? (y/n)' 'y'
    }
    if ($keep -notmatch '^[Yy]') {
        Write-Host 'Enter = keep the shown value, - = not set (commented out). Automatic updates need a window and AUTO_UPDATE=true.'
        Write-Host "Maintenance window = when and which updates are installed automatically: '[<types>] <day> <HH:MM>-<HH:MM>',"
        Write-Host '  several separated by commas. Types: * = all (also without types), crit = critical (Critical Updates or'
        Write-Host '  MSRC severity Critical), sec = security, def = definitions; several joined with +. Day: 1-7 = Monday-Sunday'
        Write-Host '  (or Mon..Sun), 1-5, * = every day, 2.3 = 2nd Wednesday. Examples: * 3 03:00-05:00 = everything on Wednesday,'
        Write-Host '  crit+sec * 02:00-03:00 = critical and security updates every night'
        $win  = Ask 'Maintenance window' $win
        $auto = Ask 'Automatic updates in the window (true/false, not set = false)' $auto
        $ex   = Ask 'Excluded updates, comma separated: KB number or a part of the title' $ex
        $rb   = Ask 'Reboot after updates when needed (true/false)' $rb
    }
    # KEY="value" when set, otherwise the commented example
    function Setting([string]$Key, [string]$Value, [string]$Example) {
        if ($Value -in $unset, '-', '') { "#$Key=`"$Example`"" } else { "$Key=`"$Value`"" }
    }
    @"
# patchbix.conf - patch management settings of this host
# Read by the checker patchbix-windows.ps1 (sent to Zabbix, template 'PatchBix - Patch management all OS')
# and by patchbix-setup-windows.ps1 (update). Written by patchbix-setup-windows.ps1 -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {`$PATCH.CONF.*} win over this file (patchbix-from-zbx-host-macro.cache).
#
# Maintenance window - when and which updates the checker installs itself (with AUTO_UPDATE="true").
#   "[<types>] <day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   types: * = all updates (also without types), crit = critical (classification Critical Updates or MSRC
#          severity Critical), sec = security, def = definitions; several joined with +, for example crit+sec
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   MAINTENANCE_WINDOW="* 3 03:00-05:00"                         = all updates every Wednesday 03:00-05:00
#   MAINTENANCE_WINDOW="crit+sec * 02:00-03:00, * 6 03:00-06:00"  = critical + security every night, all on Saturday
$(Setting 'MAINTENANCE_WINDOW' $win '* 3 03:00-05:00')
#
# Automatic updates: true = the checker installs the update types of the window itself in it (task "Zabbix
# patch auto update" every 15 min, once per window, log C:\ProgramData\patchbix\update.log); false = check
# only (default) - the windows can be set first and the automatic updates turned on later
$(Setting 'AUTO_UPDATE' $auto 'true')
#
# Updates that are not installed, separated by commas: KB number or a part of the title (default: none)
$(Setting 'EXCLUDE' $ex 'KB5034441, Preview')
#
# Reboot after updates when needed: true / false (false = the reboot is only reported to Zabbix; default: true)
$(Setting 'REBOOT' $rb 'false')
"@ | Set-Content -Path $PatchConf -Encoding ASCII
    Write-Host "Saved $PatchConf"
    # Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} -> patchbix-from-zbx-host-macro.cache),
    # the agent is restarted only when its config changed (undone when it doesn't start)
    Write-Host '=== Zabbix agent: UserParameter patch.config (settings from the host macros)'
    Invoke-Check '-InstallAgentConfig' | Out-Host
    Invoke-CheckNow
    return $true
}
#
# ---------------- 3. / 4. Install updates now (the checker does it: -Update [-Force]) ----------------
function Install-UpdatesNow([bool]$Force) {
    if (-not (Test-Checker)) {
        Write-Host 'The update checker is not installed (or old) - installing it first.'
        if (-not (Install-Monitor)) { return }
    }
    Write-Host '=== Patch settings'
    $c = Get-PatchSettings
    if ($c) { Show-PatchSettings $c }
    if ($Force) { Invoke-Check '-Update', '-Force' | Out-Host } else { Invoke-Check '-Update' | Out-Host }
}
#
# Embedded check script: patchbix-windows.ps1 from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux 3553f31 (embed-check.sh)
$CheckB64 = @'
H4sIAAAAAAACA6Q7a3fbNrLf9StwFN0VmYiMnn4ocU4c29l4Ez9qyZttHbcHIiGLNUWqJBVbif3f
78wAIEFKTtvd7J6EwmNmMO8ZoM8uxB/LIBEpc/4tkjSIIzZwO7XXz2ru6OfTs/PR8ajG4M/BTHi3
KVuIyA+iG/Y5iPz4LmXLhc8z2Mwjn6Uwl7JsJhiAW4YZy2L2C59Mgnt2F2Qz9o2+f8NlImkRVFiB
689GDOAJBC4i2CfmixDAsuY5z7zZOwDgMPpkcx7xGzHHVTwMYWPTrdXcw6PRwcXx+fj47JTAXqZC
EqLJvCQy2f4Nbtw/P3bZKCc25XPBbsUqZdYCcbjPbcbhpPgN9DphEC3v3XTGgDWf8HtIOJhc4SoO
uEjOS+CBt0yCbAWfHvwbeBxHJ8ubKRziJRPRjEeepP8l88U0iGARAMadydfAEwuObH6pUJT/SFRJ
HIbLRYr7k+AryAy+loubhPsCP29FEglEOhOhz6xZ4ANPtZzsjaSnAsAA0a5BcjBfxEnGic55DAJD
/r1kYXzHrJPRxQHTmzaDDIM0a6mxGXzHyYpZifDw4HINU8MtFga3gnEAfVOGlYhJHGfwDymo36oO
8zSO9GDI0wyHSwBwUCJzs2Au0ozPF631ORrw+aq0N05b+ZcbgYoYP79KQ9EjKbBtka2NxsvEE8yq
qOBL9nl0OWKvUdwieWOXl7v8Kw9CPglFiRilGy6cIAGq9R6+zGLFTKvt9O31cdcXGQDcMOHF0TS4
KWHx0MTXOSWH/SVogHE8OSoNnaD8m4dLsjqeMT+OmhkT9yBhtBrNAkvqJphXItBbZGhnbTBg3H+x
jFiQSdty2DSJ52zM01s2Akz+MhQJLh79PBofnbTYNE4APBAZCoZ6uGI9NgMOgtDixASBBq58ECfj
twLwLqwuvYlDWBUL6UT1FktXKSxxk2Vko28537/YPzkaH12QyxAJ7JwRBvxAB1Zya664F6VNB8Tn
fFOJFikDtwyBZfwW+PghTjNUO/KsI1KWfS8De5fnCrIybRKuXEeIzhYoLR4ONUqpcKB/iyS+XzHu
+yA8kEkQwXG5z+LpBjTIPkllhRdI3imQV8E1g2FGZAeRRmxiyE+1Bp19noGbKkbYDMQdxQQ/32WZ
ctejxyCtPSW0mRoDU5Cg5osleExFEoSrVPiVg0gvBI5dpITsdDmfwA4gNsQxPAiCKjstRlpkgQPn
GOgG7Qp7jiMvXPriMHfwCg1hUJOm+9dh1DoJvCRO42nGYC/pg/0EBagXagZ9mZomBGTgbDwTK7I0
5D9EJ+FLnw3unWwcXC44PdB3isFyaSgAc7zM2GTF1OFcAlnQNQLsoJWLRUG0KZXd04tfxr2fdi96
h5+cfJerXMD+YgEWh+ilE+DhHYfAq9GqpEBTE8VZNdEos5ms+KDwZNKqU5FlkKOkKENkDymlltUw
D+zkAjULp3HoS6njL9M8bcmAsc4UpkGIy5M5J/dVTQpO9o9Px0en+6cHR799Pj49PPu8V8ew+gIy
A/actbvDdttp9+DvFvzcYvTptLfg7/rGoH+HdoHCvpsFcDjN9Az0gMnIowUMupqlIpwyy9kHR68C
TgZO1B5uBF2/ep2tFiJ9c81egyq8Ya8/fBienLxx1L/oDJXGpJCYYArgo2aAWc15+orR5iEcA+SP
6c8e/v2DzAVUhYegbpgNopLRfjBV5A9szrMPywONToMp/CDrONATlwoM4MMcZCMqnZfku2w8hQfw
dW7WQtWG34X9QdhQadOelCaINVwVp/89BlfgbxYPZrYvXqEpDVnH2QYIJ3HkjCCuIJVx5Lrw3YKp
AQi8xbpuD5Z0QZ6fhQ/+Bfa5GwGjwmG8Bj0LvJyBkQARcMCKVkFqsX85Pvvt8vxwf3y0V8+Spahr
eEf/Ofh0eQijH98N2r1+v99psfNEfA3EXX2zeCh4a8sr3Ib18R2LlFsESYMFJZk2lSzIQqHztouj
d2dnY0UG+9EfmcQxPkXvrNGTquMJEecUVEUAqxKBiSgJRKNZP/JTaLKNTFQ2r5gICpY7ckI6xNka
+5t/7pSj8njEJpjeALQgAc+DQsqWoF0+osK6JmlJnwSmhP/a2sGsisSoKJ1UUTLnQZSJCKsH97lO
wsQ9RZJWJflWw750p6WsGQQa3xW59FpCaBO5CYZroA65pNQAbGDCrP0oDSA5taXaO6NZfCfdbyVT
yselW04CPBIAW5QdNPjPf43OTpml9VmmHlF81wI9uM8UU1uMTpRKS5UnaZFclUglB5FyyDkzl53G
4B6hSgUXSVkdsj4hxpbpvCxi5rE6ZhFpMf24q+bvQ8OLaH/V0qFZVWatsmdR0F7VtLtA16dsE3wT
KjZqJKhNDAUwMwRtmrlclulAKH0nePr3MZQNQ3K/CpGUOjlawJQGvsgdBrlCVEezRjfzUqVsSuZQ
CWt2l2wT6SmZOmVbkeR1mcNFICI0QK2suVVS71N4YpbM4TsDNg8ie/gn7PBj7Fao8BbjxAKciJwk
LFaVT8hmQJvcBeBSUEVSlgQ3M7BNSD+YBZXnkB0Mv5wnMZTR80Oe8S86S/iizAOr0/LRiPOE7zMZ
g1YQbTCmSKriWD9VGfaFQDkpnSQco4rclPul1E9jhJLFcBz8BpC0pKVKTw3Zi9oGKyWnUv5VUB75
1PEVbEeidX+HmhuS9fcUB7QKYdRQSP3Ax9LvVogFVWmEReeGdzrFJ+93x8kTc73V5En9NMYslkOq
ARHIQ0uqMyhB0ahNp4QndkwFJi+WzCE1WoKj+SprUuzmJLEH5Y5SXj+JF9T8mW+qogzPpfW1XEJe
plgGAqsERi9VD0v3OWT111Kgbx5eGx4KfimvDF/SpN5IsyE8ilAzYZ1zzJ3Z98b5/vjgg3twdvre
lQnlY6s8aoTD6pRyM9VhabyPrsxqIVJZEYQmMV9kKxssClkGgQiICnzK+Sj9BG+XofziIqpgewwr
Oefb5N5Bqh2i2vU42Lf04MCBcsJtkSfTqgDJ5IxHN8K3X5F3oz4cMJDFupAt7W6pLDjATAjLWbVb
1pNSSq6MNyk7+wjV7tHFxdkF9QtIb7BIzPN5KU6YmwR+CmlsnTVZg71iD+yZ9LnoMxBFAoEJG20q
cZDSwsppmLtonf6W/E4elmRiKL2cjy7HqInRydaB/5DF7EHI0RBBJOupC3BJqRH7P1h9F4S+xxMV
6A0gMvzpPGC9jWGoODkWksmGAG2kIdR7kvm/Y9qJZsqEe7c3SbwEaDKr40o4cEZd1pmarQtP4Ec6
m8RwCjBayBtARoZzXqurye6pj7vBTIHu5QKKDB/CCJTJULDECZjk0/YqHRCVdKXST5fosiyUrhJn
0UfpBsWNyLDvna8t9BpOILsXkW5E0JEJDwZUYmUJYU1WLtTle1X4STVCEQ/dKro7Yu4dskv1OIjJ
0mKB+YATWXb0n/2T809H0oIg40vSmYCALu4Fc05j8PR0ZufoHrIZ9K7ncRh4K/ZutYDKiznvcTY3
cZXauou0A6BPz8ZH8k4AgvsMOD9kh8sUGAFmJ7xZ7Ke3ss8xkh3QIZtl2SIdvnx5A6FoOQHWz18e
LhfJ+Ojgw0vd4Vc65dBv5yRv8zsq/3KoLpNXEXGUgUFipJ3Gb32AlAlskt7S7CdgWIRJ/MnxuPbs
TQ3r1rlFU1egEqDW142ikweje6xeBD+GJ0+/KKWX9wXdL2stvnqrDLDo8v0tgCT7LuliFaLZ0EOI
1XndgKPaw5gHzweTRlNLzg/aej/kA97suvFUh6qCxuiwlNBoMEWmX5mQ2VBlsMgGKxOUS1XGSjnQ
Ru5sRLzuIqokF/7PrtUa0hj32D9F5hxinlp7xvRNGJlo0WeRveNNTX8w859/dk9O3MPDKze6ZpYb
YTiI8giCfjC/bIIIYDNHDweZzNFkdMh9psqTEUutMaJ/NVl7rNndcjsdt73TRHJVKlzpmhwfQn0Q
ArQlRyzF/ZpdaxyUlqYA8e13GUPEljft9AZtx2t3Jk6/0/cdvtWZOt2tng8/Or3epI8xpq6rH9m1
qrenvNNtd3yn3+u1nf6U7zg7XOw6k53t7f52b7LV73don66f1D7R3t7Z3eruOJ5o7zj9fm/bmYjt
vtPt7w4mO/3utN+b0L6iplI7t3a8waTNe47f4VtOfzDoOVz0dx0gose3d7rw/x2FsbhZU3u7OxNv
Z6ctnPZgt+v0vcnU2ZnuDhxve3fS2d7tdPzBlPaWrtzUZg8mp35HOGK3B5tFjzuTKZDc2ZlM25PO
ZOLv9GizvPbLmxNaUDItqE8GfbHtd/vONveBbd0doGGyPXB24Uy7W1M+2OlLGoxLwzqBeS94tgR3
f44nUmycTL3O1Bs42x3eB/ZvT5xd7nGnN9nlg3av0+7ztmSjvDNUR+lt7exOfG/HmXTbA6fPp31n
x+9zEHlvt9v3BmLXHyg+yAvGuj7KVNGQd/YicZc3a7VV1B5rjcLDHPt0mr8i8Fptuowo7af8xBnH
yoF+Vzkh+nTlDa6utUPfT27UDWdjwql59NaSvwPIO00n7WBSZo0hEjv025izbfZd7X+BAOqOB4m6
uYA9FjBNN7228RtuLK8wtmoPbhNHK1tT3FqskNv+wczI9ZbWvy2ODtwGZ/BBX8EMf3yvlN/AmM3u
FpssM/RIHqd8Q6Rx+FUoqPqy5W9cw7hUG2PDI8cbmLc8ANkCWJj55ykXxku76FPQJnCHFdAtWXYG
6fpFj1tD/jrYwyzCJEn8b6iAVCOkkgI46ZK5hOaBDwJKHRDmHM9ljQQWq86I9JKtwaURoDJizV/V
cfcs94XdaOYYCWsQYbu6MXdPMNSI9Kp97f4TUutFetW5dumi1R0nwdyy8z14YuMsCIE+x1CGyIQJ
cgGpoRL6v+IgMhY3nzeVklXOTfqIsfFgBsUGiV9Cfy8TyCSJ6cYQLRVGoixcITpI1gTUURDXj4BB
ztnkd2AMYv/Nfb8MQxLJoyS/MAkS2WYmFgQZPNQ6tddkzk/LQGTSdnOZAw9F9HV4cHZyfgnVwykU
EYDt0XAuQCqYZTaOnaNF7M2sK3Rm2Ci5bmAuoKViXeGvMYyfTadQZMhZdxxfRuRNeYhzlm3LoXv8
NRJAs59atjRLeTVFF26m9XTdMTDKwvsA+MDbAB3658BFULOcVJQBATnkq6forH9vP7rfO4915gA7
r0B9ZtfD4fswjhPLkjTDbkg9OjaUxts2ewFf4Gj0zNn0sxC3cAjJfMt2R8uJ9LJWu8V66iw/LWOs
BKkMzkvrsrMJIrBHsuXiBD9Zef5GOozCatabQIQlB5iTiEXIoWZofvnSbNHfxlgdhurNOlKN24gU
HXHOscYZYY2Dz5fygkmkHl9g/bScALP/QLqpio84NZp5crPEsCqLUY0I+0KGioSCRxsoXyNZkSfp
Oqze7W662m0x13WhPlWddkjGxA29iAGWqjG6XgGB4TcQChVW3iVSF77P8hvhZbqExHcFtSf10DU8
2FKchnxEQZzVOAKgK60/8AknK7yah7ySS9yDHBqeHs213oAVenx1fGjXQXM+oSAsSG/FH6wU+3FX
IvAihDWwacwe6X8e2cV36QQQosQ2pmsl0OM5zTdH+l3VcZSBkAOIWcBzmU89GMxWIx/fdbtb21vt
LnztdgaD3e2mVN2n77GfuGa3imswJRLa2KIrMl65nraHgEJLMwzohctiEao0e12uryURiyT2l+Ae
jw/fOK8xTcWEHR3bm4rgaPn+YlERW8G2A0K6X+BEqRRMxO1gUUDG05z+9art7O47v1x/73Qfnasv
d+71i4binlP5U71wt0rNOnttvRGYjcIyj7Z+gKVuJVdDvRnBebKN4TRBHj8ygXeF36E8rUYThEnW
KmH/WWGu95fq3lKwRDjN0jGbNZkRn9ELApX6Ai+wJ0oLzf6JPdSNKnUDprIc2SB6yUDXMpUDUUdn
HmN/Xj6TVHjyN5GoIWmln8owDY+jomUkH2GtRFbNWBY8QDcN0f2t1cxplSdqVY8IQcJc9XTT19z6
g1V268n71RIe835yDfzapF1Oo+LQX5cdnRsSqlesgax6Yr5zXcqszNQKoNoyeZTpijEFACkDkW70
BETnyIQJKSF05XwpixeGB1Sq9yhNbaQ1pPqM7cnLgeePrbxJr7yMuq8o9WvtVwCdY6OdOv/YoKA7
qJRa7uV2e820gxNSUZNhlmmXpsUow7T/ki5QdXFXtIfz1wD6lch6W9o6G7XY/jesP1XvQzYMIaKO
Dg5O8JqT7rUUG6aQccrLyRq1oEZoZET1f3uaNdVDkX08+nmvTklRXT10adKvJvp9mSw9o7czCOxV
cX2H5ooCqLaKabaIABeC+05Ol2W26GZFwQJHuooT8ETCv377vZpbG8qa17o6KHtKAQsXgQ/g0EVQ
+h/j5VzGSujyWpZWIgodRL6kz60riCLc+fbb9Qsbfu7hkPscix1A6ukawSg6UCUhZddFD5Q6kE0v
FphOgLV+Nee6ZfuEyTx81a2rX+vXz+064Slv61wb+DBmlDfXf23C5iZsxizzTzfnK74aWeAz93kD
vVS5nLrCw13TWrNyU8HGwz6JrnCwzVoWdUkb5UJtiz9YSEvk6qpOFBK+pQRPo3Y/ihVkd3guHAKi
iWQ9Tb837yZkavuG3TSttjdIwXEpzELsWdv/wEZxkqmSEVwtPr5iyFLcGkSZTLlk17sht18115/d
Na/teq2hrsDGeBVZ3qGuRkvLlLyo1jd3Oim6BiCi+URNK2UKzvwB37EmwpzEOrchr3z35esbleQU
tMj7WCSl0GMrih/oOdJD+yGeTpXdtItkpwPMfEYPLEpXhEOjcVy8DDQyW/lyRFeZ688r1CPCgO6x
zKeEgI0eE6qbLuxZ/8lLtMrDKlsVMj9+KjVDROuPtn74hKrW4DmZZ1FZ0AZZFQ6vRPqAdD50HuII
GCyh6JdATOeiptbJNpKJzJai0FJpy/pvbCZ5+bM6GGkxMh7iHra95Lv/IbsaobWsxfgWuzrAicod
ur7LBkwLcD3ycQO2S/AGVb5swFcP6Wo+iUO6Nca7feNqGHnusE1XzNiSM+451Bt1zA2SAJ+aeXG4
nEfqXbtWo+IO15YuBzP0JEtVC7ZwGalMOWtGtrfBdMHYpY7AV8OqCoFcjCmUnPlNvHJ94uYcHLJt
pJ2A2FQMwGi81ijQViXdRH3BloWclzVGhbYmUaAMw8lZHqTFk0qixqCbzGOdQu2jgDrljgrKDP9E
DDH9VQHYWQeqnA3AlE6pAFlyUsZpN9GZp9oFGzAsb4jtBLpw8qoZmYIuQBpu5/FCa8wLsF00hgYu
6FxDwURfXTRdCTAP3Hnc+kswD56C+ahVdrScz3my0lFL7zYiUHHZpt9WoAdSYhqy/J1s64mHsvjS
UT7ZSJl6imlXavwjBbhI8KhCbxWXnx8nmvdGNUehWBGlGzSwUvZhFlTzS0DMof/eqv68sXhe39SU
qcn3uXKQBC4rkstK+NC+v/oAvHj09l+868YWjflfl/3vr7jRGKUBFv8lEtVA5cfd6iF3uTtLD/cB
gQuJFvJDxtEIH/+HwTcszCUzgLcR1hjy9UdED6fcTV1meVBsyqeFfEcL4eUJPFY8/9/dlT43kST7
7/4rOhptdLctCR8w7JPHO8O5w+McDEG8QH4gLBkUyJJDLeFhGf73V3lVZR0tyTC7H95EzIzVXV1H
VlVWVh6/dHYrN8ELNDBgWa1lY8Gkv+ObEHD2DYeHdbuNzG0yKdRk++p+KW0IBR/AqOEbQ2n4H9EU
/jKU0JXQmINqoP9Q0SlvSbOucDvCc7MNTTPfAq0/vDI7eDl1BXnH7SjWI42RFi+WWtbFMqCu1Rz+
fvCBv2LZi/8AJvT1aAgn4R7584Ne3nyfgRfX8RJ+mvU4yOZoq9/r3Myuo9f/g/kYojpK6+hVkcP/
dfPf1+DU7vn9M2cwzZCu/xC8icDsBXwBlOoD9gJiD4WF+NRBzIDtf0qqQ89ZIkxZBzYERbuGJThH
dwBxxj5iJnBo+4FTcUhdsb9GoNgAz4Ti0HbNXoLcGcEN2SU0lzvQcIAXgsKQEZbayyXqegyt8NfH
JfzPkBf+dzzA5WnmgVRvdnj3Bl+eLs/L1jTaClOl3tzr3Dpp6XVMPjNTtZKBB5StsenPrrl5jg3L
XGS34K+dHctbocNvWuMT4rBTPagx2FWAlR5mu/qeh1qW1Oa+dJtb3TV8bRboqlqXKbsfUfay6Vo9
+4RfKrn3l17ZP4ZL+U71i/xV9odf99r736oe/GX+34metApXqZ3i7SLY/590r+1jd4nGTS6fJzmj
vnIfcv/fGMlkcsLfffPqbw19zYD55CNsW5pWeX4Az8/j5zew/H70/CaWj5//dOI3TtQ1/6WbgWm5
A2a9A/m97/8+p/c3/0t+7/NvW6uauSlqqGAJohKQ/lzAvX93I6IPcW2aKUKacx17UsetgI5WrBqq
pWJ2y82Tqt8t+5c7fAXlbvlkwZniFqh62ox6YjZpD5rp6Ma4zrA2bG/zdlRN/lfDcDHRfGLZzoeF
uc7RPJmP8GdimtwWTE8DvZt3kUPimPhvuKWysJC6hxetyyIPuif7O7VakLuYI/bNRX26rM31Z4Y6
iBPDymnGYOIOMyED/P8wQ2KY0SnubpbwdvbTLtxxzs1igQPpCBeyfbrvWLy3I5nNQdiM8qfzGWpn
jznqKPtp37JUNwo4F4+wji5apW8Ph2aujGQ/9pmeISIeQDQ98BXMDz8FKr83zPWTps8Qu0XLFk5Q
a+8+5N0CtzWzX3bJXoSlb/mHgmbXSO9wvlu0kFlxcNmldWTGav5ezGzFnQ/4hN7SAOCplFNST1Qa
ZM2gcLzxL7tT6+ESegHw0AMnACOzYX1TMrjZcdDZn2hDbr6mWMPBg/TANQJNmnl8YgoYKQu6h4sN
tLqj9Huz6Kp4WCMaNekYyb3Dro+9KkWIqZCvZjrjA3Oat0bh1JHo03VSD9yHohJ6Q9OOwRmpqVJ+
xpvc7qjwxOKmVh+CpVzKqRzUCTot+bmTgwZhB9cAPvBaSJCipg0yFSWWHQZtI28UuId4FCLm6UF4
233eYBveyIIV2KZii/E1hGhgQ87GYTjd7CEzVorV6GktDBvJ2lmOwSE9vBloh0MQkk3vqE+B64fd
8q0z0hMz7oW9if1ZwLT8WhZoBZB/2S0Rhbgz8OciOc7sgAE92lOPSOg2J5l7NKdHBydaAGx9Ii36
r1iE4AoCn8fLSBS+pFshaMrwYjj9QgftpRbYdWll1WHXgEHnX1m33dvpd062PUlaCCqn2td3ieil
6GBrmdMQbAHB7QREWjoo/S6ZR4kmk031sO48MDLhKZlSO1oigr4oEcj/Lm9dvsvz8P46iGg8WKFk
RmLDpItyLTZIDdZZAeh7UcaFRqmNJkMHjZkZGRRZiQqg66yqTxNNq0w9amndvyHTIEGmUUSmEcmn
uBQtT4/X4KhxDb7d6bX/dsVVKCFxZtCjYBniiaJseX+DDaIuOI4Oopj1aCDx9mb8o8T459H45+uW
yXzlMpmvXSbzH14mHCloiDXfbIWwdtkjDMcKG7rMfbqAmhWtykfaJlBc2yS6sBM6O3iHgz1zVrhL
FLrF2ObRTgZA+cFv5qC5N5sW4GczHIPjdA+MZmPypZD+EYIHdcJrk0O3KAwTKSjOGAlfDNIOoRmH
XAQmo8HnUR3DmYzOzozY36WWUESYWHCbVm1V3LiEoFGle8M+OHW3Z1jxKFmPFlq3E/gVeCZodpYp
S3YjVn4EYTlsOH83zcl9sLTLQ73xlCKyhJ89amfm+KZY0J4dpV5q5JNzrHrQ0N+sQ46drvH709MZ
gt7dPr778GHKhwdbYD+ecF/BKoCP44bOBuMJdrdsve3e/+N0hDBK3SejujaL2O6vawinYJ27rFXR
ISzpWHbf3wUiBmuOLNrbzz6CBTaK12xzMxyPSRtI/McuB+OFI6Db8APcs4ULJoQFE8YTwjMKKcS3
D6hYbhjB8+O7ACIzHcIkGKYAr51nHxdyD95J4Jn6p+goikq17glX6qK9CiciH4Nk3nlOZlNyZcfF
UPihkkXWuc0ewo/Biw4OZrIgHC++QOgDYuvRIgscWWFF8v7X6/EbekCa0d8BwlvhtbYWrEejL2Wh
OQxqAUOZNPMC4A4R0kAszxE0HAJFLeqMoOAcZ8TwkfLZMcL7ZbudfXGpcuAMWJdZbORWlYHf7OXA
Bf1UW9esA6PvodUzvRmOawCyG7azPQB4dHabffgJMX3ZAX/mUB3b2Q14uxO/MG3dbPD5+omfJ74y
N3joejv7Ow0hLuJrx523Q4nxOFbaRyKJ+gDedGe1OeSYqEeZPLuHD5Rw6DwKPD0H10e2bfgb1Usw
1zcc2z3w9BfSVB5BYZZJ9ZEySxeV7Wskl2DHB0BAuvmrjvmdN3S2PbtpLYW6Dho8qTlsb1vha9eV
qIr69FQ0IkQUAFdb162/u27dSnTLVLmyX+591DFstS1P+Z7rOEqvMW6+jELg4/D3MJC+It7gqo8s
7PqYdYFgVRTbhANVkWKNXo6xL3WVFVGwc2GpwWo975KmVhmVcvdQu3bzThPeUKYnU/F4+0Xgf2IO
y98z31xfpT7z4Y4y37Uh9YHGV+IdBE2VV3I/QW8L6xzSOnc63xxqsg/gbDeSTKof4omG44w8Pfj2
Hzp8OP8z3++D9rpSB5xb9agSz1MkQK1PqwziozKpwMkmkf+ZA5zxpJXSHjn2AELnVyeruG6qZe65
62oG6osj8WblpaqA8Hzx0/cD7rwYXGZ/iibuAVw6/huQbvwGYpKpYxabNyJHaq1zl3BO6e/Kgf0F
ogPvtcX5BRw3xxT1+PBZ9zmpcc0gXppbAIgsEOPGuh6fGuorKGe+em1O3pFZ/YgIUELl1p8Ewmdx
YO2sfDq6FM9FrgJX16uXD/5uhWDSCFdKmPICdDsuHhUDWccQyGraY4fX7Gw8xSAl19sXo3PnKQ/D
XhlUqGhEUk+D9rET4wAEwCBthNPgyyMihyTUj1Y44Oo6ur4V7DmIJ0b6d14P5lMgYZ5AgcV4ojOQ
Cns+Xw7QSzxkvvxQbht76kZ9dg9jXVYzeipNABTg6dh4LjweDSCSB52Gim36YFtiXo4ZoESAEvB1
D8XNU5LvEUUV4VBc1K9G4zL0nwqObKv+fMr79u74HCkOR4xhswf7b6UpkNaBEDmGeD5++Oh+Vugg
nr8V+bqwVLv0Il9d3GUULyxeUo4W2zk6+HJ8Kn9lugOeq3uhL9znU0/cm1I8KokvSEP0r/Ojj/SF
W7/xfMmvTqMjIwtC++sIk4rG5YEEC7jwFrCg1NgVvHrRFtGivRbg7ZALM7sEv69nk6XhrxIw/TOV
+Ud/m31hoXJ3b93PLibLD2Ca06vsZ95k8u3PWPgfXcL0hIBm2jPozPKjod39eps7a8Medn6BEIjv
iPP2FYYYeK11oaQIPelhoCyYcLAE79U+U6I77G83BV24auWjd9sc8sWx4jEz4eBy4CKHkZn1aoHo
THXzF4ow96fDsujDZUVXK5yNob6cQ1ILdBjLC2/e3Mql6kOCU4sq6EsYpjj8us3pg/QM9e7Ur4b4
yp2Hrldag9G1err3g0/u8L87u/jCR59aTFJFx2EMIt7ScBhqr/QKDPVUpMdiS9Q1+JrcVZNqzVXW
NFCuyPZjGvLuy92wiUMg+kRDYcAcp2BG1e1cRcm4Cba2V5p7kEuQSPhfXEqmWrMfIUKXiGQn98/s
2XLReSrr4UpxmeZznwylThDB0QvEZy5nywlCHZLF1+rQPGBLiu8kTRxHZID6ZI4SD/Mew5FeXUSA
DDASFQe5NL26kF6pqNNgt2FdVZNshW/NVNIfuA6FeOvPhXCKqWbS/fg0Ex9ETfYet77RbAdOr3LY
0BUbiQkL2nuqffdDMwsclZJEYIgpBTrwXzwawet11dBDJ4FX0/nogxEgR/OVVd4lFMoee09sRt1V
FA7wUhtIvMjTFnpTjgCkVsQ7an2sVgakNkvT2qNGgHeG646b32S1HTYSwdtHzauM2rIqnCXeldIb
zHLCpv3VaKD6nvBc1L0rMIEUH3b2odzbVUeaIb/ZPml/L6hfrHvPlOI9C7TuAdTju/xda+/Pd619
8++B+feGmPMqofWdFSeyZyaiaWkyDtm3m5mEwi2faOer17ucnyMTPNSnMC8XV5jX7Dd1341sSPzR
GstRko82H7s9qXcjptkU4+vb2DShNrKFpWWK/6yFlgaoiRbvPlVJLx5HHoiGgjlrLzZYbXFb38et
PdHdV3btfeUFY3haeeDQIn82YXUCNqcG7PRd17lCUi+Eai771t7v6KQxd7MuXVZTfNVHFwhsX8eT
0egClDUIUpQd2Nd0XKbbqbqgMVvW5LbxYjmFy2ARLEJvJHq96QmkYTISKttAbSt5wuXyPbpcyqZs
i4RsvfHfR6fO+41OG2svUObk3WjVWcWN7mY804LPTX6BDeisbi3a4VQ+WoRlPZavMAuS64c3Tr/M
msFq00iiZb52eLcKzf4ck/FnOaHiaqTU6PNIyAUEEURvIVSHj/mxPcFFWSDG01ixB82jMrBMaeki
jc1j0DujvyhHlK8za7BhxkKdyqqOPa23lKM2Qqaqf478OH6/5FtSnEhJCndoYOXuzqU09m/ZaHEU
W2TCks7FFZ+yy2uy6FTi5p0RxFoQYtuAfR2HbaUqJyd41w/f188PyRcK8tMtP4/IW7HzaOr5Nh/7
BVwV3rLOPqC3tkWlyr+FqOmwvEQHJ4dILr5uiA4VnEqas+mtt1SOEhgOfnH00VEUsXAK4YoSVx8u
59nMWBn/p5pEsHeAKHh+AXnBYgW7tqQE15Ege4OGB4gN0217UoKb1AX44YY5HFqIghRpagDLT+Uo
cOI7QMj4t/wonYO9x2zhFWGz+u1HxVYCBUgqaUIDkkE0QgLZXrjxrsEHamFiPppQ1XH7eQEmNQSn
6fBleKs1mX0QWBGSyXEru9mMrcweCgIb4xWjqCy7FXmohZY8DE+iccqDN5PZ9MOJL9rTEOKBNinW
q1CIIcAZaAA8+8sGNkRqmairG2mSLD0DXVJCYubRkFgc9aWUIBg2l9nJaJg+l2uEpCqS1V7OB1O+
9fIXUk3n9gVgOof9pKPYPAIMxjI/OjrKvu72vph/Ok+edIbD7Lffeufn3yKQBHENS3mTfN37VhCs
pB1T20c+oBEyi5ALCp/ZisGnZIWviud9Q2FQf8CQis+mIxK1AHcPk5mUVivQ1gAn4pIU6uIAbgT8
CCaDi8qc/MvF6A/Tz4TN8yPkPzI96z6BMiVpcdpZ8c/J7P1g0g/v7UW1Rcv+zefZeHhCNXdfD8YL
0+XyDYKBXgymEINjrisS5XKwW7ml/SZq+vb7AYqLQ+yD9Q48gV0AcKKch5fOuF6Y6Nacq8DJzfdm
qd4ZQN4TkunhmxKyIIbpnYBoglxI1njPL+oFtvMCc67WXqBw0gKN7FJRFs4V/tPlBKS+dmnoD6dn
s6orzVDGV/ZhBoO7Pz4RDROcwTHg4rdHj5/0+sfPHrx8ffvF/b5tuM+V9e8u56DmYlh1eUxN9IFD
cnN9v1tFypFbh7yHvV0/jr+i+40Tzt3nJeP1nnvV+Gm+SaDPCy8jkU7NE6WTSsX3HEsKokSqIcRl
7XiZAHAbIzq0YeuY44j8pyXXj2RQ8/IemWZc5iNzzr0U/DXMUOt13PTF5omrs3PTkzGkgB5hV0hq
qcnqSRkRJ1+6jPdj+m2oWKM13EfD/QAZqzjX9YzZssorZXO0Gj4PWr0st+mKcsocdYbIGDxEUDJg
AqMStR7jaSBnpZInVd2tFg+QpityDFPHUGIiigCQ/aGuq2y9WNqY+5X+X7ISbJJh4PXm4+7pZGZ4
jv8r5R4lFdSkiEh+Te9Wfn4KLu8NbaM3/KqPyW87/TW9W/k5Z80KP/89w9/01vPc+n/iC1R0EHSo
AxgO6BHEYgtohP5656DVPflkgUTttAArwP7NoH8wFfDE6yQLMx47WumkGe04pSlh8Qw2qyRhc4yT
10iZqCFnd2/r8QPlj3yMxninNzi4pcTFYxYtQmbuEs+lhUlgxb1M0MdDxHQSfkJwdOg8b4Hu49np
YCJftXFcshvcjHp8B8usdwWTg8OmqujIzSdxGj0GNwgYOqe6zC4mgy/m+Px05cyPKFKFYKYcIwbe
7A2JFVmVcaiT/enzIzhSEQaujv3UBFLpq1jBfyDN5KHcjI6akxq6qxkW9VA+HNqQjV3zLpS6rFaU
BB+lwNZS2uXi+NHD58/v34Og39Q4O3ZW/OzYNhNnKj2jXUUQQE3ZT3Gg3SJUHxf1p7G5lg1ZMc6a
MOUKRgHVCY1akdpYBeympG4NnXyT6nVLAMk42XSr82IEvJyrPepo87jzNePesjgxGDuDsdI0qxq0
KjLtaJSxnjjl8HcOzATxrJSWkZcLH5vC/yhEaZOMRsD4N8lghEh8GySwKRL41sUmSYeggU3yC0lA
uVu9EgbO0on8pNhqQGVqAZOhq4D1oQrJX4Cu4Hg0mGPYD8J28F4pUkFgNaBOYkKqTe969IGrQdTe
R7ay7l1zBV6M6APqCkCddenPMn9YP5QxH+0iz3pYUyAW/wSlzlFxzLFKhRF9ddoltuojvufm/ab/
3Z0pvbCzTS3RNoUjifBAGE7G0tp1YcDomCrbwmBBVq4g1wJCmQ4WTZkWviWQMqINQx35taR2Y5Ra
2TEdh9sGwLUUG8pIOClYnWiZX7Oof5vlcI+R/gToz6Z8eCXnTQT4l4TncDzHDYYw7djZgGigXm7E
IWzahGX3ST0/PeZuA6AskFl6T/F6PO8Eqbh5LwFxjzWuYR834k4/0DRg+zU0vRHDW910E34MIiY1
gsd8ei/n5LL76M7tuSHwZPTwXq1XJZ4Gj+4gJGtQCi4N5W7VdGA6fAGyKXlrXWWHEkBOqJ8QNE3H
qsB3IJdSqL1cSlaNw6axORIsu/eXk8HtU1Dwscpr2aWf8KIMcW1YyQgsDMBvTGNVAygVlfFp5VWV
grlTHznAOz3QLGtxzUjf1riyKUS+NfqywbFyb3Y5ncxQu0kxqcRy8B6p+1rJkZMHMG+TplNCamak
+OFEOD7ZvQCekKlmXknhMgjuge40NSAnDtUPJcMW/Lrm9AIL8rdBc5uSPsFfAZOuXpoFAlcGiKFV
PzmTJFyRG5ij6VrX3BWp+6K+GYPmFf68i0GX5hDah2xP6mAwVe/wUIN5V1IYix6NBVewBF84sQbc
OtAIq6CpxPmjBZmnM4ccPpO1poT1QIEcgtGkIvKVXAtaS0jkOVqQfi2T+Bb0XSi9GMS5aLP5wjSQ
m99kdLYgoAd0YwJ4h8F8MsbsWc4GDbNG3nGeDr4KmWAg3ikm3BrO7HNmOoihw4hY7jN6EJvNW3wN
PfIAePIHtx8+hksGY+yEM4Ix8G75tEq3lnijtzOnSqO/+EXuYiil78jn20w6UGNzgwTzZcfgFcuE
9Np1v/DzzrUm9nbi+poA+c8tLHzrLUNv/Sq9TpZ/QK+4eFLQpj1XqH4kKlIfgUgWVsRzw/FTpBV1
80RBIZq2bsEEoPV0XfP8PaBL0TLDfjrvS0VZteVcsI+vpVJpKDJU+8CSXGE1RVhCGhIPDk7UJbrs
hMvpMLNXH2/ETZmGeOJLTPBGQ68OM7vU5TmroDSMiK3xh6zJq7WzoGxNqP/aGerMIs+N6ns0toH5
LL4HOkUgk8Xmgy/WquTC3buhjlhpZgP+aZWzu1WKlGSDUagnqJD0HPOQJ1Ai++WFmcrxhw8uXgE9
WXKbXAsrUuEt9cflYmhEB/S2vj7Pri8yI49n10/BRx0rdi1Jxr+Ug7fybtT0fiF8DW6A++BIs0RV
5SmoayY923x2fVAlVE6M5B9CO/h8MbC63xaKjGvLKCn/q8VrwsXyLsdbqTLRB555BdipC9GO+14l
raUSNMyuCtST2hdSlUOEOlEnuUQFcdoh8oNAhJTF7EJ7SrgVopGvSE0cuney6hsXveTSxjATUCi3
kN/UPvPCj0nDZOQ3UQzTLwt3j78oBzT9rRI50wN3lZWKXKZqi/LrpaDm7yiJM/2Q1Mz0yyLgm78/
jjADGujFW/aaHTBhr7Pj84vZfDGQ7kFE+5y8OcyvCXoXwlFBZ0CkQGGmc9daHUHSnJpWT7tw2xQc
xa2W5Fb8zs+ZF2GWl2ePchgbqIaewWGyt4WuQc4LBV2eWjZbA1AjZSN4dhwbA1qzujHS9tkFUMb0
h3ptVslnLgsnwfP5zLw3xF5rxM+evgzs+MUaE5fplcsDD/qIWd3lB1UXLlKfu6/uvDBshq6An7v3
xjXYMKQM3tNtFWD9R2iKuCBe6JCad0h2jDytTMuP+fWrC7DapHNE8jEiskFEZ3emWoXi92kUeSGM
5uvViVue9pHK07uNFI3mYNhqVALK3dBztCAuAoAkOztbWguIKj2YSoxWTvm+n6a0gsHldSgpjxq0
hLHW466nn/MRqEx9nETF9S/84I0pdBLH/4YqCKkAlGQ8RL5nLLsoMMGL/bAxm6Y+VmkgGV3CF/lI
kr7A6zf26cnODjiPOdj6AaTzzFWBXGuzPzMVQxWf3wcoR0MQpqoT0Iw+O6pX0UTJF2/8gidqUdiO
4t7Egid5CvB7U/VY/uhOvol6LO94kI4I3AD0gL5AYx1PtbX11+jQLGve2WHMSOZJ8rwKOmWuJKD2
EvEcvhBxdovv5rRLnb2XkCdMxzDID03YeDReF3/hDK4iiHeGuXdrSBWDGWSqtNWDOcWzKdMoUPDL
KuXz90qsZc/ZK9T1RUnqvspCn3273mUdj0fGIGSBlMquxR1sMKO/8hMjr2DjCj2CR44zrbhzeTXu
XjVwcXttnS0GE4/S4BoDD3+j3iIlNS4yfRFpRVvgVsUpAOGGfGTv/fkhKt7yV9OxfXCAEgjxNLVG
aQJqqmMXyjydcZw4QrZwtZD2+QP42kvVx6LFk6qPU2o98/IGvCT9gvl1E37dfj/D2pN49ejY62jz
+3I0/8KEgbTughD/ZDxlwrSzvd3d3Zh9uYkdMRto1t67sowG4LJ0/yZLyDEIlcK7RR7mK6r1cmET
lHujDYHlQOuOYsYJaVbGZ18eGQnM0AbTDLRdAXhsCr1anFbIn41wDI8TRyiNTombdCiMuiwcQjyF
Odz27PMmHasvseL/E2YK3njCYuGuzYRET64knr18ozhmmSfdd8Bxx/xnH/5zQC482JM27ok3hHuo
hnbStgvdvnTjg7eyRKomaHqb79gxN8N3Hpi9BXFomEQvcGvm4fhJuiKdk+HvZ3gs9NSzj7OFuYeZ
G2eKlpz1IcXs5TuW7n+bLR6Y61wizWfXsvRnU8IJcllMM/3OrPX6lGTixF79SKmAbLMNYRH+1Edi
xvp5N/NsNZoy9TTrH/VI2vCbBv3wHv6A3sMNG68I1cp8KNHWkFHFq/5XN+QKYHA8YkZHYIMbMimx
o2vc3DMh4EFpnpEnO7Qc69a32FSCvyINaFQfuOLZp/CNyGUNNeR8JeplIJfZYqJVbWd5JJWlBhxs
DoFhQieyCJUv6Xh97tyma/m+O56ezd5cLgeAifC5zdqyE0B0hVoBzRXRNsrhyFwW0ayxD1ikywEC
ujrU1xvZcvppOrucYtgSqtyOshtbCsAqeVX+n+OX95/InRjk6vlscjxa9Dkmue5L19ZdlGtzaFLO
0c+n3WPOy4FLaR+lEdsnEupNoXs0IvD85xheYN+xrpxX5IFfzT4/vuE/PsCkdclEvQ4j1yUp1FlC
3TSCV2zFyLk2p6/2xTMNxGC6WTlo8vNL5OrtEIRbc+bguoJmGvB5u4ZGpYL5RW+6CoaD0SYiUONj
cZi/IHyK8p/PnxlZnJBVzE2ulz2dufi0tunrswvyqNwHJDFzdONCYzsu1girzT5QxmVCDZ7AIZ4h
+F92+nE2q8GZ5JZfA35FtQPY1xzMcvu7ez/tVF2z0ch5c8A9duE2p5Mx0FmIpRMXw5S1bUGucVzz
RWQIO87LUysmyuz18Ss1ydS3CyMrfnaRCd2t1uXy+WySbaJzQhSQsdk4cQSJF/GyVvE0+Mub7N9+
tbbVy3pZO5MU9qH7qh69fsUk1SIWEqUrr8R3Knia+8bArdbE3MknLj5SQhjx6eZXFRVR2RV8iu5T
WFCsMXmMFapjrDWueQxHqEsz5BwuTxekFTH3yj2d1foJ4R/v0tEk7AUGf2B17VD6nqCfFnIeCL+0
zKbYUqZTIqjecJbrpSq1DAvwa3j76o+P9iqvegz/xtxS1JDdy1K/cGmSIRsKWabtd4a36/sRiE9u
O5eKYVTa4+cgriLgIlyj8xjQlR14ld1YUZniQD5D0NXdqMApM5rhfdXGzVCu89tL8DXdwM2qiG8R
tKxhim9UwQggfUcv3e+1PXV/3foOIgO9BDdDDeCWR3BJJR9Wn/M6dN+1ymgh5eq2YRenogUayu2T
MSe3bYsWixEFeb9WDZsDClGY/XIOChZh/u7EXk/TRP9Mb/bacltMtJv77bqtCSqeX7/u6X1bkK6h
YesUpHjwJ6z4xhc87M4J6Ie0q8dKGmSlfwD2kmcesIytYEy+cNvTzbBpAw6GxBLOD+kEpYOjDI9O
kkvQtAHfQbwjKWrQ2BNMyGEmgP7yjn4dZoiXr6AoBdyefa0Rx969tRDzkt8I5EGs4fb81Ig+qbQG
3ew4ysPgA/0LmfF0qcjoDdLa6A9TAo0i19QxJQ7RPDonuDGln/GZfF++JhhfDLR/YUQWjNqhY63/
8/QfXYvsLdi+YPi/xuZ1CuHxXYDrlzPWBLWN3PjH+Hx5fo87Lw470oARdQlpiFoiFxDnhtDNbmNE
0hgatEjiBzczTiIcJ7AAwYuCTXprs0j4z1Oiroivo/l4NjTL2IxyVNcocVMMSa3ofvf5BHy3zTYT
SqMl3ZKZkTJsFcgI7GXhzhf43GzScyPzeYsMzKjnQ9FL+IhNBb5aJ1qxJsSUdHxlfiqSFr5IAj6h
j5VZfFMjB/m+VYTsBSxgzmVFQ8tQtNBzQOZgPXv/OT0uRJfNS4qtrh/HkyG61+Tyff8H1nN/ux+u
4227in8EMxp4CMFwCS5vf7jTKiIl0FfOHqK++NaETrSlrE28Jzxr4tkHD2PPQYXxqzIA3RCB9IH5
gvragHjfnfs0AmXMR3METkZzK9VeLN+b48X+XHJwhMeNEshjLQx1sxnDub/8sHwDlUDLJzCErmUj
gRY2WTFxiAhZo0yDXXrAlwnKCPilQ8GkXWAWPsJayRcyixVzKG1KXEjQDbsVF0UTQKHre6TFmw8u
w8hONVKcwc2hRUkhNXB5wHPudb/e7pl/81LQpHeqnNz5ySHapVxOaaV1jVZxwb5CZiX1X2+XZjdU
hXUmbqwyzDwJ64LRIa1DINgg4QUsigVEi0K+MkOLg5sR8U4n1hES1lPTWQT9+nVdEU6JtuPxOoxA
i8XzOzadTjKJrGbiefLAKUEmAE5c9ZKpmPCwg+OvVa4IGEQqwdgntXWHbdE4o7OWnweHcgVeaG3x
w60XsiQcCX4BX1p+D1OLF27P5xf+zF0mkkbP7atRxciQjjAkCMRiQIm/uHdEjZURlrjegrFVEaCu
Fc7VFk6dTutO/ZzcrwOLDaOgrjz31tX8Fx1zDcedf6y8Dc6TNVjKlvP40o7lQAmpJy+CKDTvGIxX
DaySkpdJsIKaxLW8IU53VeWCi6JuEV1V3n4Lgj7mHbueMaLbh7koDcu7p+cA1QvbPEislhkJH7Us
vLD5C5lFELNNpW99Eai+i6Wone59qqGCQDrowHB0MZl9qbVqwtPt9tZnShO5l3uDcmvUc6sgEsxH
zoC1EIiWtoCofAR3Vh4gJcUxIq5/U8LfaQmXibeRjGsqsRJuPXZ+gYeYmc8TpFgo4VKh7x+2XV9g
cti54aF9U7PpAXpGUbeOnxy/Ncv44wx04MUVYM5CuUY6sjzfsB+kdP3SfzKAc2LUN40uBxNOIuj1
cc3S+ZFeAxedj8Ik1EBNRgL9KkXgpo5Ubqn3Kvfu/xpK9ih1tpcmDsuydcgJ/c/N+bwIan/y3Nbd
UN5ihEuv5aygVHjkGEnvXFLUKlIgO+e003N7YZqOvAuTEt3VCs9xp9F+oobe9bx0KnyNyoPDB5cF
u6Atz91e/6qzBcJ+l0Dw8JLgvd1oddEKOb73aN1aSiyftNAuieVtX1JG9XujwRCdrMLLlH2xMiGP
L5WJVsYTyhITopi1m5UGFo3SkwxBAhjtkKTwBRl88yxw8yvZTf8PkZ2QKEMZ2yoJT1+YEKlBKELZ
5RoOtfWrr4mhp448XZur2hwTj0YXC3TS8LIl6nSIygDJOFbnlAXYkixMsOay3IqJxirwmnFMcXlE
qI1B8jcbHQOhMqtRtAMFYTtQfwYp52wPt1r1bEkIKp7uMneqSs1VfOVn0WD/B9Im3B0C/C2LPzWr
RSHN6FTqTRfzUyEIlflxd0AegZxsMFFc/Cb5C3EZD0uSLdmVptQMXDoqTBTCKunvKl2kO/hsqA2L
0rk/hiUxfsODGVsRZZb+eMj3IPMt6m2CaygBjNI9lOGMGiqygF+/22iysGAQ6hT6mITF4WpDNzpx
z48oxc4cYigUi2FYTicw9Jd2c0kvnaFb/jKoa+jguM6XYAXWaKm3EIRlVcA6+CXC7y22rp5V9Dsy
il4pm+i/N5Ooj5/K2UTVQz+j6L8rm2i1lUAt+t5Moq4SkMMsqm8QPxZXDoV4tlftb11ZvkFd+GA4
+GKqgn2Ol+p78NOrhzsqbEe66fz3PqGvLTuAAyx3ZV4niSS+HOaTVmkjFz6dWLE0rNRGG1C1Kyu1
Zal2F3ag6l/xuY2Xsu75MPQrABE6L8r/HADhpolIQ5zBK2IM4mH8xOKCZhgzHaKPOnTQrdXd+gTu
fsEhAN6AmEl2lrczz7Gw2qIQ7aOkS7D1ULQ++okw7dyGaVtXfoxaglWxcVf5S9dJjJ5O7w2vx1cL
KYe+XvjhY/kG+I5eV2VJQyNhf81U+mCMQaxaz+3MLmI9ljZe0r2QR1XbOb+5t/LIvI03VRUhFfTC
o7/NNs+eyA75For7LxtR5MzhgDw3dXOo8kY0uRwo61PjSXQ297Krn2K2u5YCvcRZFB5CYS2WUnwI
94JTuK1zwPU8AcB2mRMl8FULQTf8vEG2SI5YcleKMebY4v8Dnhakr1DTAAA=
'@
#
# ---------------- Menu ----------------
if (-not $Mode) {
    Write-Host "Zabbix patch management - $env:COMPUTERNAME"
    Write-Host '  1) monitor - install / update the checker for Zabbix (scheduled tasks, patchbix.conf incl. AUTO_UPDATE)'
    Write-Host '  2) check   - run the update check now'
    Write-Host '  3) update  - install updates (only in the maintenance window)'
    Write-Host '  4) force   - install updates now (also outside the maintenance window)'
    $Mode = Ask 'Choose' '1'
}
switch -Regex ($Mode) {
    '^(1|monitor)$' { [void](Install-Monitor) }
    '^(2|check)$'   { Invoke-CheckNow }
    '^(3|update)$'  { Install-UpdatesNow $false }
    '^(4|force)$'   { Install-UpdatesNow $true }
    default         { Write-Warning "Unknown choice: $Mode" }
}
}
