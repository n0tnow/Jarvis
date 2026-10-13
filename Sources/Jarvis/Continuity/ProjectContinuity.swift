import Foundation
import CryptoKit

// MARK: - The effectful side of Project Continuity (V0.13)
//
// ConversationService hands a recognised project question here. This class GATHERS current truth (files, Git, the Unity descriptor, tasks, checkpoints, memory), asks the pure
// logic what it means, and — only for “continue” — turns the decision into an ordinary V0.4/V0.12 task through `TaskEngine.submit`. It has no execution path of its own,
// grants nothing ("continue" is bounded project authority: no purchase, credential, security setting, push, unrelated deletion, redesign or licence acceptance), and keeps
// no timer, poll or watcher: it runs when asked and when a task finishes.

@MainActor
protocol ContinuityConversing: AnyObject {
    /// nil = this is not a project-continuity utterance. Consulted before the memory handler and the router.
    func recognizes(_ text: String) -> ContinuityIntent?
    func reply(to intent: ContinuityIntent, language: ReplyLanguage, channel: InputSource) async -> String
}

struct ContinuityDiagnostics: Equatable, Sendable {
    var project: String
    var sources: [String]
    var reconciliation: [String]
    var decision: String
    var bounds: String
    var at = Date()
}

@MainActor
final class ProjectContinuity: ContinuityConversing {
    struct ProjectRef: Equatable, Sendable { var key: String; var name: String; var root: String; var roots: [String] }
    private enum Resolution { case found(ProjectRef), unknownName(String, [String]), noProject }

    let repository: JarvisRepository?
    unowned let engine: TaskEngine
    let memory: ProjectMemory?
    let preferences: Preferences
    var enabled: () -> Bool = { true }
    /// The live editor state for a project root (“CONNECTED”, “NOT RUNNING”…), from the Unity service. Never polled by this class.
    var unityEditorState: (String) -> String? = { _ in nil }
    /// V0.15 owns the final voice of JARVIS; until then every reply goes through this one hook unchanged.
    var presenter: (String, ReplyLanguage) -> String = { text, _ in text }
    var bounds = ContinuationBounds.standard
    var onActivity: ((String, ActivityKind) -> Void)?

    private(set) var referencedRoot: String?
    private(set) var lastDiagnostics: ContinuityDiagnostics?
    private var pendingChoice: (ref: ProjectRef, candidates: [NextCandidate])?

    init(repository: JarvisRepository?, engine: TaskEngine, memory: ProjectMemory?, preferences: Preferences) {
        self.repository = repository; self.engine = engine; self.memory = memory; self.preferences = preferences
    }

    private func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    // MARK: Recognition

    func recognizes(_ text: String) -> ContinuityIntent? {
        guard enabled() else { pendingChoice = nil; return nil }
        if pendingChoice != nil, let n = ContinuityIntent.ordinal(text) { return .choose(n) }
        let intent = ContinuityIntent.recognize(text)
        pendingChoice = nil                      // a choice question lives for exactly one answer
        return intent
    }

    // MARK: Reply

    func reply(to intent: ContinuityIntent, language l: ReplyLanguage, channel: InputSource) async -> String {
        let text = await compose(intent, language: l, channel: channel)
        return presenter(text, l)
    }

