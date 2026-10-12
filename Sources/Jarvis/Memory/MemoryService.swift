import Foundation

/// Does a research source reference point at something the V0.9 pipeline actually VERIFIED? Memory never trusts a page, only validated claims (DEC-109).
protocol ResearchEvidenceChecking: Sendable {
    func isValidated(_ source: MemorySource) -> Bool
}

struct RepositoryResearchEvidence: ResearchEvidenceChecking {
    let repository: JarvisRepository
    func isValidated(_ s: MemorySource) -> Bool {
        switch s.kind {
        case .researchClaim: return ((try? repository.database.readOne("SELECT 1 AS ok FROM research_claims WHERE id = ? AND status = 'verified'", [.text(s.ref)])) ?? nil) != nil
        case .researchCandidate: return ((try? repository.database.readOne("SELECT 1 AS ok FROM research_candidates WHERE id = ?", [.text(s.ref)])) ?? nil) != nil
        case .researchSession: return ((try? repository.database.readOne("SELECT 1 AS ok FROM research_sessions WHERE id = ? AND status = 'completed'", [.text(s.ref)])) ?? nil) != nil
        case .acquisition, .importTask: return ((try? repository.database.readOne("SELECT 1 AS ok FROM acquisitions WHERE id = ?", [.text(s.ref)])) ?? nil) != nil
        default: return false
        }
    }
}

enum MemoryUserError: Error, Equatable, CustomStringConvertible {
    case notFound, rejected(MemoryRejection), ambiguous([UUID]), conflictsWithCurrentState(String), disabled
    var description: String {
        switch self {
        case .notFound: "No such memory."
        case .rejected(let r): "That cannot be remembered: \(r)."
        case .ambiguous(let ids): "\(ids.count) memories match; please pick one."
        case .conflictsWithCurrentState(let w): "That contradicts the project's current state (\(w)); current project files win over memory."
        case .disabled: "Project Memory is turned off."
        }
    }
}

/// The curator and lifecycle owner of project memory. EVERYTHING that becomes memory passes `admit`: sanitation, secret/poison/authority gates, provenance,
/// dedupe, contradiction handling and supersession. Models and web pages only ever PROPOSE (`MemoryCandidate`); nothing here calls a model.
final class MemoryService: @unchecked Sendable {
    let repository: JarvisRepository
    var truth: any TruthProbing
    var research: (any ResearchEvidenceChecking)?
    var isEnabled: @Sendable () -> Bool = { true }
    /// Content-free observability (event name + short detail). Never memory text beyond a short, sanitized subject.
    var onEvent: (@Sendable (MemoryEvent) -> Void)?
    private let lock = NSRecursiveLock()
    private let clock: @Sendable () -> Date

    init(repository: JarvisRepository, truth: any TruthProbing = ProjectTruth(), research: (any ResearchEvidenceChecking)? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository; self.truth = truth; self.clock = clock
        self.research = research ?? RepositoryResearchEvidence(repository: repository)
    }

    /// Content-free observability hook shared with the retriever and the context builder.
    func note(_ project: String, _ kind: String, _ id: UUID? = nil, _ detail: String) { event(project, kind, id, detail) }

    private func event(_ project: String, _ kind: String, _ id: UUID?, _ detail: String) {
        let e = MemoryEvent(at: clock(), projectKey: project, kind: kind, memoryID: id, detail: detail)
        try? repository.insertMemoryEvent(e)
        onEvent?(e)
    }

    // MARK: - Admission (the single door)

