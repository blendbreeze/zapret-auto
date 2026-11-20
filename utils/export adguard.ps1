# EXPORT ADGUARD EXCLUSIONS
# Generates paste-ready domain lists so AdGuard's HTTPS filtering / DNS
# filtering never touch the domains zapret handles:
#   lists/adguard-https-exclusions.txt - plain domains for AdGuard's
#       "Settings -> Protection -> HTTPS filtering -> Exclusions" field
#   lists/adguard-dns-allowlist.txt    - @@||domain^$important rules,
#       importable in AdGuard as a custom filter
#
# Sources: lists/list-important.txt, list-google.txt, list-general.txt and
# (opt-in, it is huge) list-general-user.txt.
#
# Override: -IncludeUserList switch skips the interactive question.

param([switch]$IncludeUserList)

$rootDir = Split-Path $PSScriptRoot
$listsDir = Join-Path $rootDir "lists"

$httpsFile = Join-Path $listsDir "adguard-https-exclusions.txt"
$dnsFile = Join-Path $listsDir "adguard-dns-allowlist.txt"

# ---- domain loading (same normalization as "check important.ps1") ----------
function Convert-ListEntry {
    param([string]$raw)
    $d = $raw.Trim()
    if (-not $d -or $d.StartsWith("#")) { return $null }
    $d = $d -replace '^\^+', ''          # zapret regex anchor -> plain suffix
    $d = $d -replace '^\w+://', ''       # strip scheme
    $d = ($d -split '/')[0]              # strip path
    $d = ($d -split ':')[0]              # strip port
    $d = $d.TrimEnd('.').ToLowerInvariant()
    if ($d -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') { return $null }
    return $d
}

$sources = @(
    @{ Name = 'list-important.txt'; Path = (Join-Path $listsDir 'list-important.txt') },
    @{ Name = 'list-google.txt'; Path = (Join-Path $listsDir 'list-google.txt') },
    @{ Name = 'list-general.txt'; Path = (Join-Path $listsDir 'list-general.txt') }
)

$userFile = Join-Path $listsDir 'list-general-user.txt'
$includeUser = $false
if (Test-Path $userFile) {
    if ($IncludeUserList) {
        $includeUser = $true
    } else {
        Write-Host ""
        $sizeKb = [Math]::Round((Get-Item $userFile).Length / 1KB)
        $answer = Read-Host ("Include lists\list-general-user.txt (~{0} KB, too big for AdGuard's UI field)? y/N" -f $sizeKb)
        if ($answer -match '^[yY]') { $includeUser = $true }
    }
}
if ($includeUser) {
    $sources += @{ Name = 'list-general-user.txt'; Path = $userFile }
}

# ---- load ----
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                ADGUARD EXCLUSIONS EXPORT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$domains = New-Object System.Collections.Specialized.OrderedDictionary
$skipped = 0
foreach ($src in $sources) {
    $count = 0
    if (Test-Path $src.Path) {
        Get-Content $src.Path | ForEach-Object {
            $d = Convert-ListEntry -raw $_
            if ($d) {
                if (-not $domains.Contains($d)) { $domains[$d] = $src.Name; $count++ }
            } else {
                $skipped++
            }
        }
    } else {
        Write-Host ("  [WARN] {0} not found - skipped" -f $src.Name) -ForegroundColor Yellow
    }
    Write-Host ("  {0}: {1} new domain(s)" -f $src.Name, $count) -ForegroundColor Gray
}
Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host (" Unique domains: {0} | skipped (comments/invalid): {1}" -f $domains.Count, $skipped) -ForegroundColor Gray

if ($domains.Count -eq 0) {
    Write-Host "[ERROR] No domains collected - nothing to export" -ForegroundColor Red
    exit 1
}

# ---- HTTPS exclusions file (body is pure domains: safe to paste wholesale)
Set-Content -Path $httpsFile -Value @($domains.Keys) -Encoding UTF8

# ---- DNS allowlist file (AdGuard filter format, comments allowed)
$dnsLines = @(
    "! Zapret -> AdGuard DNS allowlist (import as a custom filter)",
    ("! Generated {0} from: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), (($sources | ForEach-Object { $_.Name }) -join ", ")),
    "! Keeps AdGuard's DNS filtering away from the domains zapret handles",
    "! NOTE: DNS filtering does not fix HTTPS filtering - exclusions for that are in adguard-https-exclusions.txt",
    ""
)
$dnsLines += @($domains.Keys | ForEach-Object { "@@||" + $_ + "^`$important" })
Set-Content -Path $dnsFile -Value $dnsLines -Encoding UTF8

Write-Host ""
Write-Host ("[OK] {0}" -f $httpsFile) -ForegroundColor Green
Write-Host "     Paste the domains into: Settings -> Protection -> HTTPS filtering -> Exclusions" -ForegroundColor DarkGray
Write-Host ("[OK] {0}" -f $dnsFile) -ForegroundColor Green
Write-Host "     Import as a custom filter in AdGuard (AdGuard DNS filtering bypass)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Reminder: HTTPS filtering is the part that breaks zapret's desync -" -ForegroundColor Yellow
Write-Host "exclusions fix it; plain ad-blocking and DNS filtering can stay on." -ForegroundColor Yellow

Start-Process notepad.exe $httpsFile
Start-Process explorer.exe ("/select," + $httpsFile)
