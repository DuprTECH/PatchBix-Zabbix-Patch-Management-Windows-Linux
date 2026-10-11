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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux f5829c8 (embed-check.sh)
$CheckB64 = @'
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
G275At0kxaxytwoM5oDg/wey8w+ATLsAAA==
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
