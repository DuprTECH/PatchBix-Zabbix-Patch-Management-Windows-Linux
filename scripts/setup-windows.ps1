# setup-windows.ps1 - Zabbix patch management on a Windows server without Ansible: setup, check, updates
#
# Paste the whole file into PowerShell as administrator, or run it as a file:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File setup-windows.ps1
# A menu asks what to do (or set $env:ZBX_PATCH_MODE = 'update' before):
#   1 monitor  = like ansible/check-windows.yml: checker zbx-patch-windows.ps1, scheduled tasks (check every
#                12 h and after a reboot, automatic update every 15 min), patch settings <Zabbix agent folder>\zbx-patch.conf,
#                UserParameter patch.config (host macros {$PATCH.CONF.*}), first check. Running it again updates an installed server and keeps the settings.
#   2 check    = run the update check now (pending updates -> Zabbix) and show the patch settings
#   3 update   = install updates now (security, critical, rollups, definitions,
#                updates) in the maintenance window, without EXCLUDE, reboot when needed and REBOOT="true", result to Zabbix
#   4 force    = like 3, also outside the maintenance window
#
# AUTO_UPDATE="false" in zbx-patch.conf (default) = the checker only checks; "true" = it installs the
# updates itself in the maintenance window (once per window, like 3).
#
# The checker zbx-patch-windows.ps1 is embedded (no internet needed); a copy in %TEMP% or C:\Temp wins.
# Requires the Zabbix agent 2 (zabbix_sender.exe). Docs: README.md (https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
& {
$Mode          = "$env:ZBX_PATCH_MODE"     # monitor | check | update | force, empty = menu
$IntervalHours = 12
$TaskName      = 'Zabbix patch check'
$AutoTaskName  = 'Zabbix patch auto update'
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
$Check     = Join-Path $AgentDir 'scripts\zbx-patch-windows.ps1'
$PatchConf = Join-Path $AgentDir 'zbx-patch.conf'
#
# ---------------- Checker ----------------
# The checker is embedded before the menu (no internet needed); a newer copy in %TEMP% or C:\Temp is used instead
function Get-Check {
    New-Item -ItemType Directory -Force (Split-Path $Check) | Out-Null
    $tmp   = "$Check.new"
    $local = @("$env:TEMP\zbx-patch-windows.ps1", 'C:\Temp\zbx-patch-windows.ps1') | Where-Object { Test-Path $_ } | Select-Object -First 1
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
        Write-Warning "The checker ($src) is damaged or old - copy zbx-patch-windows.ps1 to $env:TEMP and run again."
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
    # Legacy AUTO_UPDATE="false" of older installs blocks the automatic updates - kept until it is removed
    $blocked = "$($cur['AUTO_UPDATE'])" -match '^(no|false|0|off)$'
    $keep = 'n'
    if (Test-Path $PatchConf) {
        Write-Host "Patch settings ${PatchConf}:"
        Write-Host "  MAINTENANCE_WINDOW: $win`n  EXCLUDE:            $ex`n  REBOOT:             $rb"
        if ($blocked) { Write-Host '  AUTO_UPDATE="false" (older install): the automatic updates are blocked' }
        $keep = Ask 'Keep them? (y/n)' 'y'
    }
    if ($keep -notmatch '^[Yy]') {
        Write-Host 'Enter = keep the shown value, - = not set (commented out). No maintenance window = check only, no automatic updates.'
        Write-Host "Maintenance window = when and which updates are installed automatically: '[<types>] <day> <HH:MM>-<HH:MM>',"
        Write-Host '  several separated by commas. Types: * = all (also without types), crit = critical (Critical Updates or'
        Write-Host '  MSRC severity Critical), sec = security, def = definitions; several joined with +. Day: 1-7 = Monday-Sunday'
        Write-Host '  (or Mon..Sun), 1-5, * = every day, 2.3 = 2nd Wednesday. Examples: * 3 03:00-05:00 = everything on Wednesday,'
        Write-Host '  crit+sec * 02:00-03:00 = critical and security updates every night'
        $win  = Ask 'Maintenance window' $win
        if ($blocked -and (Ask 'Keep the automatic updates blocked (AUTO_UPDATE="false")? (y/n)' 'y') -notmatch '^[Yy]') { $blocked = $false }
        $ex   = Ask 'Excluded updates, comma separated: KB number or a part of the title' $ex
        $rb   = Ask 'Reboot after updates when needed (true/false)' $rb
    }
    # KEY="value" when set, otherwise the commented example
    function Setting([string]$Key, [string]$Value, [string]$Example) {
        if ($Value -in $unset, '-', '') { "#$Key=`"$Example`"" } else { "$Key=`"$Value`"" }
    }
    $autoSection = if ($blocked) {
        "#`r`n# Legacy (older install): AUTO_UPDATE=`"false`" blocks the automatic updates in the maintenance window.`r`n# Remove the line to install the updates in the window.`r`nAUTO_UPDATE=`"false`""
    } else { '' }
    @"
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-windows.ps1 (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-windows.ps1 (update). Written by setup-windows.ps1 -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {`$PATCH.CONF.*} win over this file (zbx-patch-from-zbx-host-macro.cache).
#
# Maintenance window - when and which updates the checker installs itself (task "Zabbix patch auto update"
# every 15 min, once per window, log C:\ProgramData\zbx-patch\update.log). No window = check only.
#   "[<types>] <day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   types: * = all updates (also without types), crit = critical (classification Critical Updates or MSRC
#          severity Critical), sec = security, def = definitions; several joined with +, for example crit+sec
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   MAINTENANCE_WINDOW="* 3 03:00-05:00"                         = all updates every Wednesday 03:00-05:00
#   MAINTENANCE_WINDOW="crit+sec * 02:00-03:00, * 6 03:00-06:00"  = critical + security every night, all on Saturday
$(Setting 'MAINTENANCE_WINDOW' $win '* 3 03:00-05:00')
$autoSection
#
# Updates that are not installed, separated by commas: KB number or a part of the title (default: none)
$(Setting 'EXCLUDE' $ex 'KB5034441, Preview')
#
# Reboot after updates when needed: true / false (false = the reboot is only reported to Zabbix; default: true)
$(Setting 'REBOOT' $rb 'false')
"@ | Set-Content -Path $PatchConf -Encoding ASCII
    Write-Host "Saved $PatchConf"
    # Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} -> zbx-patch-from-zbx-host-macro.cache),
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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux 860ff55 (embed-check.sh)
$CheckB64 = @'
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
EqwysEoBfXYCaWkI8JYu4inONZob9ePS1BRgvv3G0UTueNNOb9C2vXZnYvc7fd92dzpTu7vT8+Gl
0+tN+hhtajrp5gZGrT11O912x7f7vV7b7k/dPXvPlfv2ZG93t7/bm+xAEUrrdNqu1sn27t7+TnfP
9mR7z+73e7v2RO727W5/fzDZ63en/d6E1hWpvFq5s+cNJm23Z/sdd8fuDwY925X9fRuI6Lm7e134
f09hLM411Nru3sTb22tLuz3Y79p9bzK196b7A9vb3Z90dvc7HX8wpbWlAw+12IOPU78jbbnfg8Wy
59qTKZDc2ZtM25POZOLv9WgxH7rkFaoWFCcItcmgL3f9bt/edX1gW3cPaJjsDux92NP+ztQd7PWZ
BuPIpkZg3kk3W4Izv8IdKTZOpl5n6g3s3Y7bB/bvTux913Pt3mTfHbR7nXbfbTMb+cRGbaW3s7c/
8b09e9JtD+y+O+3be37fBZH39rt9byD3/YHiAx/v1PRWpoqGvDERyce8za7tYuN5o174kTOfdvNn
BL6xMV1GHqkxGqw9jpWb/KYqafTcyh/c3Gm3fZTcq/Ol+sSlFsJbi98DSEFNV2xjemaNIc7a9G58
azbFN7V+CwHUbA9Sc3OCeC5gms54ZeFvuLA8w1iq/XSTOFpZmuLSYgYv+x9hxqe3NP9tsXXgNjiD
97oBPvz9rn7e/zb7ni0xgZoYfJLnUjYh0zj8IhVU3er+C01whyoyrLNzvIHZYwfIFsDCIiBPqDAq
NovymBaBQ6yAbnHLKkhX2+zOBvLXxk5WEQxJ4n9BBViNkEoK06RL5hT6DnyQUPaAMOe4L2skQ+ll
9oj0UqzApRGgMhKNn9V2Dy1nq1lv5BgJaxBh57I+d84x2Mj0pn3n/AMS50V607lz6JjLGSfB3Grm
a3DHxl4QAj2OoSDhtAgiPmsoQ/9nHETG5MZmQylZZd+kjxgdj2dQdpD4Gfo7Tg+TJKbzGrRUGImy
8AnRQUomoaKC6H0KDLIvJ/8BxiD2X5x3yzAkkTwz+YVJkMjWM7EgyOCh1qnDhrB/XAYyY9vNZQ48
lNGX4fHl+dU11AYXUCIAtmfDuQCpYJbZOLZPF7E3s27QmeHZxF0dswEtFesG38YwfjmdQgnBX51x
fB2RN3VD/GY1mzz0Fd9GEmj2U6vJZsnHFHTcYVpP1xljaYZVGjxgY1gH/zlwEdQsJxVlQEBO3KeX
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
C2yTHLPK3SgwmAOC/x/ildZWbLoAAA==
'@
#
# ---------------- Menu ----------------
if (-not $Mode) {
    Write-Host "Zabbix patch management - $env:COMPUTERNAME"
    Write-Host '  1) monitor - install / update the checker for Zabbix (scheduled tasks, zbx-patch.conf incl. AUTO_UPDATE)'
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
