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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux d8e0212 (embed-check.sh)
$CheckB64 = @'
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
fz/vkC0CpykrMpviERmH+H9V5kdRUpQAAA==
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