    private func compose(_ intent: ContinuityIntent, language l: ReplyLanguage, channel: InputSource) async -> String {
        guard enabled() else { return tr(l, "Project continuation is turned off in Settings.", "Proje devamı Ayarlar'dan kapatılmış.") }
        if case .choose(let n) = intent {
            guard let p = pendingChoice, n >= 1, n <= p.candidates.count else { return tr(l, "I am not waiting for a choice right now.", "Şu an bir seçim beklemiyorum.") }
            pendingChoice = nil
            return await start(candidate: p.candidates[n - 1], ref: p.ref, language: l, channel: channel)
        }
        let ref: ProjectRef
        switch await resolve(intent.project) {
        case .found(let r): ref = r
        case .unknownName(let n, let known): return tr(l, "I do not know a project called “\(n)”." + (known.isEmpty ? "" : " Known projects: \(known.joined(separator: ", ")).") , "“\(n)” adında bir proje tanımıyorum." + (known.isEmpty ? "" : " Bildiklerim: \(known.joined(separator: ", "))."))
        case .noProject: return tr(l, "No project is selected. Choose a project folder in Settings, or name the project.", "Seçili bir proje yok. Ayarlar'dan bir proje klasörü seçin ya da projenin adını söyleyin.")
        }
        referencedRoot = ref.root
        let gathered = await gather(ref)
        let view = gathered.view, drift = gathered.report

        switch intent {
        case .status(_, let detailed): return ContinuityStatus.summary(view, drift: drift, language: l, detailed: detailed)
        case .lastDone: return ContinuityStatus.lastDone(view, language: l)
        case .next: return ContinuityStatus.next(view, language: l)
        case .lastReport(_, let detailed):
            guard let t = view.recentCompleted.first ?? view.failed.first ?? view.interrupted.first else { return ContinuityStatus.lastDone(view, language: l) }
            guard let report = engine.report(for: t.id) else { return ContinuityStatus.lastDone(view, language: l) }
            return OutputSanitizer.sanitize(String((detailed ? report.markdown() : report.userSummary).prefix(detailed ? 3_000 : 900)))
        case .queueNext(_, let item):
            if MemoryGate.grantsAuthority(item) { return tr(l, "I cannot queue that: queued work never changes what I am allowed to do.", "Bunu sıraya alamam: sıradaki iş neye izinli olduğumu değiştirmez.") }
            guard SecretGate.containsSecret(item) == false else { return tr(l, "That looks like it contains a secret, so I did not store it.", "Bunda bir sır olabilir gibi görünüyor, kaydetmedim.") }
            var st = (try? repository?.continuityState(ref.key)) ?? ContinuityState(projectKey: ref.key, lastContinuationAt: nil, lastTaskID: nil, sessions: 0)
            if st.projectKey.isEmpty { st.projectKey = ref.key }
            let key = ResearchText.fold(item).filter { $0.isLetter || $0.isNumber }
            if !st.queue.contains(where: { ResearchText.fold($0).filter { $0.isLetter || $0.isNumber } == key }) { st.queue.append(item); try? repository?.saveContinuity(st) }
            return tr(l, "Queued for \(ref.name): “\(MemoryText.clip(item, 100))”. Say “continue” when you want me to start.", "\(ref.name) için sıraya aldım: “\(MemoryText.clip(item, 100))”. Başlamamı istediğinizde “devam et” deyin.")
        case .continueProject:
            return await continueProject(view: view, report: drift, ref: ref, language: l, channel: channel)
        case .choose: return ""
        }
    }

    // MARK: Continue

