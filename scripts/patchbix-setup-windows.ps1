# patchbix-setup-windows.ps1 - Zabbix patch management on a Windows server without Ansible: setup, check, updates
#
# Paste the whole file into PowerShell as administrator, or run it as a file:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File patchbix-setup-windows.ps1
# A menu asks what to do (or set $env:PATCHBIX_MODE = 'update' before):
#   1 monitor  = like ansible/check-windows.yml: checker patchbix-windows.ps1, scheduled tasks (check every
#                12 h and after a reboot, automatic update every 15 min), patch settings <Zabbix agent folder>\patchbix.conf,
#                UserParameter patch.config (host macros {$PATCH.CONF.*}), first check. Running it again updates an installed server and keeps the settings.
#   2 check    = run the update check now (pending updates -> Zabbix) and show the patch settings
#   3 update   = install updates now (security, critical, rollups, definitions,
#                updates) in the maintenance window, without EXCLUDE, reboot when needed and REBOOT="true", result to Zabbix
#   4 force    = like 3, also outside the maintenance window
#
# AUTO_UPDATE="false" in patchbix.conf (default) = the checker only checks; "true" = it installs the
# updates itself in the maintenance window (once per window, like 3).
#
# The checker patchbix-windows.ps1 is embedded (no internet needed); a copy in %TEMP% or C:\Temp wins.
# Requires the Zabbix agent 2 (zabbix_sender.exe). Docs: README.md (https://github.com/DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux)
#
# Author : Dusan Priechodsky
# Source : https://github.com/DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux
# Contact: info@duprtech.sk
# License: MIT
& {
$Mode          = "$env:PATCHBIX_MODE"     # monitor | check | update | force, empty = menu
$IntervalHours = 12
$TaskName      = 'PatchBix check'
$AutoTaskName  = 'PatchBix auto update'
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
$Check     = Join-Path $AgentDir 'scripts\patchbix-windows.ps1'
$PatchConf = Join-Path $AgentDir 'patchbix.conf'
#
# ---------------- Checker ----------------
# The checker is embedded before the menu (no internet needed); a newer copy in %TEMP% or C:\Temp is used instead
function Get-Check {
    New-Item -ItemType Directory -Force (Split-Path $Check) | Out-Null
    $tmp   = "$Check.new"
    $local = @("$env:TEMP\patchbix-windows.ps1", 'C:\Temp\patchbix-windows.ps1') | Where-Object { Test-Path $_ } | Select-Object -First 1
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
        Write-Warning "The checker ($src) is damaged or old - copy patchbix-windows.ps1 to $env:TEMP and run again."
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
    # A run of the checker moves the settings of an older version (zbx-patch.conf) to the PatchBix names
    Invoke-Check '-ShowConfig' | Out-Null
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
# patchbix.conf - patch management settings of this host
# Read by the checker patchbix-windows.ps1 (sent to Zabbix, template 'PatchBix - Patch management all OS')
# and by patchbix-setup-windows.ps1 (update). Written by patchbix-setup-windows.ps1 -
# you can edit it, the values are kept when the setup runs again.
# A setting that is commented out is not set: the default applies (nothing set = check only).
# The Zabbix host macros {`$PATCH.CONF.*} win over this file (patchbix-from-zbx-host-macro.cache).
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
# patch auto update" every 15 min, once per window, log C:\ProgramData\patchbix\update.log); false = check
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
    # Settings from Zabbix: UserParameter patch.config (host macros {$PATCH.CONF.*} -> patchbix-from-zbx-host-macro.cache),
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
# Embedded check script: patchbix-windows.ps1 from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux f9de157 (embed-check.sh)
$CheckB64 = @'
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
'@
#
# ---------------- Menu ----------------
if (-not $Mode) {
    Write-Host "Zabbix patch management - $env:COMPUTERNAME"
    Write-Host '  1) monitor - install / update the checker for Zabbix (scheduled tasks, patchbix.conf incl. AUTO_UPDATE)'
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
