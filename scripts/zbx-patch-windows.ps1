#Requires -Version 5.1
<#
.SYNOPSIS
    Checks pending Windows updates and sends the result to Zabbix with zabbix_sender,
    to the OS independent template 'APP Patch management all OS'.

.DESCRIPTION
    Uses the Windows Update Agent API. Sends the same keys (patch.*) as zbx-patch-linux.sh on Linux:
      patch.updates.all / security / critical / bugfix / enhancement / definition / servicepacks /
                    updaterollups / drivers / upgrades / kernel / held (hidden updates)
      patch.updates.severity.critical / important / moderate / low (MSRC severity)
      patch.updates.list, patch.history (recent update history, like a log)
      patch.reboot.required, patch.reboot.reason, patch.lastboot
      patch.lastupdate.timestamp, patch.lastupdate.patchday
      patch.os, patch.os.name, patch.os.version, patch.script.version, patch.source (Windows Update / WSUS <server>), patch.source.available
      patch.service.startup, patch.autoupdate (0-4), patch.autoupdate.detail, patch.autoupdate.config
      patch.check.timestamp, patch.check.duration, patch.check.result
    Values that don't exist on Windows (kernel) are sent as 0.

    Run it:
    - from Task Scheduler as SYSTEM, for example every 3 hours, or
    - from the Zabbix agent (item "Patch - Run update check", system.run).

.PARAMETER SenderPath
    Path to zabbix_sender.exe

.PARAMETER ConfigPath
    Zabbix agent config. zabbix_sender takes Hostname and ServerActive from it.

.PARAMETER ZabbixServer
    Optional: Zabbix server / proxy address (instead of ServerActive from the config).

.PARAMETER HostName
    Optional: host name in Zabbix (instead of Hostname from the config). When the config has no
    Hostname (for example HostnameItem=system.hostname), the computer name is used.

.PARAMETER HistoryLines
    Number of lines in the update history item (default 50).

.PARAMETER IncludeDefinitionHistory
    Include definition updates (Microsoft Defender) in the update history and in the last update
    date. They are installed several times a day, so they are left out by default.

.PARAMETER PatchConfig
    Patch settings of the host (default: zbx-patch.conf in the folder of the agent config).
    The same file format as on Linux:
      MAINTENANCE_WINDOW="crit+sec * 02:00-03:00, * 6 03:00-06:00"
                    when and which updates this script installs itself (-AutoUpdate task):
                    "[<types>] <day> <HH:MM>-<HH:MM>", several separated by commas; types: * or all = all
                    updates (also without types), crit = critical (classification Critical Updates or MSRC
                    severity Critical), sec = security, def = definitions, kernel = Linux only, several joined
                    with +; day: 1-7 = Mon-Sun or Mon..Sun, 1-5, *, 2.3 = 2nd Wednesday.
                    No window = no automatic updates (only -Update -Force installs).
      EXCLUDE="KB5034441, Preview"              updates that are not installed (KB number or a part of the title)
      REBOOT="true"                             reboot after updates when needed (false = report only)
      AUTO_UPDATE="false"                       legacy (older installs): blocks the automatic updates
    They are sent to Zabbix (patch.maintenance.*, patch.exclude, patch.updates.excluded,
    patch.reboot.allowed, patch.autoupdate.config) and read by the install job (Ansible) with -ShowConfig.

.PARAMETER ShowConfig
    Print the patch settings as JSON (window active now, next window, exclusions, reboot, auto update)
    and exit. Nothing is checked or sent.

.PARAMETER Update
    Install the updates now (Windows Update: security, critical, update rollups, definitions, updates;
    without EXCLUDE), only in an open maintenance window and only its update types (-Force: all updates,
    also outside a window), send the result to
    Zabbix (patch.install.*), reboot when needed and REBOOT="true", then check.

.PARAMETER AutoUpdate
    For the scheduled task (every 15 min): in an open maintenance window does -Update once per window
    (its update types), otherwise exits right away (log: C:\ProgramData\zbx-patch\update.log).

.PARAMETER Force
    With -Update: install all updates, also outside a maintenance window.

.PARAMETER ZabbixConfig
    For the Zabbix agent (UserParameter patch.config): "<window>|<unused>|<exclude>|<reboot>", the
    values of the host macros {$PATCH.CONF.WINDOW}, {$PATCH.CONF.EXCLUDE}, {$PATCH.CONF.REBOOT}. The set (non empty) ones are validated and written to
    zbx-patch-from-zbx-host-macro.cache next to zbx-patch.conf (only when they changed); its keys win over
    zbx-patch.conf, which is never changed from Zabbix. Prints OK / ERROR for the item.
    The agent forbids * " ' $ ; | # and other characters in the values, so: window all = all update types
    and 1-7 = every day (instead of *), "none" = no window (no automatic updates); exclude % = wildcard,
    "none" = nothing excluded. The 2nd value (was AUTO_UPDATE) is ignored.

.PARAMETER InstallAgentConfig
    For the setup (administrator): UserParameter patch.config in a file of the agent Include folder
    (the main config gets an Include only when it has none), the macro file, restart of the agent
    service; when the service doesn't run afterwards, the changes are undone.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File zbx-patch-windows.ps1

.NOTES
    Author : Dusan Priechodsky
    Source : https://github.com/DuprTECH/Zabbix-Patch-Management-Windows-Linux
    Contact: info@duprtech.sk
    License: MIT