    private func continueProject(view: ProjectContinuityView, report: ReconciliationReport, ref: ProjectRef, language l: ReplyLanguage, channel: InputSource) async -> String {
        if engine.pendingApprovals.contains(where: { a in engine.view(a.taskID)?.task.workspaceRoot.map({ ref.roots.contains($0) }) ?? false }) {
            return tr(l, "A step is waiting for your approval in the HUD. Approvals are given with the buttons, not by voice or text.", "Bir adım HUD'da onayınızı bekliyor. Onay düğmelerle verilir; sesle ya da yazıyla verilmez.")
        }
        let decision = ContinuationSelector.decide(view, drift: report)
        lastDiagnostics = ContinuityDiagnostics(project: ref.name, sources: report.sources, reconciliation: report.lines, decision: describe(decision), bounds: bounds.summary)
        onActivity?("Continuation · \(ref.name): \(describe(decision))", .info)
        switch decision {
        case .alreadyRunning(let t):
            return tr(l, "“\(t.title)” is already running. Ask me for the status if you want details.", "“\(t.title)” zaten çalışıyor. Ayrıntı için durumu sorabilirsiniz.")
        case .nothingToContinue(let why):
            return tr(l, "\(ref.name): \(why) Tell me what to work on, or queue the next step (“next up is …”).", "\(ref.name): \(why == "There is no unfinished work, failed task or recorded next step for this project." ? "Yarım iş, başarısız görev ya da kayıtlı bir sonraki adım yok." : why) Ne yapacağımı söyleyin ya da sıradaki adımı yazın (“sırada … var”).")
        case .needsChoice(let cs):
            pendingChoice = (ref, cs)
            return ContinuityStatus.choice(cs, view: view, language: l)
        case .resumeInterrupted(let t):
            guard engine.resume(t.id) else { return tr(l, "I could not resume “\(t.title)” right now.", "“\(t.title)” şu an sürdürülemedi.") }
            noteSession(ref, taskID: t.id)
            return tr(l, "Resuming “\(t.title)” where it stopped. It re-checks what it had already done. Session: \(bounds.summary).", "“\(t.title)” kaldığı yerden sürdürülüyor; daha önce yaptıklarını yeniden doğruluyor. Oturum: \(bounds.summary).")
        case .replanInterrupted(let t, _), .retryFailed(let t):
            return await submit(goal: ContinuationGoal.build(decision, view: view, drift: report, bounds: bounds), kind: TaskKind(rawValue: t.kind) ?? .development, origin: t.id, ref: ref, title: t.title, language: l, channel: channel,
                                 note: { [self] in
                                     if case .retryFailed = decision { return tr(l, "“\(t.title)” failed last time (\(MemoryText.clip(t.failureReason ?? t.failureCategory ?? "unknown", 80))). I start a fresh attempt that looks at why first.", "“\(t.title)” geçen sefer başarısız oldu (\(MemoryText.clip(t.failureReason ?? t.failureCategory ?? "bilinmiyor", 80))). Önce nedenine bakan yeni bir deneme başlatıyorum.") }
                                     return tr(l, "The project changed since “\(t.title)” was interrupted (\(report.changedPaths.count) file\(report.changedPaths.count == 1 ? "" : "s")\(report.headMoved ? ", Git HEAD moved" : "")), so I do not resume the old plan: I re-plan it from the current files.",
                                               "“\(t.title)” yarım kaldığından beri proje değişmiş (\(report.changedPaths.count) dosya\(report.headMoved ? ", Git HEAD ilerlemiş" : "")); eski planı sürdürmüyorum, güncel dosyalardan yeniden planlıyorum.")
                                 }())
        case .startNext(let c):
            return await start(candidate: c, ref: ref, view: view, report: report, language: l, channel: channel)
        }
    }

