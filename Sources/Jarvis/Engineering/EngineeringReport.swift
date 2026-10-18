import Foundation

// MARK: - The engineering report, the run record and its checkpoint (V1.0 autonomous engineering pipeline)
//
// Reports are rendered from STRUCTURED records only: the assignment, the observed change set, the attribution, the verdict, the verification evidence, the findings, the attempts. There is no
// narrative that did not come from a record and no hidden reasoning to leak. Manual validation is a first-class state: AUTOMATED TESTED and MANUAL TEST REQUIRED are reported as such and nothing
// becomes MANUALLY VERIFIED without a record a person made.

enum ValidationState: String, Codable, Equatable, Sendable {
    case notVerified, automatedTested, manualTestRequired, manuallyVerified
}

enum EngineeringStage: String, Codable, CaseIterable, Sendable {
    case observe, plan, assign, implement, inspect, verify, review, correct, checkpoint, report, blocked, done
}

struct RunEvent: Codable, Equatable, Sendable {
    var stage: EngineeringStage
    var code: String
    var detail: String
}

/// One engineering run (one assignment through the pipeline) as a durable, bounded, hygiene-checked record. It decides nothing; the engine writes it and `EngineeringReport` reads it.
struct EngineeringRunRecord: Codable, Equatable, Sendable {
    static let schema = 1
    static let maxEvents = 120
    var schema = EngineeringRunRecord.schema
    var assignment: EngineeringAssignment
    var stage: EngineeringStage = .observe
    var baseline: RevisionStamp?
    var baselineGit: GitFacts?
    var workers: [String] = []
    var attempts: [AttemptSummary] = []
    var applied: [AppliedEdit] = []
    var evidence: [VerificationEvidence] = []
    var verdict: WorkVerificationStatus?
    var findings: [EngineeringFinding] = []
    var manualRequired: [String] = []
    var manualRecorded: Set<String> = []
    var stopReason: StopReason?
    var plan: VerificationPlan?
    var events: [RunEvent] = []
    var droppedEvents = 0
    var changedFiles: [String] = []
    var commit: String?
    var checkpointDigest: String?

    mutating func log(_ stage: EngineeringStage, _ code: String, _ detail: String = "") {
        self.stage = stage
        let safe = CheckpointHygiene.safeEvidence(detail, limit: 160) ?? "[withheld]"
        events.append(RunEvent(stage: stage, code: String(code.prefix(40)), detail: safe))
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents); droppedEvents += 1 }
    }

    var validationState: ValidationState {
        switch verdict {
        case .verified?: manualRequired.isEmpty ? .automatedTested : .manualTestRequired
        case .verifiedAutomated?: manualRecorded.isSuperset(of: Set(assignment.acceptance.filter { if case .manual = $0.check { return true }; return false }.map(\.id))) && manualRequired.isEmpty ? .manuallyVerified : .manualTestRequired
        default: .notVerified
        }
    }
}

enum EngineeringCheckpointer {
    /// A checkpoint is the run record plus a digest; a record that does not match its digest (torn write) is not truth.
    static func encode(_ r: EngineeringRunRecord, workspaceDigest: String) -> Data? {
        var copy = r; copy.checkpointDigest = workspaceDigest
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(copy)
    }

    enum ResumeDecision: Equatable, Sendable {
        case resume
        /// The workspace changed since the checkpoint in ways that may invalidate the plan: re-observe and re-plan before any write.
        case replan(changed: [String])
        case askUser(String)
        case corrupt
    }

    static func decode(_ data: Data) -> EngineeringRunRecord? {
        guard let r = try? JSONDecoder().decode(EngineeringRunRecord.self, from: data), r.schema == EngineeringRunRecord.schema else { return nil }
        return r
    }

    /// Resume only after revalidation: the same workspace digest resumes; changes inside the assignment's scope or read set force a re-plan; a moved HEAD or branch asks.
    static func resume(_ r: EngineeringRunRecord, checkpointSnapshot: WorkspaceSnapshot?, now: WorkspaceSnapshot) -> ResumeDecision {
        guard let base = checkpointSnapshot else { return .askUser("the checkpoint's workspace snapshot is missing") }
        if r.checkpointDigest != nil, r.checkpointDigest != base.digest { return .corrupt }
        if let a = base.git.head, let b = now.git.head, a != b { return .askUser("HEAD moved from \(a.prefix(8)) to \(b.prefix(8)) since the checkpoint") }
        if base.git.branch != now.git.branch { return .askUser("the branch changed since the checkpoint") }
        if base.digest == now.digest { return .resume }
        let own = Set(r.changedFiles)
        let changed = SnapshotDiff.between(base, now).map(\.path).filter { !own.contains($0) }
        if changed.isEmpty { return .resume }
        return .replan(changed: changed.sorted())
    }
}

struct EngineeringReport: Equatable, Sendable {
    var objective: String
    var status: WorkVerificationStatus?
    var validation: ValidationState
    var filesChanged: [String]
    var verification: [String]
    var findings: [String]
    var remainingRisks: [String]
    var manualValidation: [String]
    var attempts: Int
    var stopReason: StopReason?
    var commit: String?

