# Bounded development handoff

Status: IMPLEMENTED; end-to-end Claude execution NOT YET VERIFIED.
This is repository development infrastructure, not JARVIS runtime autonomy or
permission to begin Hamam development. Existing product milestones and manual
acceptance gates remain in force.

## Operating contract

1. Planning/review prepares `agent-workflow/tasks/issue-N.json` with an existing
   issue number, goal, exact allowed paths and acceptance criteria. A human reviews
   and places it on main. Public issue text is never the worker prompt.
2. Repository owner `n0tnow` adds `agent:approved` to the issue. The workflow checks
   the current issue, subscription secret presence and daily run count, records
   `agent:attempted` and consumes the approval. No mention/comment/fork/PR trigger.
3. Sonnet reads the pinned main snapshot and writes a JSON proposal. It has a
   read-only GitHub token, file tools, no shell, no test execution and no git writes.
4. A fresh ephemeral runner validates schema, exact paths, file count/size and
   common credential patterns. Swift proposals run existing `scripts/test.sh`
   without provider secrets. Full `verify.sh`, GUI/voice/manual acceptance are NOT
   claimed: the full verifier can kill running JARVIS processes and needs macOS UI.
5. A separate publisher revalidates the artifact without executing it, refuses
   stale main, creates a new `agent/task-N` branch and a DRAFT PR. It never overwrites
   a previous branch, approves a PR, merges, tags, releases, installs or deploys.
6. Every authorized trigger gets a fixed status report on its issue and in the
   Actions summary. Failed output remains unmerged. A Codex check-in independently
   inspects changed PR heads and reports actionable findings; it is not a merge gate.

## Limits and failure behavior

- One workflow at a time; GitHub concurrency retains at most one pending run and
  may replace an older pending run. This is not a durable multi-item queue: approve
  one issue at a time. Never assume an unstarted queued task was completed.
- At most TWO owner trigger runs per UTC day, including blocked triggers; one
  model invocation per issue, 12 turns, 15 minutes. No automated repair/retry.
- `--max-budget-usd 1` is an additional CLI guard, NOT a hard subscription-quota or
  billing guarantee. OAuth uses the user's subscription; no API-key fallback.
  Daily call/turn/time limits are the enforceable quota controls. Provider plans,
  limits and spending controls still apply. No OpenAI API credential is needed.
- Workflow reruns are refused. A failed attempt needs a newly scoped issue/manifest
  and approval, not removal of the attempted marker by a bot. Partial publish may
  leave a branch; preserve it for inspection.
- Allowed output: at most 12 regular UTF-8 `.swift`/`.md` files in the exact task
  allowlist, 64 KiB/file, 256 KiB artifact. No deletions, symlinks, workflows,
  package/build scripts, hidden paths or authority-document edits.
- Generated code remains untrusted; pattern checks are not a complete secret
  scanner or security audit. Tests run on disposable hosted runners with no
  credentials or write token; publication never executes generated code. Claude
  tool restrictions reduce exposure but are not an OS sandbox. Never put secrets
  into repository content, task manifests, issue text or model reports.

## One-time activation

- Merge the reviewed infrastructure PR. The issue workflow runs only from main.
- Store subscription token as repository Actions secret `CLAUDE_CODE_OAUTH_TOKEN`.
  Create it via the official Claude subscription setup (`claude setup-token`);
  enter it directly in GitHub Secrets, never in chat/files/logs. Do not use a paid
  API-key fallback. Rotate/revoke through the provider when needed.
- Enable Actions and "Allow GitHub Actions to create and approve pull requests"
  (GitHub combines creation/approval into one setting). This workflow never invokes
  approval. Keep default token access read-only and require human PR review on main.
- Create labels `agent:approved` and `agent:attempted`. Approve issue #1 for a
  documentation-only smoke run after activation. Inspect its run and draft PR;
  only then record end-to-end verification.
- Emergency stop: disable `agent-task.yml` in Actions AND cancel the active run.
  Remove unconsumed approval labels and revoke the subscription token if needed.

The publisher uses GITHUB_TOKEN, whose PR events do not start other workflows.
Therefore validation happens inside this same workflow before publication.
Regular human-created PRs have the secret-free `Automation policy checks` workflow.
Do not replace it with `pull_request_target` that executes PR code.

## Independent Codex check-in

The desktop heartbeat checks at low frequency, stores the last reviewed PR SHA,
and stays quiet when unchanged. It does not launch a local Claude session, grant
labels, expand scope, retry failures, merge or deploy. It can report missing setup
and review new diffs. Desktop availability, connectivity and model limits matter;
this is not proof of a continuously running cloud ChatGPT agent. GitHub Actions is
the independent cloud worker after activation.

References: [Claude Actions](https://code.claude.com/docs/en/github-actions),
[Codex scheduled tasks](https://learn.chatgpt.com/docs/automations?surface=app),
[disabling Actions](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/disable-and-enable-workflows).
