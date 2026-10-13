import Foundation

struct ExperimentRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var taskID: UUID?
    var stepKey: String?
    var projectKey: String?
    var spec: ExperimentSpec
    var environmentPath: String?
    var status: String                    // running · concluded · failed · cancelled · interrupted
    var result: ExperimentResult?
    var cleanupState: String              // pending · deleted · failed
    var createdAt = Date()
    var finishedAt: Date?
}

struct VisualObservationRecord: Equatable, Sendable, Identifiable {
    var id = UUID()
    var taskID: UUID?
    var stepKey: String?
    var at = Date()
    var provider: String
    var pictureHash: String
    var subject: String?
    var query: String?
    var outcome: String
    var detail: String?
    var injectionNotes = 0
}

struct AssetEvaluationRecord: Equatable, Sendable, Identifiable {
    var id = UUID()
    var taskID: UUID?
    var acquisitionID: UUID?
    var projectKey: String?
    var evaluation: AssetEvaluation
    var source: String?
    var createdAt = Date()
}

extension JarvisRepository {
    private static func ejs<T: Encodable>(_ v: T) -> String { (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "{}" }
    private static func unjs<T: Decodable>(_ s: String?, as: T.Type) -> T? { s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    private static func clean(_ s: String?, _ n: Int) -> String? { s.map { OutputSanitizer.sanitize(String($0.prefix(n))) } }

    // MARK: Experiments

    func save(_ e: ExperimentRecord) throws {
        var spec = e.spec
        spec.question = OutputSanitizer.sanitize(String(spec.question.prefix(300))); spec.hypothesis = OutputSanitizer.sanitize(String(spec.hypothesis.prefix(300)))
        try database.write { ctx in
            try ctx.execute("""
                INSERT INTO experiments(id, task_id, step_key, project_key, kind, question, hypothesis, contract, isolation, environment_path, status, verdict, result, cleanup_state, created_at, finished_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET task_id = excluded.task_id, step_key = excluded.step_key, project_key = excluded.project_key, kind = excluded.kind, question = excluded.question,
                    hypothesis = excluded.hypothesis, contract = excluded.contract, environment_path = excluded.environment_path, status = excluded.status, verdict = excluded.verdict,
                    result = excluded.result, cleanup_state = excluded.cleanup_state, finished_at = excluded.finished_at
                """, [.text(e.id.uuidString), .opt(e.taskID?.uuidString), .opt(e.stepKey), .opt(e.projectKey), .text(spec.kind.rawValue), .text(spec.question), .text(spec.hypothesis), .text(Self.ejs(spec)), .text("disposable"),
                      .opt(e.environmentPath), .text(e.status), .opt(e.result?.verdict.rawValue), .opt(e.result.map { Self.ejs($0) }), .text(e.cleanupState), .date(e.createdAt), .opt(e.finishedAt)])
        }
    }

    private static func experiment(_ r: SQLRow) -> ExperimentRecord? {
        guard let id = r.string("id").flatMap(UUID.init(uuidString:)), let spec = unjs(r.string("contract"), as: ExperimentSpec.self), let created = r.date("created_at") else { return nil }
        return ExperimentRecord(id: id, taskID: r.string("task_id").flatMap(UUID.init(uuidString:)), stepKey: r.string("step_key"), projectKey: r.string("project_key"), spec: spec, environmentPath: r.string("environment_path"),
                                status: r.string("status") ?? "running", result: unjs(r.string("result"), as: ExperimentResult.self), cleanupState: r.string("cleanup_state") ?? "pending", createdAt: created, finishedAt: r.date("finished_at"))
    }

    func experiment(_ id: UUID) throws -> ExperimentRecord? { try database.readOne("SELECT * FROM experiments WHERE id = ?", [.text(id.uuidString)]).flatMap(Self.experiment) }
    func experiments(taskID: UUID) throws -> [ExperimentRecord] { try database.read("SELECT * FROM experiments WHERE task_id = ? ORDER BY created_at", [.text(taskID.uuidString)]).compactMap(Self.experiment) }
    func recentExperiments(limit: Int = 20) throws -> [ExperimentRecord] { try database.read("SELECT * FROM experiments ORDER BY created_at DESC LIMIT ?", [.int(Int64(limit))]).compactMap(Self.experiment) }
    func unfinishedExperiments() throws -> [ExperimentRecord] { try database.read("SELECT * FROM experiments WHERE status = 'running'").compactMap(Self.experiment) }

    func addExperimentStep(experimentID: UUID, seq: Int, kind: ExperimentStepKind, status: String, evidence: String?) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO experiment_steps(id, experiment_id, seq, kind, status, evidence, at) VALUES (?,?,?,?,?,?,?)",
                            [.text(UUID().uuidString), .text(experimentID.uuidString), .int(Int64(seq)), .text(kind.rawValue), .text(status), .opt(Self.clean(evidence, 600)), .date(Date())])
        }
    }
    func experimentSteps(_ id: UUID) throws -> [(seq: Int, kind: String, status: String, evidence: String?)] {
        try database.read("SELECT * FROM experiment_steps WHERE experiment_id = ? ORDER BY seq", [.text(id.uuidString)]).map { ($0.int("seq") ?? 0, $0.string("kind") ?? "", $0.string("status") ?? "", $0.string("evidence")) }
    }

    /// A launch after a crash: experiments that were still running are INTERRUPTED (never resumed by themselves) and their environment is handled by the workspace reconcile.
    @discardableResult
    func reconcileExperimentsAfterRestart(now: Date = Date()) throws -> [ExperimentRecord] {
        let running = try unfinishedExperiments()
        for e in running { var u = e; u.status = "interrupted"; u.finishedAt = now; try save(u) }
        return running
    }

    // MARK: Visual evidence (hash + provider + what it said; never pixels)

    func insert(_ v: VisualObservationRecord) throws {
        try database.write { ctx in
            try ctx.execute("INSERT INTO visual_observations(id, task_id, step_key, at, provider, picture_hash, subject, query, outcome, detail, injection_notes) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                            [.text(v.id.uuidString), .opt(v.taskID?.uuidString), .opt(v.stepKey), .date(v.at), .text(String(v.provider.prefix(80))), .text(String(v.pictureHash.prefix(32))), .opt(Self.clean(v.subject, 120)), .opt(Self.clean(v.query, 200)),
                             .text(String(v.outcome.prefix(60))), .opt(Self.clean(v.detail, 400)), .int(Int64(v.injectionNotes))])
        }
    }
    func recentVisualObservations(limit: Int = 8) throws -> [VisualObservationRecord] {
        try database.read("SELECT * FROM visual_observations ORDER BY at DESC LIMIT ?", [.int(Int64(limit))]).compactMap { r in
            guard let id = r.string("id").flatMap(UUID.init(uuidString:)), let at = r.date("at") else { return nil }
            return VisualObservationRecord(id: id, taskID: r.string("task_id").flatMap(UUID.init(uuidString:)), stepKey: r.string("step_key"), at: at, provider: r.string("provider") ?? "", pictureHash: r.string("picture_hash") ?? "",
                                           subject: r.string("subject"), query: r.string("query"), outcome: r.string("outcome") ?? "", detail: r.string("detail"), injectionNotes: r.int("injection_notes") ?? 0)
        }
    }

    func visualObservations(taskID: UUID) throws -> [VisualObservationRecord] {
        try database.read("SELECT * FROM visual_observations WHERE task_id = ? ORDER BY at", [.text(taskID.uuidString)]).compactMap { r in
            guard let id = r.string("id").flatMap(UUID.init(uuidString:)), let at = r.date("at") else { return nil }
            return VisualObservationRecord(id: id, taskID: taskID, stepKey: r.string("step_key"), at: at, provider: r.string("provider") ?? "", pictureHash: r.string("picture_hash") ?? "", subject: r.string("subject"), query: r.string("query"),
                                           outcome: r.string("outcome") ?? "", detail: r.string("detail"), injectionNotes: r.int("injection_notes") ?? 0)
        }
    }
    @discardableResult
    func pruneVisualObservations(keep: Int = 500) throws -> Int {
        try database.write { ctx in try ctx.execute("DELETE FROM visual_observations WHERE id IN (SELECT id FROM visual_observations ORDER BY at DESC LIMIT -1 OFFSET ?)", [.int(Int64(keep))]); return 0 }
    }

    // MARK: Asset evaluations

    func save(_ a: AssetEvaluationRecord) throws {
        try database.write { ctx in
            try ctx.execute("INSERT OR REPLACE INTO asset_evaluations(id, task_id, acquisition_id, project_key, name, source, facts, recommendation, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                            [.text(a.id.uuidString), .opt(a.taskID?.uuidString), .opt(a.acquisitionID?.uuidString), .opt(a.projectKey), .text(Self.clean(a.evaluation.name, 160) ?? ""), .opt(Self.clean(a.source, 300)),
                             .text(Self.ejs(a.evaluation)), .opt(Self.clean(a.evaluation.recommendation, 400)), .date(a.createdAt)])
        }
    }
    func assetEvaluations(acquisitionID: UUID) throws -> [AssetEvaluationRecord] {
        try database.read("SELECT * FROM asset_evaluations WHERE acquisition_id = ? ORDER BY created_at DESC", [.text(acquisitionID.uuidString)]).compactMap { r in
            guard let id = r.string("id").flatMap(UUID.init(uuidString:)), let ev = Self.unjs(r.string("facts"), as: AssetEvaluation.self), let at = r.date("created_at") else { return nil }
            return AssetEvaluationRecord(id: id, taskID: r.string("task_id").flatMap(UUID.init(uuidString:)), acquisitionID: acquisitionID, projectKey: r.string("project_key"), evaluation: ev, source: r.string("source"), createdAt: at)
        }
    }
}
