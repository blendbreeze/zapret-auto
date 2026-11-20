# ZAPRET AUTO-ROTATION MONITOR + PER-SITE STRATEGY FIXER
# 1) Rotation: watches the active strategy with lightweight HTTP probes and
#    automatically switches to the next-best preset when the trigger group
#    (default: YouTube) keeps failing - the automatic answer to strategies
#    that decay under detection (e.g. TSPU killing video streams mid-playback).
# 2) Site fixer: probes the domains from lists/list-important.txt and, when a
#    site breaks, changes the strategy FOR THAT SITE ONLY by writing a per-site
#    override profile (hostlist-domains + another preset's desync args) into a
#    generated combined config "general (CUSTOM).bat". Working overrides are
#    remembered in lists/site-overrides.txt and applied at every start.
#
# Override via environment variables:
#   MONITOR_INTERVAL           seconds between probe rounds        (default 20)
#   MONITOR_FAIL_THRESHOLD     consecutive failed rounds to rotate (default 2)
#   MONITOR_COOLDOWN           grace after a switch before probes  (default 15)
#   MONITOR_TRIGGER_GROUP      group that triggers rotation        (default YouTube)
#   MONITOR_CURL_TIMEOUT       curl timeout per probe, seconds     (default 4)
#   MONITOR_QUARANTINE_MINUTES skip presets that failed this long ago (default 10)
#   SITEFIX                    0 disables per-site fixing           (default on)
#   SITE_OK_QUIET              quiet period after a site checks OK  (default 300)
#   SITE_BROKEN_INTERVAL       re-probe interval while broken, s    (default 15)
#   SITE_BROKEN_THRESHOLD      failed checks before a fix cycle     (default 2)
#   SITEFIX_MAX_ATTEMPTS       strategy changes per fix cycle       (default 3)
#   SITE_BACKOFF               backoff after a failed fix cycle, s  (default 600)
#   SITE_TIMEOUT               curl timeout per site GET, s         (default 12)
#   SITE_CONNECT_TIMEOUT       curl connect timeout, s              (default 5)
#   SITE_GET_GAP               pause between the two GETs, s        (default 2)
#   MONITOR_BASE_SELECT        ask|auto - base preset choice at startup:
#                              ask  = interactive list (default)
#                              auto = last choice / best ranked, no prompt
#
# Exit with Ctrl+C: state is saved; if winws ran before the monitor started,
# that original instance is restored, otherwise the last healthy config keeps
# running.

$hasErrors = $false

$rootDir = Split-Path $PSScriptRoot
$listsDir = Join-Path $rootDir "lists"
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $utilsDir "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

$stateFile = Join-Path $utilsDir "monitor state.json"
$logFile = Join-Path $resultsDir ("monitor_log_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd"))

# ---- Configuration ---------------------------------------------------------
$intervalSeconds = 20
$failThreshold = 2
$cooldownSeconds = 15
$triggerGroup = "YouTube"
$curlTimeoutSeconds = 4
$quarantineMinutes = 10
if ($env:MONITOR_INTERVAL) { [int]$intervalSeconds = $env:MONITOR_INTERVAL }
if ($env:MONITOR_FAIL_THRESHOLD) { [int]$failThreshold = $env:MONITOR_FAIL_THRESHOLD }
if ($env:MONITOR_COOLDOWN) { [int]$cooldownSeconds = $env:MONITOR_COOLDOWN }
if ($env:MONITOR_TRIGGER_GROUP) { $triggerGroup = $env:MONITOR_TRIGGER_GROUP }
if ($env:MONITOR_CURL_TIMEOUT) { [int]$curlTimeoutSeconds = $env:MONITOR_CURL_TIMEOUT }
if ($env:MONITOR_QUARANTINE_MINUTES) { [int]$quarantineMinutes = $env:MONITOR_QUARANTINE_MINUTES }
if ($intervalSeconds -lt 5) { $intervalSeconds = 5 }
if ($failThreshold -lt 1) { $failThreshold = 1 }
if ($cooldownSeconds -lt 0) { $cooldownSeconds = 0 }

$sitefixEnabled = $true
if ($env:SITEFIX -eq "0") { $sitefixEnabled = $false }
$siteOkQuiet = 300
$siteBrokenInterval = 15
$siteBrokenThreshold = 2
$sitefixMaxAttempts = 3
$siteBackoff = 600
$siteTimeout = 12
$siteConnectTimeout = 5
$siteGetGap = 2
$siteSettle = 8
if ($env:SITE_OK_QUIET) { [int]$siteOkQuiet = $env:SITE_OK_QUIET }
if ($env:SITE_BROKEN_INTERVAL) { [int]$siteBrokenInterval = $env:SITE_BROKEN_INTERVAL }
if ($env:SITE_BROKEN_THRESHOLD) { [int]$siteBrokenThreshold = $env:SITE_BROKEN_THRESHOLD }
if ($env:SITEFIX_MAX_ATTEMPTS) { [int]$sitefixMaxAttempts = $env:SITEFIX_MAX_ATTEMPTS }
if ($env:SITE_BACKOFF) { [int]$siteBackoff = $env:SITE_BACKOFF }
if ($env:SITE_TIMEOUT) { [int]$siteTimeout = $env:SITE_TIMEOUT }
if ($env:SITE_CONNECT_TIMEOUT) { [int]$siteConnectTimeout = $env:SITE_CONNECT_TIMEOUT }
if ($env:SITE_GET_GAP) { [int]$siteGetGap = $env:SITE_GET_GAP }
if ($siteOkQuiet -lt 30) { $siteOkQuiet = 30 }
if ($siteBrokenInterval -lt 5) { $siteBrokenInterval = 5 }
if ($siteBrokenThreshold -lt 1) { $siteBrokenThreshold = 1 }
if ($sitefixMaxAttempts -lt 1) { $sitefixMaxAttempts = 1 }
if ($siteSettle -lt 3) { $siteSettle = 3 }

$customPresetName = "general (CUSTOM).bat"
$overridesFile = Join-Path $listsDir "site-overrides.txt"
$script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- Shared helpers (mirrors "test zapret.ps1") ----------------------------
function Get-IpsetStatus {
    $listFile = Join-Path $listsDir "ipset-all.txt"
    if (-not (Test-Path $listFile)) { return "none" }
    $raw = [IO.File]::ReadAllText($listFile)
    if ([string]::IsNullOrWhiteSpace($raw)) { return "any" }
    if ($raw -match '203\.0\.113\.113/32') { return "none" }
    return "loaded"
}

