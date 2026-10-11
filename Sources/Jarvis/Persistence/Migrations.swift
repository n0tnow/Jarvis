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

    static let all: [Migration] = [v1]

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
}