    private func start(candidate c: NextCandidate, ref: ProjectRef, view: ProjectContinuityView? = nil, report: ReconciliationReport? = nil, language l: ReplyLanguage, channel: InputSource) async -> String {
        // A candidate the user picked from a choice is taken as the single direction; a design-sensitive one still only gets a proposal when picked blindly.
        let v: ProjectContinuityView
        let r: ReconciliationReport
        if let view, let report { v = view; r = report } else { let g = await gather(ref); v = g.view; r = g.report }
        if c.designSensitive && channel != .typed && view != nil {
            return ContinuityStatus.choice([c], view: v, language: l)
        }
        switch c.source {
        case .interrupted:
            guard let id = c.taskID, let t = v.interrupted.first(where: { $0.id == id }) else { return tr(l, "That task is no longer open.", "Bu görev artık açık değil.") }
            if r.hasDrift { return await submit(goal: ContinuationGoal.build(.replanInterrupted(t, drift: r.lines), view: v, drift: r, bounds: bounds), kind: TaskKind(rawValue: t.kind) ?? .development, origin: t.id, ref: ref, title: t.title, language: l, channel: channel, note: nil) }
            guard engine.resume(t.id) else { return tr(l, "I could not resume “\(t.title)” right now.", "“\(t.title)” şu an sürdürülemedi.") }
            noteSession(ref, taskID: t.id)
            return tr(l, "Resuming “\(t.title)”. Session: \(bounds.summary).", "“\(t.title)” sürdürülüyor. Oturum: \(bounds.summary).")
        case .failed:
            guard let id = c.taskID, let t = v.failed.first(where: { $0.id == id }) else { return tr(l, "That task is no longer retriable.", "Bu görev artık yeniden denenemez.") }
            return await submit(goal: ContinuationGoal.build(.retryFailed(t), view: v, drift: r, bounds: bounds), kind: TaskKind(rawValue: t.kind) ?? .development, origin: t.id, ref: ref, title: t.title, language: l, channel: channel, note: nil)
        case .checkpoint, .knownIssue:
            // The item leaves the queue now: the task owns it (if it fails, the failed-task tier — not the queue — brings it back).
            dequeue(c.title, ref: ref)
            return await submit(goal: ContinuationGoal.build(.startNext(c), view: v, drift: r, bounds: bounds), kind: .development, origin: nil, ref: ref, title: c.title, language: l, channel: channel, note: nil)
        }
    }

    private func submit(goal: String?, kind: TaskKind, origin: UUID?, ref: ProjectRef, title: String, language l: ReplyLanguage, channel: InputSource, note: String?) async -> String {
        guard let goal else { return tr(l, "There is nothing to submit.", "Gönderilecek bir şey yok.") }
        let bounds = self.bounds
        let preference = preferences.providerPreference
        let result = await engine.submit(goal: goal, kind: kind, workspacePath: ref.root, constraints: [ContinuationMarker.constraint], preference: preference == .auto ? nil : preference, title: title,
                                         destructiveRequested: false, originTaskID: origin, inputChannel: channel, prepare: { $0.continuation = bounds })
        switch result {
        case .success(let id):
            noteSession(ref, taskID: id)
            return (note.map { $0 + " " } ?? "") + tr(l, "Continuing “\(MemoryText.clip(title, 70))” as a bounded session (\(bounds.summary)).", "“\(MemoryText.clip(title, 70))” sınırlı bir oturum olarak sürdürülüyor (\(bounds.summary)).")
        case .failure(let e): return e.description
        }
    }

    private func noteSession(_ ref: ProjectRef, taskID: UUID) { try? repository?.recordContinuationSession(projectKey: ref.key, taskID: taskID) }

    private func dequeue(_ title: String, ref: ProjectRef) {
        guard var st = (try? repository?.continuityState(ref.key)) ?? nil else { return }
        let key = ResearchText.fold(title).filter { $0.isLetter || $0.isNumber }
        let before = st.queue.count
        st.queue.removeAll { ResearchText.fold($0).filter { $0.isLetter || $0.isNumber } == key }
        if st.queue.count != before { try? repository?.saveContinuity(st) }
    }

    private func describe(_ d: ContinuationDecision) -> String {
        switch d {
        case .resumeInterrupted(let t): "resume interrupted “\(t.title)”"
        case .replanInterrupted(let t, _): "re-plan interrupted “\(t.title)” (project changed)"
        case .retryFailed(let t): "retry failed “\(t.title)”"
        case .startNext(let c): "start next “\(c.title)” (\(c.source.rawValue))"
        case .needsChoice(let cs): "ask which of \(cs.count)"
        case .nothingToContinue: "nothing to continue"
        case .alreadyRunning(let t): "“\(t.title)” already running"
        }
    }

    // MARK: Project resolution (reuses V0.10 identity and aliases — no second identity system)

