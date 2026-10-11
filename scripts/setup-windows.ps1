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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux b784543 (embed-check.sh)
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
cI8CAvyEarZKjnGud3JVZBfF/wec+AxE/qYAAA==
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
