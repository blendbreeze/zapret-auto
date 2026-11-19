# IMPORTANT SITES CHECKER
# Verifies that every domain from lists/list-important.txt actually opens.
# Domains from the list are wired into all presets as a hostlist, so a failure
# here means the current preset's desync strategy does not cover the site
# (the browser usually shows this as NS_BINDING_ABORTED / stalled load).
#
# Modes:
#   [1] Quick check   - probe the list under the currently running bypass
#   [2] Matrix        - probe the list against every preset, recommend the best
#
# Override via environment variables:
#   IMPORTANT_TIMEOUT         total curl timeout per attempt, seconds (default 12)
#   IMPORTANT_CONNECT_TIMEOUT curl connect timeout, seconds           (default 5)
#   IMPORTANT_ATTEMPTS        attempts per domain                     (default 2)
#   IMPORTANT_DELAY           pause between attempts, seconds         (default 3)

$hasErrors = $false

$rootDir = Split-Path $PSScriptRoot
$listsDir = Join-Path $rootDir "lists"
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $utilsDir "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

$timeoutSeconds = 12
$connectTimeout = 5
$attempts = 2
$delaySeconds = 3
if ($env:IMPORTANT_TIMEOUT) { [int]$timeoutSeconds = $env:IMPORTANT_TIMEOUT }
if ($env:IMPORTANT_CONNECT_TIMEOUT) { [int]$connectTimeout = $env:IMPORTANT_CONNECT_TIMEOUT }
if ($env:IMPORTANT_ATTEMPTS) { [int]$attempts = $env:IMPORTANT_ATTEMPTS }
if ($env:IMPORTANT_DELAY) { [int]$delaySeconds = $env:IMPORTANT_DELAY }
if ($attempts -lt 1) { $attempts = 1 }

# ---- Shared helpers (mirrors "test zapret.ps1" / "monitor zapret.ps1") -----
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

function Test-ZapretServiceConflict {
    return [bool](Get-Service -Name "zapret" -ErrorAction SilentlyContinue)
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

# ---- Domain loading and exclusion matching ---------------------------------
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
foreach ($name in @("list-exclude.txt", "list-exclude-user.txt")) {
    $file = Join-Path $listsDir $name
    if (Test-Path $file) {
        Get-Content $file | ForEach-Object {
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
    if (-not (Test-Path $file)) {
        Write-Host "[ERROR] lists\list-important.txt not found" -ForegroundColor Red
        Write-Host "         Add your priority domains there, one per line" -ForegroundColor Yellow
        return @()
    }
    $domains = @()
    $seen = @{}
    Get-Content $file | ForEach-Object {
        $d = Normalize-Domain -raw $_
        if ($d -and -not $seen.ContainsKey($d)) {
            $seen[$d] = $true
            $domains += $d
        }
    }
    if ($domains.Count -eq 0) {
        Write-Host "[ERROR] lists\list-important.txt is empty (or has no valid domains)" -ForegroundColor Red
        Write-Host "         Format: one domain per line, e.g. example.com" -ForegroundColor Yellow
    }
    return $domains
}

# ---- Probe engine ----------------------------------------------------------
$maxParallel = 8
$runspacePool = $null

$probeScriptBlock = {
    param($domain, $timeoutSeconds, $connectTimeout, $attempts, $delaySeconds)

    # Same stderr/stdout split as "test zapret.ps1"; any real HTTP status
    # (2xx-5xx, incl. bot-check 403) means the transport path works. Censors
    # kill connections, they don't answer with valid statuses.
    $lastDetail = ""
    for ($a = 1; $a -le $attempts; $a++) {
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
            # -L writes "%{http_code}" per redirect hop -> take the last code
            $codeStr = ($output | Out-String).Trim()
            $codes = [regex]::Matches($codeStr, '\d{3}')
            $code = if ($codes.Count -gt 0) { $codes[$codes.Count - 1].Value } else { $codeStr }
            if ($exit -eq 0 -and $code -ne "000" -and $code -match '^\d{3}$') {
                return @{ Ok = $true; Detail = "HTTP $code"; Attempts = $a }
            }
            $lastDetail = $stderr.Trim()
            if (-not $lastDetail) { $lastDetail = "curl exit $exit" }
            if ($lastDetail.Length -gt 70) { $lastDetail = $lastDetail.Substring(0, 70) }
        } catch {
            $lastDetail = $_.Exception.Message
            if ($lastDetail.Length -gt 70) { $lastDetail = $lastDetail.Substring(0, 70) }
        }
        if ($a -lt $attempts) { Start-Sleep -Seconds $delaySeconds }
    }
    return @{ Ok = $false; Detail = $lastDetail; Attempts = $attempts }
}

function Invoke-DomainProbes {
    # probes all domains in parallel; each domain retries internally
    param([array]$domains)
    if ($script:runspacePool -eq $null) {
        $script:runspacePool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(2, [Math]::Min($maxParallel, $domains.Count)))
        $script:runspacePool.Open()
    }

    $powers = @()
    $handles = @()
    foreach ($d in $domains) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($probeScriptBlock).AddArgument($d).AddArgument($timeoutSeconds).AddArgument($connectTimeout).AddArgument($attempts).AddArgument($delaySeconds)
        $handles += $ps.BeginInvoke()
        $powers += $ps
    }

    $results = @()
    for ($i = 0; $i -lt $powers.Count; $i++) {
        try {
            $out = $powers[$i].EndInvoke($handles[$i])
            $r = @($out)[0]
            if ($r) {
                $results += (New-Object PSObject -Property @{
                    Domain   = $domains[$i]
                    Ok       = [bool]$r.Ok
                    Detail   = [string]$r.Detail
                    Attempts = [int]$r.Attempts
                })
            } else {
                $results += (New-Object PSObject -Property @{ Domain = $domains[$i]; Ok = $false; Detail = "no result"; Attempts = 0 })
            }
        } catch {
            $results += (New-Object PSObject -Property @{ Domain = $domains[$i]; Ok = $false; Detail = "probe error"; Attempts = 0 })
        }
        $powers[$i].Dispose()
    }
    return $results
}