function Wait-WinwsReady {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 5000) {
        if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
            Start-Sleep -Milliseconds 300
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Get-WinwsSnapshot {
    try {
        return Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
            Select-Object ProcessId, CommandLine, ExecutablePath
    } catch {
        return @()
    }
}

function Restore-WinwsSnapshot {
    param($snapshot)

    if (-not $snapshot -or $snapshot.Count -eq 0) { return }

    Write-Host "[INFO] Restoring previously running winws instances..." -ForegroundColor DarkGray
    foreach ($p in $snapshot) {
        if (-not $p.ExecutablePath) { continue }

        $exe = $p.ExecutablePath
        $processArgs = $null
        if ($p.CommandLine -match '^\s*"[^"]*"\s*(.*)$') {
            $processArgs = $matches[1].Trim()
        } elseif ($p.CommandLine -and $p.CommandLine.StartsWith($exe, [StringComparison]::OrdinalIgnoreCase)) {
            $processArgs = $p.CommandLine.Substring($exe.Length).Trim()
        } elseif ($p.CommandLine -match '^\s*\S+\s*(.*)$') {
            $processArgs = $matches[1].Trim()
        }

        if (-not $processArgs) { continue }

        try {
            Start-Process -FilePath $exe -ArgumentList $processArgs -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
        } catch {
            Write-Host "[WARN] Failed to restore previous winws instance ($exe): $_" -ForegroundColor Yellow
        }
    }
}

# Pause that tolerates non-interactive hosts (same as in "test zapret.ps1")
function Wait-AnyKey {
    param([string]$message = "Press any key to close...")
    Write-Host $message -ForegroundColor Yellow
    try {
        while ([System.Console]::KeyAvailable) { [void][System.Console]::ReadKey($true) }
        [void][System.Console]::ReadKey($true)
    } catch {
        [void](Read-Host)
    }
}

function Log-Line {
    param([string]$text, [string]$color = $null)
    $stamp = Get-Date -Format "HH:mm:ss"
    if ($color) {
        Write-Host "[$stamp] $text" -ForegroundColor $color
    } else {
        Write-Host "[$stamp] $text"
    }
    Add-Content -Path $logFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text) -Encoding UTF8
}

# ---- Learning state --------------------------------------------------------
$script:state = $null
if (Test-Path $stateFile) {
    try { $script:state = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { $script:state = $null }
}

function Get-PresetState {
    param([string]$name)
    if (-not $script:state) {
        $script:state = New-Object PSObject -Property @{ presets = (New-Object PSObject); sites = (New-Object PSObject) }
    }
    if (-not $script:state.presets) {
        $script:state | Add-Member -MemberType NoteProperty -Name presets -Value (New-Object PSObject) -Force
    }
    if (-not $script:state.presets.PSObject.Properties[$name]) {
        $record = New-Object PSObject -Property @{
            lastSuccess       = $null
            lastFail          = $null
            failStreak        = 0
            successRuntimeSec = 0
            switches          = 0
        }
        $script:state.presets | Add-Member -MemberType NoteProperty -Name $name -Value $record -Force
    }
    return $script:state.presets.$name
}

function Get-SiteState {
    param([string]$domain)
    if (-not $script:state) {
        $script:state = New-Object PSObject -Property @{ presets = (New-Object PSObject); sites = (New-Object PSObject) }
    }
    if (-not $script:state.sites) {
        $script:state | Add-Member -MemberType NoteProperty -Name sites -Value (New-Object PSObject) -Force
    }
    if (-not $script:state.sites.PSObject.Properties[$domain]) {
        $record = New-Object PSObject -Property @{
            strategy     = $null   # override strategy (preset name); $null = base preset's own treatment
            lastOk       = $null
            lastFail     = $null
            nextCheck    = $null
            brokenRounds = 0
            backoffUntil = $null
            tried        = @()     # strategies tried in the current broken episode
        }
        $script:state.sites | Add-Member -MemberType NoteProperty -Name $domain -Value $record -Force
    }
    return $script:state.sites.$domain
}

function Convert-StateDate {
    param([object]$value)
    if ($value -is [datetime]) { return $value }
    if ($value) {
        try { return [datetime]::Parse($value) } catch { return $null }
    }
    return $null
}

function Convert-StateDateString {
    # Save-safe formatter: state loaded from JSON holds dates as STRINGS, which
    # have no ToString(format) overload - parse first, then format
    param([object]$value)
    $d = Convert-StateDate $value
    if ($d) { return $d.ToString("yyyy-MM-ddTHH:mm:ss") }
    return $null
}

function Save-State {
    try {
        # Normalize dates to strings so ConvertTo-Json round-trips cleanly
        $out = New-Object PSObject
        $presets = New-Object PSObject
        if ($script:state -and $script:state.presets) {
            foreach ($prop in $script:state.presets.PSObject.Properties) {
                $r = $prop.Value
                $record = New-Object PSObject -Property @{
                    lastSuccess       = (Convert-StateDateString $r.lastSuccess)
                    lastFail          = (Convert-StateDateString $r.lastFail)
                    failStreak        = [int]$r.failStreak
                    successRuntimeSec = [long]$r.successRuntimeSec
                    switches          = [long]$r.switches
                }
                $presets | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $record -Force
            }
        }
        $out | Add-Member -MemberType NoteProperty -Name presets -Value $presets
        $sites = New-Object PSObject
        if ($script:state -and $script:state.sites) {
            foreach ($prop in $script:state.sites.PSObject.Properties) {
                $r = $prop.Value
                $record = New-Object PSObject -Property @{
                    strategy     = if ($r.strategy) { [string]$r.strategy } else { $null }
                    lastOk       = (Convert-StateDateString $r.lastOk)
                    lastFail     = (Convert-StateDateString $r.lastFail)
                    nextCheck    = (Convert-StateDateString $r.nextCheck)
                    brokenRounds = [int]$r.brokenRounds
                    backoffUntil = (Convert-StateDateString $r.backoffUntil)
                    tried        = @($r.tried | ForEach-Object { [string]$_ })
                }
                $sites | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $record -Force
            }
        }
        $out | Add-Member -MemberType NoteProperty -Name sites -Value $sites
        $out | Add-Member -MemberType NoteProperty -Name basePreset -Value $(if ($script:basePresetName) { [string]$script:basePresetName } else { $null })
        $out | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8
    } catch {
        Write-Host "[WARN] Could not save state: $_" -ForegroundColor Yellow
    }
}

# ---- Presets and probe targets ---------------------------------------------
$presetFiles = Get-ChildItem -Path $rootDir -Filter "*.bat" | Where-Object { $_.Name -notlike "service*" } | Sort-Object { [Regex]::Replace($_.Name, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }

$probeTargets = @()
$probeFile = Join-Path $utilsDir "probe targets.txt"
if (Test-Path $probeFile) {
    Get-Content $probeFile | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
            $probeTargets += (New-Object PSObject -Property @{ Group = $matches[1]; Url = $matches[2] })
        }
    }
}
if ($probeTargets.Count -eq 0) {
    Write-Host "[INFO] probe targets.txt missing or empty. Using defaults." -ForegroundColor Gray
    $probeTargets += (New-Object PSObject -Property @{ Group = "YouTube";    Url = "https://www.youtube.com/generate_204" })
    $probeTargets += (New-Object PSObject -Property @{ Group = "YouTube";    Url = "https://redirector.googlevideo.com/report_mapping?di=no" })
    $probeTargets += (New-Object PSObject -Property @{ Group = "Discord";    Url = "https://gateway.discord.gg" })
    $probeTargets += (New-Object PSObject -Property @{ Group = "Cloudflare"; Url = "https://www.cloudflare.com/cdn-cgi/trace" })
}
$groupNames = @($probeTargets | ForEach-Object { $_.Group } | Sort-Object -Unique)
$triggerKey = $groupNames | Where-Object { $_ -ieq $triggerGroup } | Select-Object -First 1

