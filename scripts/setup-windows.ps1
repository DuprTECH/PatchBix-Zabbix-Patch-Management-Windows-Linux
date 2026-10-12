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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux 2edf39a (embed-check.sh)
$CheckB64 = @'
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
yTFB3I1ifDm29/8BqfEsrHm8AAA=
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