    private func resolve(_ name: String?) async -> Resolution {
        func known() -> [MemoryProjectRow] { (try? repository?.memoryProjects()) ?? [] }
        func ref(root: String) async -> ProjectRef? {
            guard FileManager.default.fileExists(atPath: root) else { return nil }
            let id: ProjectIdentity
            if let memory { id = await memory.resolver.resolve(root: root) } else { id = ProjectIdentity(key: "path:" + root, name: (root as NSString).lastPathComponent, kind: "path", rootPath: root) }
            let rows = known().filter { $0.key == id.key }
            let roots = Array(Set([id.rootPath, root] + rows.flatMap { ($0.rootPath.map { [$0] } ?? []) + $0.aliases }))
            return ProjectRef(key: id.key, name: id.name, root: id.rootPath, roots: roots)
        }
        if let name, !name.isEmpty {
            let want = ResearchText.fold(name)
            var candidates: [(String, String)] = known().compactMap { r in r.rootPath.map { (r.name, $0) } }
            if !preferences.projectRoot.isEmpty { candidates.append(((preferences.projectRoot as NSString).lastPathComponent, preferences.projectRoot)) }
            let hits = candidates.filter { let f = ResearchText.fold($0.0); return f == want || (want.count >= 3 && (f.hasPrefix(want) || want.hasPrefix(f) && f.count >= 3)) }
            for h in hits { if let r = await ref(root: h.1) { return .found(r) } }
            return .unknownName(name, Array(Set(candidates.map(\.0))).sorted().prefix(5).map { $0 })
        }
        let root = referencedRoot ?? preferences.projectRoot
        guard !root.isEmpty, let r = await ref(root: root) else { return .noProject }
        return .found(r)
    }

    // MARK: Gathering current truth

    /// The project the user has chosen, gathered for the Project panel (nil when none is chosen or it cannot be resolved).
    func gatherCurrent() async -> Gathered? {
        guard case .found(let ref) = await resolve(nil) else { return nil }
        return await gather(ref)
    }

    struct Gathered { var view: ProjectContinuityView; var report: ReconciliationReport; var snapshot: ProjectSnapshot }

    func gather(_ ref: ProjectRef, now: Date = Date()) async -> Gathered {
        let started = Date()
        let git = await GitTool.continuity(at: ref.root)
        let unity = Self.unityFacts(root: ref.root, editor: unityEditorState(ref.root))
        let checkpoint = (try? repository?.latestCheckpoint(projectKey: ref.key)) ?? nil
        let state = (try? repository?.continuityState(ref.key)) ?? nil
        let records = (try? repository?.continuityTasks(roots: ref.roots, limit: 60)) ?? []
        let digests: [TaskDigest] = records.enumerated().map { i, t in
            if i < ContinuityLimits.recentTasks, let steps = try? repository?.steps(taskID: t.id) {
                let counted = steps.filter { $0.state != .skipped && !$0.optional }
                return TaskDigest(t, passed: counted.filter { $0.state == .passed }.count, total: counted.count)
            }
            return TaskDigest(t)
        }
        let live = ((try? repository?.memories(projectKey: ref.key, statuses: [.current, .stale, .disputed], types: [.knownIssue, .constraint, .decision, .validationResult], limit: 80)) ?? []).map(MemoryDigest.init)
        let docs = ProjectDocsSummary.read(root: ref.root)
        let approvals = engine.pendingApprovals.filter { a in engine.view(a.taskID)?.task.workspaceRoot.map { ref.roots.contains($0) } ?? false }.count

        // Reconcile memory with CURRENT truth first (a stale fact is superseded by the inspection-derived one; the project wins).
        var corrections: [String] = []
        if let memory {
            await memory.truth.refreshGit(root: ref.root)
            for o in memory.service.reconcileWithTruth(projectKey: ref.key, projectRoot: ref.root) {
                if case .superseded(let newID) = o.outcome, let old = (try? repository?.memory(o.id)) ?? nil, let new = (try? repository?.memory(newID)) ?? nil {
                    corrections.append("\(o.key): memory said “\(MemoryText.clip(old.value ?? "", 40))”, the project says “\(MemoryText.clip(new.value ?? "", 40))”")
                }
            }
        }

        let later = checkpoint.flatMap { cp in try? repository?.jarvisFileChanges(roots: ref.roots, after: cp.createdAt) } ?? [:]
        let expected = ExpectedState(checkpoint: checkpoint, laterChanges: later)
        let watch = Set(expected.hashes.keys).union(git.dirtyPaths).union(git.untrackedPaths)
        let snapshot = await Self.snapshot(root: ref.root, git: git, unity: unity, paths: Array(watch.prefix(ContinuityLimits.maxFileHashes)), fingerprint: git.isRepository ? false : true)
        var committed: [String] = []
        if let old = expected.head, let new = git.head, old != new { committed = await GitTool.changedFiles(from: old, to: new, at: ref.root) }
        let report = ContinuityReconciler.reconcile(expected: expected, current: snapshot, committedSince: committed, memoryCorrections: corrections)

        let view = ContinuityBuilder.build(.init(key: ref.key, name: ref.name, root: ref.root, aliases: ref.roots.filter { $0 != ref.root }, docs: docs, tasks: digests, checkpoint: checkpoint, queue: state?.queue ?? [],
                                                  lastContinuationAt: state?.lastContinuationAt, git: git, unity: unity, memory: live, pendingApprovals: approvals, now: now))
        lastDiagnostics = ContinuityDiagnostics(project: ref.name, sources: report.sources, reconciliation: report.lines, decision: lastDiagnostics?.decision ?? "status", bounds: bounds.summary)
        _ = started
        return Gathered(view: view, report: report, snapshot: snapshot)
    }

