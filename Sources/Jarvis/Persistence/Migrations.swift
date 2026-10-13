import Foundation

/// Versioned schema. `PRAGMA user_version` holds the applied version; `schema_migrations` keeps the history.
/// Rules: never edit a shipped migration — append a new one. Opening a database NEWER than this build is refused.
struct Migration: Sendable {
    let version: Int
    let name: String
    let statements: [String]

    static var latestVersion: Int { all.map(\.version).max() ?? 0 }

    static func migrate(connection: SQLiteConnection, migrations: [Migration]) throws {
        try connection.sync {
            try connection.run("""
                CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at REAL NOT NULL)
                """, [])
            let current = (try connection.run("PRAGMA user_version", []).first?.int("user_version")) ?? 0
            let supported = migrations.map(\.version).max() ?? 0
            if current > supported { throw DatabaseError.newerSchema(found: current, supported: supported) }
            for m in migrations.sorted(by: { $0.version < $1.version }) where m.version > current {
                try connection.run("BEGIN IMMEDIATE", [])
                do {
                    for sql in m.statements { try connection.run(sql, []) }
                    try connection.run("INSERT INTO schema_migrations(version, name, applied_at) VALUES (?, ?, ?)",
                                       [.int(Int64(m.version)), .text(m.name), .date(Date())])
                    try connection.run("PRAGMA user_version = \(m.version)", [])
                    try connection.run("COMMIT", [])
                } catch {
                    _ = try? connection.run("ROLLBACK", [])
                    throw error
                }
            }
        }
    }

    // MARK: Schema

    static let all: [Migration] = [v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12]

