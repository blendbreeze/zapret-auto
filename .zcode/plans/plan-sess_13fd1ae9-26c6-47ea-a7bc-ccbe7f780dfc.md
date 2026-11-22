# FirefoxZapret: Firefox extension → native host → list-browser-user.txt

## Context

The user's idea: a Firefox WebExtension that watches for `NS_BINDING_ABORTED` request errors (their empirically observed signature of DPI kills: first request OK, follow-ups aborted), extracts the hostname, and delivers it to Zapret so the same treatment as `list-general-user.txt` applies automatically. Extensions can't write files → a **native messaging host** bridges them: a tiny C# exe (compiled with the in-box `csc.exe`, no toolchain downloads) that appends domains to the new `lists/list-browser-user.txt` and best-effort kills winws; the monitor's keepalive + a new list-mtime watcher restart Zapret to apply.

**User decisions**: separate `lists/list-browser-user.txt` wired into all presets (same scripted-edit pattern as `list-important.txt`); **auto-add every NS_BINDING_ABORTED host, always** (no thresholds, no popups, no curl verification — user accepted the false-positive trade-off; undo = remove the line from the list file); extension keeps a session + persistent memory of already-added hosts to skip re-reporting.

## Implementation

### 1. New directory `F:\Dev\blockings\FirefoxZapret`

```
FirefoxZapret/
├── README.md                        (RU primary: install, how it works, config, undo, caveats)
├── extension/
│   ├── manifest.json                (MV2; permissions: webRequest, nativeMessaging, storage, <all_urls>;
│   │                                 background persistent; browser_action popup;
│   │                                 applications.gecko.id = zapret-browser-list@localhost)
│   ├── background.js                (see logic below)
│   └── popup.html / popup.js        (status only: added-host count, last 5 hosts, native-host ping)
└── native-host/
    ├── host.cs                      (native messaging host, ~150 lines)
    ├── build.bat                    (compiles host.exe via in-box csc.exe)
    ├── nm-manifest.json             (template; register.bat patches absolute host.exe path into "path")
    ├── register.bat / unregister.bat (HKCU\SOFTWARE\Mozilla\NativeMessagingHosts\zapret_browser_list)
    └── config.json (optional; absent → defaults: listsPath = ..\..\zapret-discord-youtube\lists, killWinws = true)
```

### 2. Extension logic (`background.js`, MV2 persistent background)
- `browser.webRequest.onErrorOccurred` (urls `<all_urls>`): process only `details.error === 'NS_ERROR_ABORT' || details.error === 'NS_BINDING_ABORTED'` (the devtools label NS_BINDING_ABORTED maps to NS_ERROR_ABORT — match both for safety)
- Extract hostname via `new URL(details.url).hostname`, lowercase; sanity guards: must contain a dot, not an IP literal, not `localhost`/`.local`, not `moz-extension`
- Dedup: session `Set` + persistent `storage.local.addedHosts` (map host→timestamp); host-side file dedup is the final backstop
- Deliver via `runtime.connectNative('zapret_browser_list')` (persistent port, lazy connect, reconnect on disconnect): `{type:'add', host}`
- Badge: `browserAction.setBadgeText` = session-added count
- No thresholds, no confirmations (per user decision)

### 3. Native host (`host.cs` → `host.exe`)
- Chrome-style native messaging: 4-byte LE length + UTF-8 JSON frames on stdio; loop until stdin EOF
- `Handle(json)`: `type=add` → sanitize host (lowercase, strip scheme/port, domain-shape validation, length cap 253) → target file `<listsPath>\list-browser-user.txt` → ensure dir → **exact-dup check** (case-insensitive `File.ReadAllLines` contains) → `File.AppendAllLines` → best-effort `taskkill /IM winws.exe /F` when `killWinws:true` (fails silently when winws runs elevated — the monitor watcher covers that case) → respond `{"ok":true,"duplicate":...,"list":...}`
- `type=ping` → `{"ok":true,"version":"1.0","killSwitchApplied":...}` (popup status)
- `type=remove` → remove the host's line from the list (undo path) → respond
- Config: optional `config.json` beside host.exe (`{"listsPath": "...", "killWinws": true}`); default listsPath resolves `..\..\zapret-discord-youtube\lists` relative to host.exe
- Log each action to `host.log` beside the exe (append, timestamped) for debugging

