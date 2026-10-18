import Foundation

// MARK: - What happened, from structured state only (V1.0 background pass)
//
// "Gece ne yaptın?", "Nerede kaldın?", "Ne başarısız oldu?", "Benden ne bekliyorsun?", "Devam edebilir misin?" must be answerable after hours WITHOUT reconstructing anything from a model's memory.
// `TaskDigest` folds the durable records the engine already keeps — the task, its steps, the attempts (provider, outcome), the approvals, the changed files and, when kept, the event log — into one value; the
// report and every answer are rendered from it. No chain-of-thought exists to leak, no narrative is invented: counts, titles, states, the stored (already sanitised) validation evidence, and the machine
// reason of a failure. "Can you continue?" is a QUESTION about state: answering it starts nothing.

struct DigestStep: Equatable, Sendable {
    var key: String
    var title: String
    var state: TaskStepState
    var evidence: String?
    var failureReason: String?
    var optional: Bool
}

struct DigestApproval: Equatable, Sendable {
    var action: String
    var risk: RiskClass
    var state: ApprovalState
}

struct TaskDigest: Equatable, Sendable {
    var taskID: UUID
    var objective: String
    var taskState: TaskState
    var derived: DerivedTaskView
    var steps: [DigestStep]
    var approvals: [DigestApproval]
    var changedFiles: [String]
    var providersUsed: [String: Int]
    var retries: Int
    var fallbacks: Int
    var failureCategory: FailureCategory?
    var failureReason: String?
    var eventSummary: [String]

    var completed: [DigestStep] { steps.filter { $0.state == .passed } }
    var failed: [DigestStep] { steps.filter { $0.state == .failed } }
    var remaining: [DigestStep] { steps.filter { !$0.state.isTerminal } }
    var pendingApprovals: [DigestApproval] { approvals.filter { $0.state == .pending } }

    static func build(task: TaskRecord, steps: [TaskStepRecord], attempts: [StepAttemptRecord] = [], approvals: [ApprovalRecord] = [], changes: [TaskFileChange] = [], events: TaskEventLog? = nil, language: ReplyLanguage = .en) -> TaskDigest {
        var providers: [String: Int] = [:]
        var retries = 0, fallbacks = 0
        var lastEngineByStep: [UUID: String] = [:]
        for a in attempts.sorted(by: { $0.startedAt < $1.startedAt }) {
            let name = a.engine?.rawValue ?? "deterministic"
            providers[name, default: 0] += 1
            if a.kind == .repair || a.kind == .recheck { retries += 1 }
            if a.kind == .escalation { fallbacks += 1 }
            if let prev = lastEngineByStep[a.stepID], prev != name, a.kind != .escalation { fallbacks += 1 }
            lastEngineByStep[a.stepID] = name
        }
        let digestSteps = steps.sorted { $0.index < $1.index }.map { DigestStep(key: $0.key, title: $0.title, state: $0.state, evidence: $0.validationEvidence.map { String($0.prefix(200)) }, failureReason: $0.failureReason.map { String($0.prefix(200)) }, optional: $0.optional) }
        return TaskDigest(taskID: task.id, objective: String(task.goal.prefix(240)), taskState: task.state, derived: TaskStatusDeriver.derive(task: task.state, steps: steps, failure: task.failureCategory), steps: digestSteps,
                          approvals: approvals.map { DigestApproval(action: String($0.action.prefix(160)), risk: $0.risk, state: $0.state) }, changedFiles: changes.map(\.path).uniqued().sorted(), providersUsed: providers,
                          retries: retries, fallbacks: fallbacks, failureCategory: task.failureCategory, failureReason: task.failureReason.map { String($0.prefix(200)) }, eventSummary: events?.summaryLines(language: language) ?? [])
    }