# ---- Important sites and overrides (per-site fixing) ------------------------
function Normalize-Domain {
    param([string]$raw)
    $d = $raw.Trim()
    if (-not $d -or $d.StartsWith("#")) { return $null }
    $d = $d -replace '^\w+://', ''       # strip scheme
    $d = ($d -split '/')[0]              # strip path
    $d = ($d -split ':')[0]              # strip port
    $d = $d.TrimEnd('.').ToLowerInvariant()
    if ($d -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') { return $null }
    return $d
}

$script:excludeEntries = @()
foreach ($excludeListName in @("list-exclude.txt", "list-exclude-user.txt")) {
    $excludeListFile = Join-Path $listsDir $excludeListName
    if (Test-Path $excludeListFile) {
        Get-Content $excludeListFile | ForEach-Object {
            $e = $_.Trim()
            if ($e -and -not $e.StartsWith("#")) { $script:excludeEntries += $e.ToLowerInvariant() }
        }
    }
}

function Test-DomainExcluded {
    # mirrors winws hostlist-exclude semantics: "^..." entries are regexes,
    # plain entries match the domain itself or any subdomain (suffix match)
    param([string]$domain)
    foreach ($entry in $script:excludeEntries) {
        if ($entry.StartsWith("^")) {
            if ($domain -match $entry) { return $entry }
        } elseif ($domain -eq $entry -or $domain.EndsWith(".$entry")) {
            return $entry
        }
    }
    return $null
}

function Get-ImportantDomains {
    $file = Join-Path $listsDir "list-important.txt"
    if (-not (Test-Path $file)) { return @() }
    $domains = @()
    $seen = @{}
    Get-Content $file | ForEach-Object {
        $d = Normalize-Domain -raw $_
        if ($d -and -not $seen.ContainsKey($d)) {
            $seen[$d] = $true
            $domains += $d
        }
    }
    return $domains
}

$script:importantDomains = @()
if ($sitefixEnabled) { $script:importantDomains = Get-ImportantDomains }
if ($sitefixEnabled -and $script:importantDomains.Count -eq 0) {
    Write-Host "[INFO] lists\list-important.txt missing or empty - per-site fixing disabled" -ForegroundColor Gray
    $sitefixEnabled = $false
}

function Get-Overrides {
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    if (Test-Path $overridesFile) {
        Get-Content $overridesFile | ForEach-Object {
            $l = $_.Trim()
            if (-not $l -or $l.StartsWith("#")) { return }
            $idx = $l.IndexOf('=')
            if ($idx -lt 1) { return }
            $d = $l.Substring(0, $idx).Trim().ToLowerInvariant()
            $s = $l.Substring($idx + 1).Trim()
            if ($d -and $s) { $map[$d] = $s }
        }
    }
    return ,$map
}

function Set-Override {
    # writes/removes a "domain = strategy" line; $strategyName $null/empty removes
    param([string]$domain, [string]$strategyName)
    $lines = @()
    if (Test-Path $overridesFile) { $lines = @(Get-Content $overridesFile) }
    $newLines = New-Object System.Collections.Generic.List[string]
    $found = $false
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -and -not $t.StartsWith("#") -and $t.Contains('=')) {
            $d = $t.Substring(0, $t.IndexOf('=')).Trim().ToLowerInvariant()
            if ($d -eq $domain.ToLowerInvariant()) {
                $found = $true
                if ($strategyName) { $newLines.Add("$domain = $strategyName") }
                continue
            }
        }
        $newLines.Add($l)
    }
    if (-not $found -and $strategyName) { $newLines.Add("$domain = $strategyName") }
    [IO.File]::WriteAllLines($overridesFile, $newLines, $script:utf8NoBom)
}

# ---- Combined config generation --------------------------------------------
function Get-PresetSectionArgs {
    # Extracts the "hostlist strategy" profile args from a preset:
    #   udp -> the QUIC hostlist profile (--filter-udp=443 / --filter-l7=quic with --hostlist=)
    #   tcp -> the general TCP hostlist profile (--filter-tcp=80,443 with --hostlist=);
    #          fallback: ALT5-style global TCP section (--filter-l3=ipv4)
    param([string]$presetName, [ValidateSet('tcp', 'udp')][string]$kind)
    $file = Join-Path $rootDir $presetName
    if (-not (Test-Path $file)) { return $null }
    $lines = @([IO.File]::ReadAllText($file) -split "`r`n")
    $udpArgs = $null
    $tcpHostlist = $null
    $tcpGlobal = $null
    foreach ($line in $lines) {
        if ($line -match 'winws\.exe') { continue }                    # the start line
        if ($line -notmatch '--filter-') { continue }
        $args = ($line -replace '\s*--new\s*\^\s*$', '').Trim()
        if ($args -match '--filter-udp=443|--filter-l7=quic' -and $args -match '--hostlist="%LISTS%') {
            if (-not $udpArgs) { $udpArgs = $args }
        }
        if ($args -match '--filter-tcp=80,443(\s|$)' -and $args -match '--hostlist="%LISTS%') {
            if (-not $tcpHostlist) { $tcpHostlist = $args }
        }
        if ($args -match '--filter-l3=ipv4' -and -not $tcpGlobal) { $tcpGlobal = $args }
    }
    if ($kind -eq 'udp') { return $udpArgs }
    if ($tcpHostlist) { return $tcpHostlist }
    return $tcpGlobal
}

