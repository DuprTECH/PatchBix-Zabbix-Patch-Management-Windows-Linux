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
# Embedded check script: zbx-patch-windows.ps1 from DuprTECH/Zabbix-Patch-Management-Windows-Linux 2743b7c (embed-check.sh)
$CheckB64 = @'
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
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
