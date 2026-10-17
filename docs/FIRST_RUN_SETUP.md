# First run, readiness and setup (V0.15)

Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED · MANUAL TEST REQUIRED.

## Is JARVIS ready to use?
Full HUD → **System** shows a *Readiness* card (read on appear and on **Recheck**, never polled): Core · Intelligence · Local AI · Voice · Computer Use · Unity · MCPs · Permissions · Startup. Each item has a state — READY (a safe check ran), AVAILABLE (present, not verified), NOT INSTALLED, SIGN-IN REQUIRED, PERMISSION NEEDED, OPTIONAL · NOT SET UP, NOT RUNNING (idle by design: Unity, MCP servers, models), DEGRADED, STALE, NOT CHECKED, UNAVAILABLE — and, when it makes sense, one button.
* Providers: Claude Code and Codex are READY only after the existing safe status probe (version + auth state, **no model call, no quota**); an executable that was never probed is only AVAILABLE; OpenCode is read lazily. JARVIS cannot sign in for you and never reads a credential store. **A Claude / ChatGPT sign-in is never permission to use a paid API; there is no paid API item to enable.**
* Local AI: the existing Qwen / vision / Whisper / memory-embedding installations are discovered where they are (`~/AI/models/...`, the configured model path) and are never downloaded again.
* Unity / MCP: shown from stored facts; nothing is started to fill the dashboard; MCP health is labelled stored, not live.
* The same picture answers “Claude hazır mı?” by voice or text, and **Settings → About → Show Diagnostics** gives a sanitised text (versions and states only).

## First launch of the installed app
The Full HUD opens on System with a six-step walk-through (Welcome · Permissions · Intelligence · Local models · Voice · Ready). Every step can be skipped; nothing in it is required; the app is fully usable without finishing it. It requests **no** permission by itself.

## Permissions (never faked, never auto-requested)
| Permission | Needed for | Requested |
|---|---|---|
| Microphone | Push-to-Talk / wake mode | when you press *Allow Microphone* or first use voice |
| Accessibility | Computer Use (operating other apps) | when you press *Allow Accessibility* (macOS shows its own prompt; only you can allow it) |
| Screen Recording | optional window-scoped visual grounding | only when you press its button |
| Notifications | optional task notifications | only when you switch task notifications on |
| Speech Recognition | not used (Apple on-device recogniser needs no prompt here) | — |
Direct buttons open the right System Settings pane. TCC is never reset by JARVIS.

## Typed setup (`SetupAction`, DEC-239)
A closed list: *Recheck*, the permission buttons, *Select Existing Model Folder*, and five installs — local model runtime, Whisper, natural voice + wake word, visual model, memory search. An install runs ONE script from `JARVIS.app/Contents/Resources/setup/scripts` (pinned revisions / SHA-256 inside the scripts; `uv` + PyPI + the pinned Hugging Face revision), directly (no shell string), with the provider environment allowlist (no keys), after a confirmation that shows source, size, destination; free space is checked (1.25× the installed size); progress is shown; **Cancel** kills the whole process tree; one setup at a time; a rerun resumes or repairs and an existing valid installation is reused. There is no URL or command field, no sudo, no installer for Claude Code / Codex / OpenCode / MCP servers, and no paid dependency. If `uv` is missing the app says so and starts nothing.
Large models are never bundled in the app; an already installed model is referenced where it is (validated: `config.json` + weights, inside your home or an external volume, no link leaving the folder).

## Disposable setup fixture
`--setup-live-test` (15 checks): missing tool, existing installation, interrupted `.part` then atomic resume, checksum mismatch, insufficient disk, cancel, duplicate request, non-executable and linked scripts, no URL/command action, no paid dependency, model-folder link escape, archive traversal / symlink rejection.

## V1.0 stabilisation fix 2
Wake Word remains OFF by default and is switched by you (Settings → Voice, the menu bar, or “wake word'ü aç”); the Hands-free overview shows Voice, Push-to-Talk, Wake Word, the detector state, the microphone, recognition, output and the session state in one place.

## V1.0 stabilisation fix 3
Settings is a destination in the Full HUD (gear, ⌘,). Wake Word is under Settings → Voice & Wake Word, with the real detector state beside the switch; System → Recheck re-reads every permission without a restart (Screen Recording applies after Restart JARVIS).
