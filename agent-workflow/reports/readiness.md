# Automation readiness report (issue #1)

Scope: infrastructure smoke test only. This report changes no application code, begins no milestone and resolves no manual-test gate. It is based on `PROJECT_STATE.md`, `docs/CURRENT_TASK.md`, `docs/KNOWN_ISSUES.md` (first 546 of 863 lines), `AGENTS.md`, `CLAUDE.md`, `agent-workflow/README.md` and `agent-workflow/tasks/issue-1.json`, as read in this checkout.

## 1. Application manual-test blockers (NOT resolved)

Per `PROJECT_STATE.md` and `docs/CURRENT_TASK.md`, the current state is V1.0 decision milestone Phase B: AUTOMATED TESTED, REAL TESTED (selected parts), MANUAL TEST REQUIRED. Nothing is marked manually verified or tagged. Recorded open items:

- **Permissions lost for the installed build.** The installed `/Applications/JARVIS.app` 0.15.0 build 125 is recorded with Accessibility false, Screen Recording false and Microphone not determined. They must be re-granted by the user (ad-hoc signature: macOS ties permissions to the build).
- **Real Hamam project not connected (JARVIS-V1PB-1).** The real Hamam project is recorded as not on the development Mac and the project registry as empty. The user must point JARVIS at the real folder.
- **README 1295-1305** (Phase B: microphone/speaker voice tests, Computer Use media, Hamam, model judgement) is MANUAL TEST REQUIRED.
- **Fix 4 checks (README 1268-1277)** are still listed as open human action and voice tests.
- Earlier manual lists (for example fix 3: README 1259-1267; fix 2: 1243-1258) are described as human tests in `PROJECT_STATE.md`. This report did not audit which of them were later completed.
- `docs/CURRENT_TASK.md` states the next step is to wait for the user. Only after "Jarvis, Hamam projesini aç." opens the real project and the voice tests pass may controlled Hamam work be discussed. No V1.1, no Hamam development and no tag without approval.
- `docs/KNOWN_ISSUES.md` additionally lists many MANUAL TEST REQUIRED items. Lines 547-863 were not read for this report, so the list above is not exhaustive.

The automation described below does not alter any of these gates.

## 2. Workflow boundaries (from `agent-workflow/README.md`)

- **Approval.** A human reviews a task manifest (`agent-workflow/tasks/issue-N.json`: existing issue number, goal, exact allowed paths, acceptance criteria) and places it on main. Only the repository owner `n0tnow` adding the `agent:approved` label starts a run. There is no mention, comment, fork or PR trigger. Issue text is never the worker prompt. The label is consumed and `agent:attempted` is recorded.
- **One attempt.** One model invocation per issue (12 turns, 15 minutes). There is no automated repair or retry. Workflow reruns are refused. A failed attempt needs a newly scoped issue/manifest and fresh approval; a bot does not remove the attempted marker.
- **Daily limit.** At most two owner-trigger runs per UTC day, including blocked triggers. Only one workflow runs at a time, and GitHub concurrency keeps at most one pending run, which is not a durable queue. Approve one issue at a time. `--max-budget-usd 1` is an extra CLI guard, not a billing guarantee, and there is no API-key fallback.
- **Draft PR only.** The worker only proposes a JSON artifact (read-only token, no shell, no git writes, no test execution). A fresh runner validates it. A separate publisher revalidates it, refuses stale main and creates a new `agent/task-N` branch with a DRAFT PR. It never overwrites a previous branch and never approves a PR. Human review is required.
- **No deploy.** The workflow never merges, tags, releases, installs or deploys. Output is limited to at most 12 `.swift`/`.md` files from the task allowlist, with no deletions, symlinks, workflows, build scripts, hidden paths or authority-document edits. Credential-pattern checks are not a complete secret scanner.
- **Emergency stop.** Disable `agent-task.yml` AND cancel the active run. Remove unconsumed approval labels. Revoke the subscription token if needed.

## 3. Implemented versus end-to-end tested

- **Implemented:** the bounded handoff is described as IMPLEMENTED, and `docs/CURRENT_TASK.md` records 12 isolated policy/controller tests passed.
- **NOT verified end-to-end:** `agent-workflow/README.md` states "end-to-end Claude execution NOT YET VERIFIED", and `docs/CURRENT_TASK.md` says GitHub activation and the actual Claude smoke run are not yet verified. This issue-1 run is that smoke run. Its result is not evidence until a human inspects the Actions run and the draft PR, and only then may end-to-end verification be recorded.
- **Not knowable from the repository:** whether the `CLAUDE_CODE_OAUTH_TOKEN` secret exists, whether the labels exist, whether Actions or PR-creation settings are enabled, and the status of the Codex desktop check-in. This report makes no claim about any of them. The README lists them as one-time activation steps for the owner.
- Tests not run by this worker: no Swift tests, `scripts/test.sh` or `scripts/verify.sh`. This change is documentation only and the worker has no execution authority.
