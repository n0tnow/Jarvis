# Asset Acquisition (V0.9)

> Status: IMPLEMENTED · AUTOMATED TESTED · REAL TESTED (a real CC0 file from Poly Haven, md5-verified, into the quarantine; import only on disposable fixtures) · **MANUAL TEST REQUIRED**. Companion: `WEB_RESEARCH.md`. Decisions: DEC-095…097.

Acquisition turns a researched **candidate** into a **file in the quarantine** — nothing more. It never imports into a project, never executes anything, never signs in, never pays.

```
discovered → verifying → eligible ─────────────→ downloading → downloaded → inspecting → readyForImport
                       ↘ approvalRequired → approved ↗                                   ↘ rejected / failed
(any non-terminal) → cancelled | interrupted (restart; explicit user resume only)
```
`AcquisitionState.canMove` validates every transition; each is persisted (`acquisitions`).

## 1. Policy matrix (`AcquisitionPolicy.evaluate`, DEC-096)

| Candidate | Result |
|---|---|
| purchase required / paid | **rejected**: "PURCHASE REQUIRED — JARVIS never purchases anything" (commercial authority, not implemented) |
| free but needs a login / marketplace "claim" | **rejected**: "ACCOUNT ACTION REQUIRED" — open the listing in your own browser (account authority, not implemented) |
| no verified download route | rejected (class UNKNOWN) |
| public direct download, `FREE_VERIFIED` ≤ 24 h, licence allows commercial use + modification (official source), source trust ≥ 3, ≤ 100 MB | **eligible** (automatic) |
| anything else on a public download (price UNKNOWN or stale, licence unknown/needs review, untrusted origin, large) | **approval required**, with the exact reasons |

Approval is a normal V0.4/V0.5 HUD approval ("Download “X” from host into the JARVIS quarantine"). Approval **never grants capabilities** and a spoken "yes" is never a decision (voice has no authority). Before the download the candidate is **re-verified now** (price/licence from its own listing), because a result from yesterday is not a decision today.

## 2. Download (`Downloader`, DEC-095)

* https only (configurable only for fixtures); every redirect hop revalidated by the URL gate; post-connection address check; no cookies/credentials.
* Limits: 250 MB per file, 600 MB per session, 30 s idle, 900 s overall, 5 redirects, free disk ≥ 2× the limit.
* Streams into `download.part` (0600), hashes **incrementally** (SHA-256 + MD5). A publisher checksum (Poly Haven md5, GitHub asset digest) is **compared, never invented**: mismatch ⇒ file deleted, failure reported.
* The `.part` file is deleted unless the transfer completed (length matches), was verified and sniffed. Cancel/short/oversize/mismatch never leave an artifact.
* Content sniffing (`ArtifactSniffer`): a login page saved as `pack.zip`, a MIME that lies (zip served as image/png), Mach-O/ELF/PE/script/installer types are refused. Native libraries are allowed only as flagged content *inside* an archive.
* The macOS download-quarantine attribute (`com.apple.quarantine`) is set on every stored file.
* Filename sanitisation (ASCII, no traversal, ≤ 100 chars). Files live in `Application Support/JARVIS/acquisitions/<id>/` — never in a project.

## 3. Inspection (`ArchiveInspector`)

Archives are **listed before anything is extracted**: ZIP (incl. ZIP64, central directory bounded), tar.gz and `.unitypackage` (listing only). Rejected: path traversal (`..`), absolute paths, drive letters, symlinks, device/special files; duplicate names are flagged and refused at extraction, > 5,000 entries, > 1.5 GB uncompressed, > 700 MB per entry, compression ratio > 150, depth > 40, names > 512. Extraction (`extractZIP`, own `RawInflater` on Apple's Compression) enforces declared sizes **while inflating** (a header that lies about sizes aborts at once), verifies CRC32, and refuses to write outside the destination. Findings flag scripts, `Editor` scripts, native libraries and executables (`CodeBearing`: none / scripts / editorScripts / nativeLibraries / unknown). rar/7z and other unknown archive types are rejected as **uninspectable**. Trust ladder: `DOWNLOADED → INSPECTED → VALIDATED_FOR_IMPORT | REJECTED` — *downloaded is never trusted*.

`provenance.json` (beside the artifact): source page, sanitized download URL and host, publisher, version, licence id + source, price state + verified time, SHA-256, published checksum result, detected type, inspection summary, timestamps.

## 4. Import (a separate task; DEC-097)

Not part of acquisition. `TaskEngine.submitImport` creates a **V0.4 development task** with the extra capability `importIntoProject`:

1. plan: destination `Assets/ThirdParty/<slug>-<id6>`, the files that will be copied, the files **skipped** (scripts/editor scripts/native/executables unless explicitly approved), total bytes, flagged items;
2. approval (high risk) showing exactly that, the source and the licence;
3. `AssetImporter.apply`: workspace-guarded, hash-verified against the quarantine copy, never overwrites, only from a `readyForImport` artifact, writes `JARVIS-PROVENANCE.json` into the folder;
4. in a Unity project, a V0.6 compile step follows (the editor's own compiler decides).

Automated tests use disposable fixtures only; **the user's real game is never an automated test target**.

## 5. Measured (real, this Mac)

* Poly Haven CC0 model glTF (2.8–5.6 KB JSON entry file; the md5 was published by the vendor): research → eligible (no approval needed: FREE_VERIFIED, CC0, trusted origin) → downloaded → inspected → `READY FOR IMPORT` (the download of such a small file is not separately timed); the published md5 matched; the file carried the quarantine attribute; provenance written; **nothing imported by the acquisition itself**.
* Import of that same real artifact into a **disposable Git folder fixture** (not Unity, not your game): `submitImport` → approval → `AssetImporter` → `ThirdParty/<name>-xxxxxx/…` byte-identical (SHA-256) + `JARVIS-PROVENANCE.json`, task completed, acquisition record updated with the destination and the import task. (Non-Unity folders use `ThirdParty/`, Unity projects `Assets/ThirdParty/`.) The artifact was glTF JSON, so no Unity-editor import was attempted; the Unity compile step is exercised with the simulated editor in unit tests.
* Offline security fixtures (production URL policy, virtual public hosts): executable, HTML-as-zip, MIME-lying and script downloads refused; traversal, absolute-path, symlink and bomb archives rejected by inspection; lying-header zip aborts at extraction after < 1 KB.

## 6. Not done (honest)

Unity Asset Store and any login-bound "free" asset (account authority); `.unitypackage`/tar extraction and import (listed only); rar/7z; image/preview download (preview links are shown, never fetched); automatic update checks; purchases of any kind.

## V0.10 — asset memory

Acquisitions that reached READY_FOR_IMPORT, and imports, become asset-decision memories linked to the acquisition / import task and the destination (`modifies file:…`). They record what happened and why, not a permission: a later download or import still goes through the full V0.9 policy and approvals.