    /// V1 — operational foundation (V0.3.1). Tables for later milestones (tasks/steps/approvals/proposals) exist as plain
    /// storage only: nothing in V0.3.1 runs autonomous work.
    static let v1 = Migration(version: 1, name: "operational foundation", statements: [
        """
        CREATE TABLE projects (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, root_path TEXT, created_at REAL NOT NULL, metadata TEXT
        )
        """,
        """
        CREATE TABLE tasks (
            id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id), parent_task_id TEXT,
            title TEXT NOT NULL, category TEXT, status TEXT NOT NULL, privacy TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, finished_at REAL, summary TEXT
        )
        """,
        """
        CREATE TABLE task_steps (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, idx INTEGER NOT NULL,
            title TEXT NOT NULL, status TEXT NOT NULL, started_at REAL, finished_at REAL, detail TEXT
        )
        """,
        """
        CREATE TABLE agent_runs (
            id TEXT PRIMARY KEY,
            task_id TEXT REFERENCES tasks(id),
            parent_agent_run_id TEXT REFERENCES agent_runs(id),
            agent_type TEXT NOT NULL,
            engine TEXT NOT NULL,
            model TEXT,
            cost_class TEXT NOT NULL,
            selection_reason TEXT,
            privacy TEXT,
            started_at REAL NOT NULL, finished_at REAL,
            status TEXT NOT NULL,
            tools_used TEXT, files_read TEXT, files_changed TEXT,
            validation_status TEXT, result_summary TEXT,
            retry_count INTEGER NOT NULL DEFAULT 0,
            escalated_from TEXT, escalated_to TEXT,
            error_category TEXT,
            prompt_hash TEXT, prompt_chars INTEGER,
            input_tokens INTEGER, output_tokens INTEGER
        )
        """,
        "CREATE INDEX idx_agent_runs_task ON agent_runs(task_id)",
        "CREATE INDEX idx_agent_runs_parent ON agent_runs(parent_agent_run_id)",
        "CREATE INDEX idx_agent_runs_started ON agent_runs(started_at)",
        """
        CREATE TABLE model_registry (
            id TEXT PRIMARY KEY, engine TEXT NOT NULL, provider TEXT NOT NULL, provider_model_id TEXT NOT NULL,
            display_name TEXT NOT NULL, availability TEXT NOT NULL, pricing_status TEXT NOT NULL,
            input_price REAL, output_price REAL,
            free_verified INTEGER NOT NULL DEFAULT 0, free_verified_at REAL, free_verification_source TEXT,
            capabilities TEXT NOT NULL, data_policy TEXT NOT NULL, context_limit INTEGER,
            benchmark_status TEXT NOT NULL DEFAULT 'none',
            last_health_check REAL, last_successful_run REAL,
            enabled INTEGER NOT NULL DEFAULT 1, blocked_reason TEXT, updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE model_benchmarks (
            id INTEGER PRIMARY KEY AUTOINCREMENT, model_id TEXT NOT NULL, suite TEXT NOT NULL, case_id TEXT NOT NULL,
            category TEXT NOT NULL, passed INTEGER NOT NULL, validation TEXT,
            latency_ms REAL, duration_ms REAL, retries INTEGER NOT NULL DEFAULT 0,
            malformed INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0,
            ran_at REAL NOT NULL, artifact_id TEXT
        )
        """,
        "CREATE INDEX idx_benchmarks_model ON model_benchmarks(model_id, category)",
        """
        CREATE TABLE tool_executions (
            id TEXT PRIMARY KEY, agent_run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
            tool TEXT NOT NULL, summary TEXT, status TEXT NOT NULL,
            started_at REAL NOT NULL, finished_at REAL, exit_code INTEGER
        )
        """,
        "CREATE INDEX idx_tool_exec_run ON tool_executions(agent_run_id)",
        """
        CREATE TABLE file_changes (
            id TEXT PRIMARY KEY, task_id TEXT, agent_run_id TEXT REFERENCES agent_runs(id),
            path TEXT NOT NULL, change_type TEXT NOT NULL,
            git_hash TEXT, git_commit TEXT, diff_artifact_id TEXT, verification_result TEXT,
            changed_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_file_changes_path ON file_changes(path)",
        """
        CREATE TABLE approvals (
            id TEXT PRIMARY KEY, task_id TEXT, agent_run_id TEXT, kind TEXT NOT NULL, summary TEXT,
            status TEXT NOT NULL, requested_at REAL NOT NULL, decided_at REAL, decided_by TEXT
        )
        """,
        """
        CREATE TABLE proposals (
            id TEXT PRIMARY KEY, task_id TEXT, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT,
            status TEXT NOT NULL, created_at REAL NOT NULL, decided_at REAL
        )
        """,
        """
        CREATE TABLE activity_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT NOT NULL, message TEXT NOT NULL,
            task_id TEXT, agent_run_id TEXT
        )
        """,
        "CREATE INDEX idx_activity_ts ON activity_events(ts)",
        """
        CREATE TABLE artifacts (
            id TEXT PRIMARY KEY, type TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, sha256 TEXT NOT NULL,
            created_at REAL NOT NULL, task_id TEXT, agent_run_id TEXT, meta TEXT
        )
        """,
        "CREATE INDEX idx_artifacts_task ON artifacts(task_id)",
        "CREATE INDEX idx_artifacts_run ON artifacts(agent_run_id)",
        """
        CREATE TABLE provider_health (
            engine TEXT NOT NULL, subject TEXT NOT NULL DEFAULT '',
            consecutive_failures INTEGER NOT NULL DEFAULT 0, total_failures INTEGER NOT NULL DEFAULT 0,
            last_failure_at REAL, last_error_category TEXT, cooldown_until REAL,
            last_success_at REAL, updated_at REAL NOT NULL,
            PRIMARY KEY (engine, subject)
        )
        """,
    ])

    /// V2 — agent observability (V0.3.2): run label/progress/activity, sanitized console events, structured steps.
    /// Events hold ONLY text that already crossed `OutputSanitizer`; there is no raw-output table.
    static let v2 = Migration(version: 2, name: "agent observability", statements: [
        "ALTER TABLE agent_runs ADD COLUMN label TEXT",
        "ALTER TABLE agent_runs ADD COLUMN progress_source TEXT",
        "ALTER TABLE agent_runs ADD COLUMN steps_total INTEGER",
        "ALTER TABLE agent_runs ADD COLUMN steps_done INTEGER",
        "ALTER TABLE agent_runs ADD COLUMN progress_fraction REAL",
        "ALTER TABLE agent_runs ADD COLUMN activity TEXT",
        """
        CREATE TABLE agent_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE, seq INTEGER NOT NULL,
            ts REAL NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL, severity TEXT NOT NULL, summary TEXT NOT NULL,
            detail TEXT, artifact_id TEXT, UNIQUE (run_id, seq)
        )
        """,
        "CREATE INDEX idx_agent_events_run ON agent_events(run_id, seq)",
        "CREATE INDEX idx_agent_events_ts ON agent_events(ts)",
        """
        CREATE TABLE agent_run_steps (
            run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE, idx INTEGER NOT NULL, title TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1, state TEXT NOT NULL, PRIMARY KEY (run_id, idx)
        )
        """,
    ])

    /// V3 — autonomous task engine (V0.4): durable task/plan/step state, attempts (repair/escalation), approvals, write leases and
    /// per-step file-change evidence. Columns are appended to the V1 storage tables; nothing is renamed. All text stored here is
    /// bounded and passed through the sanitizer/redactor by the repository.
    static let v3 = Migration(version: 3, name: "autonomous task engine", statements: [
        "ALTER TABLE tasks ADD COLUMN goal TEXT",
        "ALTER TABLE tasks ADD COLUMN kind TEXT",
        "ALTER TABLE tasks ADD COLUMN risk TEXT",
        "ALTER TABLE tasks ADD COLUMN workspace_root TEXT",
        "ALTER TABLE tasks ADD COLUMN started_at REAL",
        "ALTER TABLE tasks ADD COLUMN current_step TEXT",
        "ALTER TABLE tasks ADD COLUMN activity TEXT",
        "ALTER TABLE tasks ADD COLUMN progress_fraction REAL",
        "ALTER TABLE tasks ADD COLUMN progress_source TEXT",
        "ALTER TABLE tasks ADD COLUMN constraints TEXT",
        "ALTER TABLE tasks ADD COLUMN failure_category TEXT",
        "ALTER TABLE tasks ADD COLUMN failure_reason TEXT",
        "ALTER TABLE tasks ADD COLUMN cancel_requested INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tasks ADD COLUMN recovery TEXT",
        "ALTER TABLE tasks ADD COLUMN plan_version INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tasks ADD COLUMN capabilities TEXT",
        "ALTER TABLE tasks ADD COLUMN git_baseline TEXT",
        "ALTER TABLE tasks ADD COLUMN report_artifact_id TEXT",
        "ALTER TABLE tasks ADD COLUMN checkpoint_artifact_id TEXT",
        "ALTER TABLE tasks ADD COLUMN accumulated_seconds REAL NOT NULL DEFAULT 0",
        "ALTER TABLE tasks ADD COLUMN preference TEXT",
        "ALTER TABLE tasks ADD COLUMN destructive_requested INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX idx_tasks_status ON tasks(status)",
        "ALTER TABLE task_steps ADD COLUMN step_key TEXT",
        "ALTER TABLE task_steps ADD COLUMN type TEXT",
        "ALTER TABLE task_steps ADD COLUMN description TEXT",
        "ALTER TABLE task_steps ADD COLUMN depends_on TEXT",
        "ALTER TABLE task_steps ADD COLUMN expected TEXT",
        "ALTER TABLE task_steps ADD COLUMN validation TEXT",
        "ALTER TABLE task_steps ADD COLUMN risk TEXT",
        "ALTER TABLE task_steps ADD COLUMN weight REAL NOT NULL DEFAULT 1",
        "ALTER TABLE task_steps ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE task_steps ADD COLUMN agent_run_id TEXT",
        "ALTER TABLE task_steps ADD COLUMN result_summary TEXT",
        "ALTER TABLE task_steps ADD COLUMN failure_category TEXT",
        "ALTER TABLE task_steps ADD COLUMN failure_reason TEXT",
        "ALTER TABLE task_steps ADD COLUMN validation_evidence TEXT",
        "CREATE INDEX idx_task_steps_task ON task_steps(task_id, idx)",
        """
        CREATE TABLE step_attempts (
            id TEXT PRIMARY KEY, step_id TEXT NOT NULL REFERENCES task_steps(id) ON DELETE CASCADE, task_id TEXT NOT NULL,
            number INTEGER NOT NULL, kind TEXT NOT NULL, engine TEXT, model TEXT, agent_run_id TEXT,
            outcome TEXT NOT NULL, evidence TEXT, started_at REAL NOT NULL, finished_at REAL
        )
        """,
        "CREATE INDEX idx_step_attempts_task ON step_attempts(task_id)",
        """
        CREATE TABLE file_leases (
            id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL, task_id TEXT NOT NULL, step_id TEXT, owner TEXT NOT NULL,
            acquired_at REAL NOT NULL, state TEXT NOT NULL, released_at REAL
        )
        """,
        "CREATE INDEX idx_file_leases_state ON file_leases(state)",
        "ALTER TABLE approvals ADD COLUMN step_id TEXT",
        "ALTER TABLE approvals ADD COLUMN action TEXT",
        "ALTER TABLE approvals ADD COLUMN reason TEXT",
        "ALTER TABLE approvals ADD COLUMN risk TEXT",
        "ALTER TABLE file_changes ADD COLUMN step_key TEXT",
        "ALTER TABLE file_changes ADD COLUMN before_hash TEXT",
        "ALTER TABLE file_changes ADD COLUMN after_hash TEXT",
        "ALTER TABLE file_changes ADD COLUMN preexisting INTEGER NOT NULL DEFAULT 0",
    ])

    /// V4 — proactive reasoning (V0.5): durable opportunities (with their structured assessment and deterministic policy decision),
    /// proposals (the user-facing card, bound to an exact scope by `action_hash`), proposal approvals, and task origin/scope/depth.
    /// Evidence and text are bounded + sanitized by the repository; there is no table for model reasoning.
    static let v4 = Migration(version: 4, name: "proactive reasoning", statements: [
        "ALTER TABLE tasks ADD COLUMN origin TEXT NOT NULL DEFAULT 'userTask'",
        "ALTER TABLE tasks ADD COLUMN origin_task_id TEXT",
        "ALTER TABLE tasks ADD COLUMN origin_opportunity_id TEXT",
        "ALTER TABLE tasks ADD COLUMN autonomy_depth INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE tasks ADD COLUMN scope TEXT",
        """
        CREATE TABLE opportunities (
            id TEXT PRIMARY KEY, project_root TEXT NOT NULL, origin TEXT NOT NULL, origin_task_id TEXT, origin_step_id TEXT, origin_run_id TEXT,
            title TEXT NOT NULL, summary TEXT, category TEXT NOT NULL, evidence TEXT, affected_scope TEXT, assessment TEXT,
            risk TEXT, design_impact TEXT, reversibility TEXT, destructiveness TEXT, external_effects TEXT, required_capabilities TEXT,
            confidence REAL, relation TEXT, evidence_strength TEXT, policy_decision TEXT, policy_reasons TEXT, status TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, expires_at REAL, dedup_key TEXT NOT NULL, related_opportunity_id TEXT,
            occurrences INTEGER NOT NULL DEFAULT 1, cooldown_until REAL, autonomy_depth INTEGER NOT NULL DEFAULT 0, proposed_action TEXT,
            action_hash TEXT, task_id TEXT, source_event TEXT
        )
        """,
        "CREATE INDEX idx_opportunities_project ON opportunities(project_root, status)",
        "CREATE INDEX idx_opportunities_dedup ON opportunities(dedup_key)",
        "CREATE INDEX idx_opportunities_origin ON opportunities(origin_task_id)",
        "CREATE UNIQUE INDEX idx_opportunities_event ON opportunities(source_event) WHERE source_event IS NOT NULL",
        "ALTER TABLE proposals ADD COLUMN opportunity_id TEXT",
        "ALTER TABLE proposals ADD COLUMN project_root TEXT",
        "ALTER TABLE proposals ADD COLUMN reason TEXT",
        "ALTER TABLE proposals ADD COLUMN evidence TEXT",
        "ALTER TABLE proposals ADD COLUMN proposed_action TEXT",
        "ALTER TABLE proposals ADD COLUMN affected_scope TEXT",
        "ALTER TABLE proposals ADD COLUMN risk TEXT",
        "ALTER TABLE proposals ADD COLUMN design_impact TEXT",
        "ALTER TABLE proposals ADD COLUMN reversibility TEXT",
        "ALTER TABLE proposals ADD COLUMN expected_benefit TEXT",
        "ALTER TABLE proposals ADD COLUMN validation_plan TEXT",
        "ALTER TABLE proposals ADD COLUMN action_hash TEXT",
        "ALTER TABLE proposals ADD COLUMN resulting_task_id TEXT",
        "ALTER TABLE proposals ADD COLUMN expires_at REAL",
        "ALTER TABLE proposals ADD COLUMN critical INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX idx_proposals_opportunity ON proposals(opportunity_id)",
        "ALTER TABLE approvals ADD COLUMN proposal_id TEXT",
        "ALTER TABLE approvals ADD COLUMN scope_hash TEXT",
    ])

    /// V5 — Unity project agent (V0.6): the typed, bounded parameters of a Unity plan step (scene, targets, test scope, expectations).
    /// Nothing else is stored: editor state is transient, console text is sanitized into step evidence, there is no table for raw Unity output.
    static let v5 = Migration(version: 5, name: "unity project agent", statements: [
        "ALTER TABLE task_steps ADD COLUMN unity_params TEXT",
    ])

    /// V6 — voice (V0.7): where a task's goal text came from ('typed' or 'voice'). Informational only. There is NO audio, transcript-history or
    /// partial-transcript storage anywhere in the schema: raw microphone audio is never persisted.
    static let v6 = Migration(version: 6, name: "voice input channel", statements: [
        "ALTER TABLE tasks ADD COLUMN input_channel TEXT NOT NULL DEFAULT 'typed'",
    ])

    /// V7 — web research & asset acquisition (V0.9): sessions, queries, sources (provenance), claims (evidence), candidates and acquisitions.
    /// Metadata, hashes, URLs (sanitized, no tokens) and SMALL bounded excerpts only: no page bodies, no archive of third-party content, no binaries.
    /// Downloaded artifacts live in the quarantine folder (Application Support/acquisitions), referenced here by relative path.
    static let v7 = Migration(version: 7, name: "web research and asset acquisition", statements: [
        """
        CREATE TABLE research_sessions (
            id TEXT PRIMARY KEY, goal TEXT NOT NULL, type TEXT NOT NULL, constraints TEXT, freshness TEXT, status TEXT NOT NULL, deep INTEGER NOT NULL DEFAULT 0,
            project_facts TEXT, meter TEXT, note TEXT, report_artifact_id TEXT, markdown_artifact_id TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL, finished_at REAL
        )
        """,
        "CREATE INDEX idx_research_sessions_updated ON research_sessions(updated_at)",
        """
        CREATE TABLE research_queries (
            id TEXT PRIMARY KEY, research_id TEXT NOT NULL, text TEXT NOT NULL, provider TEXT NOT NULL, result_count INTEGER NOT NULL DEFAULT 0, failure TEXT, at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_research_queries_session ON research_queries(research_id)",
        """
        CREATE TABLE research_sources (
            id TEXT PRIMARY KEY, research_id TEXT NOT NULL, url TEXT NOT NULL, final_url TEXT, domain TEXT, title TEXT, type TEXT NOT NULL, official TEXT NOT NULL,
            retrieved_at REAL NOT NULL, published_at REAL, author TEXT, content_hash TEXT, license TEXT, method TEXT NOT NULL, auth_required INTEGER NOT NULL DEFAULT 0,
            dynamic INTEGER NOT NULL DEFAULT 0, http_status INTEGER, trust INTEGER NOT NULL DEFAULT 0, excerpt TEXT, note TEXT, injection_flags TEXT
        )
        """,
        "CREATE INDEX idx_research_sources_session ON research_sources(research_id)",
        """
        CREATE TABLE research_claims (
            id TEXT PRIMARY KEY, research_id TEXT NOT NULL, subject TEXT, kind TEXT NOT NULL, statement TEXT NOT NULL, epistemic TEXT NOT NULL, status TEXT NOT NULL,
            freshness TEXT, evidence TEXT, note TEXT, created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_research_claims_session ON research_claims(research_id)",
        """
        CREATE TABLE research_candidates (
            id TEXT PRIMARY KEY, research_id TEXT NOT NULL, name TEXT NOT NULL, url TEXT NOT NULL, rank INTEGER NOT NULL DEFAULT 0, verdict TEXT, data TEXT NOT NULL, updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_research_candidates_session ON research_candidates(research_id)",
        """
        CREATE TABLE acquisitions (
            id TEXT PRIMARY KEY, research_id TEXT, candidate_id TEXT, task_id TEXT, state TEXT NOT NULL, class TEXT NOT NULL, name TEXT NOT NULL, source_url TEXT, sha256 TEXT,
            size INTEGER, trust TEXT, data TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_acquisitions_state ON acquisitions(state)",
        "CREATE INDEX idx_acquisitions_research ON acquisitions(research_id)",
    ])

    /// V8 — project memory (V0.10): DERIVED knowledge about a project, with provenance. History tables stay history; nothing here duplicates them.
    /// `memory_embeddings` is a derived, rebuildable index (model/revision/dimension tracked); canonical truth is `memory_items` + `memory_sources`.
    /// No raw conversation archive, no page body, no secret: summaries are sanitized and bounded before they reach this schema.
    static let v8 = Migration(version: 8, name: "project memory", statements: [
        """
        CREATE TABLE memory_projects (
            key TEXT PRIMARY KEY, name TEXT NOT NULL, root_path TEXT, aliases TEXT, identity_kind TEXT NOT NULL, created_at REAL NOT NULL, last_seen REAL NOT NULL
        )
        """,
        """
        CREATE TABLE memory_items (
            id TEXT PRIMARY KEY, project_key TEXT NOT NULL, type TEXT NOT NULL, subject TEXT NOT NULL, key TEXT, value TEXT, summary TEXT NOT NULL, details TEXT,
            status TEXT NOT NULL, strength INTEGER NOT NULL, importance INTEGER NOT NULL, scope TEXT NOT NULL, area TEXT, tags TEXT, origin TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, valid_from REAL NOT NULL, last_verified_at REAL, expires_at REAL, superseded_by TEXT,
            pinned INTEGER NOT NULL DEFAULT 0, user_corrected INTEGER NOT NULL DEFAULT 0, current_sensitive INTEGER NOT NULL DEFAULT 0,
            language TEXT, extraction_version INTEGER NOT NULL DEFAULT 1, canonical_hash TEXT NOT NULL, forgotten_at REAL
        )
        """,
        "CREATE INDEX idx_memory_items_project ON memory_items(project_key, status)",
        "CREATE INDEX idx_memory_items_key ON memory_items(project_key, key)",
        "CREATE INDEX idx_memory_items_hash ON memory_items(project_key, canonical_hash)",
        """
        CREATE TABLE memory_sources (
            memory_id TEXT NOT NULL REFERENCES memory_items(id) ON DELETE CASCADE, kind TEXT NOT NULL, ref TEXT NOT NULL, label TEXT NOT NULL, locator TEXT, observed_at REAL NOT NULL,
            PRIMARY KEY (memory_id, kind, ref)
        )
        """,
        """
        CREATE TABLE memory_relations (
            memory_id TEXT NOT NULL REFERENCES memory_items(id) ON DELETE CASCADE, predicate TEXT NOT NULL, target_kind TEXT NOT NULL, target TEXT NOT NULL,
            PRIMARY KEY (memory_id, predicate, target_kind, target)
        )
        """,
        "CREATE INDEX idx_memory_relations_target ON memory_relations(target_kind, target)",
        """
        CREATE TABLE memory_embeddings (
            memory_id TEXT PRIMARY KEY REFERENCES memory_items(id) ON DELETE CASCADE, model_id TEXT NOT NULL, revision TEXT NOT NULL, dim INTEGER NOT NULL,
            text_hash TEXT NOT NULL, vector BLOB NOT NULL, checksum TEXT NOT NULL, created_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE memory_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, project_key TEXT NOT NULL, kind TEXT NOT NULL, memory_id TEXT, detail TEXT
        )
        """,
        "CREATE TABLE memory_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        """
        CREATE TABLE memory_context_uses (
            id TEXT PRIMARY KEY, run_id TEXT, task_id TEXT, project_key TEXT NOT NULL, agent_type TEXT NOT NULL, memory_ids TEXT NOT NULL, truth_keys TEXT,
            items INTEGER NOT NULL, chars INTEGER NOT NULL, created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_memory_context_run ON memory_context_uses(run_id)",
        "CREATE INDEX idx_memory_context_task ON memory_context_uses(task_id)",
    ])

    /// V9 — General Computer Use (V0.11). Bounded session metadata only: the goal, the typed actions with their risk / mechanism / verification, and observation
    /// METADATA (counts, sizes, a few-bytes hash). Never an Accessibility dump, never a screenshot, never typed text (class + length only), never clipboard contents.
    static let v9 = Migration(version: 9, name: "general computer use", statements: [
        "ALTER TABLE task_steps ADD COLUMN computer_params TEXT",
        """
        CREATE TABLE computer_sessions (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, goal TEXT NOT NULL, status TEXT NOT NULL, target_apps TEXT, plan_summary TEXT, capability TEXT,
            vision_enabled INTEGER NOT NULL DEFAULT 0, started_at REAL NOT NULL, finished_at REAL, failure TEXT, resume_count INTEGER NOT NULL DEFAULT 0,
            memory_ids TEXT, origin TEXT
        )
        """,
        "CREATE INDEX idx_computer_sessions_status ON computer_sessions(status)",
        """
        CREATE TABLE computer_actions (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES computer_sessions(id) ON DELETE CASCADE, seq INTEGER NOT NULL, at REAL NOT NULL,
            kind TEXT NOT NULL, mechanism TEXT NOT NULL, app TEXT, window TEXT, target TEXT, risk TEXT NOT NULL, status TEXT NOT NULL, resolution TEXT,
            verification TEXT, detail TEXT, approval_id TEXT, text_class TEXT, text_length INTEGER, duration_ms REAL, attempts INTEGER NOT NULL DEFAULT 1, provider TEXT
        )
        """,
        "CREATE INDEX idx_computer_actions_session ON computer_actions(session_id, seq)",
        """
        CREATE TABLE computer_observations (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES computer_sessions(id) ON DELETE CASCADE, at REAL NOT NULL, kind TEXT NOT NULL, app TEXT, window TEXT,
            nodes INTEGER, windows INTEGER, truncated INTEGER, duration_ms REAL, width INTEGER, height INTEGER, fingerprint TEXT, provider TEXT, persisted INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_computer_observations_session ON computer_observations(session_id, at)",
    ])

    /// V10 — multi-agent orchestration (V0.12). The graph is the V0.4 plan: `task_steps` already hold nodes and edges (`depends_on`), so they only gain the orchestration
    /// attributes (optional / revision / delegate parameters / the delegated child task). New tables hold what did not exist: the graph header, bounded structural revisions,
    /// typed agent artifacts (sanitized, bounded, with provenance and a trust label), and one routing decision per node execution. No chain-of-thought, no raw provider
    /// conversation, no secret and no page body is stored here.
    static let v10 = Migration(version: 10, name: "multi-agent orchestration", statements: [
        "ALTER TABLE task_steps ADD COLUMN optional INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE task_steps ADD COLUMN revision INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE task_steps ADD COLUMN delegate_params TEXT",
        "ALTER TABLE task_steps ADD COLUMN delegated_task_id TEXT",
        "ALTER TABLE model_benchmarks ADD COLUMN context_chars INTEGER",
        "CREATE INDEX idx_tasks_parent ON tasks(parent_task_id)",
        """
        CREATE TABLE task_graphs (
            task_id TEXT PRIMARY KEY, template TEXT NOT NULL, planner TEXT NOT NULL, rationale TEXT, node_count INTEGER NOT NULL, revisions INTEGER NOT NULL DEFAULT 0,
            planner_chars INTEGER, planner_ms REAL, created_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE graph_revisions (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, n INTEGER NOT NULL, reason TEXT NOT NULL, added TEXT, at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_graph_revisions_task ON graph_revisions(task_id, n)",
        """
        CREATE TABLE agent_artifacts (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, node_key TEXT NOT NULL, role TEXT, kind TEXT NOT NULL, trust TEXT NOT NULL, provider TEXT, model TEXT,
            agent_run_id TEXT, attempt INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL, inputs TEXT, status TEXT NOT NULL, validation TEXT, content TEXT NOT NULL,
            content_hash TEXT NOT NULL, chars INTEGER NOT NULL, injection_flags TEXT
        )
        """,
        "CREATE INDEX idx_agent_artifacts_task ON agent_artifacts(task_id, node_key)",
        """
        CREATE TABLE routing_decisions (
            id TEXT PRIMARY KEY, task_id TEXT NOT NULL, node_key TEXT, role TEXT, agent_run_id TEXT, engine TEXT, model TEXT, mode TEXT, reason_text TEXT NOT NULL,
            reason_json TEXT, independence TEXT, escalation_reason TEXT, failure_class TEXT, outcome TEXT, context_chars INTEGER, memory_items INTEGER, artifact_count INTEGER,
            file_count INTEGER, handoff_chars INTEGER, queue_ms REAL, run_ms REAL, input_tokens INTEGER, output_tokens INTEGER, cost_class TEXT, created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_routing_decisions_task ON routing_decisions(task_id, created_at)",
        "CREATE INDEX idx_routing_decisions_role ON routing_decisions(role, engine, model)",
    ])

    /// V11 — project continuity (V0.13). Continuity is DERIVED (tasks, Git, memory, the Unity descriptor); only what cannot be derived cheaply is stored: one row per project
    /// (when the last continuation session ran) and the checkpoints a finished task or session left behind (Git HEAD, dirty set, file hashes, validated / remaining / next).
    /// No chain-of-thought, no screenshots, no raw output.
    static let v11 = Migration(version: 11, name: "project continuity", statements: [
        """
        CREATE TABLE project_continuity (
            project_key TEXT PRIMARY KEY, last_continuation_at REAL, last_task_id TEXT, sessions INTEGER NOT NULL DEFAULT 0, queue TEXT, updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE project_checkpoints (
            id TEXT PRIMARY KEY, project_key TEXT NOT NULL, task_id TEXT, created_at REAL NOT NULL, kind TEXT NOT NULL, outcome TEXT NOT NULL, title TEXT NOT NULL,
            git_head TEXT, git_branch TEXT, payload TEXT NOT NULL
        )
        """,
        "CREATE INDEX idx_project_checkpoints_project ON project_checkpoints(project_key, created_at)",
        "CREATE INDEX idx_tasks_workspace ON tasks(workspace_root, created_at)",
    ])

    /// V12 — experiments, visual evidence and asset evaluations (V0.13). An experiment is declared (question, hypothesis, bounds), run in a disposable environment and judged;
    /// only the contract and the structured result are kept (never the environment, never pixels). Visual evidence records WHICH picture (hash), WHICH provider and WHAT it
    /// reported — no screenshot is stored. An asset evaluation keeps the fact classes (verified / tested / supported by source / inferred / unknown / incompatible) apart.
    static let v12 = Migration(version: 12, name: "experiments, visual evidence, asset evaluations", statements: [
        """
        CREATE TABLE experiments (
            id TEXT PRIMARY KEY, task_id TEXT, step_key TEXT, project_key TEXT, kind TEXT NOT NULL, question TEXT NOT NULL, hypothesis TEXT NOT NULL, contract TEXT NOT NULL,
            isolation TEXT NOT NULL DEFAULT 'disposable', environment_path TEXT, status TEXT NOT NULL, verdict TEXT, result TEXT, cleanup_state TEXT NOT NULL DEFAULT 'pending',
            created_at REAL NOT NULL, finished_at REAL
        )
        """,
        "CREATE INDEX idx_experiments_task ON experiments(task_id)",
        "CREATE INDEX idx_experiments_status ON experiments(status)",
        """
        CREATE TABLE experiment_steps (
            id TEXT PRIMARY KEY, experiment_id TEXT NOT NULL REFERENCES experiments(id) ON DELETE CASCADE, seq INTEGER NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, evidence TEXT, at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_experiment_steps_exp ON experiment_steps(experiment_id, seq)",
        """
        CREATE TABLE visual_observations (
            id TEXT PRIMARY KEY, task_id TEXT, step_key TEXT, at REAL NOT NULL, provider TEXT NOT NULL, picture_hash TEXT NOT NULL, subject TEXT, query TEXT, outcome TEXT NOT NULL, detail TEXT,
            injection_notes INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_visual_observations_task ON visual_observations(task_id, at)",
        """
        CREATE TABLE asset_evaluations (
            id TEXT PRIMARY KEY, task_id TEXT, acquisition_id TEXT, project_key TEXT, name TEXT NOT NULL, source TEXT, facts TEXT NOT NULL, recommendation TEXT, created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_asset_evaluations_acq ON asset_evaluations(acquisition_id)",
    ])
}