function Convert-SectionToOverride {
    # Turns a preset section into a per-domain profile: the three list include
    # tokens are replaced by --hostlist-domains=<domain>, everything else
    # (excludes, desync args, batch-escaped ^! fakes) stays byte-identical.
    param([string]$sectionArgs, [string]$domain)
    if (-not $sectionArgs) { return $null }
    $s = $sectionArgs
    if ($s -match '--hostlist="%LISTS%[^"]*"') {
        # single-pass rebuild: split on the include tokens, rejoin with exactly
        # one --hostlist-domains token in place of the first include
        $parts = [regex]::Split($s, '\s*--hostlist="%LISTS%[^"]*"')
        $head = $parts[0].Trim()
        $tail = ((@($parts | Select-Object -Skip 1) | Where-Object { $_.Trim() }) -join ' ').Trim()
        return (("$head --hostlist-domains=$domain $tail") -replace '\s{2,}', ' ').Trim()
    }
    return ($s.Trim() + " --hostlist-domains=$domain")
}

function New-CustomConfig {
    param([string]$basePresetName)
    if ($basePresetName -eq $customPresetName) { throw "Base preset cannot be the generated config itself" }
    $baseFile = Join-Path $rootDir $basePresetName
    if (-not (Test-Path $baseFile)) { throw "Base preset not found: $basePresetName" }
    $lines = @([IO.File]::ReadAllText($baseFile) -split "`r`n")
    $startIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'winws\.exe') { $startIdx = $i; break }
    }
    if ($startIdx -lt 0) { throw "winws start line not found in $basePresetName" }

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $startIdx; $i++) { $out.Add($lines[$i]) }
    $out.Add(":: GENERATED by auto-rotation monitor - do not edit; base preset: $basePresetName")
    $out.Add($lines[$startIdx].TrimEnd())

    $baseProfileLines = @()
    for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].Trim()) { continue }
        $baseProfileLines += (($lines[$i] -replace '\s*--new\s*\^\s*$', '').TrimEnd())
    }

    $overrides = Get-Overrides
    foreach ($domain in $overrides.Keys) {
        $strategy = [string]$overrides[$domain]
        $tcpArgs = Convert-SectionToOverride -sectionArgs (Get-PresetSectionArgs -presetName $strategy -kind 'tcp') -domain $domain
        $udpArgs = Convert-SectionToOverride -sectionArgs (Get-PresetSectionArgs -presetName $strategy -kind 'udp') -domain $domain
        if (-not $tcpArgs -and -not $udpArgs) {
            Write-Host "[WARN] Override strategy '$strategy' for '$domain' not found - skipped" -ForegroundColor Yellow
            continue
        }
        if ($udpArgs) { $out.Add("$udpArgs --new ^") }
        if ($tcpArgs) { $out.Add("$tcpArgs --new ^") }
    }
    for ($i = 0; $i -lt $baseProfileLines.Count; $i++) {
        if ($i -lt $baseProfileLines.Count - 1) { $out.Add("$($baseProfileLines[$i]) --new ^") }
        else { $out.Add($baseProfileLines[$i]) }
    }

    $customPath = Join-Path $rootDir $customPresetName
    [IO.File]::WriteAllText($customPath, (($out -join "`r`n") + "`r`n"), $script:utf8NoBom)
    return (Get-Item -LiteralPath $customPath)
}

function Get-CustomPresetFile {
    return Get-Item -LiteralPath (Join-Path $rootDir $customPresetName) -ErrorAction SilentlyContinue
}

# ---- Preflight --------------------------------------------------------------
Write-Host ""
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Run as Administrator to execute the monitor" -ForegroundColor Red
    $hasErrors = $true
} else {
    Write-Host "[OK] Administrator rights detected" -ForegroundColor Green
}

if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] curl.exe not found" -ForegroundColor Red
    Write-Host "Install curl or add it to PATH" -ForegroundColor Yellow
    $hasErrors = $true
} else {
    Write-Host "[OK] curl.exe found" -ForegroundColor Green
}

if (Get-Service -Name "zapret" -ErrorAction SilentlyContinue) {
    Write-Host "[ERROR] Windows service 'zapret' is installed" -ForegroundColor Red
    Write-Host "         The monitor manages winws directly and cannot run along the service" -ForegroundColor Yellow
    Write-Host "         Open service.bat and choose 'Remove Services' first" -ForegroundColor Yellow
    $hasErrors = $true
}

# guard: two monitor instances would fight over winws restarts
$otherMonitors = @()
try {
    $otherMonitors = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'monitor\s+zapret\.ps1' })
} catch { }
if ($otherMonitors.Count -gt 0) {
    Write-Host "[ERROR] Another monitor instance is already running (PID $($otherMonitors[0].ProcessId))" -ForegroundColor Red
    Write-Host "         Close its window first - two monitors would fight over winws restarts" -ForegroundColor Yellow
    $hasErrors = $true
}

if (-not $presetFiles -or $presetFiles.Count -eq 0) {
    Write-Host "[ERROR] No strategy .bat files found in $rootDir" -ForegroundColor Red
    $hasErrors = $true
}

if (-not $triggerKey) {
    Write-Host "[ERROR] Trigger group '$triggerGroup' not found in probe targets. Available: $($groupNames -join ', ')" -ForegroundColor Red
    $hasErrors = $true
}

if ($hasErrors) {
    Write-Host ""
    Write-Host "Fix the errors above and rerun." -ForegroundColor Yellow
    Wait-AnyKey -message "Press any key to exit..."
    exit 1
}

$excludedImportant = @($script:importantDomains | Where-Object { Test-DomainExcluded -domain $_ })

# ---- Probe machinery --------------------------------------------------------
$maxParallel = [Math]::Max(2, [Math]::Max($probeTargets.Count, $script:importantDomains.Count))
$runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
$runspacePool.Open()