#>
param(
    [string]$SenderPath   = "C:\Program Files\Zabbix Agent 2\zabbix_sender.exe",
    [string]$ConfigPath   = "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf",
    [string]$ZabbixServer = "",
    [string]$HostName     = "",
    [int]$HistoryLines    = 50,
    [switch]$IncludeDefinitionHistory,
    [string]$PatchConfig  = "",
    [switch]$ShowConfig,
    [switch]$Update,
    [switch]$AutoUpdate,
    [switch]$Force,
    [string]$ZabbixConfig,
    [switch]$InstallAgentConfig
)

$start = Get-Date

# Version of this script (item patch.script.version), YY.MM.DD[.n] (.n = another change the same day) - change it with every change of the script
$ScriptVersion = '26.10.11.5'

# Update classification IDs (language independent)
$Classifications = @{
    "e6cf1350-c01b-414d-a61f-263d14d133b4" = "critical"
    "0fa1201d-4330-4fa8-8ae9-b877473b6441" = "security"
    "e0789628-ce08-4437-be74-2495b842f43b" = "definition"
    "68c5b0a3-d1a6-4553-ae49-01d3a7827828" = "servicepacks"
    "28bc880e-0592-4cbf-8f95-c79b17911d5f" = "updaterollups"
    "cd5ffd1e-e932-4e3a-bf74-18bf0b1bbd83" = "bugfix"        # Updates
    "b54e7d24-7add-428f-8b75-90a396fa584f" = "enhancement"   # Feature Packs
    "ebfc1fc5-71a4-4f7b-9aca-3b9a503104a0" = "drivers"
    "3689bdc8-b205-4af4-8d4a-a63924c5e9d5" = "upgrades"      # feature updates (new Windows version)
}
$DefinitionId = "e0789628-ce08-4437-be74-2495b842f43b"

function Send-ToZabbix {
    param([string[]]$SenderArgs)
    $base = @()
    if ($ConfigPath -and (Test-Path $ConfigPath)) { $base += @("-c", $ConfigPath) }
    if ($ZabbixServer) { $base += @("-z", $ZabbixServer) }
    if ($HostName)     { $base += @("-s", $HostName) }
    & $SenderPath @base @SenderArgs
}