    @discardableResult
    func admit(_ c: MemoryCandidate, projectKey: String, projectRoot: String? = nil) -> AdmitResult {
        lock.lock(); defer { lock.unlock() }
        guard isEnabled() else { return .rejected(.disabled) }
        let now = clock()

        // 1. text hygiene: anything credential-shaped is REFUSED (not "redacted and kept"): it must not reach SQLite, an embedding or a prompt
        let rawText = [c.summary, c.details ?? "", c.value ?? "", c.subject].joined(separator: "\n")
        if MemoryGate.containsSecret(rawText) || rawText.contains(OutputSanitizer.mask) { return reject(.secret, c, projectKey) }
        let summary = MemoryText.clip(c.summary, MemoryConstants.maxSummary)
        let details = c.details.map { MemoryText.clip($0, MemoryConstants.maxDetails) }.flatMap { $0.isEmpty ? nil : $0 }
        let isUser = c.origin == .user
        if c.summary.count > 6_000 { return reject(.tooLong, c, projectKey) }
        if summary.trimmingCharacters(in: .whitespaces).isEmpty { return reject(.empty, c, projectKey) }
        if !isUser && MemoryGate.isTrivial(summary) { return reject(.trivial, c, projectKey) }
        if isUser && MemoryText.words(summary).isEmpty { return reject(.empty, c, projectKey) }

        // 2. origin gates
        let trustedAuthor = [.document, .bootstrap, .inspection].contains(c.origin)       // the user's own repository: human-written, version-controlled
        if !trustedAuthor {
            if !isUser, MemoryGate.looksInjected(summary + "\n" + (details ?? "")) { return reject(.webInjection, c, projectKey) }
            if MemoryGate.grantsAuthority(summary + "\n" + (details ?? "")) { return reject(.authorityGrant, c, projectKey) }
        }
        if c.scope == .taskLocal { return reject(.taskLocal, c, projectKey) }

        // 3. provenance
        var sources = c.sources
        if isUser && !sources.contains(where: { $0.kind == .userStatement || $0.kind == .correction || $0.kind == .conversationTurn }) {
            sources.append(MemorySource(kind: .userStatement, ref: "explicit", label: "stated by the user", observedAt: now))
        }
        if c.origin == .model, let by = c.proposedBy, !sources.contains(where: { $0.kind == .agentRun }) {
            sources.append(MemorySource(kind: .agentRun, ref: by, label: "proposed by \(by)", observedAt: now))
        }
        guard !sources.isEmpty else { return reject(.noProvenance, c, projectKey) }
        if c.origin == .research {
            let research = sources.filter { [.researchClaim, .researchCandidate, .researchSession, .acquisition, .importTask].contains($0.kind) }
            guard !research.isEmpty, let checker = self.research, research.allSatisfy({ checker.isValidated($0) }) else { return reject(.unverifiedResearch, c, projectKey) }
        }
        if !isUser && !sources.contains(where: { $0.isVerifiable }) { return reject(.noProvenance, c, projectKey) }

        // 4. strength / status by origin: a model's statement is an inference until something verifiable supports it
        var strength = c.strength
        var status: MemoryStatus = .current
        if c.origin == .model {
            let corroborated = sources.contains { $0.isVerifiable && $0.kind != .agentRun }
            strength = corroborated ? min(strength, .supported) : .inferred
            if strength <= .weak { status = .unverified }
        }
        if isUser { strength = .authoritative }

        // 5. the item
        var item = MemoryItem(projectKey: projectKey, type: c.type, subject: MemoryText.clip(c.subject, 80), summary: summary, origin: c.origin)
        item.key = c.key; item.value = c.value; item.details = details; item.status = status; item.strength = strength; item.importance = c.importance
        item.area = c.area.map { MemoryText.clip($0, 40) }; item.tags = Array(c.tags.map { MemoryText.fold($0).replacingOccurrences(of: " ", with: "-") }.filter { !$0.isEmpty }.prefix(MemoryConstants.maxTags))
        item.createdAt = now; item.updatedAt = now; item.validFrom = c.validFrom
        item.lastVerifiedAt = c.lastVerifiedAt ?? ((c.origin == .inspection || isUser) ? now : nil)
        item.pinned = c.pinned; item.userCorrected = c.userCorrected; item.currentSensitive = c.currentSensitive
        item.language = MemoryText.guessLanguage(summary); item.sources = sources; item.relations = c.relations
        item.canonicalHash = MemoryText.canonicalHash(type: c.type, summary: summary, key: c.key, value: c.value)

        // 6. a memory the user forgot is not quietly resurrected by an automatic source
        if let t = ((try? repository.memories(projectKey: projectKey, canonicalHash: item.canonicalHash)) ?? []).first(where: { $0.status == .forgotten }), !isUser {
            _ = t; return reject(.forgotten, c, projectKey)
        }
        event(projectKey, "proposed", nil, "\(c.type.rawValue): \(MemoryText.clip(c.subject, 40))")

        // 7. current deterministic truth outranks everything (a keyed fact that the project's files contradict is not stored as current)
        if let key = c.key, let value = c.value, let t = truth.truth(for: key, projectRoot: projectRoot), MemoryText.fold(t.value) != MemoryText.fold(value) {
            if isUser { event(projectKey, "rejected", nil, "contradicts current state: \(key)"); return .rejected(.conflictsCurrent(key)) }
            if c.origin == .inspection || c.origin == .document || c.origin == .bootstrap {
                item.status = .stale; item.strength = min(item.strength, .weak); item.relations.append(MemoryRelation(predicate: "contradicts", targetKind: "entity", target: "truth:\(key)"))
            } else { return reject(.conflictsCurrent(key), c, projectKey) }
        }

        // 8. duplicates and conflicts among live items
        let live = ((try? repository.memories(projectKey: projectKey, statuses: [.current, .stale, .unverified, .disputed])) ?? []).filter { $0.scope == .project }
        if let dup = live.first(where: { $0.canonicalHash == item.canonicalHash && $0.status != .disputed }) {
            return merge(item, into: dup, now: now)
        }
        let conflicts = findConflicts(item, in: live)
        if conflicts.isEmpty {
            if let near = live.first(where: { $0.type == item.type && isNearDuplicate($0, item) }) { return merge(item, into: near, now: now) }
            return create(item)
        }
        return resolve(item, against: conflicts, now: now)
    }

