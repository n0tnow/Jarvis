# JARVIS.app — packaging, installation and lifecycle (V0.15)

Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (installed copy launched through LaunchServices, no Terminal) · MANUAL TEST REQUIRED.

## Producing the app
`scripts/package-app.sh` → `build/package/JARVIS.app` (release build · bundle · icon · packaged setup scripts · signature · verification). `scripts/install-app.sh` → `/Applications/JARVIS.app` (atomic swap, no root, never touches Application Support, never overwrites a newer version, refuses while JARVIS runs). `scripts/verify-installed.sh [path]` launches an installed copy like Finder does and checks it. These scripts are for building a release; **running JARVIS never needs them, Terminal, `swift run`, Xcode, a development server or the repository.**

## Bundle
* Name `JARVIS.app`, executable `Contents/MacOS/Jarvis`, bundle id `dev.jarvis.Jarvis` (unchanged, so existing macOS permissions and preferences carry over), version 0.15.0, build = commit count, `JarvisBuildCommit` in Info.plist (developer diagnostics only), `LSUIElement` (menu-bar agent, no Dock icon), min macOS 14.
* Icon: a TEMPORARY, programmatically drawn mark (`scripts/make-app-icon.swift`: the HUD's ice-cyan core ring on ink). Replace it by adding `Resources/AppIcon.icns`; the script prefers that file.
* `Contents/Resources/setup/scripts/` holds the four pinned setup scripts and their worker files for the typed Set Up buttons. **No model, runtime, database, fixture or test resource is inside the bundle** (size ≈ 31 MB).
* Mutable data never lives inside the app: durable data `~/Library/Application Support/JARVIS/`, disposable data `~/Library/Caches/JARVIS/`, models under `~/AI/models/` or a folder you select. Replacing the app never touches them.

## Signing and security model (honest)
* Signature: the first valid code-signing identity in the keychain (names only are read), otherwise **ad-hoc** (this Mac has none). Hardened runtime ON. Single entitlement: `com.apple.security.device.audio-input`. **Not sandboxed** — Computer Use (Accessibility), provider CLIs, the local model helpers, Unity and the MCP sandbox need what the App Sandbox forbids. The security model is the one in `AGENTS.md` (typed capabilities, approvals, no shell, no credentials). **Not notarized**: not required for a private build opened from Applications on this Mac; a copy that is downloaded would need notarization (future distribution). Info.plist keeps exactly one privacy key (microphone).
* Development mode vs installed mode: a bare binary or `build/Jarvis.app` is *development* (live tests, captures, `--smoke-test`); `JARVIS.app` outside the repository is *installed*. Installed mode assumes no repository, no source tree, no `.build`, no working directory, no test resources.

## Lifecycle
* **Launch**: menu-bar item first; no model, provider, MCP server, Unity, vision helper, Whisper or screen capture starts. Only cheap, non-prompting reads (provider status probes, availability lists) run after launch.
* **Single instance**: a plain launch (no `--flag`) hands over to the running copy (LaunchServices running-application list, a distributed notification shows the Compact HUD); reopening from Finder shows the Compact HUD. Developer / live-test launches are exempt.
* **Launch at Login**: Settings → Startup, `SMAppService.mainApp` — OFF by default, state read from macOS, visible and removable in System Settings → Login Items. No LaunchAgent, daemon, plist or helper tool.
* **Quit** (menu bar, ⌘Q, Full HUD): speech stops, microphone closes, owned providers / MCP processes / models stop, screen capture stops, interrupted tasks are recorded (resume is explicit). Unity and Blender are never force-quit.
* **Crash**: the V0.4–V0.14 reconciliation runs on relaunch (stale runs → INTERRUPTED, dead sandboxes removed, experiments cleaned); nothing destructive is replayed, no stale voice or UI-coordinate action is restored.
* **Updates**: no self-update. Version + build are shown in Settings → About; an update is a new `JARVIS.app` installed over the old one with `install-app.sh` or Finder. Automatic updating may come after V1.0.

## Verification (this Mac)
See `PROJECT_STATE.md` (package checks, installed-app check, `--packaging-live-test`, cold launch, idle).

## V1.0 stabilisation fix 2
Signing identity check: this Mac has no stable Developer ID / development identity usable for JARVIS (see the final report of fix 2), so the app stays ad-hoc signed; every rebuild invalidates the macOS Microphone / Accessibility grants (JARVIS-V15-11) — grant them once after installing the build you will keep using. TCC was not reset and no credential was touched. Application Support, the database, settings and models are untouched by an install.