$probeScriptBlock = {
    param($target, $timeoutSeconds)

    # Same stderr/stdout split as "test zapret.ps1": stderr lines arrive as
    # ErrorRecords, stdout holds only the "%{http_code}" written by -o NUL
    $stderr = ""
    try {
        $output = & curl.exe -I -s -m $timeoutSeconds --connect-timeout ([Math]::Min(2, $timeoutSeconds)) -o NUL -w "%{http_code}" --show-error $target.Url 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $stderr += $_.Exception.Message + " "
            } else {
                $_
            }
        }
        $exit = $LASTEXITCODE
        $code = ($output | Out-String).Trim()
        if ($exit -eq 0 -and $code -match '^\d{3}$' -and $code -ne "000") {
            # Any real HTTP status (2xx/3xx/4xx) means the connection path works:
            # censors kill connections, they don't answer with valid statuses.
            return (New-Object PSObject -Property @{ Group = $target.Group; Url = $target.Url; Ok = $true; Detail = "HTTP $code" })
        }
        $detail = $stderr.Trim()
        if (-not $detail) { $detail = "curl exit $exit" }
        if ($detail.Length -gt 80) { $detail = $detail.Substring(0, 80) }
        return (New-Object PSObject -Property @{ Group = $target.Group; Url = $target.Url; Ok = $false; Detail = $detail })
    } catch {
        return (New-Object PSObject -Property @{ Group = $target.Group; Url = $target.Url; Ok = $false; Detail = $_.Exception.Message })
    }
}

$siteProbeScriptBlock = {
    param($domain, $timeoutSeconds, $connectTimeout, $gapSeconds)

    # Two sequential GETs on FRESH connections: a site that serves the first
    # request but kills the follow-up ones (the "page loads only its title"
    # TSPU pattern) is reported as failing. Mid-body stalls (curl exit 28 with
    # partial bytes) fail too. Any real HTTP status (2xx-5xx) = transport OK.
    $codes = @()
    $lastDetail = ""
    for ($g = 1; $g -le 2; $g++) {
        if ($g -gt 1) { Start-Sleep -Seconds $gapSeconds }
        $stderr = ""
        try {
            $output = & curl.exe -L -sS -m $timeoutSeconds --connect-timeout $connectTimeout -o NUL -w "%{http_code}" --show-error "https://$domain" 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $stderr += $_.Exception.Message + " "
                } else {
                    $_
                }
            }
            $exit = $LASTEXITCODE
            $codeStr = ($output | Out-String).Trim()
            $m = [regex]::Matches($codeStr, '\d{3}')
            $code = if ($m.Count -gt 0) { $m[$m.Count - 1].Value } else { $codeStr }
            if ($exit -ne 0 -or -not $code -or $code -eq "000" -or $code -notmatch '^\d{3}$') {
                $lastDetail = $stderr.Trim()
                if (-not $lastDetail) { $lastDetail = "curl exit $exit" }
                if ($lastDetail.Length -gt 70) { $lastDetail = $lastDetail.Substring(0, 70) }
                return (New-Object PSObject -Property @{ Domain = $domain; Ok = $false; Detail = "GET$($g): $lastDetail" })
            }
            $codes += $code
        } catch {
            return (New-Object PSObject -Property @{ Domain = $domain; Ok = $false; Detail = "GET$($g): $($_.Exception.Message)" })
        }
    }
    return (New-Object PSObject -Property @{ Domain = $domain; Ok = $true; Detail = "HTTP $($codes -join '/')" })
}

function Invoke-ProbeRound {
    $powers = @()
    $handles = @()
    foreach ($t in $probeTargets) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($probeScriptBlock).AddArgument($t).AddArgument($curlTimeoutSeconds)
        $handles += $ps.BeginInvoke()
        $powers += $ps
    }

    $results = @()
    for ($i = 0; $i -lt $powers.Count; $i++) {
        try {
            $out = $powers[$i].EndInvoke($handles[$i])
            $results += @($out)
        } catch {
            $results += (New-Object PSObject -Property @{ Group = $probeTargets[$i].Group; Url = $probeTargets[$i].Url; Ok = $false; Detail = "probe error" })
        }
        $powers[$i].Dispose()
    }
    return $results
}

function Invoke-SiteProbes {
    param([array]$domains)
    $powers = @()
    $handles = @()
    foreach ($d in $domains) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($siteProbeScriptBlock).AddArgument($d).AddArgument($siteTimeout).AddArgument($siteConnectTimeout).AddArgument($siteGetGap)
        $handles += $ps.BeginInvoke()
        $powers += $ps
    }

    $results = @()
    for ($i = 0; $i -lt $powers.Count; $i++) {
        try {
            $out = $powers[$i].EndInvoke($handles[$i])
            $results += @($out)[0]
        } catch {
            $results += (New-Object PSObject -Property @{ Domain = $domains[$i]; Ok = $false; Detail = "probe error" })
        }
        $powers[$i].Dispose()
    }
    return $results
}

function Get-GroupSummary {
    param($probeResults)
    # Ordered summary: one record per group: Ok (any target ok), OkCount, Total
    $summary = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($group in $groupNames) {
        $groupResults = @($probeResults | Where-Object { $_.Group -ieq $group })
        $okCount = @($groupResults | Where-Object { $_.Ok }).Count
        $summary[$group] = (New-Object PSObject -Property @{
            Ok      = ($okCount -gt 0)
            OkCount = $okCount
            Total   = $groupResults.Count
        })
    }
    return $summary
}

# ---- Rotation ---------------------------------------------------------------
function Get-RankedPresets {
    param([string]$excludeName)
    $now = Get-Date
    $cutoff = $now.AddMinutes(-$quarantineMinutes)
    $candidates = @($presetFiles | Where-Object { $_.Name -ne $customPresetName -and $_.Name -ne $excludeName })
    $ranked = @($candidates | Sort-Object -Property @(
        @{ Expression = { $s = Get-PresetState $_.Name; $lf = Convert-StateDate $s.lastFail; if ($lf -and $lf -gt $cutoff) { 1 } else { 0 } }; Ascending = $true },
        @{ Expression = { (Get-PresetState $_.Name).failStreak }; Ascending = $true },
        @{ Expression = { $s = Get-PresetState $_.Name; $ls = Convert-StateDate $s.lastSuccess; if ($ls) { ($now - $ls).TotalSeconds } else { [double]1e12 } }; Ascending = $true },
        @{ Expression = { $s = Get-PresetState $_.Name; $lf = Convert-StateDate $s.lastFail; if ($lf) { ($now - $lf).TotalSeconds } else { [double]1e12 } }; Descending = $true },
        @{ Expression = { $presetFiles.IndexOf($_) }; Ascending = $true }
    ))
    return ,$ranked
}

function Start-Preset {
    param($file)
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $rootDir -PassThru -WindowStyle Minimized
    if (-not (Wait-WinwsReady)) {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        return $false
    }
    return $true
}