    private func reject(_ r: MemoryRejection, _ c: MemoryCandidate, _ project: String) -> AdmitResult {
        event(project, "rejected", nil, "\(r) · \(c.type.rawValue)")
        return .rejected(r)
    }

    private func create(_ item: MemoryItem) -> AdmitResult {
        do { try repository.insertMemory(item) } catch { return .rejected(.empty) }
        event(item.projectKey, "accepted", item.id, "\(item.type.rawValue): \(MemoryText.clip(item.subject, 40))")
        return .created(item.id)
    }

    // MARK: Dedupe / contradiction

    private func isNearDuplicate(_ a: MemoryItem, _ b: MemoryItem) -> Bool {
        let ta = MemoryText.tokens(a.summary), tb = MemoryText.tokens(b.summary)
        return MemoryText.jaccard(ta, tb) >= 0.82 && MemoryText.numbers(a.summary) == MemoryText.numbers(b.summary) && MemoryText.hasNegation(a.summary) == MemoryText.hasNegation(b.summary)
    }

    /// Existing live items that say something INCOMPATIBLE: same key with another value, or a near-identical sentence whose numbers / negation differ.
    private func findConflicts(_ item: MemoryItem, in live: [MemoryItem]) -> [MemoryItem] {
        live.filter { other in
            if other.id == item.id { return false }
            if let k = item.key, k == other.key { return MemoryText.fold(item.value ?? item.summary) != MemoryText.fold(other.value ?? other.summary) }
            guard other.type == item.type || (other.type.isNormative && item.type.isNormative) else { return false }
            let j = MemoryText.jaccard(MemoryText.tokens(item.summary), MemoryText.tokens(other.summary))
            guard j >= 0.6 else { return false }
            return MemoryText.numbers(item.summary) != MemoryText.numbers(other.summary) || MemoryText.hasNegation(item.summary) != MemoryText.hasNegation(other.summary)
        }
    }

