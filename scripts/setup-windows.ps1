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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux b0c12ff (embed-check.sh)
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
H7MAAA==
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
