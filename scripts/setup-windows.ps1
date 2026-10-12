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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux 33d9103 (embed-check.sh)
$CheckB64 = @'
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
/n9w30QyS8IAAA==
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