    private func merge(_ new: MemoryItem, into old: MemoryItem, now: Date) -> AdmitResult {
        var m = old
        for s in new.sources where !m.sources.contains(where: { $0.kind == s.kind && $0.ref == s.ref }) { m.sources.append(s) }
        m.strength = max(m.strength, new.strength); m.importance = max(m.importance, new.importance)
        if let v = new.lastVerifiedAt { m.lastVerifiedAt = max(m.lastVerifiedAt ?? .distantPast, v) }
        if new.origin == .user { m.userCorrected = m.userCorrected || new.userCorrected }
        if m.status == .stale, new.lastVerifiedAt != nil, new.status == .current { m.status = .current }
        if m.status == .unverified, m.strength >= .supported { m.status = .current }
        m.pinned = m.pinned || new.pinned
        m.updatedAt = now
        try? repository.updateMemory(m)
        event(m.projectKey, "merged", m.id, "duplicate of \(MemoryText.clip(m.subject, 40))")
        return .merged(m.id)
    }

    /// Conflict policy (DEC-110). Facts that change over time → the newer, at least as strong observation supersedes. Normative memory (decisions, constraints, …)
    /// → only something STRONGER supersedes; equal strength is a dispute shown to the user; a weaker newcomer is stored as UNVERIFIED and never displaces.
    private func resolve(_ item: MemoryItem, against conflicts: [MemoryItem], now: Date) -> AdmitResult {
        var item = item
        let changesOverTime: Bool = [.projectFact, .validationResult, .knownIssue].contains(item.type)
        let strongest = conflicts.map(\.strength).max() ?? .inferred
        let wins: Bool
        if item.origin == .user { wins = true }
        else if item.strength > strongest { wins = true }
        else if item.strength == strongest, changesOverTime, conflicts.allSatisfy({ item.validFrom >= $0.validFrom }), item.origin != .model { wins = true }
        else { wins = false }

        if wins {
            item.relations.append(contentsOf: conflicts.map { MemoryRelation(predicate: "supersedes", targetKind: "memory", target: $0.id.uuidString) })
            if conflicts.contains(where: { $0.pinned }) { item.pinned = true }
            do { try repository.insertMemory(item) } catch { return .rejected(.empty) }
            for var old in conflicts {
                old.status = .superseded; old.supersededBy = item.id; old.updatedAt = now; old.pinned = false
                try? repository.updateMemory(old); try? repository.deleteEmbedding(old.id)
            }
            event(item.projectKey, "superseded", item.id, "replaces \(conflicts.count) older: \(MemoryText.clip(item.subject, 40))")
            return .superseded(new: item.id, old: conflicts.map(\.id))
        }
        let equal = item.strength == strongest
        item.status = equal ? .disputed : .unverified
        item.relations.append(contentsOf: conflicts.map { MemoryRelation(predicate: "contradicts", targetKind: "memory", target: $0.id.uuidString) })
        do { try repository.insertMemory(item) } catch { return .rejected(.empty) }
        if equal {
            for var old in conflicts where old.status != .disputed {
                old.status = .disputed; old.updatedAt = now
                old.relations.append(MemoryRelation(predicate: "contradicts", targetKind: "memory", target: item.id.uuidString))
                try? repository.updateMemory(old)
            }
        }
        event(item.projectKey, "disputed", item.id, equal ? "unresolved conflict with \(conflicts.count) memory(ies)" : "weaker than existing memory; kept unverified")
        return .disputed(new: item.id, with: conflicts.map(\.id))
    }

    // MARK: - User actions

