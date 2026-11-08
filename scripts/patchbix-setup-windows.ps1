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
# Embedded check script: patchbix-windows.ps1 from DuprTECH/PatchBix-Zabbix-Patch-Management-Windows-Linux b46f93a (embed-check.sh)
$CheckB64 = @'
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
JB5+nQfbJMfcdFeKMebY4v8H2KI+9m3LAAA=
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