function Invoke-Rotation {
    param([string]$reason)
    $attempts = 0
    $exclude = $script:currentPresetName
    while ($attempts -lt $presetFiles.Count) {
        $next = (Get-RankedPresets -excludeName $exclude) | Select-Object -First 1
        if (-not $next) {
            Log-Line "No other preset available to switch to" Red
            return $false
        }

        $quarantineNote = ""
        $s = Get-PresetState $next.Name
        $lf = Convert-StateDate $s.lastFail
        if ($lf -and ((Get-Date) - $lf).TotalMinutes -lt $quarantineMinutes) {
            $quarantineNote = " (all presets recently failed - retrying best candidate)"
        }

        Log-Line ("SWITCH{0}: {1} -> {2}" -f $quarantineNote, $script:currentPresetName, $next.Name) Magenta
        Log-Line ("  reason: {0}" -f $reason) DarkGray

        $targetFile = $next
        if ($script:sitefixEnabled) {
            try {
                $targetFile = New-CustomConfig -basePresetName $next.Name
                $script:basePresetName = $next.Name
            } catch {
                Log-Line "Combined config regeneration failed: $($_.Exception.Message) - per-site fixing disabled, switching to the raw preset" Yellow
                $script:sitefixEnabled = $false
                $targetFile = $next
            }
        }

        Stop-Zapret
        if (Start-Preset -file $targetFile) {
            $script:currentPresetName = if ($script:sitefixEnabled) { $customPresetName } else { $next.Name }
            $rec = Get-PresetState $next.Name
            $rec.switches = [long]$rec.switches + 1
            Touch-SiteChecksAfterRestart -settleSeconds ([Math]::Max($siteSettle, $cooldownSeconds))
            Save-State
            if ($cooldownSeconds -gt 0) { Start-Sleep -Seconds $cooldownSeconds }
            return $true
        }

        Log-Line "Strategy failed to start (winws process not found). Trying the next one..." Red
        $rec = Get-PresetState $next.Name
        $rec.lastFail = Get-Date
        $rec.failStreak = [int]$rec.failStreak + 1
        Save-State
        $exclude = $next.Name
        $attempts++
    }
    return $false
}

# ---- Per-site fixing --------------------------------------------------------
$script:basePresetName = $null

function Touch-SiteChecksAfterRestart {
    # after any winws restart, push the next site checks out past the settle time
    param([int]$settleSeconds)
    if (-not $script:sitefixEnabled) { return }
    $t = (Get-Date).AddSeconds($settleSeconds)
    foreach ($d in $script:importantDomains) {
        $rec = Get-SiteState $d
        $nc = Convert-StateDate $rec.nextCheck
        if (-not $nc -or $nc -lt $t) { $rec.nextCheck = $t }
    }
}

function Get-SiteCandidates {
    # '<base>' sentinel = remove the override and rely on the base preset's own
    # treatment; the rest are presets, best-ranked first, minus already-tried ones
    param([string]$domain)
    $rec = Get-SiteState $domain
    $tried = @($rec.tried | ForEach-Object { [string]$_ })
    $rankedNames = @((Get-RankedPresets -excludeName $null) | ForEach-Object { $_.Name })
    $all = @('<base>') + @($rankedNames | Where-Object { $_ -ne $customPresetName })
    return @($all | Where-Object { $tried -notcontains $_ })
}

function Invoke-SiteFixCycle {
    param([string]$domain)
    $rec = Get-SiteState $domain
    $current = if ($rec.strategy) { [string]$rec.strategy } else { '<base>' }
    $attempts = 0
    foreach ($cand in (Get-SiteCandidates -domain $domain)) {
        if ($attempts -ge $sitefixMaxAttempts) { break }
        if ($cand -eq $current) { continue }   # the strategy that just failed

        $strategyArg = $null
        if ($cand -ne '<base>') { $strategyArg = $cand }
        try {
            Set-Override -domain $domain -strategyName $strategyArg
            [void](New-CustomConfig -basePresetName $script:basePresetName)
        } catch {
            Log-Line ("SITEFIX {0}: config generation failed: {1}" -f $domain, $_.Exception.Message) Red
            $rec.tried = @($rec.tried | ForEach-Object { [string]$_ }) + $cand
            $attempts++
            continue
        }

        Log-Line ("SITEFIX {0}: trying strategy '{1}'..." -f $domain, $cand) Cyan
        Stop-Zapret
        $customFile = Get-CustomPresetFile
        $started = $false
        if ($customFile) { $started = Start-Preset -file $customFile }
        if (-not $started) {
            Log-Line ("SITEFIX {0}: combined config failed to start - candidate skipped" -f $domain) Red
            $rec.tried = @($rec.tried | ForEach-Object { [string]$_ }) + $cand
            $attempts++
            continue
        }
        $script:currentPresetName = $customPresetName
        Start-Sleep -Seconds $siteSettle
        $r = @(Invoke-SiteProbes -domains @($domain))[0]
        if ($r -and $r.Ok) {
            $rec.strategy = if ($cand -eq '<base>') { $null } else { $cand }
            $rec.lastOk = Get-Date
            $rec.lastFail = $null
            $rec.brokenRounds = 0
            $rec.nextCheck = (Get-Date).AddSeconds($siteOkQuiet)
            $rec.tried = @()
            Save-State
            Log-Line ("SITEFIX {0}: FIXED via '{1}' ({2})" -f $domain, $cand, $r.Detail) Green
            Touch-SiteChecksAfterRestart -settleSeconds $siteSettle
            return $true
        }
        Log-Line ("SITEFIX {0}: '{1}' did not fix it ({2})" -f $domain, $cand, $(if ($r) { $r.Detail } else { "no result" })) DarkYellow
        $rec.tried = @($rec.tried | ForEach-Object { [string]$_ }) + $cand
        $attempts++
    }
    $rec.backoffUntil = (Get-Date).AddSeconds($siteBackoff)
    $rec.nextCheck = $rec.backoffUntil
    $rec.brokenRounds = 0
    $rec.tried = @()   # fresh episode after the backoff
    Save-State
    Log-Line ("SITEFIX {0}: no working strategy found - backing off {1}s" -f $domain, $siteBackoff) Yellow
    Touch-SiteChecksAfterRestart -settleSeconds $siteSettle
    return $false
}