    /// "Remember that …": a user-authored, project-scoped memory. Impossible-vs-current-state statements are refused with the reason.
    @discardableResult
    func remember(_ statement: String, projectKey: String, projectRoot: String? = nil, now: Date? = nil) -> AdmitResult {
        guard isEnabled() else { return .rejected(.disabled) }
        let cls = MemoryStatementClassifier.classify(statement)
        let c = MemoryCandidate(type: cls.type, subject: cls.subject, key: cls.key, value: cls.value, summary: cls.summary, strength: .authoritative, importance: cls.importance, scope: cls.scope,
                                area: cls.area, tags: cls.tags, origin: .user, sources: [], pinned: false)
        return admit(c, projectKey: projectKey, projectRoot: projectRoot)
    }

    /// "Actually, we no longer use X": creates a new authoritative user memory that SUPERSEDES the old one; the old record and its provenance stay.
    @discardableResult
    func correct(_ id: UUID, with statement: String, projectRoot: String? = nil) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard isEnabled() else { throw MemoryUserError.disabled }
        guard var old = try repository.memory(id), old.status != .forgotten else { throw MemoryUserError.notFound }
        let cls = MemoryStatementClassifier.classify(statement)
        if MemoryGate.containsSecret(statement) { throw MemoryUserError.rejected(.secret) }
        if MemoryGate.grantsAuthority(statement) { throw MemoryUserError.rejected(.authorityGrant) }
        let summary = MemoryText.clip(statement, MemoryConstants.maxSummary)
        if let key = old.key, let value = cls.key == key ? cls.value : nil, let t = truth.truth(for: key, projectRoot: projectRoot), MemoryText.fold(t.value) != MemoryText.fold(value) {
            throw MemoryUserError.conflictsWithCurrentState(key)
        }
        let now = clock()
        var new = MemoryItem(projectKey: old.projectKey, type: old.type, subject: old.subject, summary: summary, origin: .user)
        new.key = old.key; new.value = cls.key == old.key ? cls.value : old.value
        new.status = .current; new.strength = .authoritative; new.importance = max(old.importance, .normal); new.area = old.area; new.tags = old.tags
        new.pinned = old.pinned; new.userCorrected = true; new.lastVerifiedAt = now; new.createdAt = now; new.updatedAt = now; new.validFrom = now
        new.language = MemoryText.guessLanguage(summary)
        new.sources = [MemorySource(kind: .correction, ref: old.id.uuidString, label: "user correction of an earlier memory", observedAt: now), MemorySource(kind: .userStatement, ref: "correction", label: "stated by the user", observedAt: now)]
        new.relations = [MemoryRelation(predicate: "corrects", targetKind: "memory", target: old.id.uuidString), MemoryRelation(predicate: "supersedes", targetKind: "memory", target: old.id.uuidString)] + old.relations.filter { $0.predicate == "affects" || $0.predicate == "about" }
        new.canonicalHash = MemoryText.canonicalHash(type: new.type, summary: summary, key: new.key, value: new.value)
        try repository.insertMemory(new)
        old.status = .superseded; old.supersededBy = new.id; old.updatedAt = now; old.pinned = false
        try repository.updateMemory(old); try? repository.deleteEmbedding(old.id)
        // anything else live with the same key is superseded too (one current value per key)
        if let key = new.key { for var other in try repository.memories(projectKey: new.projectKey, key: key) where other.id != new.id && other.id != old.id && other.status.isLive {
            other.status = .superseded; other.supersededBy = new.id; other.updatedAt = now; try repository.updateMemory(other); try? repository.deleteEmbedding(other.id)
        } }
        event(new.projectKey, "corrected", new.id, "supersedes \(MemoryText.clip(old.subject, 40))")
        return new.id
    }

    /// Forgetting stops a memory from being used in future context and removes its derived vector and its rationale text. It does NOT touch Git, task history,
    /// the audit trail or research evidence: those belong to their own systems (DEC-114).
    func forget(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var m = try repository.memory(id) else { throw MemoryUserError.notFound }
        m.status = .forgotten; m.forgottenAt = clock(); m.updatedAt = clock(); m.details = nil; m.pinned = false
        try repository.updateMemory(m); try repository.deleteEmbedding(id)
        event(m.projectKey, "forgotten", id, MemoryText.clip(m.subject, 40))
    }

    func restore(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var m = try repository.memory(id), m.status == .forgotten else { throw MemoryUserError.notFound }
        m.status = .current; m.forgottenAt = nil; m.updatedAt = clock()
        try repository.updateMemory(m)
        event(m.projectKey, "restored", id, MemoryText.clip(m.subject, 40))
    }

    func setPinned(_ id: UUID, _ pinned: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard var m = try repository.memory(id), m.status != .forgotten else { throw MemoryUserError.notFound }
        m.pinned = pinned; m.updatedAt = clock()
        try repository.updateMemory(m)
        event(m.projectKey, "pinned", id, pinned ? "pinned" : "unpinned")
    }

    func setImportance(_ id: UUID, _ importance: MemoryImportance) throws {
        lock.lock(); defer { lock.unlock() }
        guard var m = try repository.memory(id) else { throw MemoryUserError.notFound }
        m.importance = importance; m.updatedAt = clock()
        try repository.updateMemory(m)
    }

    /// Items that a "forget …" phrase could mean (lexical match over live items; the caller decides whether one match is clear enough).
    func forgetCandidates(matching phrase: String, projectKey: String, limit: Int = 5) -> [(item: MemoryItem, score: Double)] {
        let q = Set(MemoryText.tokens(phrase))
        guard !q.isEmpty else { return [] }
        let items = ((try? repository.memories(projectKey: projectKey, statuses: [.current, .stale, .disputed, .unverified])) ?? [])
        return items.map { i -> (MemoryItem, Double) in
            let t = Set(MemoryText.tokens(i.subject + " " + i.summary + " " + (i.area ?? "")))
            return (i, Double(q.intersection(t).count) / Double(q.count))
        }.filter { $0.1 > 0.3 }.sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.1) }
    }

    // MARK: - Staleness and truth (event-driven; called on use, never by a timer)

    /// Marks live memory whose verification is older than its type allows. Historical types never age. Returns the ids changed.
    @discardableResult
    func applyStaleness(projectKey: String, now: Date? = nil) -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        let now = now ?? clock()
        var changed: [UUID] = []
        for var m in (try? repository.memories(projectKey: projectKey, statuses: [.current])) ?? [] {
            let limit: TimeInterval? = m.currentSensitive ? 86_400 : m.type.defaultStaleAfter
            guard let limit, now.timeIntervalSince(m.lastVerifiedAt ?? m.createdAt) > limit else { continue }
            m.status = .stale; m.updatedAt = now
            try? repository.updateMemory(m); changed.append(m.id)
            event(projectKey, "stale", m.id, MemoryText.clip(m.subject, 40))
        }
        return changed
    }

    struct RevalidationOutcome: Equatable, Sendable { var id: UUID; var key: String; var outcome: Outcome; enum Outcome: Equatable, Sendable { case confirmed, superseded(by: UUID), unknown } }

    /// Compares every keyed live memory with CURRENT truth. A confirmed fact is re-stamped; a contradicted one is SUPERSEDED by a new inspection-derived item (the old
    /// record stays, historical). Keys no probe knows are left alone (and age normally).
    @discardableResult
    func reconcileWithTruth(projectKey: String, projectRoot: String?) -> [RevalidationOutcome] {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        var out: [RevalidationOutcome] = []
        for var m in ((try? repository.memories(projectKey: projectKey, statuses: [.current, .stale, .disputed, .unverified])) ?? []) {
            guard let key = m.key, let value = m.value, let t = truth.truth(for: key, projectRoot: projectRoot) else { continue }
            if MemoryText.fold(t.value) == MemoryText.fold(value) {
                // already confirmed within the last hour and nothing to change: no write (context building calls this often)
                if m.status == .current, let v = m.lastVerifiedAt, now.timeIntervalSince(v) < 3_600 { continue }
                m.lastVerifiedAt = now; m.updatedAt = now; if m.status == .stale || m.status == .disputed { m.status = .current }
                if !m.sources.contains(where: { $0.kind == t.source.kind && $0.ref == t.source.ref }) { m.sources.append(t.source) }
                try? repository.updateMemory(m); out.append(RevalidationOutcome(id: m.id, key: key, outcome: .confirmed))
                event(projectKey, "revalidated", m.id, "\(key) confirmed")
            } else {
                var new = MemoryItem(projectKey: projectKey, type: m.type, subject: m.subject, summary: Self.refreshedSummary(m, newValue: t.value), origin: .inspection)
                new.key = key; new.value = t.value; new.status = .current; new.strength = .authoritative; new.importance = m.importance; new.area = m.area; new.tags = m.tags
                new.lastVerifiedAt = now; new.createdAt = now; new.updatedAt = now; new.validFrom = now; new.language = m.language
                new.sources = [t.source]; new.relations = [MemoryRelation(predicate: "supersedes", targetKind: "memory", target: m.id.uuidString)]
                new.pinned = m.pinned
                new.canonicalHash = MemoryText.canonicalHash(type: new.type, summary: new.summary, key: key, value: t.value)
                if (try? repository.insertMemory(new)) != nil {
                    m.status = .superseded; m.supersededBy = new.id; m.updatedAt = now; m.pinned = false
                    try? repository.updateMemory(m); try? repository.deleteEmbedding(m.id)
                    out.append(RevalidationOutcome(id: m.id, key: key, outcome: .superseded(by: new.id)))
                    event(projectKey, "superseded", new.id, "\(key): current project state differs from memory")
                }
            }
        }
        return out
    }

    private static func refreshedSummary(_ old: MemoryItem, newValue: String) -> String {
        if let v = old.value, old.summary.contains(v) { return MemoryText.clip(old.summary.replacingOccurrences(of: v, with: newValue), MemoryConstants.maxSummary) }
        return MemoryText.clip("\(old.subject): \(newValue)", MemoryConstants.maxSummary)
    }

    // MARK: - Consolidation (bounded, derived, never destructive)

    /// Several live failures/episodes that share a `lesson:<slug>` tag support ONE lesson. The sources stay; the lesson cites them.
    @discardableResult
    func consolidateLessons(projectKey: String) -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        let live = (try? repository.memories(projectKey: projectKey, statuses: [.current, .stale])) ?? []
        var groups: [String: [MemoryItem]] = [:]
        for m in live where m.type == .failure || m.type == .episode { for t in m.tags where t.hasPrefix("lesson:") { groups[t, default: []].append(m) } }
        var made: [UUID] = []
        for (tag, members) in groups.sorted(by: { $0.key < $1.key }) where members.count >= 2 {
            let slug = String(tag.dropFirst(7))
            if live.contains(where: { $0.type == .lesson && $0.tags.contains(tag) }) { continue }
            let text = "Repeated experience (\(members.count) records) about \(slug.replacingOccurrences(of: "-", with: " ")): " + MemoryText.clip(members.first!.summary, 200)
            let cand = MemoryCandidate(type: .lesson, subject: slug.replacingOccurrences(of: "-", with: " "), summary: text, strength: .supported, importance: .normal, area: members.first?.area, tags: [tag], origin: .consolidation,
                                       sources: members.map { MemorySource(kind: .memory, ref: $0.id.uuidString, label: "supports: " + MemoryText.clip($0.subject, 50)) },
                                       relations: members.map { MemoryRelation(predicate: "derived_from", targetKind: "memory", target: $0.id.uuidString) })
            if case .created(let id) = admit(cand, projectKey: projectKey) { made.append(id) }
        }
        return made
    }
}
