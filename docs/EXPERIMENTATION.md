# Experimentation (V0.13)

"We do not know whether X works. Can we test it **safely**?" An experiment is not self-improvement and not a way to touch a user's project. Code: `Sources/Jarvis/Experiments/`, `TaskEngine+Experiment.swift`.

## 1. Contract (`ExperimentSpec`)

question · hypothesis · kind (`assetImport` / `materialRender` / `animationPlayback`) · optional quarantined acquisition id · asset paths inside the disposable `Assets/` · success criteria · failure criteria · bounds (≤ 20 min, ≤ 2 GB, ≤ 6 artifacts, **0 network**) · cleanup = delete. `ExperimentValidator` rejects: a missing part, an unbounded part, a path outside `Assets/`, a command-like criterion (`rm -rf`, `sudo`, `curl`, `git push`, …), and any text naming a real project root. Validated at **plan time** (the `experiment` step must carry a full contract) and **again at step start**.

## 2. Isolation and cleanup

A disposable Unity project is created under JARVIS' own experiments root (`<data dir>/experiments/<id>/project`) with a **marker file**. Deletion (`ExperimentWorkspace.remove`) happens only for a real directory inside that root whose marker carries the expected id — never a symlink, never the root, never a user's folder. The engine **always** cleans up: success, failure, cancel, time budget, disk budget. It closes only the editor JARVIS started for that project, and proves the real project untouched with a tree fingerprint before / after.
After a crash: at launch the experiment record becomes INTERRUPTED (never resumed) and `ExperimentWorkspace.reconcile` removes the orphan folder and stops any headless editor whose `-projectPath` is inside it (REAL TESTED: self-SIGKILL mid-experiment, then relaunch).

## 3. Steps (fixed, typed)

createEnvironment → importAsset (assetImport only: hash-verified copy of the *quarantined, inspected* artifact via `AssetImporter`, scripts / executables never copied) → openEditor (render-capable, owned) → compileAndConsole → discover → instantiateAndCapture (with the bounded correction loop) → evaluate. `animationPlayback` plays and samples twice.

## 4. Verdicts

`CONFIRMED` only when every check the kind needs was **made and held**; any failed check ⇒ `REFUTED`; a check that was never made, or nothing tested ⇒ `INCONCLUSIVE` ("no verdict") — an inconclusive experiment fails its step honestly rather than "passing". Facts carry a class: VERIFIED · TESTED · SUPPORTED BY SOURCE · INFERRED · UNKNOWN · INCOMPATIBLE.

## 5. Asset suitability (`AssetEvaluator`)

Price and licence come from the V0.9 records. UNKNOWN price is never free; an unknown licence is **never safe**. "Probably compatible" is INFERRED until an experiment imported and compiled it (then TESTED). A style claim needs rendered pictures of **both** the asset and the project — otherwise "style fit" is UNKNOWN. Usage suggestions are labelled FACT / INFERENCE / RECOMMENDATION. Promoting an asset into the real project is a **separate**, approval-gated V0.4 task; an experiment never imports into a project.

## 6. Limits

Built-in render pipeline only (URP mirroring would need the registry). The material-render experiment without a material asset tests the *default* material and says so. Real-asset experiments (V0.9 research → acquisition → experiment) depend on a current free asset and are exercised through the README manual checks.