function Invoke-SiteChecks {
    # probes due domains; starts fix cycles for the ones past the threshold
    $now = Get-Date
    $due = @()
    foreach ($d in $script:importantDomains) {
        if (Test-DomainExcluded -domain $d) { continue }
        $rec = Get-SiteState $d
        $bu = Convert-StateDate $rec.backoffUntil
        if ($bu -and $now -lt $bu) { continue }
        $nc = Convert-StateDate $rec.nextCheck
        if (-not $nc -or $now -ge $nc) { $due += $d }
    }
    if ($due.Count -eq 0) { return }

    $results = Invoke-SiteProbes -domains $due
    $toFix = @()
    foreach ($r in $results) {
        if (-not $r) { continue }
        $rec = Get-SiteState $r.Domain
        if ($r.Ok) {
            if ([int]$rec.brokenRounds -gt 0) { Log-Line ("SITE {0}: recovered ({1})" -f $r.Domain, $r.Detail) Green }
            $rec.lastOk = $now
            $rec.lastFail = $null
            $rec.brokenRounds = 0
            $rec.nextCheck = $now.AddSeconds($siteOkQuiet)
        } else {
            $rec.lastFail = $now
            $rec.brokenRounds = [int]$rec.brokenRounds + 1
            $rec.nextCheck = $now.AddSeconds($siteBrokenInterval)
            Log-Line ("SITE {0}: FAIL ({1}) [{2}/{3}]" -f $r.Domain, $r.Detail, $rec.brokenRounds, $siteBrokenThreshold) DarkYellow
            if ($rec.brokenRounds -ge $siteBrokenThreshold) {
                $toFix += $r.Domain
            }
        }
    }
    Save-State
    foreach ($d in $toFix) {
        [void](Invoke-SiteFixCycle -domain $d)
    }
}

# ---- Startup ----------------------------------------------------------------
$host.UI.RawUI.WindowTitle = "zapret auto-rotation monitor"
$env:NO_UPDATE_CHECK = "1"

$script:snapshot = Get-WinwsSnapshot
$script:snapshotEmpty = @($script:snapshot).Count -eq 0
$script:currentPresetName = $null
$script:failRounds = 0

$overrideCount = 0
if ($sitefixEnabled) { $overrideCount = @(Get-Overrides).Keys.Count }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "            ZAPRET AUTO-ROTATION + SITE FIXER" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Interval: $intervalSeconds s | Fail threshold: $failThreshold rounds | Cooldown: $cooldownSeconds s" -ForegroundColor Gray
Write-Host " Trigger group: $triggerGroup | Quarantine: $quarantineMinutes min" -ForegroundColor Gray
Write-Host " Presets: $($presetFiles.Count) | Probe targets: $($probeTargets.Count) ($($groupNames -join ', '))" -ForegroundColor Gray
Write-Host (" Site fix: {0} (domains: {1}, learned overrides: {2}, quiet: {3}s, broken recheck: {4}s)" -f $(if ($sitefixEnabled) { "ENABLED" } else { "off" }), $script:importantDomains.Count, $overrideCount, $siteOkQuiet, $siteBrokenInterval) -ForegroundColor Gray
if ($excludedImportant.Count -gt 0) {
    Write-Host (" [WARN] Important domains excluded by exclude lists (skipped): {0}" -f ($excludedImportant -join ", ")) -ForegroundColor Yellow
}
Write-Host " State: $(Join-Path $utilsDir 'monitor state.json')" -ForegroundColor Gray
Write-Host " Ipset filter: $(Get-IpsetStatus)" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Cyan

$stateCount = 0
if ($script:state -and $script:state.presets) { $stateCount = @($script:state.presets.PSObject.Properties).Count }
Write-Host "[INFO] Loaded learning state: $stateCount preset record(s)" -ForegroundColor DarkGray