    static func build(_ r: EngineeringRunRecord) -> EngineeringReport {
        let ev = r.evidence.map { "\($0.stage.rawValue): \($0.profile) → exit \($0.exitStatus)\($0.counts.map { " (\($0.passed) passed, \($0.failed) failed)" } ?? "")" }
        let notable = r.findings.filter { $0.severity >= .minor }.map { "\($0.severity.label) \($0.code.rawValue)\($0.path.map { " (\($0))" } ?? "")" }
        var risks: [String] = []
        if r.verdict != .verified, r.verdict != .verifiedAutomated { risks.append("the work is NOT verified (\(r.verdict?.rawValue ?? "no verdict"))") }
        if let s = r.stopReason, s != .verified { risks.append("stopped: \(s.rawValue)") }
        risks += r.findings.filter { $0.severity == .major }.map { "unresolved: \($0.code.rawValue)" }
        return EngineeringReport(objective: r.assignment.objective, status: r.verdict, validation: r.validationState, filesChanged: r.changedFiles.sorted(), verification: ev, findings: notable, remainingRisks: risks,
                                 manualValidation: r.manualRequired, attempts: r.attempts.count, stopReason: r.stopReason, commit: r.commit)
    }

    func render(language l: ReplyLanguage) -> [String] {
        let tr = l == .tr
        var out: [String] = []
        out.append((tr ? "Hedef: " : "Objective: ") + objective)
        let state: String
        switch validation {
        case .notVerified: state = tr ? "DOĞRULANMADI" : "NOT VERIFIED"
        case .automatedTested: state = tr ? "OTOMATİK TEST EDİLDİ" : "AUTOMATED TESTED"
        case .manualTestRequired: state = tr ? "OTOMATİK TEST EDİLDİ · MANUEL TEST GEREKLİ" : "AUTOMATED TESTED · MANUAL TEST REQUIRED"
        case .manuallyVerified: state = tr ? "MANUEL DOĞRULANDI" : "MANUALLY VERIFIED"
        }
        out.append((tr ? "Durum: " : "State: ") + state)
        out.append((tr ? "Değişen dosyalar: " : "Files changed: ") + (filesChanged.isEmpty ? (tr ? "yok" : "none") : filesChanged.joined(separator: ", ")))
        out.append((tr ? "Doğrulama: " : "Verification: ") + (verification.isEmpty ? (tr ? "çalıştırılmadı" : "none was run") : verification.joined(separator: "; ")))
        if !findings.isEmpty { out.append((tr ? "Bulgular: " : "Findings: ") + findings.joined(separator: "; ")) }
        if !remainingRisks.isEmpty { out.append((tr ? "Kalan riskler: " : "Remaining risks: ") + remainingRisks.joined(separator: "; ")) }
        if !manualValidation.isEmpty { out.append((tr ? "Sizin kontrol etmeniz gereken: " : "For you to check: ") + manualValidation.joined(separator: "; ")) }
        if let c = commit { out.append((tr ? "Yerel commit: " : "Local commit: ") + String(c.prefix(12))) }
        return out
    }
}

/// "Gece ne yaptın?" — answered from the run records of a night, never from a model's memory.
struct EngineeringDigest: Equatable, Sendable {
    var attempted: Int
    var verified: Int
    var automatedOnly: Int
    var blocked: Int
    var failed: Int
    var awaitingApproval: Int
    var filesChanged: [String]
    var testsRun: Int
    var failuresAndFixes: Int
    var manualChecks: [String]

    static func build(_ runs: [EngineeringRunRecord]) -> EngineeringDigest {
        var d = EngineeringDigest(attempted: runs.count, verified: 0, automatedOnly: 0, blocked: 0, failed: 0, awaitingApproval: 0, filesChanged: [], testsRun: 0, failuresAndFixes: 0, manualChecks: [])
        var files = Set<String>(), manual: [String] = []
        for r in runs {
            switch r.verdict {
            case .verified?: d.verified += 1
            case .verifiedAutomated?: d.automatedOnly += 1
            case .failed?: d.failed += 1
            default: break
            }
            if r.stopReason == .approvalRequired || r.stage == .blocked && r.stopReason == nil { d.awaitingApproval += 1 }
            else if let s = r.stopReason, s != .verified { d.blocked += 1 }
            files.formUnion(r.changedFiles)
            d.testsRun += r.evidence.filter { $0.stage == .unitTests || $0.stage == .integrationTests }.count
            d.failuresAndFixes += r.attempts.filter { $0.outcome.hasPrefix("failed") }.count
            manual += r.manualRequired
        }
        d.filesChanged = files.sorted(); d.manualChecks = Array(Set(manual)).sorted()
        return d
    }

    func render(language l: ReplyLanguage) -> String {
        if attempted == 0 { return l == .tr ? "Kayıtlı bir mühendislik görevi yok." : "No engineering task is on record." }
        if l == .tr {
            return "\(attempted) görev denendi: \(verified) doğrulandı, \(automatedOnly) otomatik test edildi (manuel kontrol gerekli), \(blocked) engellendi, \(failed) başarısız, \(awaitingApproval) onay bekliyor. \(filesChanged.count) dosya değişti, \(testsRun) test çalıştırıldı, \(failuresAndFixes) başarısız deneme oldu." + (manualChecks.isEmpty ? "" : " Sizin kontrol etmeniz gereken: " + manualChecks.joined(separator: "; ") + ".")
        }
        return "\(attempted) task(s) attempted: \(verified) verified, \(automatedOnly) automated-tested (manual check required), \(blocked) blocked, \(failed) failed, \(awaitingApproval) awaiting approval. \(filesChanged.count) file(s) changed, \(testsRun) test run(s), \(failuresAndFixes) failed attempt(s)." + (manualChecks.isEmpty ? "" : " For you to check: " + manualChecks.joined(separator: "; ") + ".")
    }
}
