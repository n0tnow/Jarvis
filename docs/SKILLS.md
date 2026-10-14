# Skills (V0.14)

A **Skill** is a JARVIS-owned, validated workflow template — a bounded task graph — not code and not a prompt with authority. Matching a Skill only changes the *template the V0.12 planner starts from*; plan validation, role contracts, capabilities, approvals and every V0.4/V0.12 rule apply exactly as for any plan.

## Kinds

* **Built-in** (documentation of deterministic templates): Unity Asset Suitability, Fix/Test/Review, Investigate. Not matched again (the planner already routes to them).
* **Learned**: a workflow candidate (≥ 3 successful, independent, comparable tasks with the same step shape) promoted by an HUD decision. Triggers are the significant words shared by the goals it was learned from.

## Validation (`SkillValidator`)

≥ 2 and ≤ 12 steps; only generic step types (analysis, codeChange, build, test, review, unityCompile, unityTest) — acquisition, import, deletion, delegation and typed Unity/Computer steps are never learned; unique keys, existing dependencies; the V0.12 `GraphValidator` and `PlanValidator` pass with the Skill's own capabilities; a code change must be followed by a validation step.

## Use and decay

A learned Skill is matched only when ≥ 2 triggers hit (or all, if fewer), its capabilities are available, its success count ≥ failure count and it still validates. Outcomes are recorded; a Skill that keeps failing stops being preferred. Skills can be disabled / enabled / retired from the Learning screen (tab "Skills"); history is kept.

## Skill vs rule vs MCP

Rule = "add this requirement"; Skill = "start from this graph"; MCP = "an external capability the user approved". The capability-gap detector recommends which one fits (native first, then Skill, then MCP).
