# ADGUARD VPN COMPATIBILITY TEST
# Guided retest for Zapret + AdGuard VPN coexistence.
#
# Why this exists: turning Kill Switch off in AdGuard VPN takes effect only
# when the tunnel settings are recreated (next connect / settings change).
# Retries inside that window fail even though the fix is correct, which looks
# like "didn't work". This tool verifies the kill-switch state at the tunnel
# level (from AdGuard VPN's own logs), enforces the test discipline, and gives
# a verdict from evidence instead of eyeballing the app.
#
# What it watches during the test window:
#   - "Health check has timed out" / "connection_timeout"  -> FAIL markers
#   - "VPN_SS_CONNECTED" / "Using endpoint"                -> tunnel events
#   - "BlockUntunneled (kill switch) - True"               -> setting regression
#   - monitor log restarts (Combined config / winws disappeared / SWITCH)
#     -> correlation if failures coincide with Zapret restarts
#
# Override via environment variables:
#   ADGUARD_TEST_WINDOW   test window, seconds       (default 600)
#   ADGUARD_LOG_DIR       AdGuard VPN logs folder    (default C:\ProgramData\AdguardVpn\Logs)
#   ADGUARD_POLL          poll interval, seconds     (default 5)

$rootDir = Split-Path $PSScriptRoot
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $utilsDir "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

$windowSeconds = 600
$pollSeconds = 5
$logDir = "C:\ProgramData\AdguardVpn\Logs"
if ($env:ADGUARD_TEST_WINDOW) { [int]$windowSeconds = $env:ADGUARD_TEST_WINDOW }
if ($env:ADGUARD_LOG_DIR) { $logDir = $env:ADGUARD_LOG_DIR }
if ($env:ADGUARD_POLL) { [int]$pollSeconds = $env:ADGUARD_POLL }
if ($windowSeconds -lt 15) { $windowSeconds = 15 }
if ($pollSeconds -lt 2) { $pollSeconds = 2 }

# ---- log reading ------------------------------------------------------------
function Get-AdguardLogFiles {
    # newest log in service\ and agent\ subfolders (plus the root folder itself)
    param([string]$logDirectory)
    $found = @()
    foreach ($sub in @('service', 'agent', '.')) {
        $dir = if ($sub -eq '.') { $logDirectory } else { Join-Path $logDirectory $sub }
        if (Test-Path $dir) {
            $f = Get-ChildItem -Path $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($f -and -not ($found | Where-Object { $_.FullName -eq $f.FullName })) { $found += $f }
        }
    }
    return ,$found
}

function Get-KillSwitchState {
    # the newest log file that contains a WinTunnel settings line wins
    param([string[]]$logFiles)
    foreach ($f in ($logFiles | Where-Object { $_ })) {
        if (-not (Test-Path $f)) { continue }
        try {
            $hits = @(Select-String -Path $f -Pattern 'BlockUntunneled \(kill switch\) - (True|False)' -ErrorAction SilentlyContinue)
            if ($hits.Count -gt 0) { return $hits[-1].Matches[0].Groups[1].Value }
        } catch { }
    }
    return 'Unknown'
}

function Read-NewLogLines {
    # byte-offset tail reader: returns only complete new lines, tracks partial writes
    param([string]$file, [ref]$offset)
    if (-not $file -or -not (Test-Path $file)) { return @() }
    try {
        $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($offset.Value -gt $len) { $offset.Value = 0 }   # rotated/truncated
            if ($len -le $offset.Value) { return @() }
            $fs.Position = $offset.Value
            $size = [int]($len - $offset.Value)
            $buf = New-Object byte[] $size
            [void]$fs.Read($buf, 0, $size)
            $text = [Text.Encoding]::UTF8.GetString($buf)
            $bomAdjust = 0
            if ($offset.Value -eq 0 -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
                $text = $text.Substring(1)      # strip UTF-8 BOM from the very first read
                $bomAdjust = 3
            }
            $idx = $text.LastIndexOf("`n")
            if ($idx -lt 0) { return @() }                       # no complete line yet
            $complete = $text.Substring(0, $idx + 1)
            $offset.Value = $offset.Value + $bomAdjust + [Text.Encoding]::UTF8.GetByteCount($complete)
            $lines = @(($complete -split "`r?`n") | Where-Object { $_.Trim() })
            return ,$lines                    # comma preserves single-element arrays
        } finally { $fs.Dispose() }
    } catch {
        return @()
    }
}

function Get-TestVerdict {
    # FAIL on any health-check/disconnect marker; otherwise PASS with info
    param([string[]]$eventLines)
    $failures = @($eventLines | Where-Object { $_ -match 'Health check has timed out|connection_timeout' })
    if ($failures.Count -gt 0) {
        return (New-Object PSObject -Property @{ Ok = $false; Failures = $failures })
    }
    return (New-Object PSObject -Property @{ Ok = $true; Failures = @() })
}