# Host name: zabbix_sender takes Hostname from the agent config, but it can't resolve
# HostnameItem (for example HostnameItem=system.hostname). Without Hostname in the config
# (or its Include files) send the name of system.hostname, that is the computer name.
if (-not $HostName -and $ConfigPath -and (Test-Path $ConfigPath)) {
    $confFiles = @($ConfigPath)
    foreach ($m in (Select-String -Path $ConfigPath -Pattern '^Include=(.+)$')) {
        $inc = $m.Matches[0].Groups[1].Value.Trim()
        if (Test-Path $inc -PathType Container) { $inc = Join-Path $inc '*' }
        $confFiles += @(Get-ChildItem $inc -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    if (-not (Select-String -Path $confFiles -Pattern '^Hostname=' -Quiet)) { $HostName = $env:COMPUTERNAME }
}

function ConvertTo-Epoch([datetime]$Date) {
    ([DateTimeOffset]$Date.ToUniversalTime()).ToUnixTimeSeconds()
}

# Patch day, for example 2.Tue (2nd Tuesday of the month)
function Get-PatchDay([datetime]$Date) {
    "{0}.{1}" -f ([Math]::Floor(($Date.Day - 1) / 7) + 1), $Date.DayOfWeek.ToString().Substring(0, 3)
}

# Quoted value for the zabbix_sender input file
function Q([string]$Value) { '"' + ($Value -replace '\\', '\\' -replace '"', "'") + '"' }

# Windows PowerShell 5.1 doesn't escape double quotes in native arguments, so replace them
function Clean([string]$Value) { $Value -replace '"', "'" }

function Test-Definition($Entry) {
    try { foreach ($c in $Entry.Categories) { if ("$($c.CategoryID)".ToLower() -eq $DefinitionId) { return $true } } } catch {}
    return $false
}

# ---------------- Patch settings (zbx-patch.conf) ----------------
if (-not $PatchConfig) {
    $dir = if ($ConfigPath) { Split-Path $ConfigPath -Parent } else { "" }
    if (-not $dir) { $dir = "C:\Program Files\Zabbix Agent 2" }
    $PatchConfig = Join-Path $dir 'zbx-patch.conf'
}

# Settings from the Zabbix host macros {$PATCH.CONF.*}, written by the agent (-ZabbixConfig);
# a key set there wins over zbx-patch.conf
$PatchConfigMacro = Join-Path (Split-Path $PatchConfig -Parent) 'zbx-patch-from-zbx-host-macro.cache'

# KEY="value" (also 'value' or value # comment); the last one wins, the macro file last
function Read-PatchConf([string]$Path) {
    $c = [ordered]@{}
    if (-not (Test-Path $Path)) { return $c }
    foreach ($line in Get-Content $Path) {
        if ($line -notmatch '^\s*([A-Za-z_]+)\s*=\s*(.*)$') { continue }
        $key = $Matches[1].ToUpper(); $v = $Matches[2]
        if ($v -match '^"([^"]*)"') { $v = $Matches[1] }
        elseif ($v -match "^'([^']*)'") { $v = $Matches[1] }
        else { $v = $v -replace '#.*$', '' }
        $c[$key] = $v.Trim()
    }
    $c
}
$confFile  = Read-PatchConf $PatchConfig
$confMacro = Read-PatchConf $PatchConfigMacro
$conf = [ordered]@{}
foreach ($k in $confFile.Keys)  { $conf[$k] = $confFile[$k] }
foreach ($k in $confMacro.Keys) { $conf[$k] = $confMacro[$k] }
$macroKeys = (@($confMacro.Keys) | Sort-Object) -join ', '
$maintWindow   = "$($conf['MAINTENANCE_WINDOW'])"
$excludeText   = "$($conf['EXCLUDE'])"
$exclude       = @($excludeText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$rebootAllowed = if ("$($conf['REBOOT'])" -match '^(no|false|0|off)$') { 0 } else { 1 }
# Automatic updates: on when a maintenance window is set - the script installs the update types of the
# window in it (-AutoUpdate task). Legacy AUTO_UPDATE="false" (zbx-patch.conf of older installs) still
# blocks them, AUTO_UPDATE="true" is not needed any more.
$autoUpdateOff = "$($conf['AUTO_UPDATE'])" -match '^(no|false|0|off)$'
$autoInstall   = if ($maintWindow -and -not $autoUpdateOff) { 1 } else { 0 }

# The settings that are set, each with its source: [S] = Zabbix host macro, [C] = zbx-patch.conf (the item
# preprocessing shows them as symbols); empty = nothing set - no automatic updates
# (item patch.config.override, column Config of the dashboards)
$configParts = @()
foreach ($s in @(
        @('MAINTENANCE_WINDOW', 'window', $(if ($maintWindow) { $maintWindow } else { 'none (no automatic updates)' })),
        @('AUTO_UPDATE', 'auto update', $(if ($autoUpdateOff) { 'off (AUTO_UPDATE=false)' } else { '' })),
        @('EXCLUDE', 'exclude', $(if ($excludeText) { $excludeText } else { '-' })),
        @('REBOOT', 'reboot', $(if ($rebootAllowed) { 'true' } else { 'false' })))) {
    if (-not $s[2]) { continue }
    if ($confMacro.Contains($s[0])) { $configParts += "[S] $($s[1]): $($s[2])" }
    elseif ($confFile.Contains($s[0])) { $configParts += "[C] $($s[1]): $($s[2])" }
}
$configSummary = $configParts -join ', '

# Update excluded by EXCLUDE: KB number, or a part of the title (wildcards allowed)
function Test-Excluded([string]$Title, [string]$Kb) {
    foreach ($p in $exclude) { if ($Kb -eq $p -or $Title -like "*$p*") { return $true } }
    return $false
}

# Update types of a window: * or all = all updates, crit = critical (classification Critical Updates or
# MSRC severity Critical), sec = security, def = definitions, kernel = Linux only (nothing on Windows);
# several joined with +, for example crit+def. Returns the normalized types or $null when invalid.
function ConvertTo-UpdateTypes([string]$Spec) {
    $out = @()
    foreach ($t in ($Spec.ToLower() -split '\+')) {
        if ($t -in '*', 'all') { return '*' }
        if ($t -notin 'crit', 'sec', 'kernel', 'def') { return $null }
        if ($out -notcontains $t) { $out += $t }
    }
    if ($out.Count) { $out -join '+' } else { $null }
}

# Maintenance window "[<types>] <day> <HH:MM>-<HH:MM>, ..." - without types = all updates; day: 3 or Wed
# (1 = Monday ... 7 = Sunday), a range 1-5 / Mon-Fri, * (every day), 2.3 / 2.Wed (2nd Wednesday of the
# month); an end lower than the start = the next day. types = update types of the open window(s)
function Get-Maintenance([string]$Spec) {
    $r = @{ active = $false; start = $null; next = $null; error = ''; types = '' }
    if (-not $Spec) { return $r }
    $days = 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
    function DayNum($n) {
        if ($n -match '^[1-7]$') { return [int]$n }
        for ($i = 0; $i -lt 7; $i++) { if ($days[$i] -eq $n) { return $i + 1 } }; 0
    }
    $wins = @()
    foreach ($w in ($Spec -split ',')) {
        $w = $w.Trim()
        if (-not $w) { continue }
        $ok = $w -match '^(?:(\S+)\s+)?(\S+)\s+(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$'
        $types = '*'
        if ($ok) {
            if ($Matches[1]) { $types = ConvertTo-UpdateTypes $Matches[1]; $ok = [bool]$types }
            $d = $Matches[2]; $h1 = [int]$Matches[3]; $m1 = [int]$Matches[4]; $h2 = [int]$Matches[5]; $m2 = [int]$Matches[6]
            $ok = $ok -and $h1 -le 23 -and $h2 -le 23 -and $m1 -le 59 -and $m2 -le 59
        }
        $nth = 0; $from = 0; $to = 0
        if ($ok) {
            if ($d -eq '*') { $from = 1; $to = 7 }
            elseif ($d -match '^([1-5])\.(\w+)$') { $nth = [int]$Matches[1]; $from = $to = DayNum $Matches[2] }
            elseif ($d -match '^(\w+)-(\w+)$') { $from = DayNum $Matches[1]; $to = DayNum $Matches[2] }
            else { $from = $to = DayNum $d }
            $ok = $from -gt 0 -and $to -gt 0
        }
        if (-not $ok) {
            if (-not $r.error) { $r.error = "invalid maintenance window '$w'" }
            continue
        }
        $wins += [pscustomobject]@{ nth = $nth; from = $from; to = $to; start = $h1 * 60 + $m1; end = $h2 * 60 + $m2; types = $types }
    }
    $now = Get-Date
    for ($i = -1; $i -le 62; $i++) {
        $day = $now.Date.AddDays($i)
        if ($r.next -and $day -gt $r.next) { break }
        $dow = [int]$day.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
        foreach ($w in $wins) {
            $match = if ($w.from -le $w.to) { $dow -ge $w.from -and $dow -le $w.to } else { $dow -ge $w.from -or $dow -le $w.to }
            if ($w.nth -and ([Math]::Floor(($day.Day - 1) / 7) + 1) -ne $w.nth) { $match = $false }
            if (-not $match) { continue }
            $s = $day.AddMinutes($w.start); $e = $day.AddMinutes($w.end)
            if ($e -le $s) { $e = $e.AddDays(1) }
            if ($now -ge $s -and $now -lt $e) {
                $r.active = $true
                if (-not $r.start -or $s -lt $r.start) { $r.start = $s }
                $r.types = ConvertTo-UpdateTypes ($(if ($r.types) { "$($r.types)+" }) + $w.types)
            }
            if ($s -gt $now -and (-not $r.next -or $s -lt $r.next)) { $r.next = $s }
        }
    }
    $r
}

# ---------------- Settings from the Zabbix host macros (-ZabbixConfig) ----------------
# Run by the Zabbix agent (UserParameter patch.config). Invalid values: nothing is written, "ERROR: ..."
function Set-MacroConfig([string]$Values) {
    $f = @($Values -split '\|') + @('', '', '', '')
    # the 2nd value was AUTO_UPDATE - ignored, the maintenance window turns the automatic updates on
    $w = $f[0].Trim(); $e = $f[2].Trim(); $r = $f[3].Trim()
    $keys = @(); $lines = @()
    if ($w) {
        if ($w -in 'none', 'any') { $w = '' }
        if ($w -notmatch '^[0-9A-Za-z .,:+\-]*$') { return "ERROR: invalid {`$PATCH.CONF.WINDOW} '$w'" }
        $err = (Get-Maintenance $w).error
        if ($err) { return "ERROR: {`$PATCH.CONF.WINDOW}: $err" }
        $keys += 'MAINTENANCE_WINDOW'; $lines += "MAINTENANCE_WINDOW=`"$w`""
    }
    if ($e) {
        if ($e -eq 'none') { $e = '' }
        if ($e -notmatch '^[0-9A-Za-z ._+:,%\-]*$') { return "ERROR: invalid {`$PATCH.CONF.EXCLUDE} '$e'" }
        $e = $e -replace '%', '*'
        $keys += 'EXCLUDE'; $lines += "EXCLUDE=`"$e`""
    }
    if ($r) {
        if ($r -match '^(yes|true|1|on)$') { $r = 'true' }
        elseif ($r -match '^(no|false|0|off)$') { $r = 'false' }
        else { return "ERROR: invalid {`$PATCH.CONF.REBOOT} '$r' (true / false)" }
        $keys += 'REBOOT'; $lines += "REBOOT=`"$r`""
    }
    $content = @(
        '# zbx-patch-from-zbx-host-macro.cache - written by the Zabbix agent from the host macros {$PATCH.CONF.*}'
        '# (item patch.config, zbx-patch-windows.ps1 -ZabbixConfig). Don''t edit it: it is overwritten when a macro'
        '# changes. The keys here win over zbx-patch.conf; an empty macro leaves zbx-patch.conf in effect.'
    ) + $lines
    $summary = if ($keys.Count) { $keys -join ', ' } else { 'no host macros set' }
    if ((Test-Path $PatchConfigMacro) -and ((@(Get-Content $PatchConfigMacro) -join "`n") -eq ($content -join "`n"))) {
        return "OK, unchanged: $summary"
    }
    try { Set-Content -Path $PatchConfigMacro -Value $content -Encoding ASCII -ErrorAction Stop }
    catch { return "ERROR: writing $PatchConfigMacro failed: $($_.Exception.Message)" }
    "OK, written: $summary"
}
if ($PSBoundParameters.ContainsKey('ZabbixConfig')) { Set-MacroConfig $ZabbixConfig; exit 0 }

# ---------------- -InstallAgentConfig (administrator, run by the setup) ----------------
function Install-AgentConfig {
    if (-not (Test-Path $ConfigPath)) { Write-Warning "Zabbix agent config not found: $ConfigPath - UserParameter not installed"; return 1 }
    $confDir = Split-Path $ConfigPath -Parent
    $agent2  = (Split-Path $ConfigPath -Leaf) -like '*agent2*'
    # Service of this agent: its command line has the config, otherwise by name
    $svc = Get-CimInstance Win32_Service -Filter "Name LIKE 'Zabbix Agent%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -like "*$ConfigPath*" } | Select-Object -First 1
    if (-not $svc) {
        $name = if ($agent2) { 'Zabbix Agent 2' } else { 'Zabbix Agent' }
        $svc = Get-CimInstance Win32_Service -Filter "Name = '$name'" -ErrorAction SilentlyContinue
    }
    if (-not $svc) { Write-Warning 'Zabbix agent service not found - UserParameter not installed'; return 1 }
    # Include folder: the first absolute Include=<folder>\*.conf (not the agent 2 plugins), otherwise <config folder>\<agent>.d
    $incDir = $null
    foreach ($m in (Select-String -Path $ConfigPath -Pattern '^\s*Include\s*=\s*(.+?)\s*$')) {
        $inc = $m.Matches[0].Groups[1].Value
        if ($inc -notmatch '^[A-Za-z]:\\' -or $inc -like '*\plugins.d\*') { continue }
        if ($inc -like '*\`*.conf') { $incDir = Split-Path $inc -Parent; break }
        if (Test-Path $inc -PathType Container) { $incDir = $inc.TrimEnd('\'); break }
    }
    $changed = $false; $backup = $null
    if (-not $incDir) {
        $incDir = Join-Path $confDir $(if ($agent2) { 'zabbix_agent2.d' } else { 'zabbix_agentd.d' })
        $backup = "$ConfigPath.zbx-patch.bak"
        Copy-Item $ConfigPath $backup -Force
        Add-Content -Path $ConfigPath -Encoding ASCII -Value @('', '# Added by zbx-patch-windows.ps1 (UserParameter patch.config)', "Include=$incDir\*.conf")
        Write-Host "Include=$incDir\*.conf added to $ConfigPath"
        $changed = $true
    }
    New-Item -ItemType Directory -Force $incDir | Out-Null
    $upFile = Join-Path $incDir 'zbx-patch-userparameter.conf'
    $content = @(
        '# Settings from the Zabbix host macros {$PATCH.CONF.*} - installed by zbx-patch-windows.ps1'
        "UserParameter=patch.config[*],powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`" -ZabbixConfig `"`$1|`$2|`$3|`$4`""
    )
    $upBackup = $null
    if (-not ((Test-Path $upFile) -and ((@(Get-Content $upFile) -join "`n") -eq ($content -join "`n")))) {
        if (Test-Path $upFile) { $upBackup = "$upFile.bak"; Copy-Item $upFile $upBackup -Force }
        Set-Content -Path $upFile -Value $content -Encoding ASCII
        Write-Host "UserParameter patch.config: $upFile"
        $changed = $true
    }
    if (-not (Test-Path $PatchConfigMacro)) {
        Set-Content -Path $PatchConfigMacro -Encoding ASCII -Value '# zbx-patch-from-zbx-host-macro.cache - written by the Zabbix agent from the host macros {$PATCH.CONF.*}'
    }
    Write-Host "Settings from the host macros: $PatchConfigMacro"
    if (-not $changed) { Write-Host 'Agent config unchanged'; return 0 }
    # Restart the agent; when it doesn't run afterwards, undo the changes
    function Restart-Agent {
        try { Restart-Service -Name $svc.Name -Force -ErrorAction Stop } catch {}
        Start-Sleep -Seconds 3
        (Get-Service -Name $svc.Name).Status -eq 'Running'
    }
    if (Restart-Agent) {
        Write-Host "Agent restarted: $($svc.Name)"
        foreach ($b in $upBackup, $backup) { if ($b) { Remove-Item $b -Force -ErrorAction SilentlyContinue } }
        return 0
    }
    Write-Warning "$($svc.Name) doesn't run after the restart - the changes are undone"
    if ($upBackup) { Move-Item $upBackup $upFile -Force } else { Remove-Item $upFile -Force -ErrorAction SilentlyContinue }
    if ($backup) { Move-Item $backup $ConfigPath -Force }
    if (-not (Restart-Agent)) { Write-Warning "$($svc.Name) doesn't run even after undoing the changes - check it" }
    return 1
}
if ($InstallAgentConfig) { exit (Install-AgentConfig | Select-Object -Last 1) }

$maint = Get-Maintenance $maintWindow

if ($ShowConfig) {
    [pscustomobject]@{
        config             = $PatchConfig
        config_found       = [bool](Test-Path $PatchConfig)
        maintenance_window = $maintWindow
        maintenance_active = $maint.active
        maintenance_next   = if ($maint.next) { ConvertTo-Epoch $maint.next } else { $null }
        maintenance_error  = $maint.error
        exclude            = $exclude
        reboot_allowed     = [bool]$rebootAllowed
        auto_update        = [bool]$autoInstall
        auto_update_blocked = [bool]$autoUpdateOff
        maintenance_types  = $maint.types
        macro_config       = $PatchConfigMacro
        macro_keys         = $macroKeys
        config_summary     = $configSummary
    } | ConvertTo-Json -Compress
    exit 0
}

# -AutoUpdate (scheduled task every 15 min): only with a maintenance window, when it is open, once per window
$stateDir = Join-Path $env:ProgramData 'zbx-patch'
$stamp    = Join-Path $stateDir 'last-auto-update'
$logFile  = $null
if ($AutoUpdate) {
    if (-not ($autoInstall -and $maint.active)) { exit 0 }
    $last = 0; try { $last = [long](Get-Content $stamp -ErrorAction Stop | Select-Object -First 1) } catch {}
    if ($last -ge (ConvertTo-Epoch $maint.start)) { exit 0 }
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    Set-Content -Path $stamp -Value (ConvertTo-Epoch (Get-Date))
    $logFile = Join-Path $stateDir 'update.log'
    Start-Transcript -Path $logFile -Append | Out-Null
    Write-Output ("=== {0:yyyy-MM-dd HH:mm} automatic update in the maintenance window '{1}'" -f (Get-Date), $maintWindow)
    $Update = $true
}
if ($maint.error) { Write-Warning "${PatchConfig}: $($maint.error)" }

# One run at a time (the check, the update and the scheduled tasks can overlap)
$mutex = New-Object System.Threading.Mutex($false, 'Global\zbx-patch-windows')
try { [void]$mutex.WaitOne([TimeSpan]::FromMinutes(30)) } catch [System.Threading.AbandonedMutexException] {}

# Pending reboot: Windows Update or Component Based Servicing (used by the install and by the check)
function Get-RebootReasons {
    $r = @()
    try {
        if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { $r += "Windows Update" }
    } catch {}
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        if ($r -notcontains "Windows Update") { $r += "Windows Update" }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $r += "Component Based Servicing"
    }
    $r
}

# ---------------- Install updates (-Update) ----------------
# Like the Ansible playbook: security, critical, update rollups, definitions and updates without EXCLUDE,
# reboot when needed and allowed; the result goes to the patch.install.* items
function Install-Updates {
    # Only in an open maintenance window and only its update types; -Force = all updates, also outside
    if ($Force) { $types = '*' }
    elseif ($maint.active) { $types = $maint.types }
    elseif (-not $maintWindow) {
        Write-Host 'SKIPPED: no maintenance window - updates are installed only in a maintenance window. Install now with -Force.'
        return 'skipped'
    } else {
        $next = if ($maint.next) { '{0:yyyy-MM-dd HH:mm}' -f $maint.next } else { '-' }
        Write-Host "SKIPPED: outside the maintenance window '$maintWindow', next window: $next. Install now with -Force."
        return 'skipped'
    }
    $typeList = @($types -split '\+')
    Write-Host "Update types: $(if ($types -eq '*') { 'all' } else { $types })"
    $install = @('e6cf1350-c01b-414d-a61f-263d14d133b4', '0fa1201d-4330-4fa8-8ae9-b877473b6441', 'e0789628-ce08-4437-be74-2495b842f43b',
                 '28bc880e-0592-4cbf-8f95-c79b17911d5f', 'cd5ffd1e-e932-4e3a-bf74-18bf0b1bbd83')
    $installed = @(); $failed = @(); $err = ''; $needReboot = $false
    Write-Host '=== Searching for updates'
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $found   = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates
        $coll    = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $found) {
            $ok = $false
            $cats = @(foreach ($cat in $u.Categories) { "$($cat.CategoryID)".ToLower() })
            if ($types -eq '*') { $ok = @($cats | Where-Object { $install -contains $_ }).Count -gt 0 }
            else {
                # crit = classification Critical Updates or MSRC severity Critical, sec = Security Updates, def = definitions
                if ($typeList -contains 'crit' -and ($cats -contains 'e6cf1350-c01b-414d-a61f-263d14d133b4' -or "$($u.MsrcSeverity)" -eq 'Critical')) { $ok = $true }
                if ($typeList -contains 'sec' -and $cats -contains '0fa1201d-4330-4fa8-8ae9-b877473b6441') { $ok = $true }
                if ($typeList -contains 'def' -and $cats -contains 'e0789628-ce08-4437-be74-2495b842f43b') { $ok = $true }
            }
            if (-not $ok) { continue }
            $kb = if ($u.KBArticleIDs.Count -gt 0) { 'KB' + $u.KBArticleIDs.Item(0) } else { '-' }
            if ($exclude.Count -gt 0 -and (Test-Excluded $u.Title $kb)) { Write-Host "Excluded: $($u.Title)"; continue }
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }
        if ($coll.Count -gt 0) {
            for ($i = 0; $i -lt $coll.Count; $i++) { Write-Host "  $($coll.Item($i).Title)" }
            Write-Host "=== Downloading and installing $($coll.Count) updates"
            $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
            $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
            $res = $inst.Install()
            for ($i = 0; $i -lt $coll.Count; $i++) {
                # 2 = succeeded, 3 = succeeded with errors
                if ($res.GetUpdateResult($i).ResultCode -in 2, 3) { $installed += $coll.Item($i).Title } else { $failed += $coll.Item($i).Title }
            }
            $needReboot = [bool]$res.RebootRequired
        } else {
            Write-Host 'No updates to install.'
        }
    } catch {
        $err = $_.Exception.Message
    }
    # Same detection as the check (patch.reboot.required), also a reboot left over from an earlier install
    if (@(Get-RebootReasons).Count -gt 0) { $needReboot = $true }
    $doReboot = (-not $err) -and $needReboot -and $rebootAllowed
    $result = if ($err) { "FAILED: $err" } else {
        "OK, installed $($installed.Count), failed $($failed.Count)" + $(if ($doReboot) { ', rebooting' } elseif ($needReboot) { ', reboot required' } else { '' })
    }
    $list = @($installed | ForEach-Object { "Install  $_" }) + @($failed | ForEach-Object { "Failed  $_" })
    Write-Host '=== Result'
    $list | ForEach-Object { Write-Host $_ }
    Write-Host $result
    $status = if ($err -or $failed.Count -gt 0) { 1 } else { 0 }
    $text   = if ($list.Count -gt 0) { $list -join "`n" } else { 'No updates installed' }
    Send-ToZabbix -SenderArgs @('-k', 'patch.install.timestamp', '-o', (ConvertTo-Epoch (Get-Date))) | Out-Null
    Send-ToZabbix -SenderArgs @('-k', 'patch.install.status', '-o', $status) | Out-Null
    Send-ToZabbix -SenderArgs @('-k', 'patch.install.count', '-o', $installed.Count) | Out-Null
    Send-ToZabbix -SenderArgs @('-k', 'patch.install.failed', '-o', $failed.Count) | Out-Null
    Send-ToZabbix -SenderArgs @('-k', 'patch.install.list', '-o', (Clean $text)) | Out-Null
    Send-ToZabbix -SenderArgs @('-k', 'patch.install.result', '-o', (Clean $result)) | Out-Null
    if ($doReboot) {
        Send-ToZabbix -SenderArgs @('-k', 'patch.reboot.required', '-o', 0) | Out-Null
        # The check runs again after the reboot (startup trigger of the task "Zabbix patch check")
        shutdown.exe /r /t 120 /c "Reboot after the update (zbx-patch-windows.ps1)"
        Write-Host 'Rebooting in 2 minutes (cancel: shutdown /a).'
        return 'reboot'
    }
    if ($needReboot) { Write-Warning "A reboot is required, but REBOOT=`"false`" in $PatchConfig" }
    return 'done'
}
if ($Update) {
    $updateResult = Install-Updates
    if ($updateResult -in 'skipped', 'reboot') {
        if ($logFile) { Stop-Transcript | Out-Null }
        exit 0
    }
    Write-Output '=== Update check'
}

$counts = [ordered]@{
    all = 0; security = 0; critical = 0; bugfix = 0; enhancement = 0; definition = 0; servicepacks = 0
    updaterollups = 0; drivers = 0; upgrades = 0; kernel = 0; held = 0
}
$severity = [ordered]@{ critical = 0; important = 0; moderate = 0; low = 0 }
$list     = New-Object System.Collections.Generic.List[string]
$history  = New-Object System.Collections.Generic.List[string]
$result   = "OK"
$searchOk = 1
$lastUpdate = $null
$excluded = 0

# ---------------- OS ----------------
$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$osVersion = "$($os.Version).$($cv.UBR)"
if ($cv.DisplayVersion) { $osVersion += " ($($cv.DisplayVersion))" }
$lastBoot = ConvertTo-Epoch $os.LastBootUpTime

# ---------------- Pending updates ----------------
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $found    = $searcher.Search("IsInstalled=0 and IsHidden=0")

    foreach ($u in $found.Updates) {
        $counts.all++
        $category = "other"
        foreach ($c in $u.Categories) {
            $id = "$($c.CategoryID)".ToLower()
            if ($Classifications.ContainsKey($id)) { $category = $Classifications[$id]; break }
        }
        if ($category -eq "other" -and $u.Type -eq 2) { $category = "drivers" }
        if ($counts.Contains($category)) { $counts[$category]++ }

        $tag = "[$category]"
        $sev = "$($u.MsrcSeverity)"
        if ($sev -and $severity.Contains($sev.ToLower())) {
            $severity[$sev.ToLower()]++
            $tag += " [$sev]"
        }
        $kb = if ($u.KBArticleIDs.Count -gt 0) { "KB" + $u.KBArticleIDs.Item(0) } else { "-" }
        $line = "$tag $kb - $($u.Title)"
        if ($exclude.Count -gt 0 -and (Test-Excluded $u.Title $kb)) { $excluded++; $line += " (excluded)" }
        $list.Add((Clean $line))
    }

    # Hidden updates (the counterpart of held / version locked packages on Linux)
    try {
        $searcher.Online = $false
        $counts.held = $searcher.Search("IsInstalled=0 and IsHidden=1").Updates.Count
    } catch {}
} catch {
    $searchOk = 0
    $result   = "ERROR: update search failed: $($_.Exception.Message)"
}

# ---------------- Update history ----------------
try {
    if (-not $searcher) { $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher() }
    $total = $searcher.GetTotalHistoryCount()
    if ($total -gt 0) {
        $ops     = @{ 1 = "Install"; 2 = "Uninstall"; 3 = "Other" }
        $results = @{ 0 = "Not started"; 1 = "In progress"; 2 = "Succeeded"; 3 = "Succeeded with errors"; 4 = "Failed"; 5 = "Aborted" }
        foreach ($e in $searcher.QueryHistory(0, [Math]::Min($total, 1000))) {
            if (-not $e.Title) { continue }
            if (-not $IncludeDefinitionHistory -and (Test-Definition $e)) { continue }
            $date = [DateTime]::SpecifyKind($e.Date, [DateTimeKind]::Utc).ToLocalTime()
            if (-not $lastUpdate -and $e.Operation -eq 1 -and $e.ResultCode -in 2, 3) { $lastUpdate = $date }
            if ($history.Count -lt $HistoryLines) {
                $history.Add((Clean ("{0:yyyy-MM-dd HH:mm}  {1}  {2}  {3}" -f $date, $ops[[int]$e.Operation], $results[[int]$e.ResultCode], $e.Title)))
            }
        }
    }
} catch {}

# Fallback (no Windows Update history, for example updates installed offline): installed hotfixes
if ($history.Count -eq 0) {
    try {
        $hotfixes = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending
        foreach ($h in ($hotfixes | Select-Object -First $HistoryLines)) {
            $history.Add((Clean ("{0:yyyy-MM-dd}  Install  {1}  {2}" -f $h.InstalledOn, $h.HotFixID, $h.Description)))
        }
        if (-not $lastUpdate -and $hotfixes) { $lastUpdate = @($hotfixes)[0].InstalledOn }
    } catch {}
}

# ---------------- Reboot ----------------
$rebootRequired = 0
$reasons = @(Get-RebootReasons)
if ($reasons.Count -gt 0) { $rebootRequired = 1 }
$rebootReason = if ($reasons.Count -gt 0) { "Pending: " + ($reasons -join ", ") } else { "-" }

# ---------------- Windows Update service and automatic updates ----------------
# Same values as service.info[wuauserv,startup]: 0 auto, 1 auto (delayed), 2 manual, 3 disabled, 4 unknown
$startup = 4
$svc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' -ErrorAction SilentlyContinue
switch ($svc.Start) {
    2 { $startup = if ($svc.DelayedAutostart -eq 1) { 1 } else { 0 } }
    3 { $startup = 2 }
    4 { $startup = 3 }
}
# Automatic updates: 0 disabled (nothing is installed automatically), 2 OS installs all updates,
# 3 patch management (AUTO_UPDATE="true" in zbx-patch.conf - this script installs the updates),
# 4 OS + patch management. 1 (OS security only) is used on Linux only.
# The policy (GPO / registry): NoAutoUpdate, AUOptions 2 notify, 3 download only, 4 download and install,
# 5 local admin chooses, 7 download only and notify (Server 2016+). Without a policy: Windows client installs
# automatically, Windows Server is counted as no automatic install. WSUS installs only approved updates.
$wuPol  = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
$auPol  = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
$wsus   = if ($auPol.UseWUServer -eq 1 -and $wuPol.WUServer) { "$($wuPol.WUServer)" } else { '' }
$level  = $null
try { $level = (New-Object -ComObject Microsoft.Update.AutoUpdate).Settings.NotificationLevel } catch {}
$isServer = $os.ProductType -ne 1
$autoUpdateMode = 0
if ($startup -eq 3) {
    $autoDetail = 'service wuauserv disabled'
} elseif ($auPol.NoAutoUpdate -eq 1) {
    $autoDetail = 'disabled by policy (NoAutoUpdate=1)'
} elseif ($null -ne $auPol.AUOptions) {
    switch ([int]$auPol.AUOptions) {
        2 { $autoDetail = 'notify before download (AUOptions 2)' }
        3 { $autoDetail = 'download only, notify to install (AUOptions 3)' }
        4 { $autoDetail = 'download and install automatically (AUOptions 4)'; $autoUpdateMode = 2 }
        5 {
            $autoDetail = 'local admin chooses (AUOptions 5)'
            if ($level -eq 4) { $autoDetail += ': install automatically'; $autoUpdateMode = 2 }
        }
        7 { $autoDetail = 'download only, notify to install and restart (AUOptions 7)' }
        default { $autoDetail = "policy AUOptions $($auPol.AUOptions)" }
    }
} elseif ($level -eq 4 -or ($level -in $null, 0 -and -not $isServer)) {
    $autoDetail = 'not configured: Windows installs automatically'; $autoUpdateMode = 2
} elseif ($level -in 1, 2, 3) {
    $autoDetail = "not configured by policy: $(@{1 = 'disabled'; 2 = 'notify before download'; 3 = 'download only'}[[int]$level])"
} else {
    $autoDetail = 'not configured (Windows Server: no automatic install)'
}
$autoDetail = "Windows Update: $autoDetail"
if ($wsus) { $autoDetail += "; WSUS $wsus (approved updates only)" }
if ($autoInstall) {
    $autoUpdateMode = if ($autoUpdateMode -gt 0) { 4 } else { 3 }
    $autoDetail = "Patch management (maintenance window '$maintWindow'); $autoDetail"
}
$source = if ($wsus) { "WSUS $wsus" } else { 'Windows Update' }

# ---------------- Send ----------------
$lines = @(
    "- patch.os Windows",
    "- patch.os.name $(Q $os.Caption.Trim())",
    "- patch.os.version $(Q $osVersion)",
    "- patch.script.version $ScriptVersion",
    "- patch.source $(Q $source)",
    "- patch.source.available $searchOk",
    "- patch.check.timestamp $(ConvertTo-Epoch (Get-Date))",
    "- patch.check.duration $([int]((Get-Date) - $start).TotalSeconds)",
    "- patch.check.result $(Q $result)",
    "- patch.reboot.required $rebootRequired",
    "- patch.lastboot $lastBoot",
    "- patch.service.startup $startup",
    "- patch.autoupdate $autoUpdateMode",
    "- patch.autoupdate.detail $(Q $autoDetail)",
    # 1 = this script installs the updates in the maintenance window (-AutoUpdate task): a window is set
    "- patch.autoupdate.config $autoInstall",
    "- patch.config.override $(Q $configSummary)",
    "- patch.reboot.allowed $rebootAllowed",
    "- patch.maintenance.window $(Q ($(if ($maintWindow) { $maintWindow } else { '-' }) + $(if ($maint.error) { " ($($maint.error))" })))",
    "- patch.exclude $(Q $(if ($excludeText.Trim()) { $excludeText.Trim() } else { '-' }))"
)
if ($maint.next) { $lines += "- patch.maintenance.next $(ConvertTo-Epoch $maint.next)" }
if ($lastUpdate) {
    $lines += "- patch.lastupdate.timestamp $(ConvertTo-Epoch $lastUpdate)"
    $lines += "- patch.lastupdate.patchday $(Get-PatchDay $lastUpdate)"
}
if ($searchOk) {
    foreach ($k in $counts.Keys)   { $lines += "- patch.updates.$k $($counts[$k])" }
    foreach ($k in $severity.Keys) { $lines += "- patch.updates.severity.$k $($severity[$k])" }
    $lines += "- patch.updates.excluded $excluded"
}
$tmp = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllLines($tmp, [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))
    Send-ToZabbix -SenderArgs @("-i", $tmp)
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# Multi-line text values are sent separately
Send-ToZabbix -SenderArgs @("-k", "patch.reboot.reason", "-o", $rebootReason)
$text = if ($history.Count -gt 0) { $history -join "`n" } else { "No update history found" }
Send-ToZabbix -SenderArgs @("-k", "patch.history", "-o", $text)
if ($searchOk) {
    $text = if ($list.Count -gt 0) { $list -join "`n" } else { "No pending updates" }
    Send-ToZabbix -SenderArgs @("-k", "patch.updates.list", "-o", $text)
}

Write-Output "Pending updates: $($counts.all) (critical $($counts.critical), security $($counts.security), excluded $excluded), reboot required: $rebootRequired, result: $result"
$nextText = if ($maint.next) { " (next {0:yyyy-MM-dd HH:mm})" -f $maint.next } else { "" }
Write-Output "Maintenance window: $(if ($maintWindow) { $maintWindow } else { '-' })$nextText, exclude: $(if ($excludeText) { $excludeText } else { '-' }), reboot allowed: $rebootAllowed, auto update: $autoInstall$(if ($autoUpdateOff) { ' (blocked by AUTO_UPDATE=false)' })$(if ($macroKeys) { ", from host macros: $macroKeys" })"
if ($logFile) { Stop-Transcript | Out-Null }
exit 0