    nonisolated static func unityFacts(root: String, editor: String?) -> ContinuityUnity? {
        guard let d = UnityProjectDetector.describe(root: root) else { return nil }
        return ContinuityUnity(version: d.declaredVersionRaw, renderPipeline: d.renderPipeline, packageCount: d.packages.count, sceneCount: d.scenes.count, bridgeInstalled: d.bridgeInstalled, hasTests: d.hasTestFramework, editor: editor)
    }

    /// Reads and hashes OFF the main actor; bounded in file count and size.
    nonisolated static func snapshot(root: String, git: ContinuityGit, unity: ContinuityUnity?, paths: [String], fingerprint: Bool) async -> ProjectSnapshot {
        await Task.detached(priority: .utility) {
            ProjectSnapshot(root: root, git: git, fileHashes: fileHashes(root: root, paths: paths), treeFingerprint: fingerprint ? treeFingerprint(root: root) : nil, unity: unity)
        }.value
    }

    nonisolated static func fileHashes(root: String, paths: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for p in paths.prefix(ContinuityLimits.maxFileHashes) {
            guard !p.contains(".."), !p.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: root).appendingPathComponent(p)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            if let size = (attrs[.size] as? NSNumber)?.intValue, size > 2_000_000 { out[p] = "big:\(size)"; continue }
            if let data = FileManager.default.contents(atPath: url.path) { out[p] = Redactor.sha256(data) }
        }
        return out
    }

    nonisolated static func treeFingerprint(root: String, limit: Int = 3_000) -> String {
        let skip: Set<String> = [".git", "Library", "Temp", "Logs", "obj", "build", ".build", "node_modules", "Builds", "UserSettings", ".idea", ".vs"]
        let exts: Set<String> = ["swift", "cs", "py", "js", "ts", "json", "md", "unity", "prefab", "mat", "asset", "anim", "controller", "shader", "txt", "yml", "yaml", "toml", "c", "cpp", "h", "m", "java", "kt", "go", "rs", "html", "css"]
        var lines: [String] = []
        if let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                if skip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
                guard exts.contains(url.pathExtension.lowercased()), let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]), v.isDirectory != true else { continue }
                lines.append("\(url.path.dropFirst(root.count)):\(v.fileSize ?? 0):\(Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0))")
                if lines.count >= limit { break }
            }
        }
        return Redactor.sha256(lines.sorted().joined(separator: "\n"))
    }

    // MARK: Checkpoints (event-driven: when a task finishes)

    /// Leaves the checkpoint a finished root task of a project implies. Called from the finish hook; nothing here runs on a timer.
    func taskFinished(_ v: TaskView, report: TaskReport?) async {
        let t = v.task
        guard enabled(), let repository, t.parentTaskID == nil, [.development, .readOnlyAnalysis].contains(t.kind), let root = t.workspaceRoot else { return }
        let id: ProjectIdentity
        if let memory { id = await memory.resolver.resolve(root: root) } else { id = ProjectIdentity(key: "path:" + root, name: (root as NSString).lastPathComponent, kind: "path", rootPath: root) }
        let git = await GitTool.continuity(at: root)
        let changes = (try? repository.taskFileChanges(taskID: t.id)) ?? []
        let changedPaths = Array(Set(changes.map(\.path))).sorted()
        let watch = Array(Set(changedPaths).union(git.dirtyPaths).union(git.untrackedPaths).prefix(ContinuityLimits.maxFileHashes))
        let snap = await Self.snapshot(root: root, git: git, unity: nil, paths: watch, fingerprint: !git.isRepository)
        var hashes = snap.fileHashes
        for c in changes where c.changeType == "deleted" { hashes[c.path] = "deleted" }

        let continuation = t.constraints.contains(ContinuationMarker.constraint)
        let steps = (try? repository.steps(taskID: t.id)) ?? []
        let counted = steps.filter { $0.state != .skipped && !$0.optional }
        let outcome: String
        switch t.state {
        case .completed: outcome = report?.outcome ?? "SUCCESS"
        case .failed: outcome = report?.outcome ?? "FAILED"
        case .cancelled: outcome = "STOPPED"
        default: outcome = t.state.label
        }
        var validated = Array((report?.validations ?? []).prefix(5))
        validated.insert("\(counted.filter { $0.state == .passed }.count)/\(counted.count) steps validated", at: 0)
        var remaining = steps.filter { $0.state != .passed && $0.state != .skipped && !$0.optional }.prefix(4).map(\.title)
        if let f = t.failureReason, t.state == .failed { remaining.insert("failed: " + MemoryText.clip(f, 120), at: 0) }
        var inconclusive = steps.filter { $0.optional && $0.state == .failed }.prefix(3).map { "optional step did not complete: \($0.title)" }
        inconclusive += (report?.advisories ?? []).prefix(2).map { "reviewer advice: " + MemoryText.clip($0, 100) }
        let st = (try? repository.continuityState(id.key)) ?? nil
        var cp = ContinuityCheckpoint(projectKey: id.key, taskID: t.id, kind: continuation ? "continuation" : "task", outcome: outcome, title: t.title)
        cp.gitHead = git.head; cp.gitBranch = git.branch; cp.dirtyPaths = git.dirtyPaths + git.untrackedPaths; cp.fileHashes = hashes; cp.treeFingerprint = snap.treeFingerprint
        cp.changed = changedPaths; cp.validated = validated; cp.remaining = Array(remaining); cp.next = st?.queue ?? []
        cp.unresolvedApprovals = ((try? repository.approvals(taskID: t.id)) ?? []).filter { $0.state == .pending }.count
        cp.inconclusive = inconclusive; cp.unity = Array((report?.unity ?? []).prefix(6))
        cp.summary = report?.userSummary ?? t.summary ?? ""
        try? repository.insert(cp)
        _ = try? repository.pruneCheckpoints(keep: 30)
        if continuation { onActivity?("Continuation checkpoint · \(id.name): \(outcome.lowercased()), \(validated.first ?? "")", .info) }
    }
}

/// The same secret screen the memory door uses, reached through one name here (queued text must never carry a credential).
enum SecretGate {
    static func containsSecret(_ s: String) -> Bool { MemoryGate.containsSecret(s) }
}