# ---- helpers -----------------------------------------------------------------
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

# ---- pre-checks ----------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "           ADGUARD VPN COMPATIBILITY TEST" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host (" Log dir: {0} | Window: {1}s | Poll: {2}s" -f $logDir, $windowSeconds, $pollSeconds) -ForegroundColor Gray

if (-not (Get-Process -Name "AdGuardVpnSvc" -ErrorAction SilentlyContinue) -and
    -not (Get-Process -Name "AdGuardVpn" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] AdGuard VPN is not running - start it first" -ForegroundColor Red
    Wait-AnyKey
    exit 1
}
Write-Host "[OK] AdGuard VPN is running" -ForegroundColor Green

$logFiles = Get-AdguardLogFiles -logDirectory $logDir
if ($logFiles.Count -eq 0) {
    Write-Host "[ERROR] No AdGuard VPN logs found in $logDir" -ForegroundColor Red
    Wait-AnyKey
    exit 1
}
foreach ($f in $logFiles) { Write-Host ("[OK] Log: {0}" -f $f.FullName) -ForegroundColor Gray }

$ksState = Get-KillSwitchState -logFiles @($logFiles | ForEach-Object { $_.FullName })
Write-Host (" Kill switch (tunnel level): {0}" -f $ksState) -ForegroundColor $(if ($ksState -eq 'False') { "Green" } elseif ($ksState -eq 'True') { "Red" } else { "Yellow" })
if ($ksState -eq 'True') {
    Write-Host "[ERROR] Kill Switch is ON - it drops Zapret-processed packets and breaks the tunnel." -ForegroundColor Red
    Write-Host "         Turn it off in AdGuard VPN settings, then RECONNECT the VPN (the setting" -ForegroundColor Yellow
    Write-Host "         applies only when tunnel settings are recreated) and re-run this test." -ForegroundColor Yellow
    $override = Read-Host "Override and continue anyway? y/N"
    if ($override -notmatch '^[yY]') { Wait-AnyKey; exit 1 }
}

# VPN carrier exclusion coverage (see README: --wf-raw-part)
$listsDir = Join-Path $rootDir "lists"
$fragFile = Join-Path $listsDir "windivert-part-exclude.txt"
$endpoint = $null
$agentNewest = @($logFiles | Where-Object { $_.FullName -match '\\agent\\' }) | Select-Object -First 1
if (-not $agentNewest) { $agentNewest = $logFiles | Select-Object -First 1 }
if ($agentNewest) {
    try {
        $m = Select-String -Path $agentNewest.FullName -Pattern 'Using endpoint:.*address=([0-9.]+):\d+' -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($m) { $endpoint = $m.Matches[0].Groups[1].Value }
    } catch { }
}
$carrierExcluded = $false
if ($endpoint -and (Test-Path $fragFile)) {
    try {
        $frag = [IO.File]::ReadAllText($fragFile)
        if ($frag -match ([regex]::Escape("ip.DstAddr != $endpoint"))) { $carrierExcluded = $true }
    } catch { }
}
if ($endpoint) {
    if ($carrierExcluded) {
        Write-Host ("[OK] VPN carrier ({0}) excluded from Zapret capture at kernel level" -f $endpoint) -ForegroundColor Green
    } else {
        Write-Host ("[WARN] VPN carrier ({0}) is NOT excluded from Zapret capture." -f $endpoint) -ForegroundColor Yellow
        Write-Host "       Run the monitor (menu 13) once - it tracks the endpoint and writes the exclusion." -ForegroundColor Yellow
    }
}

if (-not (Get-Process -Name "winws" -ErrorAction SilentlyContinue)) {
    Write-Host "[WARNING] Zapret (winws.exe) is NOT running - start it (menu 13 or a preset)." -ForegroundColor Yellow
    Write-Host "          The test is only meaningful with Zapret running." -ForegroundColor Yellow
} else {
    Write-Host "[OK] Zapret (winws.exe) is running" -ForegroundColor Green
}

# monitor log for correlation (today's file)
$monitorLog = Join-Path $resultsDir ("monitor_log_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd"))
$monitorOffset = 0
if (-not (Test-Path $monitorLog)) { $monitorLog = $null } else {
    # start correlating from the current end: only in-window events matter
    $monitorOffset = @(Get-Content $monitorLog).Count
}

# ---- snapshot offsets -----------------------------------------------------------
$offsets = @{}
foreach ($f in $logFiles) {
    # seek past the historical part: read everything once, discard, keep the offset
    $off = 0
    [void](Read-NewLogLines -file $f.FullName -offset ([ref]$off))
    $offsets[$f.FullName] = $off
}

