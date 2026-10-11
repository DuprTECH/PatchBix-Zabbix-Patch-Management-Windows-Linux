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
# zbx-patch.conf - patch management settings of this host
# Read by the checker zbx-patch-windows.ps1 (sent to Zabbix, template 'APP Patch management all OS')
# and by setup-windows.ps1 (update). Written by setup-windows.ps1 -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {`$PATCH.CONF.*} win over this file (zbx-patch-from-zbx-host-macro.cache).
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
# patch auto update" every 15 min, once per window, log C:\ProgramData\zbx-patch\update.log); false = check
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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux 99dea19 (embed-check.sh)
$CheckB64 = @'
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
sE1yTBB3oxhfju39f1rlu9d8vAAA
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