    /// The end-of-task report (also usable mid-task), rendered from the digest only.
    func report(language l: ReplyLanguage) -> [String] {
        func t(_ en: String, _ tr: String) -> String { l == .tr ? tr : en }
        var out = [t("Objective: ", "Hedef: ") + objective]
        out.append(ProgressReport.build(steps.map { ProgressStep(title: $0.title, state: ProgressStep.State(rawValue: $0.state.rawValue) ?? .pending) }).line(language: l))
        out.append(t("Status: ", "Durum: ") + derived.status.rawValue)
        if !completed.isEmpty { out.append(t("Completed and verified: ", "Biten ve doğrulanan: ") + completed.map(\.title).joined(separator: "; ")) }
        if !changedFiles.isEmpty { out.append(t("Files changed: ", "Değişen dosyalar: ") + changedFiles.prefix(12).joined(separator: ", ") + (changedFiles.count > 12 ? " …(+\(changedFiles.count - 12))" : "")) }
        for f in failed { out.append(t("Failed: ", "Başarısız: ") + f.title + (f.failureReason.map { " — \($0)" } ?? "")) }
        if !pendingApprovals.isEmpty { out.append(t("Waiting for your approval: ", "Onayınızı bekleyen: ") + pendingApprovals.map(\.action).joined(separator: "; ")) }
        if !remaining.isEmpty, !derived.status.isFinal { out.append(t("Remaining: ", "Kalan: ") + remaining.map(\.title).joined(separator: "; ")) }
        if !providersUsed.isEmpty { out.append(t("Providers: ", "Sağlayıcılar: ") + providersUsed.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")) }
        if retries + fallbacks > 0 { out.append(t("Retries \(retries), fallbacks \(fallbacks).", "Yeniden deneme \(retries), başka sağlayıcıya geçiş \(fallbacks).")) }
        out += eventSummary
        return out
    }
}

enum MorningQuestion: String, Equatable, Sendable, CaseIterable { case whatDidYouDo, whereDidYouStop, whatFailed, whatDoYouNeedFromMe, canYouContinue }

enum MorningBrief {
    private static func fold(_ s: String) -> String {
        var f = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        for q in ["'", "’", "‘", "ʼ", "`"] { f = f.replacingOccurrences(of: q, with: "") }
        return f
    }

    /// Recognises the five questions in Turkish and English (closed phrase sets over folded tokens). nil = not one of them.
    static func recognize(_ raw: String) -> MorningQuestion? {
        let f = fold(raw).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        func has(_ p: String...) -> Bool { p.contains { f.contains($0) } }
        guard f.split(separator: " ").count <= 8 else { return nil }
        if has("gece ne yaptin", "ne yaptin", "what did you do", "what happened overnight", "what did you get done") { return .whatDidYouDo }
        if has("nerede kaldin", "nerede durdun", "where did you stop", "where are you at", "where did you leave off") { return .whereDidYouStop }
        if has("ne basarisiz", "neler basarisiz", "what failed", "what went wrong", "hangi adim basarisiz") { return .whatFailed }
        if has("benden ne bekliyorsun", "benden ne istiyorsun", "what do you need from me", "what are you waiting for") { return .whatDoYouNeedFromMe }
        if has("devam edebilir misin", "devam edebilirsin", "can you continue", "can you keep going") { return .canYouContinue }
        return nil
    }

    /// Answers from the digests (newest task first). Reading state starts, approves and changes nothing.
    static func answer(_ q: MorningQuestion, digests: [TaskDigest], language l: ReplyLanguage) -> String {
        func t(_ en: String, _ tr: String) -> String { l == .tr ? tr : en }
        guard let d = digests.first else { return t("There is no task on record.", "Kayıtlı bir görev yok.") }
        switch q {
        case .whatDidYouDo:
            var lines = d.report(language: l)
            if digests.count > 1 { lines.append(t("(\(digests.count - 1) older task(s) are also on record.)", "(\(digests.count - 1) eski görev daha kayıtlı.)")) }
            return lines.joined(separator: "\n")
        case .whereDidYouStop:
            let progress = ProgressReport.build(d.steps.map { ProgressStep(title: $0.title, state: ProgressStep.State(rawValue: $0.state.rawValue) ?? .pending) }).line(language: l)
            return t("\(d.derived.status.rawValue): ", "\(d.derived.status.rawValue): ") + progress
        case .whatFailed:
            let failed = digests.flatMap(\.failed)
            if failed.isEmpty, d.taskState != .failed { return t("Nothing failed in the recorded task(s).", "Kayıtlı görevlerde başarısız olan bir şey yok.") }
            var lines = failed.map { ($0.title) + ($0.failureReason.map { " — \($0)" } ?? "") }
            if let c = d.failureCategory { lines.append(t("Task failure: ", "Görev hatası: ") + c.label + (d.failureReason.map { " — \($0)" } ?? "")) }
            return lines.joined(separator: "\n")
        case .whatDoYouNeedFromMe:
            var needs: [String] = d.pendingApprovals.map { t("Approval: ", "Onay: ") + $0.action + " (\($0.risk.rawValue))" }
            if d.derived.status == .paused { needs.append(t("Resume the interrupted task (say “continue”; I re-check everything first).", "Yarıda kalan görevi sürdürmek ister misiniz (“devam et” deyin; önce her şeyi yeniden kontrol ederim).")) }
            if d.derived.status == .blocked { needs.append(t("A required step failed: ", "Gerekli bir adım başarısız oldu: ") + d.derived.blockedBy.joined(separator: ", ")) }
            return needs.isEmpty ? t("Nothing is waiting for you.", "Sizden bekleyen bir şey yok.") : needs.joined(separator: "\n")
        case .canYouContinue:
            switch d.derived.status {
            case .paused: return t("Yes — say “continue”; I will re-check the project and the earlier results first.", "Evet — “devam et” deyin; önce projeyi ve önceki sonuçları yeniden kontrol ederim.")
            case .waitingForApproval: return t("Not until you decide: \(d.pendingApprovals.first?.action ?? "an approval is pending").", "Siz karar verene kadar hayır: \(d.pendingApprovals.first?.action ?? "bir onay bekliyor").")
            case .blocked, .failed: return t("Not as it stands: a required step failed. Tell me what to change.", "Bu haliyle hayır: gerekli bir adım başarısız oldu. Neyi değiştirmem gerektiğini söyleyin.")
            case .completed: return t("The task is complete; there is nothing left to continue.", "Görev tamamlandı; devam edecek bir şey kalmadı.")
            case .cancelled: return t("The task was stopped; it can be started again as a new task.", "Görev durduruldu; yeni bir görev olarak yeniden başlatılabilir.")
            default: return t("It is still running.", "Hâlâ çalışıyor.")
            }
        }
    }
}
