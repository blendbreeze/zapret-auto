# AdGuard / VPN compatibility kit

## Context

The user runs AdGuard for Windows (AdguardSvc.exe) alongside zapret and asks whether they can coexist. Technical reality: the conflict is **specific and configurable away**, not fundamental:

- **AdGuard's HTTPS filtering (MITM)** re-encrypts TLS through its driver → desync patterns (fakedsplit/multisplit, fake packets) no longer align on the wire, and TSPU sees AdGuard's TLS fingerprint. Main breaker. Fix: disable HTTPS filtering or add bypassed domains to its exclusions.
- **QUIC handling** — same story for UDP-443; covered by the same exclusions.
- **DNS filtering** — mostly orthogonal (zapret matches by SNI/hostname); keep, just ensure the DNS provider isn't blocked (README already advises `dns.google`).
- **Kill-switch/firewall WFP rules** can drop zapret's deliberately-malformed fakes → whitelist/disable while bypassing.
- **True VPNs** (WireGuard/OpenVPN/Amnezia) coexist at driver level — desync is just pointless inside a tunnel. GoodbyeDPI-style tools are the real driver collision (`WinDivert`/`WinDivert14`) — diagnostics already auto-remediates.
- **Cleanest alternative**: browser-extension ad-blocking (no driver) instead of the system-wide app.

Current repo state: AdGuard is only *detected* (`service.bat:468-476`, red warning + issue #417 link, no remedy); README has zero AdGuard/VPN guidance; the raw material for exclusions is the four hostlist files (`list-important`, `list-google`, `list-general`, optional `list-general-user` — 211k lines).

**Scope (user absent — recommended defaults taken):** full kit — README guide + exclusions export tool (menu 15) + actionable diagnostics warning + site-fixer hint. Both export formats. Curated lists by default, user list opt-in.

## Implementation

### 1. New tool: `utils/export adguard.ps1` (~200 lines, checker/monitor style)

- Loads and normalizes domains from `list-important.txt`, `list-google.txt`, `list-general.txt` (reuse `Normalize-Domain` from the checker verbatim; `^regex` entries → strip `^`, keep only if the remainder is a valid domain, else skip with a count). Dedup by suffix (`domain == entry or endswith .entry`), preserving first occurrence.
- **HTTPS exclusions export** → `lists/adguard-https-exclusions.txt`: plain domains, one per line, header comment `# Paste into AdGuard: Настройки → Защита → HTTPS-фильтрация → Исключения` — for AdGuard's exclusion field (subdomains covered automatically by AdGuard).
- **DNS allowlist export** → `lists/adguard-dns-allowlist.txt`: `@@||domain^$important` per line with `!` comment header — importable in AdGuard as a custom filter so DNS filtering never touches bypassed domains.
- Interactive prompt (repo Y/N style, default N): include `list-general-user.txt` (211k lines) — off by default, impractical for the UI field; `-IncludeUserList` param for non-interactive use.
- Prints per-source counts + skipped-entry count; opens the HTTPS file in notepad and `explorer /select` the folder (mirrors `:hosts_update` UX, service.bat:1148-1209). No admin required.
- Both output files added to `.gitignore` (generated from personal lists).

### 2. service.bat: menu option 15

- Menu block: `15. Export AdGuard exclusions` under `:: TOOLS`, dispatch `goto service_adguard`, prompt `(0-15)`.
- `:service_adguard` handler: PowerShell ≥3.0 check (copy `:run_tests` pattern), then run **inline** (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\export adguard.ps1"`) + `pause` — the tool is fast and its console output matters, unlike the long-running windowed tools.

### 3. Diagnostics upgrade (`service.bat:468-476`)

Keep the existing red AdGuard lines + issue link, append two yellow remedy lines: disable HTTPS filtering in AdGuard or add bypassed domains to its exclusions (`Run 15. Export AdGuard exclusions` exports the ready list; see README).

### 4. Site-fixer hint (`utils/monitor zapret.ps1`)

In `Invoke-SiteFixCycle`'s exhaustion path (no candidate cured the site): if `AdguardSvc.exe` is running (cheap `tasklist` check), log a yellow hint that AdGuard's HTTPS filtering may be breaking the site and point at menu 15 / the README. Also log the same hint once at startup if AdGuard is detected while site-fixing is enabled (DarkGray, informational).

### 5. README: new section `## 🛡️Совместимость с AdGuard и VPN`

Placed after the Important Sites section, before the FAQ. Content (Russian):
- Mechanics summary table (HTTPS MITM / QUIC / DNS / kill-switch) — why the conflict happens
- Recommended compatible setup: HTTPS filtering off **or** exclusions via menu 15 export; keep DNS filtering with an unblocked provider; QUIC covered by the same exclusions
- Browser-extension alternative (no driver, zero conflict)
- VPN notes: true VPNs coexist but make desync pointless inside the tunnel; kill-switches drop fakes; GoodbyeDPI/WinDivert14 collision → Run Diagnostics handles it; AdGuard note cross-referenced from the diagnostics message
- How to import the DNS allowlist as a custom filter; exclusion list covers subdomains
- One-line cross-reference added to the Important Sites section

## Files
- **Created**: `utils/export adguard.ps1`
- **Modified**: `service.bat` (menu 15 + handler + diagnostics lines), `utils/monitor zapret.ps1` (two hint logs), `README.md` (new section + menu description line for 15), `.gitignore` (+2 export files)
- **Generated at runtime** (gitignored): `lists/adguard-https-exclusions.txt`, `lists/adguard-dns-allowlist.txt`

## Verification

1. Syntax checks (new ps1 + monitor).
2. AST-extracted tests for the export logic (mirror `_test_checker.ps1`): domain loading from the real lists (assert `^dns.google` → `dns.google` kept, invalid junk skipped, dedup), HTTPS file format (plain domains, header), DNS file format (`@@||…^$important`), user-list inclusion flag on/off, re-run idempotency (same output).
3. `service.bat` menu review: option 15 dispatch, `(0-15)` prompt, handler — plus a dry `git status` audit (no stray files).
4. **Live (user)**: menu 15 → two files generated + notepad opens → paste HTTPS list into AdGuard exclusions → with HTTPS filtering still on, `itch.io` (which currently fails under AdGuard) should open; alternatively re-run Run Diagnostics to see the new actionable AdGuard lines.
