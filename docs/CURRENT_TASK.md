# Current Task

Version:
V0.13 — Autonomous Project Operator & General Visual Grounding — **IN PROGRESS** (not READY). Base: V0.12 (957f95e, READY FOR MANUAL TEST), V0.11 … V0.1.

Task:
Make JARVIS an operator that can resume a real project, work inside its development environment, inspect the result, correct itself and leave a validated continuation state — WITHOUT a second orchestrator (V0.12 stays the only one) and WITHOUT self-improvement (V0.14) or the final personality / whiteboard (V0.15). Parts: (1) Project Continuity (status, “continue”, reconciliation, bounded sessions, checkpoints); (2) Unity development operator (typed scene / prefab / material / lighting / animation / audio / camera / physics / UI operations, Play Mode observation, camera capture); (3) general visual grounding (typed, benchmarked, never an authority); (4) bounded Experiments and asset suitability; (5) the observe → act → inspect → correct loop.

State:
* CHECKPOINT 1 — Project Continuity: IMPLEMENTED · AUTOMATED TESTED (45 new tests; the V0.12 baseline of 1326 tests still passes). Derived view (tasks · Git · last checkpoint · memory · docs · Unity descriptor), reconciliation (current truth wins; JARVIS-written files are not “interference”), selection (interrupted → failed-once → recorded next → known issue; several ⇒ ask; design-sensitive ⇒ propose), bounded sessions (30 min / 12 nodes / 2 revisions / 2 correction rounds / 2 experiments), checkpoints per finished task (schema v11), Project panel in Tasks, Compact “Hamam · Continuing · Editing” line, Settings switch.
* Next: Unity operator (C# bridge + typed Swift operations), visual grounding research + benchmark, experiments / asset suitability, correction loop, `--operator-live-test`, guards, docs, 150+ manual checks.

Next Step:
Continue the V0.13 plan; the final report is owed only when everything is verified. No tag, no V0.14.

Blocked By:
Nothing.

Notes:
* Git: main only, no tags, no AI co-author trailers (the user's brief overrides the harness attribution reminder).
* Automated tests never touch the user's real Hamam / Unity game; Unity live tests use a disposable fixture copy.
* Nothing in continuity runs while idle: no timer, poll or watcher; it runs when asked and when a task finishes.
