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
    $win  = if ($cur.ContainsKey('MAINTENANCE_WINDOW')) { if ($cur['MAINTENANCE_WINDOW']) { $cur['MAINTENANCE_WINDOW'] } else { 'any' } } else { $unset }
    $auto = if ($cur.ContainsKey('AUTO_UPDATE')) { $cur['AUTO_UPDATE'] } else { $unset }
    $ex   = if ($cur.ContainsKey('EXCLUDE') -and $cur['EXCLUDE']) { $cur['EXCLUDE'] } else { $unset }
    $rb   = if ($cur.ContainsKey('REBOOT')) { $cur['REBOOT'] } else { $unset }
    $keep = 'n'
    if (Test-Path $PatchConf) {
        Write-Host "Patch settings ${PatchConf}:"
        Write-Host "  MAINTENANCE_WINDOW: $win`n  AUTO_UPDATE:        $auto`n  EXCLUDE:            $ex`n  REBOOT:             $rb"
        $keep = Ask 'Keep them? (y/n)' 'y'
    }
    if ($keep -notmatch '^[Yy]') {
        Write-Host 'Enter = keep the shown value, - = not set (commented out). Nothing set = check only, no automatic updates.'
        Write-Host "Maintenance window: '<day> <HH:MM>-<HH:MM>', several separated by commas; day 1-7 = Monday-Sunday"
        Write-Host "  (or Mon..Sun), 1-5, * = every day, 2.3 = 2nd Wednesday; any = any time. Example: 3 03:00-05:00 = Wednesday"
        $win  = Ask 'Maintenance window' $win
        $auto = Ask 'Automatic updates in the maintenance window (true/false)' $auto
        $ex   = Ask 'Excluded updates, comma separated: KB number or a part of the title' $ex
        $rb   = Ask 'Reboot after updates when needed (true/false)' $rb
    }
    # KEY="value" when set, otherwise the commented example
    function Setting([string]$Key, [string]$Value, [string]$Example) {
        if ($Value -in $unset, '-', '') { "#$Key=`"$Example`"" } else { "$Key=`"$Value`"" }
    }
    $winLine = if ($win -eq 'any') { 'MAINTENANCE_WINDOW=""' } else { Setting 'MAINTENANCE_WINDOW' $win '3 03:00-05:00' }
    @"
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-windows.ps1 (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-windows.ps1 (update). Written by setup-windows.ps1 -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {`$PATCH.CONF.*} win over this file (zbx-patch-from-zbx-host-macro.cache).
#
# Maintenance window - when updates may be installed and the host rebooted (default: any time).
#   "<day> <HH:MM>-<HH:MM>", several separated by commas, local time of the host
#   day: 1-7 = Monday-Sunday (or Mon..Sun), a range 1-5, * = every day, 2.3 = 2nd Wednesday of the month
#   an end lower than the start = the window ends the next day (6 22:00-04:00)
#   empty = any time
#   MAINTENANCE_WINDOW="3 03:00-05:00"   = every Wednesday 03:00-05:00
$winLine
#
# Automatic updates: true = the checker installs the updates itself in the maintenance window
# (task "Zabbix patch auto update" every 15 min, once per window, log C:\ProgramData\zbx-patch\update.log);
# false = check only (default)
$(Setting 'AUTO_UPDATE' $auto 'true')
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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux b1c5fa6 (embed-check.sh)
$CheckB64 = @'
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
4ulmlAAA
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
