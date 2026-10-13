import Foundation

// MARK: - Status from the graph (V0.12, DEC-182)
//
// "Durum ne?" / "What are you doing?" / "Which agent is running?" / "Did the tests pass?" are answered from the REAL graph state — no model call, no second task,
// no invented percentage. Pure: the same graph always gives the same sentence.

enum StatusFocus: Equatable, Sendable { case general, agents, tests }

struct StatusSnapshot: Equatable, Sendable {
    var title: String
    var state: TaskState
    var steps: [TaskStepRecord]
    var pendingApprovalAction: String?
    var activeChildren: [TaskRecord] = []
    /// Provider label of the run that serves a node right now ("OpenCode Free · space-bunny-free"), keyed by node key.
    var providers: [String: String] = [:]
}

enum OrchestrationStatus {
    private static func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    static func describe(_ s: StatusSnapshot, focus: StatusFocus, language l: ReplyLanguage) -> String {
        switch focus {
        case .tests: return tests(s, l)
        case .agents: return agents(s, l)
        case .general: return general(s, l)
        }
    }

    // MARK: Pieces

    private static func done(_ s: TaskStepRecord, _ l: ReplyLanguage) -> String? {
        switch s.type {
        case .analysis: return tr(l, "The analysis is finished.", "Analiz tamamlandı.")
        case .codeChange: return tr(l, "The code change is finished.", "Kod düzeltmesi tamamlandı.")
        case .delegateResearch: return tr(l, "The research is finished.", "Araştırma tamamlandı.")
        case .delegateComputer: return tr(l, "The on-screen check is finished.", "Ekran kontrolü tamamlandı.")
        case .unityCompile: return tr(l, "Unity compiled.", "Unity derlendi.")
        case .build: return tr(l, "The build passed.", "Derleme geçti.")
        case .test where s.validation == .testPass: return tr(l, "The tests passed\(count(s).map { " (\($0))" } ?? "").", "Testler geçti\(count(s).map { " (\($0))" } ?? "").")
        case .review: return tr(l, "The review is finished.", "İnceleme tamamlandı.")
        default: return nil
        }
    }
    private static func count(_ s: TaskStepRecord) -> String? { s.resultSummary.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } }

    private static func running(_ s: TaskStepRecord, _ l: ReplyLanguage) -> String {
        let role = s.role
        switch s.type {
        case .test, .build: return tr(l, "The QA agent is running the \(s.type == .build ? "build" : "tests").", "Test ajanı \(s.type == .build ? "derlemeyi" : "testleri") çalıştırıyor.")
        case .approvalGate: return tr(l, "Waiting for your approval.", "Onayınızı bekliyorum.")
        default: return tr(l, "The \(role?.noun(.en) ?? "agent") is working on “\(s.title)”.", "\(role.map { $0.noun(.tr).prefix(1).uppercased() + $0.noun(.tr).dropFirst() } ?? "Ajan") “\(s.title)” üzerinde çalışıyor.")
        }
    }

    private static func progress(_ s: StatusSnapshot, _ l: ReplyLanguage) -> String {
        let (d, t) = GraphProgress.validated(s.steps)
        return tr(l, "\(d)/\(t) required steps validated.", "\(d)/\(t) adım doğrulandı.")
    }

    // MARK: Focuses

    static func general(_ s: StatusSnapshot, _ l: ReplyLanguage) -> String {
        switch s.state {
        case .completed: return tr(l, "“\(s.title)” is finished. \(progress(s, l))", "“\(s.title)” tamamlandı. \(progress(s, l))")
        case .failed: return tr(l, "“\(s.title)” failed. \(progress(s, l))", "“\(s.title)” başarısız oldu. \(progress(s, l))")
        case .cancelled: return tr(l, "“\(s.title)” was stopped. \(progress(s, l))", "“\(s.title)” durduruldu. \(progress(s, l))")
        case .interrupted: return tr(l, "“\(s.title)” was interrupted. Nothing resumes by itself — say or press Resume. \(progress(s, l))", "“\(s.title)” yarıda kaldı. Kendiliğinden devam etmez; devam ettir diyebilir ya da düğmeye basabilirsiniz. \(progress(s, l))")
        case .waitingForApproval:
            return tr(l, "Waiting for your approval\(s.pendingApprovalAction.map { ": \($0)" } ?? ""). Use the buttons — a spoken or typed yes does not approve.", "Onayınızı bekliyorum\(s.pendingApprovalAction.map { ": \($0)" } ?? ""). Düğmeleri kullanın; söylenen ya da yazılan evet onay sayılmaz.")
        default: break
        }
        var parts: [String] = []
        if let last = s.steps.last(where: { $0.state == .passed && done($0, l) != nil }), let d = done(last, l) { parts.append(d) }
        let active = s.steps.filter { $0.state.isActive }
        if active.isEmpty, let next = s.steps.first(where: { $0.state == .ready || $0.state == .pending }) { parts.append(tr(l, "Next: \(next.role?.label ?? "step") — \(next.title).", "Sıradaki: \(next.role?.label ?? "adım") — \(next.title).")) }
        parts += active.prefix(2).map { running($0, l) }
        if let c = s.activeChildren.first { parts.append(tr(l, "A delegated task is running: \(c.title).", "Devredilen bir görev çalışıyor: \(c.title).")) }
        if parts.isEmpty { parts.append(tr(l, "“\(s.title)” is starting.", "“\(s.title)” başlıyor.")) }
        return parts.joined(separator: " ") + " " + progress(s, l)
    }

    static func agents(_ s: StatusSnapshot, _ l: ReplyLanguage) -> String {
        let active = s.steps.filter { $0.state.isActive }
        guard !active.isEmpty else {
            return s.state.isTerminal ? tr(l, "No agent is running; “\(s.title)” is \(s.state.label.lowercased()).", "Çalışan ajan yok; “\(s.title)” \(s.state.label.lowercased()).") : tr(l, "No agent is running right now.", "Şu an çalışan ajan yok.")
        }
        let list = active.map { st -> String in
            let who = st.role?.label ?? "Approval"
            let prov = s.providers[st.key].map { " · \($0)" } ?? ""
            return "\(who)\(prov) — \(st.title)"
        }
        return tr(l, "Running now: ", "Şu an çalışan: ") + list.joined(separator: "; ") + "."
    }

    static func tests(_ s: StatusSnapshot, _ l: ReplyLanguage) -> String {
        let runs = s.steps.filter { $0.type == .test && $0.validation == .testPass }
        if let r = runs.last(where: { $0.state.isActive }) { _ = r; return tr(l, "The tests are running now.", "Testler şu an çalışıyor.") }
        if let r = runs.last(where: { $0.state == .passed }) { return tr(l, "Yes — the tests passed\(count(r).map { " (\($0))" } ?? "").", "Evet, testler geçti\(count(r).map { " (\($0))" } ?? "").") }
        if let r = runs.last(where: { $0.state == .failed }) { return tr(l, "No — the tests failed: \(String((r.validationEvidence ?? r.failureReason ?? "see the report").prefix(120))).", "Hayır, testler başarısız: \(String((r.validationEvidence ?? r.failureReason ?? "rapora bakın").prefix(120))).") }
        return tr(l, "The tests have not run yet.", "Testler henüz çalışmadı.")
    }
}