### 4. Zapret repo wiring (branch `adguard-vpn-fix`)
- **Presets**: scripted insert (same pattern as list-important) of ` --hostlist="%LISTS%list-browser-user.txt"` after the `--hostlist="%LISTS%list-important.txt"` token on the two hostlist Strategy lines per preset (sections 1 UDP + 5 TCP); **exclude `general (CUSTOM).bat`** (generated file — inherits wiring from its base preset via `New-CustomConfig`); expected **43 insertions** (21 presets ×2 + ALT5 ×1); dry-run first, idempotent, CRLF/UTF8-no-BOM preserved
- **service.bat** `:load_user_lists` (lines 121–136): bootstrap-create `list-browser-user.txt` (comment line + `domain.example.abc` placeholder, following the existing convention)
- **Monitor** (`utils/monitor zapret.ps1`): list-mtime watcher in the main loop — track `lists/list-browser-user.txt` LastWriteTimeUtc; on change **and winws still running** → `Log-Line "Browser list updated (FirefoxZapret) - restarting"` + `Stop-Zapret` + restart current config (when the host's taskkill already killed winws, the existing keepalive handles it — the watcher only restarts when nothing else did); initialize mtime at startup
- **.gitignore**: + `/lists/list-browser-user.txt` (user-specific learned list)

### 5. FirefoxZapret README (Russian, matching repo style)
- What it does + the mechanism chain (browser error → extension → native host → list → winws restart)
- Install: `native-host\build.bat` → `register.bat` → load extension via `about:debugging` (temporary) **or** self-sign on AMO (unlisted) for permanent use / DevEdition `xpinstall.signatures.required=false` — all three documented with trade-offs
- Enable in private windows (about:addons → permission)
- config.json fields; how to undo (remove line from `list-browser-user.txt` or use remove-message); caveats: benign NS_BINDING_ABORTED causes exist (per user decision every abort is added — a working site may get desynced; delete its line to undo); requirement: list applies after winws restart (automatic under the monitor)

## Files
- **Created**: `F:\Dev\blockings\FirefoxZapret\` tree (README, extension×4 files, native-host×6 files)
- **Modified** (zapret repo, branch `adguard-vpn-fix`): 21 presets + ALT5 (43 insertions), `service.bat` (bootstrap), `utils/monitor zapret.ps1` (list-mtime watcher), `.gitignore`
- **Generated at runtime**: `lists/list-browser-user.txt`, `native-host/host.exe`, `host.log`

## Verification
1. **host.exe**: `build.bat` compiles clean via csc; automated NM protocol test — PS script writes frames (`ping`, `add` new host, `add` duplicate) to host stdin via redirected pipes and asserts JSON responses + list-file content + dedup; `remove` test
2. **Wiring**: dry-run count 43 (0 warnings) → apply → grep audit (43 lines, CUSTOM excluded, insertion after list-important token)
3. **Bootstrap**: grep `list-browser-user.txt` in service.bat `:load_user_lists`
4. **Extension**: manifest.json JSON-validates; background.js syntax-checked (node --check if available, else parser-careful review)
5. **Live (user)**: register host → load extension via about:debugging → browse a site that dies under the current Strategy → popup shows the added host, `lists/list-browser-user.txt` contains it, Zapret restarts (monitor log line), site opens on reload; then flip Kill Switch test conclusion: coexistence unaffected

## Commit
Zapret-repo changes committed on `adguard-vpn-fix` (`firefox browser list wiring + monitor watcher`). `FirefoxZapret/` left unversioned (user may `git init` it separately).
