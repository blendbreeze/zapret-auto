# AdGuard VPN carrier exclusion via --wf-raw-part (config-level, no recompile)

## Context (root cause now fully proven)

With Kill Switch ON, AdGuard VPN's tunnel dies under Zapret because the tunnel's own carrier (TCP to rotating endpoints like `208.77.165.15:443`, `201.8.95.x:443`) sits inside Zapret's WinDivert capture range (`--wf-tcp=80,443,...`). winws captures → re-injects → re-injected packets lose their WFP flow context → the kill switch drops them → health check times out (verified in both directions by the user's tests: KS ON fails, KS OFF works).

**The fix is already built into the bundled winws.exe** — discovered in upstream docs/binary (no recompile):
- `--wf-raw-part=<filter>|@<file>` — a partial WinDivert filter ANDed with `--wf-tcp/--wf-udp` (upstream `docs/windows.md`; the repo even ships `init.d/windivert.filter.examples/`)
- WinDivert filter language (verified against reqrypt.org docs): `ip.DstAddr != <ip>` / `ip.SrcAddr != <ip>` are valid network-layer conditions, bare `ipv6` is a boolean ("Is IPv6?"), `or`/`and` supported; **no** `ip.RemoteAddr` at the network layer, so both addresses must be excluded per endpoint
- Kernel-level exclusion: the carrier packets are never sent to winws at all → never re-injected → flow context intact → **Kill Switch can stay ON**

The endpoint rotates per location, so the exclusion must be dynamic: the monitor already owns the generated `general (CUSTOM).bat` and restarts winws — it will also track the VPN endpoint from AdGuard VPN's logs and regenerate the exclusion.

## Implementation

### 1. Fragment file: `lists/windivert-part-exclude.txt`
Content = one WinDivert filter fragment, e.g. for one endpoint:
```
ipv6 or (ip.DstAddr != 208.77.165.15 and ip.SrcAddr != 208.77.165.15)
```
(the `ipv6 or` branch keeps IPv6 traffic desynced — without it, the `ip.*` conditions would exclude all IPv6 from capture). Written/updated by the monitor; no VPN endpoint known → file absent → no raw-part arg → presets behave exactly as before.

### 2. Monitor (`utils/monitor zapret.ps1`) — endpoint tracking + exclusion lifecycle
- **Endpoint polling** (each main-loop iteration, cheap): tail the newest AdGuard VPN agent log (reuse the log-file discovery from the test tool) for the last `Using endpoint:.*address=([0-9.]+):\d+` line (regex verified against real log lines: `Using endpoint: name=cache-25.smart-pixl.net, address=201.8.95.149:443, relay=none, ping=72ms`).
- **State**: `monitor state.json` gains a `vpn` record `{endpoint, seen: [ip,...]}` (max 8 MRU) — same on-demand creation pattern as `sites`/`presets`; `Save-State` extended.
- **Fragment builder** `New-WindivertExcludeFragment`: one `ip.DstAddr != E and ip.SrcAddr != E` pair per seen endpoint (MRU order, max 8 → bounded filter size, 16 KB WinDivert limit is far away), wrapped as `ipv6 or ( ... )`.
- **On endpoint change** (new IP): update seen list → write fragment file → `New-CustomConfig` → restart winws → `Touch-SiteChecksAfterRestart` → log (`VPN endpoint 208.77.165.15 -> 201.8.95.149: exclude updated, Zapret restarted`). Unchanged endpoint → no action.
- **Generator** (`New-CustomConfig`): after the start line, if `lists/windivert-part-exclude.txt` exists and is non-blank → append ` --wf-raw-part="@<absolute lists path>windivert-part-exclude.txt"` (absolute path contains `:` — the service-install arg parser keeps quoted args containing `:` as-is, per its audited logic; verify with `sc qc zapret` after installing CUSTOM).
- VPN absent / never connected → no endpoint → no file → no raw-part → zero behavior change for non-AdGuard users.

### 3. Menu 15 test tool: exclusion pre-check
`utils/adguard vpn test.ps1` gains one pre-check line: current endpoint (from the same log regex) vs the fragment file → prints whether the carrier is excluded ("carrier excluded from Zapret: YES/NO") so a Kill-Switch-ON run of the test is meaningful. If the fragment is missing/stale → the tool says so and instructs running the monitor once.

### 4. README: update `## 🛡️Совместимость с AdGuard VPN`
- Kill Switch can now **stay ON**: Zapret excludes the VPN carrier at the kernel level via `--wf-raw-part` (upstream-supported option — no recompile); monitor tracks the rotating endpoint automatically
- Mechanism summary (capture/re-inject/flow-context loss) stays, now with the resolution
- How it works: `lists/windivert-part-exclude.txt` fragment + monitor regeneration on endpoint change; requirement: use menu 13 / launcher (monitor) for the exclusion to be dynamic
- Verification hint: `--wf-save` can dump the final WinDivert filter for inspection

### 5. Git
Commit on `adguard-vpn-fix` (message style: `adguard vpn carrier exclusion via wf-raw-part`).

## Files
- **Modified**: `utils/monitor zapret.ps1` (endpoint poll, fragment builder/writer, generator arg, state), `utils/adguard vpn test.ps1` (exclusion pre-check), `README.md`
- **Runtime-generated**: `lists/windivert-part-exclude.txt` (add to `.gitignore`)

## Verification
1. Syntax checks (monitor + test tool).
2. AST-extracted unit tests: endpoint regex against the 3 real log line shapes; fragment builder (1 endpoint, 3 endpoints, MRU rotation, >8 pruning); `ipv6 or (...)` structure; file write/rewrite; state round-trip of the `vpn` record.
3. Generated CUSTOM audit: start line contains `--wf-raw-part="@...windivert-part-exclude.txt"` only when the file is non-blank; absolute path.
4. **Filter validity**: run the generated config through `winws --wf-save=<tmp>` (filter construction happens before driver open — if it requires admin, note it for the user's live run); confirm the saved WinDivert filter contains the `ip.DstAddr != ...` conditions and parses (winws errors out on invalid filters before saving).
5. **Live (user)**: Kill Switch ON → menu 13 → connect AdGuard VPN → tunnel stays up (no `Health check has timed out` in the log), Zapret keeps working; endpoint change test: switch AdGuard VPN location → monitor log shows `VPN endpoint ... exclude updated` → tunnel survives the restart.
