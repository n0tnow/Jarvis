# Unity Development Operator (V0.13)

Extends the V0.6 Unity Project Agent. Same rules: Unity is reached **only** through the typed `UnityOperation` enum and the JARVIS-owned Editor bridge (local file spool). No operation carries C#, a menu item, a shell line, a URL or reflection; no third-party MCP; no network; no package install / project upgrade. Bridge version **0.13.0**.

## 1. Operations (`UnityDevOp`, 23, closed)

Scene: `createScene` (goal must ask for it) · `sceneProfile` · hierarchy: `editGameObject` (rename / parent / sibling / transform / active / tag / layer / static) · `duplicateGameObject` · `removeComponent` (goal must ask; asks the user) · `setObjectReference` · `configureComponent` (kinds: light, camera, renderer, rigidbody, collider, characterController, audioSource, animator, canvas / UI, input) — every setting is whitelisted, typed and range-checked in Swift (`UnityComponentSchema`) and equal to the bridge's accepted keys (a parity test fails otherwise).
Prefabs: `instantiatePrefab` · `prefabOverrides` · `revertPrefabOverrides` · `applyPrefabOverrides` (asks) · `createPrefabVariant` · `unpackPrefab` (goal + asks).
Assets: `inspectAsset` · `createMaterial` · `setMaterialProperty` · `setModelImporter` (asks) · Animator controllers: `createAnimatorController` · `editAnimatorController` (states, parameters, transitions, conditions).
Lighting: `inspectLighting` · `setEnvironment` (ambient, fog, skybox properties — never the render pipeline).
Observation: `inspectRuntime` (Play Mode: animator state, normalized time, audio playing, pose) · `captureView`.

## 2. Capability priority

Typed JARVIS operation > structured data > controlled CLI > browser DOM > Accessibility > window-scoped vision > coordinates (V0.11 ladder). Scene work **never** falls to the GUI while the bridge is up.

## 3. Safety (Swift **and** bridge)

* Play Mode / compiling: persistent changes are refused by `UnityPolicy` first and by the bridge (`playModeMutationBlocked`) even if the policy were bypassed. Reads and captures stay allowed.
* The user's **dirty scene** is protected for scene-touching ops only; saving needs the existing approval.
* Per-action approval (`session.approvedActions`): `applyPrefabOverrides`, `setModelImporter`, `removeComponent`, `unpackPrefab`. Only overrides JARVIS touched can be reverted / applied.
* Every edit is **verified by the editor's own read-back** (`UnityDevVerifier`, idempotent second pass). No read-back ⇒ not passed.
* Unity 6000.5 specifics are handled behind `#if UNITY_6000_5_OR_NEWER`.

## 4. Capture and inspection

`captureView` renders the Game camera into memory (PNG read, spool file deleted at once). Objective analysis comes from the editor: frustum, area fraction, contrast against the surroundings, luminance statistics, magenta fraction. An owned editor that must render is (re)launched **with a graphics device but without a window** (`-batchmode` without `-nographics`).

## 5. Observe → act → inspect → correct

`UnityCorrectionSpec` on a `unityEdit` step: capture → if not clearly visible, `OperatorCorrection.plan` picks a deterministic fix (aim the camera / add a fill light / raise the brightest light / raise the ambient) → apply through the same typed ops → capture again. Default 2 rounds (never more than the session bound); when nothing objective is left to try it **reports**, it does not loop. Taste words ("beautiful", "cinematic", "güzel") are labelled SUBJECTIVE and are never corrected or counted as a passed check.

## 6. Known limits

* Experiments and the correction loop run in the built-in pipeline; URP mirroring is not done (documented in docs/EXPERIMENTATION.md).
* Audio output is not heard by JARVIS: `isPlaying` and the configured clip are the evidence; "sounds right" is the user's call.
* Unity packages (URP, ugui, test framework) are not bundled offline; the registry is Unity's own traffic.

## 7. Tests

Automated: `UnityOperatorTests`, `UnityOperatorEngineTests` (simulated editor), parity + boundary tests. Real: `--operator-live-test` (real Unity 6000.5.1f1 on a disposable fixture; 83 checks for the operations, plus the correction and experiment sections). Evidence labels: REAL · ENGINE (real engine, scripted planner) · POLICY.