try {
    # ---- per-site fixing: choose the base preset and build the combined config
    if ($sitefixEnabled) {
        $ranked = Get-RankedPresets -excludeName $null
        $defaultBase = $null
        if ($script:state -and $script:state.PSObject.Properties['basePreset'] -and $script:state.basePreset) {
            $candidate = [string]$script:state.basePreset
            if ($candidate -ne $customPresetName -and @($ranked | Where-Object { $_.Name -eq $candidate }).Count -gt 0) {
                $defaultBase = $candidate
            }
        }
        if (-not $defaultBase -and $ranked.Count -gt 0) { $defaultBase = $ranked[0].Name }

        $chosen = $null
        if ("$env:MONITOR_BASE_SELECT" -ieq 'auto') {
            if ($defaultBase) {
                $chosen = $defaultBase
                Write-Host "[INFO] Base preset auto-selected: $chosen (last choice / best ranked)" -ForegroundColor Cyan
            }
        } else {
            Write-Host ""
            Write-Host "Select the BASE preset for the combined config (per-site overrides ride on top of it):" -ForegroundColor Cyan
            for ($i = 0; $i -lt $ranked.Count; $i++) {
                $marker = ""
                if ($ranked[$i].Name -eq $defaultBase) { $marker = "   <- last choice / best ranked (Enter)" }
                Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $ranked[$i].Name, $marker) -ForegroundColor Gray
            }
            while ($true) {
                $choice = Read-Host ("Enter number (Enter = {0}), or 'N' for watch-only (no per-site fixing)" -f $defaultBase)
                if ($choice -match '^[nN]') { break }
                if (-not $choice.Trim()) { $chosen = $defaultBase; break }
                if ($choice -match '^\d+$') {
                    $n = [int]$choice
                    if ($n -ge 1 -and $n -le $ranked.Count) { $chosen = $ranked[$n - 1].Name; break }
                }
                Write-Host "Invalid input. Enter a number from the list, 'N', or press Enter." -ForegroundColor Yellow
            }
        }
        if (-not $chosen) {
            $sitefixEnabled = $false
            $script:sitefixEnabled = $false
            Write-Host "[INFO] Watch-only mode: per-site fixing is disabled for this run." -ForegroundColor Yellow
        } else {
            $script:basePresetName = $chosen
            $script:sitefixEnabled = $true
            try {
                [void](New-CustomConfig -basePresetName $script:basePresetName)
            } catch {
                Log-Line "Combined config generation failed: $($_.Exception.Message) - continuing watch-only" Red
                $sitefixEnabled = $false
                $script:sitefixEnabled = $false
            }
        }
    }

    # ---- bring winws up
    if ($script:sitefixEnabled) {
        $customFile = Get-CustomPresetFile
        Stop-Zapret   # the monitor owns the combined config now
        if ($customFile -and (Start-Preset -file $customFile)) {
            $script:currentPresetName = $customPresetName
            Log-Line "Combined config started (base: $script:basePresetName + overrides)" Cyan
            foreach ($d in $script:importantDomains) {
                $rec = Get-SiteState $d
                if (-not (Convert-StateDate $rec.nextCheck)) { $rec.nextCheck = (Get-Date).AddSeconds($siteSettle) }
            }
            Save-State
            if ($cooldownSeconds -gt 0) { Start-Sleep -Seconds $cooldownSeconds }
        } else {
            Log-Line "Combined config failed to start - falling back to the best-ranked preset" Yellow
            $sitefixEnabled = $false
            $script:sitefixEnabled = $false
            $best = (Get-RankedPresets -excludeName $null) | Select-Object -First 1
            if (-not (Start-Preset -file $best)) {
                Log-Line "Strategy failed to start on launch. Rotating..." Yellow
                [void](Invoke-Rotation -reason "launch failure")
            } else {
                $script:currentPresetName = $best.Name
                $rec = Get-PresetState $best.Name
                $rec.switches = [long]$rec.switches + 1
                Save-State
                if ($cooldownSeconds -gt 0) { Start-Sleep -Seconds $cooldownSeconds }
            }
        }
    } elseif (-not $snapshotEmpty) {
        Write-Host "[INFO] winws is already running - monitoring it as-is" -ForegroundColor Cyan
        Write-Host "[INFO] Its preset name is unknown until the first switch" -ForegroundColor DarkGray
    } else {
        $best = (Get-RankedPresets -excludeName $null) | Select-Object -First 1
        Log-Line "winws is not running - starting best-ranked preset: $($best.Name)" Cyan
        if (-not (Start-Preset -file $best)) {
            Log-Line "Strategy failed to start on launch. Rotating..." Yellow
            [void](Invoke-Rotation -reason "launch failure")
        } else {
            $script:currentPresetName = $best.Name
            $rec = Get-PresetState $best.Name
            $rec.switches = [long]$rec.switches + 1
            Save-State
            if ($cooldownSeconds -gt 0) { Start-Sleep -Seconds $cooldownSeconds }
        }
    }

    Log-Line "Monitor started. Press Ctrl+C to stop." Green

    while ($true) {
      try {
        # keep a preset alive
        if (-not (Get-Process -Name "winws" -ErrorAction SilentlyContinue)) {
            if ($script:currentPresetName) {
                Log-Line "winws disappeared - restarting $script:currentPresetName" Yellow
                $file = $presetFiles | Where-Object { $_.Name -eq $script:currentPresetName } | Select-Object -First 1
                if (-not $file -and $script:sitefixEnabled -and $script:currentPresetName -eq $customPresetName -and $script:basePresetName) {
                    # generated config was deleted - rebuild it
                    try { $file = New-CustomConfig -basePresetName $script:basePresetName } catch { $file = $null }
                }
                if ($file -and (Start-Preset -file $file)) {
                    Touch-SiteChecksAfterRestart -settleSeconds ([Math]::Max($siteSettle, $cooldownSeconds))
                    if ($cooldownSeconds -gt 0) { Start-Sleep -Seconds $cooldownSeconds }
                } else {
                    [void](Invoke-Rotation -reason "preset process died")
                }
            } else {
                [void](Invoke-Rotation -reason "no active preset")
            }
        }

        # per-site checks / fix cycles (restart winws on strategy changes)
        if ($script:sitefixEnabled) {
            Invoke-SiteChecks
        }

        $probeResults = Invoke-ProbeRound
        $summary = Get-GroupSummary -probeResults $probeResults

        $parts = @()
        foreach ($group in $groupNames) {
            $g = $summary[$group]
            $parts += ("{0}: {1} {2}/{3}" -f $group, $(if ($g.Ok) { "OK" } else { "FAIL" }), $g.OkCount, $g.Total)
        }
        $triggerOk = $summary[$triggerKey].Ok
        $color = if ($triggerOk) { "Green" } else { "Red" }
        Log-Line ("PROBE {0}" -f ($parts -join " | ")) $color

        if (-not $triggerOk) {
            foreach ($r in $probeResults) {
                if (-not $r.Ok) {
                    Log-Line ("  FAIL {0}: {1}" -f $r.Url, $r.Detail) DarkYellow
                }
            }
        }

        if ($triggerOk) {
            $script:failRounds = 0
            # learn on the BASE preset: with per-site fixing the running config
            # is the generated CUSTOM file, not a rotation candidate
            $learnName = if ($script:sitefixEnabled -and $script:basePresetName) { $script:basePresetName } else { $script:currentPresetName }
            if ($learnName) {
                $rec = Get-PresetState $learnName
                $rec.lastSuccess = Get-Date
                $rec.failStreak = 0
                $rec.successRuntimeSec = [long]$rec.successRuntimeSec + $intervalSeconds
                Save-State
            }
            Start-Sleep -Seconds $intervalSeconds
        } else {
            $script:failRounds++
            $knownNote = ""
            if (-not $script:currentPresetName) { $knownNote = " (preset unknown)" }
            Log-Line ("Trigger group '{0}' failing{1} [{2}/{3}]" -f $triggerGroup, $knownNote, $script:failRounds, $failThreshold) Yellow
            if ($script:failRounds -ge $failThreshold) {
                $script:failRounds = 0
                $learnName = if ($script:sitefixEnabled -and $script:basePresetName) { $script:basePresetName } else { $script:currentPresetName }
                if ($learnName) {
                    $rec = Get-PresetState $learnName
                    $rec.lastFail = Get-Date
                    $rec.failStreak = [int]$rec.failStreak + 1
                    Save-State
                }
                if (Invoke-Rotation -reason "'$triggerGroup' failed $failThreshold probe round(s) in a row") {
                    # loop continues immediately: the next probe verifies the switch
                    continue
                }
                Start-Sleep -Seconds $intervalSeconds
            } else {
                Start-Sleep -Seconds $intervalSeconds
            }
        }
      } catch [System.Management.Automation.PipelineStoppedException] {
          throw  # Ctrl+C must pass through to the cleanup in finally
      } catch {
          Log-Line "Loop error: $($_.Exception.Message) - retrying in 5s" Red
          Start-Sleep -Seconds 5
      }
    }
} finally {
    Write-Host ""
    Log-Line "Monitor stopping..." Cyan
    Save-State
    if (-not $snapshotEmpty) {
        Stop-Zapret
        Restore-WinwsSnapshot -snapshot $script:snapshot
        Write-Host "[INFO] Original winws configuration restored." -ForegroundColor Green
    } else {
        if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
            Write-Host "[INFO] Leaving preset '$script:currentPresetName' running so the bypass keeps working." -ForegroundColor Green
            Write-Host "[INFO] Close winws manually or install it as a service when done." -ForegroundColor DarkGray
        }
    }
    try { $runspacePool.Close() } catch { }
    Log-Line "Monitor stopped." Cyan
}
