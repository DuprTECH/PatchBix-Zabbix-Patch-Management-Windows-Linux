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
#                updates) in the maintenance window, without EXCLUDE, reboot when needed and REBOOT="yes", result to Zabbix
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
        $rb   = Ask 'Reboot after updates when needed (yes/no)' $rb
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
# Reboot after updates when needed: yes / no (no = the reboot is only reported to Zabbix; default: yes)
$(Setting 'REBOOT' $rb 'no')
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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux f4e8a9d (embed-check.sh)
$CheckB64 = @'
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
OE1ZkdkWj8g4xP8D19XQ8UCUAAA=
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