# ---- guided steps ----------------------------------------------------------------
Write-Host ""
Read-Host "Step 1: make sure Zapret is running (it is, per the check above). Press Enter"
Read-Host "Step 2: connect AdGuard VPN to a location now. After connecting, DO NOT change locations or settings (each change forces a tunnel recreate). Press Enter once connected"

$reportFile = Join-Path $resultsDir ("adguard_vpn_test_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
$reportHeader = @(
    "AdGuard VPN compatibility test - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Window: ${windowSeconds}s | Kill switch at start: $ksState | winws: $(if (Get-Process -Name 'winws' -ErrorAction SilentlyContinue) { 'running' } else { 'NOT running' })",
    ""
)
Set-Content -Path $reportFile -Value $reportHeader -Encoding UTF8

$allEvents = @()
$monitorRestartEvents = @()

Write-Host ""
Write-Host ("Watching for {0}s (press any key to end early)...`n" -f $windowSeconds) -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($windowSeconds)
try {
    while ((Get-Date) -lt $deadline) {
        foreach ($f in $logFiles) {
            $off = $offsets[$f.FullName]
            $newLines = Read-NewLogLines -file $f.FullName -offset ([ref]$off)
            $offsets[$f.FullName] = $off
            foreach ($line in $newLines) {
                $allEvents += $line
                if ($line -match 'Health check has timed out|connection_timeout') {
                    Write-Host ("  [FAIL] {0}" -f $line) -ForegroundColor Red
                    Add-Content -Path $reportFile -Value "[FAIL] $line" -Encoding UTF8
                } elseif ($line -match 'VPN_SS_CONNECTED|Using endpoint') {
                    Write-Host ("  [VPN ] {0}" -f $line) -ForegroundColor Green
                    Add-Content -Path $reportFile -Value "[VPN ] $line" -Encoding UTF8
                } elseif ($line -match 'BlockUntunneled \(kill switch\) - True') {
                    Write-Host ("  [KS!] {0}" -f $line) -ForegroundColor Yellow
                    Add-Content -Path $reportFile -Value "[KS!] $line" -Encoding UTF8
                } elseif ($line -match 'Start disconnecting|disconnected') {
                    Write-Host ("  [VPN ] {0}" -f $line) -ForegroundColor DarkYellow
                    Add-Content -Path $reportFile -Value "[VPN ] $line" -Encoding UTF8
                }
            }
        }
        if ($monitorLog -and (Test-Path $monitorLog)) {
            $mLines = @(Get-Content $monitorLog | Select-Object -Skip $monitorOffset)
            $monitorOffset += $mLines.Count
            foreach ($line in $mLines) {
                if ($line -match 'Combined config started|winws disappeared|SWITCH|SITEFIX') {
                    $monitorRestartEvents += $line
                    Write-Host ("  [ZAP ] {0}" -f $line) -ForegroundColor Magenta
                    Add-Content -Path $reportFile -Value "[ZAP ] $line" -Encoding UTF8
                }
            }
        }
        $keyPressed = $false
        try { $keyPressed = [Console]::KeyAvailable } catch { }   # no console (redirected input)
        if ($keyPressed) {
            [void][System.Console]::ReadKey($true)
            Write-Host "  (ended early by keypress)" -ForegroundColor DarkGray
            break
        }
        Start-Sleep -Seconds $pollSeconds
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    throw
} catch {
    Write-Host "[WARN] Watch loop error: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---- verdict ------------------------------------------------------------------------
$verdict = Get-TestVerdict -eventLines $allEvents
Write-Host ""
if ($verdict.Ok) {
    Write-Host "VERDICT: PASS - no tunnel failures during the window." -ForegroundColor Green
    Add-Content -Path $reportFile -Value "VERDICT: PASS" -Encoding UTF8
    Write-Host "Zapret and AdGuard VPN coexist. Keep Kill Switch OFF permanently." -ForegroundColor Green
} else {
    Write-Host "VERDICT: FAIL - {$($verdict.Failures.Count)} failure event(s) during the window." -ForegroundColor Red
    Add-Content -Path $reportFile -Value "VERDICT: FAIL ($($verdict.Failures.Count) events)" -Encoding UTF8
    if ($monitorRestartEvents.Count -gt 0) {
        Write-Host "NOTE: Zapret restarted during the window (see [ZAP] lines). Re-run once more with a" -ForegroundColor Yellow
        Write-Host "      quiet monitor (start a preset manually instead of menu 13) to separate causes." -ForegroundColor Yellow
    }
    Write-Host "Next step: collect this report - if failures persist with a quiet monitor, the VPN role" -ForegroundColor Yellow
    Write-Host "moves to a non-intercepting tool (ByeDPI local proxy / WireGuard-class VPN)." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Report: $reportFile" -ForegroundColor DarkGray
Wait-AnyKey