function Close-ProbePool {
    if ($script:runspacePool -ne $null) {
        try { $script:runspacePool.Close() } catch { }
        $script:runspacePool = $null
    }
}

# ---- Reporting -------------------------------------------------------------
function New-ReportFile {
    $reportFile = Join-Path $resultsDir ("important_sites_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
    $header = @(
        "Important sites check - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Timeout: ${timeoutSeconds}s | Connect timeout: ${connectTimeout}s | Attempts: $attempts | Delay: ${delaySeconds}s",
        ""
    )
    Set-Content -Path $reportFile -Value $header -Encoding UTF8
    return $reportFile
}

function Show-ResultsTable {
    param([array]$results, [System.Text.StringBuilder]$report)

    $maxLen = 10
    foreach ($r in $results) { if ($r.Domain.Length -gt $maxLen) { $maxLen = $r.Domain.Length } }

    foreach ($r in $results) {
        $excluded = Test-DomainExcluded -domain $r.Domain
        $padded = $r.Domain.PadRight($maxLen)
        if ($r.Ok) {
            Write-Host ("  {0}  OK    {1}" -f $padded, $r.Detail) -ForegroundColor Green
            if ($excluded) { Write-Host ("  {0}  [WARN] excluded by '{1}' - treatment will NOT apply to it" -f $padded, $excluded) -ForegroundColor Yellow }
            [void]$report.AppendLine(("  {0}  OK    {1}{2}" -f $padded, $r.Detail, $(if ($excluded) { "  [excluded by '$excluded']" } else { "" })))
        } else {
            Write-Host ("  {0}  FAIL  {1}" -f $padded, $r.Detail) -ForegroundColor Red
            if ($excluded) { Write-Host ("  {0}  [WARN] excluded by '{1}' - treatment will NOT apply to it" -f $padded, $excluded) -ForegroundColor Yellow }
            [void]$report.AppendLine(("  {0}  FAIL  {1}{2}" -f $padded, $r.Detail, $(if ($excluded) { "  [excluded by '$excluded']" } else { "" })))
        }
    }
}

# ---- Mode 1: quick check ---------------------------------------------------
function Invoke-QuickCheck {
    param([array]$domains)

    $winwsRunning = [bool](Get-Process -Name "winws" -ErrorAction SilentlyContinue)
    $serviceRunning = $false
    $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { $serviceRunning = $true }

    Write-Host ""
    if ($winwsRunning) {
        if ($serviceRunning) {
            Write-Host "[INFO] Bypass is running (service 'zapret') - probing through it" -ForegroundColor Cyan
        } else {
            Write-Host "[INFO] Bypass is running (standalone winws) - probing through it" -ForegroundColor Cyan
        }
    } else {
        Write-Host "[WARNING] Bypass is NOT running (no winws process)." -ForegroundColor Yellow
        Write-Host "          Results will reflect the RAW network without any bypass." -ForegroundColor Yellow
    }
    Write-Host ""

    $report = New-ReportFile
    $sb = New-Object System.Text.StringBuilder
    $results = Invoke-DomainProbes -domains $domains
    Show-ResultsTable -results $results -report $sb
    Add-Content -Path $report -Value $sb.ToString() -Encoding UTF8

    $okCount = @($results | Where-Object { $_.Ok }).Count
    Write-Host ""
    Write-Host ("Summary: {0}/{1} domains OK" -f $okCount, $results.Count) -ForegroundColor $(if ($okCount -eq $results.Count) { "Green" } else { "Yellow" })
    Add-Content -Path $report -Value "Summary: $okCount/$($results.Count) domains OK" -Encoding UTF8
    if ($okCount -lt $results.Count) {
        Write-Host "Sites that FAIL here are not covered by the current preset's strategy." -ForegroundColor Yellow
        Write-Host "Run mode [2] Matrix to find a preset that covers them." -ForegroundColor Yellow
    }
    Write-Host "Report: $report" -ForegroundColor DarkGray
}

# ---- Mode 2: matrix across presets ----------------------------------------
function Invoke-MatrixCheck {
    param([array]$domains)

    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[ERROR] Run as Administrator to test presets" -ForegroundColor Red
        $hasErrors = $true
    }
    if (Test-ZapretServiceConflict) {
        Write-Host "[ERROR] Windows service 'zapret' is installed" -ForegroundColor Red
        Write-Host "         Remove the service before running the matrix (menu 2)" -ForegroundColor Yellow
        $hasErrors = $true
    }
    if ($hasErrors) {
        Write-Host ""
        Wait-AnyKey -message "Press any key to exit..."
        exit 1
    }

    $presetFiles = Get-ChildItem -Path $rootDir -Filter "*.bat" | Where-Object { $_.Name -notlike "service*" } | Sort-Object { [Regex]::Replace($_.Name, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }
    if (-not $presetFiles -or $presetFiles.Count -eq 0) {
        Write-Host "[ERROR] No strategy .bat files found" -ForegroundColor Red
        Wait-AnyKey -message "Press any key to exit..."
        exit 1
    }

    Write-Host ""
    Write-Host "[WARNING] Each preset restarts the bypass - active connections will drop." -ForegroundColor Yellow
    Write-Host ("[INFO] {0} presets x {1} domains, up to {2} attempts each. This can take ~10 minutes." -f $presetFiles.Count, $domains.Count, $attempts) -ForegroundColor Cyan

    $snapshot = Get-WinwsSnapshot
    $env:NO_UPDATE_CHECK = "1"
    $report = New-ReportFile

    $matrix = @()
    try {
        $pNum = 0
        foreach ($file in $presetFiles) {
            $pNum++
            Write-Host ""
            Write-Host ("  [{0}/{1}] {2}" -f $pNum, $presetFiles.Count, $file.Name) -ForegroundColor Yellow
            Stop-Zapret

            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $rootDir -PassThru -WindowStyle Minimized
            if (-not (Wait-WinwsReady)) {
                if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
                Write-Host "  > Strategy failed to start (winws process not found). Skipping..." -ForegroundColor Red
                $row = New-Object PSObject -Property @{ Name = $file.Name; Index = $pNum; Started = $false; Results = @() }
                foreach ($d in $domains) {
                    $row.Results += (New-Object PSObject -Property @{ Domain = $d; Ok = $false; Detail = "preset failed to start"; Attempts = 0 })
                }
                $matrix += $row
                continue
            }

            # settle: give the strategy a moment before probing
            Start-Sleep -Seconds 2
            $results = Invoke-DomainProbes -domains $domains
            $okCount = @($results | Where-Object { $_.Ok }).Count
            Write-Host ("  > {0}/{1} domains OK" -f $okCount, $results.Count) -ForegroundColor $(if ($okCount -eq $results.Count) { "Green" } else { "DarkYellow" })
            $matrix += (New-Object PSObject -Property @{ Name = $file.Name; Index = $pNum; Started = $true; Results = $results })
        }
    } finally {
        Stop-Zapret
        Restore-WinwsSnapshot -snapshot $snapshot
        Close-ProbePool
    }

    # ---- matrix table (rows = presets, columns = domains)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "                 IMPORTANT SITES MATRIX" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $colWidth = 12
    $headerRow = "".PadRight(34)
    foreach ($d in $domains) { $headerRow += ("{0}" -f $d.Substring(0, [Math]::Min($colWidth - 1, $d.Length))).PadLeft($colWidth) }
    Write-Host $headerRow -ForegroundColor Gray
    Add-Content -Path $report -Value $headerRow -Encoding UTF8

    foreach ($row in $matrix) {
        $line = $row.Name.PadRight(34)
        foreach ($d in $domains) {
            $r = @($row.Results | Where-Object { $_.Domain -eq $d })[0]
            $cell = if ($row.Started) { $(if ($r.Ok) { "OK" } else { "FAIL" }) } else { "NOSTART" }
            $line += $cell.PadLeft($colWidth)
        }
        $score = @($row.Results | Where-Object { $_.Ok }).Count
        $line += ("  [{0}/{1}]" -f $score, $domains.Count)
        $color = if ($score -eq $domains.Count) { "Green" } elseif ($score -gt 0) { "Yellow" } else { "Red" }
        Write-Host $line -ForegroundColor $color
        Add-Content -Path $report -Value $line -Encoding UTF8
    }

    # ---- best preset: max OK count, tiebreak = earlier in natural order
    $best = $matrix | Sort-Object -Property @(
        @{ Expression = { @($_.Results | Where-Object { $_.Ok }).Count }; Descending = $true },
        @{ Expression = { $_.Index }; Ascending = $true }
    ) | Select-Object -First 1
    $bestScore = @($best.Results | Where-Object { $_.Ok }).Count

    Write-Host ""
    Write-Host ("Best preset: {0} ({1}/{2} important sites OK)" -f $best.Name, $bestScore, $domains.Count) -ForegroundColor $(if ($bestScore -eq $domains.Count) { "Green" } else { "Yellow" })
    Add-Content -Path $report -Value "" -Encoding UTF8
    Add-Content -Path $report -Value ("Best preset: {0} ({1}/{2} important sites OK)" -f $best.Name, $bestScore, $domains.Count) -Encoding UTF8

    # ---- per-domain coverage summary
    Write-Host ""
    Write-Host "Per-domain coverage:" -ForegroundColor Cyan
    Add-Content -Path $report -Value "Per-domain coverage:" -Encoding UTF8
    foreach ($d in $domains) {
        $covered = @($matrix | Where-Object { @($_.Results | Where-Object { $_.Domain -eq $d -and $_.Ok }).Count -gt 0 })
        $excluded = Test-DomainExcluded -domain $d
        $note = if ($excluded) { "  [excluded by '$excluded']" } else { "" }
        if ($covered.Count -eq $matrix.Count) {
            Write-Host ("  {0}: covered by ALL presets{1}" -f $d, $note) -ForegroundColor Green
            Add-Content -Path $report -Value ("  {0}: covered by ALL presets{1}" -f $d, $note) -Encoding UTF8
        } elseif ($covered.Count -gt 0) {
            $names = ($covered | ForEach-Object { $_.Name -replace '^general |\)$', '' -replace '^general$', 'base' }) -join ", "
            Write-Host ("  {0}: only {1}/{2} presets ({3}){4}" -f $d, $covered.Count, $matrix.Count, $names, $note) -ForegroundColor Yellow
            Add-Content -Path $report -Value ("  {0}: only {1}/{2} presets ({3}){4}" -f $d, $covered.Count, $matrix.Count, $names, $note) -Encoding UTF8
        } else {
            Write-Host ("  {0}: NOT covered by any preset{1}" -f $d, $note) -ForegroundColor Red
            Add-Content -Path $report -Value ("  {0}: NOT covered by any preset{1}" -f $d, $note) -Encoding UTF8
        }
    }

    Write-Host ""
    Write-Host "Report: $report" -ForegroundColor DarkGray
}

# ---- Startup ---------------------------------------------------------------
$host.UI.RawUI.WindowTitle = "zapret important sites checker"
$env:NO_UPDATE_CHECK = "1"

$domains = Get-ImportantDomains
if ($domains.Count -eq 0) {
    Write-Host ""
    Wait-AnyKey -message "Press any key to exit..."
    exit 1
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                IMPORTANT SITES CHECKER" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host (" Domains ({0}): {1}" -f $domains.Count, ($domains -join ", ")) -ForegroundColor Gray
Write-Host (" Timeout: ${timeoutSeconds}s | Connect: ${connectTimeout}s | Attempts: $attempts | Delay: ${delaySeconds}s") -ForegroundColor Gray

$excludedDomains = @($domains | Where-Object { Test-DomainExcluded -domain $_ })
if ($excludedDomains.Count -gt 0) {
    Write-Host (" [WARN] Excluded by exclude lists (treatment will NOT apply): {0}" -f ($excludedDomains -join ", ")) -ForegroundColor Yellow
}
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host ""
Write-Host "Select mode:" -ForegroundColor Cyan
Write-Host "  [1] Quick check (current bypass)" -ForegroundColor Gray
Write-Host "  [2] Matrix - test against ALL presets (restarts bypass, needs admin, no service)" -ForegroundColor Gray
$choice = Read-Host "Enter 1 or 2"

switch ($choice) {
    '1' { Invoke-QuickCheck -domains $domains }
    '2' { Invoke-MatrixCheck -domains $domains }
    default { Write-Host "Incorrect input." -ForegroundColor Yellow }
}

Write-Host ""
Close-ProbePool
Wait-AnyKey
