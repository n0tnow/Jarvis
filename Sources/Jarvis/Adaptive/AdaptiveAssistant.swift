import Foundation

// MARK: - The conversational face of learning and capabilities (V0.14, DEC-230)
//
// Answers come from PERSISTED records only (no invented introspection). Anything that could change the system acts within its authority: show/status are free; disable/enable follow the
// permission envelope; benchmark runs only in the sandbox; install / update / removal only CREATE a request that a HUD button decides — typed or spoken “yes” never does.

@MainActor
protocol AdaptiveConversing: AnyObject {
    func recognizes(_ text: String) -> AdaptiveIntent?
    func reply(to intent: AdaptiveIntent, language: ReplyLanguage, channel: InputSource) async -> String
    /// Called for every accepted utterance (never consumes it): a correction becomes an observation for learning.
    func observe(_ text: String)
}

@MainActor
final class AdaptiveAssistant: AdaptiveConversing {
    let learning: LearningService
    let skills: SkillRegistry
    let registry: MCPRegistry
    let selfImprovement: SelfImprovementService
    let decisions: AdaptiveDecisionService
    @ObservationIgnored var discovery: MCPDiscovery?
    @ObservationIgnored var discoveryEnabled: () -> Bool = { true }
    @ObservationIgnored var projectKey: () -> String? = { nil }
    @ObservationIgnored var taskTitle: (UUID) -> String? = { _ in nil }
    @ObservationIgnored var enabled: () -> Bool = { true }
    private var lastMCP: String?

    init(learning: LearningService, skills: SkillRegistry, registry: MCPRegistry, selfImprovement: SelfImprovementService, decisions: AdaptiveDecisionService) {
        self.learning = learning; self.skills = skills; self.registry = registry; self.selfImprovement = selfImprovement; self.decisions = decisions
    }

    func recognizes(_ text: String) -> AdaptiveIntent? { enabled() ? AdaptiveIntentParser.recognize(text) : nil }
    func observe(_ text: String) { _ = learning.recordCorrection(text, projectKey: projectKey()) }

    private func tr(_ l: ReplyLanguage, _ en: String, _ tr: String) -> String { l == .tr ? tr : en }
    private func ago(_ d: Date, _ l: ReplyLanguage) -> String {
        let days = Int(Date().timeIntervalSince(d) / 86_400)
        return days <= 0 ? tr(l, "today", "bugün") : tr(l, "\(days) day(s) ago", "\(days) gün önce")
    }

    // MARK: - Reply

    func reply(to intent: AdaptiveIntent, language l: ReplyLanguage, channel: InputSource) async -> String {
        switch intent {
        case .learnedRecently: return learned(project: nil, l)
        case .learnedAboutProject: return learned(project: projectKey(), l)
        case .listRules: return rules(l)
        case .whyRule: return whyRule(l)
        case .workflowOrigin: return workflowOrigin(l)
        case .wantToImprove: return wantToImprove(l)
        case .missingCapabilities: return missing(l)
        case .listSkills: return skillList(l)
        case .learningStatus: return status(l)
        case .listMCPs: return listMCPs(l)
        case .activeMCPs: return activeMCPs(l)
        case .mcpRunning(let n): return running(n, l)
        case .whatIsMCP(let n): return whatIs(n, l)
        case .unusedMCPs(let days): return unused(days, l)
        case .findMCP(let domain, let words): return await find(domain: domain, words: words, l)
        case .recommendMCPs: return recommended(l)
        case .whyMCP(let n): return why(n, l)
        case .isMCPSafe(let n): return safe(n, l)
        case .disableMCP(let n): return await disable(n, l)
        case .enableMCP(let n): return enable(n, l)
        case .benchmarkMCP(let n): return await benchmark(n, l)
        case .removeMCP(let n): return remove(n, channel: channel, l)
        case .installMCP(let n): return install(n, l)
        case .updateMCP(let n): return update(n, l)
        }
    }

    // MARK: - Learning answers

    private func learned(project: String?, _ l: ReplyLanguage) -> String {
        let since = Date().addingTimeInterval(-14 * 86_400)
        var cs = learning.candidates(statuses: [.candidate, .testing, .validated, .proposed, .approved, .active], limit: 100).filter { $0.updatedAt >= since }
        if let project { cs = cs.filter { $0.projectKey == project || $0.scope.level == .global } }
        let active = learning.activeRules().filter { project == nil || $0.projectKey == project || $0.scope.level == .global }
        if cs.isEmpty && active.isEmpty {
            return tr(l, "Nothing worth keeping yet\(project.map { " about \($0)" } ?? ""). I have \(learning.signalCount) recorded signal(s) from finished work, but no pattern has reached three independent occurrences. Nothing was changed.",
                      "Henüz saklamaya değer bir şey yok\(project.map { " (\($0))" } ?? ""). Biten işlerden \(learning.signalCount) sinyal kaydettim ama hiçbir örüntü üç bağımsız tekrara ulaşmadı. Hiçbir şey değişmedi.")
        }
        let lines = cs.sorted { $0.confidence > $1.confidence }.prefix(5).map { "• [\($0.kind.label.uppercased()) · \($0.status.label)] \($0.title) — \($0.occurrenceCount) \(tr(l, "event(s)", "olay")), \(tr(l, "confidence", "güven")) \(String(format: "%.2f", $0.confidence))" }
        let head = tr(l, "Over the last two weeks I recorded:", "Son iki haftada kaydettiklerim:")
        let tail = tr(l, "Candidates change nothing until you activate them in Learning. \(active.count) rule(s) are active.", "Adaylar, Öğrenme ekranında etkinleştirene kadar hiçbir şeyi değiştirmez. \(active.count) kural etkin.")
        return ([head] + lines + [tail]).joined(separator: "\n")
    }

    private func rules(_ l: ReplyLanguage) -> String {
        let all = learning.rules(statuses: [.active, .disabled])
        guard !all.isEmpty else { return tr(l, "I have not created any rules. A rule needs repeated evidence and your approval before it is active.", "Henüz kural oluşturmadım. Bir kural, tekrarlayan kanıt ve onayın olmadan etkin olmaz.") }
        let lines = all.prefix(8).map { r -> String in
            let use = r.effectiveness.map { String(format: "%.0f%%", $0 * 100) } ?? tr(l, "not used yet", "henüz kullanılmadı")
            return "• [\(r.status.label) v\(r.version)] \(RuleEngine.describe(r.definition)) — \(r.origin); \(tr(l, "worked", "işe yaradı")) \(use)"
        }
        return ([tr(l, "Rules I created from evidence (each one is data from a closed vocabulary and can only add a requirement):", "Kanıttan oluşturduğum kurallar (her biri kapalı bir sözlükten veridir ve yalnızca bir gereksinim ekleyebilir):")] + lines).joined(separator: "\n")
    }

    private func whyRule(_ l: ReplyLanguage) -> String {
        guard let r = learning.rules(statuses: [.active, .disabled]).first else { return tr(l, "There is no rule to explain yet.", "Açıklanacak bir kural henüz yok.") }
        let c = r.candidateID.flatMap(learning.candidate)
        let ev = (c?.evidence ?? []).prefix(3).map { "  – \($0.kind.rawValue) \(String($0.sourceID.prefix(8))): \($0.note)" }
        let when = r.activatedAt.map { ago($0, l) } ?? "?"
        return ([tr(l, "Why: “\(r.title)” — \(RuleEngine.describe(r.definition)).", "Neden: “\(r.title)” — \(RuleEngine.describe(r.definition)).")] +
                [tr(l, "Evidence: \(c?.occurrenceCount ?? 0) independent event(s); activated \(when) \(r.version > 1 ? "(version \(r.version))" : "").", "Kanıt: \(c?.occurrenceCount ?? 0) bağımsız olay; \(when) etkinleştirildi.")] + ev +
                [tr(l, "You can disable or revert it in Learning.", "Öğrenme ekranından kapatabilir veya geri alabilirsin.")]).joined(separator: "\n")
    }

    private func workflowOrigin(_ l: ReplyLanguage) -> String {
        guard let s = skills.all().first(where: { !$0.builtIn }) else {
            return tr(l, "I have not learned any workflow yet. The built-in skills (\(skills.all().filter(\.builtIn).map(\.name).joined(separator: ", "))) are part of JARVIS, not learned.", "Henüz öğrenilmiş bir iş akışı yok. Yerleşik beceriler (\(skills.all().filter(\.builtIn).map(\.name).joined(separator: ", "))) JARVIS'in parçasıdır, öğrenilmiş değildir.")
        }
        return tr(l, "“\(s.name)”: \(s.origin). Evidence: \(s.evidence.count) finished task(s); used \(s.successCount) time(s) successfully, \(s.failureCount) failed. Status \(s.status.label).",
                  "“\(s.name)”: \(s.origin). Kanıt: \(s.evidence.count) biten görev; \(s.successCount) kez başarılı, \(s.failureCount) kez başarısız. Durum \(s.status.label).")
    }

    private func wantToImprove(_ l: ReplyLanguage) -> String {
        var lines = learning.candidates(statuses: [.candidate, .validated, .proposed], kinds: [.sourceCodeImprovement, .capabilityGap, .routingAdjustment]).prefix(5).map { "• \($0.title) — \($0.summary)" }
        lines += selfImprovement.proposals().filter { $0.status == .proposed }.prefix(3).map { "• \(tr(l, "Proposal", "Öneri")): \($0.title)" }
        guard !lines.isEmpty else { return tr(l, "Nothing in the records suggests a change to myself right now. I do not invent wishes.", "Şu an kayıtlarda kendimde bir değişiklik öneren bir şey yok. İstek uydurmam.") }
        let level = learning.settings().level
        return ([tr(l, "From the records (self-improvement level: \(level.label)):", "Kayıtlardan (kendini geliştirme seviyesi: \(level.label)):")] + lines +
                [tr(l, level >= .approvedSelfImprovement ? "I can open a development task for one of these only after your explicit approval." : "I cannot change my own source at this level; I can only describe and test.", level >= .approvedSelfImprovement ? "Bunlardan biri için ancak açık onayından sonra bir geliştirme görevi açabilirim." : "Bu seviyede kendi kaynağımı değiştiremem; yalnızca anlatabilir ve test edebilirim.")]).joined(separator: "\n")
    }

    private func missing(_ l: ReplyLanguage) -> String {
        let gaps = learning.candidates(statuses: [.candidate, .validated, .proposed, .active], kinds: [.capabilityGap])
        guard !gaps.isEmpty else { return tr(l, "No capability gap has reached three separate occurrences. A gap is evidence, not permission to install anything.", "Hiçbir yetenek eksikliği üç ayrı tekrara ulaşmadı. Eksiklik kanıttır, bir şey kurma izni değildir.") }
        let lines = gaps.prefix(5).map { c -> String in
            let best = c.payload.gap?.options.sorted { $0.rank < $1.rank }.first
            return "• \(c.title) (\(c.occurrenceCount)×)" + (best.map { " — \(tr(l, "first option", "ilk seçenek")): \($0.architecture)" } ?? "")
        }
        return ([tr(l, "Gaps seen in my own work:", "Kendi işimde gördüğüm eksikler:")] + lines + [tr(l, "Say “find an MCP for <area>” and I will research candidates; nothing is installed without your approval.", "“<alan> için bir MCP bul” dersen adayları araştırırım; onayın olmadan hiçbir şey kurulmaz.")]).joined(separator: "\n")
    }

    private func skillList(_ l: ReplyLanguage) -> String {
        let all = skills.all()
        guard !all.isEmpty else { return tr(l, "There are no skills yet.", "Henüz beceri yok.") }
        return ([tr(l, "Skills (reusable, validated workflows — they still run through the normal engine and approvals):", "Beceriler (yeniden kullanılabilir, doğrulanmış iş akışları — yine normal motor ve onaylar üzerinden çalışır):")] +
                all.prefix(10).map { "• \($0.name) [\($0.status.label)\($0.builtIn ? " · built in" : " · learned")] — \($0.successCount)✓ \($0.failureCount)✗" }).joined(separator: "\n")
    }

    private func status(_ l: ReplyLanguage) -> String {
        let cs = learning.candidates(limit: 500)
        let by = Dictionary(grouping: cs, by: \.status).mapValues(\.count)
        let level = learning.settings().level
        return tr(l, "Learning: level \(level.label); \(learning.signalCount) signals; candidates \(cs.count) (\(by[.candidate] ?? 0) open, \(by[.active] ?? 0) active, \(by[.rejected] ?? 0) rejected); \(learning.activeRules().count) active rule(s); \(skills.active().count) skill(s); \(decisions.pending().count) waiting for your decision.",
                  "Öğrenme: seviye \(level.label); \(learning.signalCount) sinyal; aday \(cs.count) (\(by[.candidate] ?? 0) açık, \(by[.active] ?? 0) etkin, \(by[.rejected] ?? 0) reddedildi); \(learning.activeRules().count) etkin kural; \(skills.active().count) beceri; \(decisions.pending().count) karar bekliyor.")
    }

    // MARK: - Capability answers

    private func resolve(_ name: String?) -> MCPServerRecord? {
        if let name, let s = registry.find(name) { lastMCP = s.id; return s }
        if name == nil, let id = lastMCP, let s = registry.server(id) { return s }
        return nil
    }
    private func notFound(_ name: String?, _ l: ReplyLanguage) -> String {
        let known = registry.servers().filter { $0.status != .removed }.map(\.name)
        if let name { return tr(l, "I don't know an MCP called “\(name)”.\(known.isEmpty ? " The registry is empty." : " Known: \(known.prefix(6).joined(separator: ", ")).")", "“\(name)” adında bir MCP tanımıyorum.\(known.isEmpty ? " Kayıt defteri boş." : " Bildiklerim: \(known.prefix(6).joined(separator: ", ")).")") }
        return tr(l, "Which MCP do you mean? Say its name, for example “Blender MCP”.", "Hangi MCP'yi kastediyorsun? Adını söyle, örneğin “Blender MCP”.")
    }

    private func line(_ s: MCPServerRecord, _ l: ReplyLanguage) -> String {
        "• \(s.name) [\(s.status.label)\(s.revalidationRequired ? " · REVALIDATION REQUIRED" : "")\(registry.isRunning(s.id) ? " · running" : "")] v\(s.version) — \(s.domain); \(s.envelopeLabels.joined(separator: ", "))"
    }

    private func listMCPs(_ l: ReplyLanguage) -> String {
        let all = registry.servers().filter { $0.status != .removed }
        guard !all.isEmpty else { return tr(l, "No MCP is registered or discovered yet. Say “find an MCP for audio”, for example, and I will research candidates.", "Henüz kayıtlı veya keşfedilmiş MCP yok. Örneğin “ses için bir MCP bul” dersen adayları araştırırım.") }
        let installed = all.filter { [.installed, .active, .degraded, .disabled].contains($0.status) }, candidates = all.filter { ![.installed, .active, .degraded, .disabled].contains($0.status) }
        var out: [String] = []
        if !installed.isEmpty { out += [tr(l, "Installed:", "Kurulu:")] + installed.map { line($0, l) } }
        if !candidates.isEmpty { out += [tr(l, "Candidates (nothing installed):", "Adaylar (hiçbiri kurulu değil):")] + candidates.prefix(8).map { line($0, l) } }
        return out.joined(separator: "\n")
    }

    private func activeMCPs(_ l: ReplyLanguage) -> String {
        let a = registry.activeServers
        guard !a.isEmpty else { return tr(l, "No MCP is active.", "Etkin MCP yok.") }
        return ([tr(l, "Active:", "Etkin:")] + a.map(\.self).map { line($0, l) }).joined(separator: "\n")
    }

    private func running(_ name: String?, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        let proc = registry.isRunning(s.id) ? tr(l, "its process is running now", "süreci şu an çalışıyor") : tr(l, "no process is running (servers start only when a task needs them)", "çalışan süreç yok (sunucular yalnızca bir görev gerektirdiğinde başlar)")
        return tr(l, "\(s.name): \(s.status.label.lowercased()), health \(s.health.label); \(proc).\(s.revalidationRequired ? " It must be revalidated first: \(s.revalidationReason ?? "")." : "")",
                  "\(s.name): \(s.status.label.lowercased()), sağlık \(s.health.label); \(proc).\(s.revalidationRequired ? " Önce yeniden doğrulanmalı: \(s.revalidationReason ?? "")." : "")")
    }

    private func whatIs(_ name: String?, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        let caps = s.wrappers.map(\.capability).joined(separator: ", ")
        return tr(l, "\(s.name) — \(s.discovery?.expectedBenefit ?? s.domain). Typed capabilities offered to agents: \(caps.isEmpty ? "none" : caps). Permissions: \(s.envelopeLabels.joined(separator: ", ")). Source: \(s.provenance).",
                  "\(s.name) — \(s.discovery?.expectedBenefit ?? s.domain). Ajanlara sunulan tipli yetenekler: \(caps.isEmpty ? "yok" : caps). İzinler: \(s.envelopeLabels.joined(separator: ", ")). Kaynak: \(s.provenance).")
    }

    private func unused(_ days: Int, _ l: ReplyLanguage) -> String {
        let u = registry.advice(unusedDays: days).filter { $0.kind == "unused" }
        guard !u.isEmpty else { return tr(l, "Every MCP was used in the last \(days) days (or none is installed).", "Her MCP son \(days) gün içinde kullanıldı (veya hiç kurulu yok).") }
        return (u.map { "• \($0.detail)" } + [tr(l, "Unused is not the same as safe to delete — removal stays your decision.", "Kullanılmamış olmak silmek için güvenli olmak demek değildir — silme kararı sende kalır.")]).joined(separator: "\n")
    }

    private func recommended(_ l: ReplyLanguage) -> String {
        let r = registry.servers(statuses: [.recommended, .benchmarked])
        guard !r.isEmpty else { return tr(l, "No candidate has cleared the bar yet (benchmarked in the sandbox, licence known, price verified). A valid answer is “none right now”.", "Henüz hiçbir aday çıtayı geçmedi (sandbox'ta ölçülmüş, lisansı bilinen, fiyatı doğrulanmış). “Şu an yok” geçerli bir cevaptır.")}
        return ([tr(l, "Recommendations (nothing is installed until you approve):", "Öneriler (onaylamadan hiçbir şey kurulmaz):")] + r.map { s -> String in
            let rec = MCPBenchmarkRunner.recommendation(for: s)
            return line(s, l) + (rec.recommend ? " — " + tr(l, "clears the bar", "çıtayı geçti") : " — " + tr(l, "not recommended: ", "önerilmiyor: ") + rec.reasons.joined(separator: "; "))
        }).joined(separator: "\n")
    }

    private func why(_ name: String?, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) ?? registry.servers(statuses: [.recommended]).first else { return notFound(name, l) }
        let rec = MCPBenchmarkRunner.recommendation(for: s)
        let b = s.benchmark.map { "\($0.passedCount)/\($0.cases.count) benchmark cases, cold start \(Int($0.coldStartMS)) ms" } ?? "not benchmarked"
        return tr(l, "\(s.name): \(rec.recommend ? "it clears the bar" : "it does not clear the bar (\(rec.reasons.joined(separator: "; ")))"). Evidence: \(b); licence \(s.discovery?.license ?? "unknown"); activity \(s.discovery?.lastPush.map { ago($0, l) } ?? "unknown"); source \(s.discovery?.sourceKind ?? s.provenance), checked \(s.discovery?.freshness() ?? "—").",
                  "\(s.name): \(rec.recommend ? "çıtayı geçiyor" : "çıtayı geçmiyor (\(rec.reasons.joined(separator: "; ")))"). Kanıt: \(b); lisans \(s.discovery?.license ?? "bilinmiyor"); kaynak \(s.discovery?.sourceKind ?? s.provenance).")
    }

    private func safe(_ name: String?, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        let findings = (s.discovery?.findings ?? []) + (s.benchmark?.findings ?? [])
        let high = findings.filter { $0.severity == .high }.map { "\($0.category): \($0.detail)" }
        return tr(l, "I cannot call any MCP “safe”. Evidence for \(s.name): \(MCPInspector.verdict(findings))\(high.isEmpty ? "" : " High-risk: " + Set(high).prefix(3).joined(separator: "; ")). Sandbox: \(s.benchmark?.boundary ?? "not yet run"). Credentials: \(s.credentialRequirement). Network: \(s.network).",
                  "Hiçbir MCP'ye “güvenli” diyemem. \(s.name) için kanıt: \(MCPInspector.verdict(findings))\(high.isEmpty ? "" : " Yüksek risk: " + Set(high).prefix(3).joined(separator: "; ")). Sandbox: \(s.benchmark?.boundary ?? "henüz çalıştırılmadı"). Kimlik bilgisi: \(s.credentialRequirement). Ağ: \(s.network).")
    }

    private func find(domain: MCPDomain?, words: String, _ l: ReplyLanguage) async -> String {
        guard discoveryEnabled() else { return tr(l, "MCP discovery is switched off in Settings → Adaptive learning.", "MCP keşfi Ayarlar → Uyarlanabilir öğrenme bölümünde kapalı.") }
        guard let domain else { return tr(l, "For which area? For example audio, 3D / Blender, design, animation or Unity.", "Hangi alan için? Örneğin ses, 3D / Blender, tasarım, animasyon veya Unity.") }
        guard let discovery else { return tr(l, "Research is not available in this session.", "Bu oturumda araştırma kullanılamıyor.") }
        let report = await discovery.search(domain: domain, limit: 5)
        for r in report.records.prefix(8) { registry.addCandidate(Self.candidateRecord(from: r)) }
        let credible = report.credible
        var out = [tr(l, "Researched “\(domain.label)” in: \(report.sourcesQueried.joined(separator: "; ")). \(report.records.count) lead(s); \(credible.count) clear the bar (licence known, active within a year, a repository to inspect).", "“\(domain.label)” için araştırdım: \(report.sourcesQueried.joined(separator: "; ")). \(report.records.count) ipucu; \(credible.count) tanesi çıtayı geçiyor (lisans belli, bir yıl içinde etkin, incelenebilir depo).")]
        if credible.isEmpty { out.append(tr(l, "No candidate currently clears the bar. Nothing was installed.", "Şu an çıtayı geçen aday yok. Hiçbir şey kurulmadı.")) }
        for r in credible.prefix(4) { out.append("• \(r.name) — \(r.license ?? "?"), \(r.stars.map { "\($0)★" } ?? "?"), \(r.sourceKind)") }
        out.append(tr(l, "Leads are saved as DISCOVERED. Inspecting or benchmarking one is a separate step; installing needs your approval.", "İpuçları KEŞFEDİLDİ olarak kaydedildi. İncelemek veya ölçmek ayrı bir adımdır; kurmak onayını gerektirir."))
        return out.joined(separator: "\n")
    }

    static func candidateRecord(from d: MCPDiscoveryRecord) -> MCPServerRecord {
        let id = MCPRegistry.slug(d.name).isEmpty ? UUID().uuidString.prefix(8).lowercased() : MCPRegistry.slug(d.name)
        return MCPServerRecord(id: String(id), name: d.name, domain: d.domain, status: .discovered, version: d.version ?? "", executableHash: nil, launch: MCPLaunch(executable: "", arguments: []), tools: [], wrappers: [], envelope: [.read],
                               allowedProjects: [], network: d.networkRequirement.hasPrefix("required") ? "required" : "unknown", credentialRequirement: d.credentialRequirement, health: .available, benchmark: nil, discovery: d,
                               provenance: "\(d.sourceKind): \(d.sourceURL)")
    }

    // MARK: - Management (within authority)

    private func disable(_ name: String?, _ l: ReplyLanguage) async -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        switch await registry.disable(s.id) {
        case .disabled: return tr(l, "\(s.name) is switched off. Nothing was deleted; say “turn it on” to re-enable it.", "\(s.name) kapatıldı. Hiçbir şey silinmedi; yeniden açmak için “aç” de.")
        case .alreadyDisabled: return tr(l, "\(s.name) is already off.", "\(s.name) zaten kapalı.")
        case .notFound: return tr(l, "\(s.name) cannot be switched off from its state (\(s.status.label.lowercased())).", "\(s.name) bu durumdan (\(s.status.label.lowercased())) kapatılamaz.")
        case .inUse(let ids):
            let titles = ids.compactMap { taskTitle($0) }.prefix(2).joined(separator: ", ")
            return tr(l, "\(s.name) is being used by \(titles.isEmpty ? "\(ids.count) task(s)" : "“\(titles)”") right now. I did not stop it. Stop or finish that task first, then ask again.", "\(s.name) şu anda \(titles.isEmpty ? "\(ids.count) görevde" : "“\(titles)” görevinde") kullanılıyor. Durdurmadım. Önce o görevi durdur veya bitir, sonra tekrar iste.")
        }
    }

    private func enable(_ name: String?, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        switch registry.enable(s.id) {
        case .enabled: return tr(l, "\(s.name) is on. It starts only when a task needs it.", "\(s.name) açıldı. Yalnızca bir görev gerektirdiğinde başlar.")
        case .notFound: return notFound(name, l)
        case .refused(let why): return tr(l, "I cannot switch \(s.name) on: \(why).", "\(s.name) açılamıyor: \(why).")
        case .needsApproval: return tr(l, "\(s.name) asks for more than read access (\(s.envelopeLabels.joined(separator: ", "))), so switching it on needs your click in Capabilities. A spoken or typed yes does not count.", "\(s.name) salt okumadan fazlasını istiyor (\(s.envelopeLabels.joined(separator: ", "))), bu yüzden açmak için Yetenekler ekranında tıklaman gerekir. Sesli veya yazılı “evet” sayılmaz.")
        }
    }

    private func benchmark(_ name: String?, _ l: ReplyLanguage) async -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        guard !s.launch.executable.isEmpty else {
            return tr(l, "\(s.name) is only a research lead — there is nothing to run yet. Benchmarking needs it staged in the sandbox first (a separate step that downloads nothing into your projects).", "\(s.name) yalnızca bir araştırma ipucu — henüz çalıştırılacak bir şey yok. Ölçüm için önce sandbox'a hazırlanması gerekir (projelerine hiçbir şey indirmeyen ayrı bir adım).")
        }
        if s.status == .discovered { registry.inspect(s.id, sourceDirectory: nil) }
        let spec = s.isFixture ? MCPBenchmarkSpec.fixture : MCPBenchmarkSpec.domain(s.domain)
        guard let r = await MCPBenchmarkRunner.run(registry: registry, serverID: s.id, spec: spec, allowNetwork: s.envelope.contains(.network)) else { return notFound(name, l) }
        return tr(l, "Benchmarked \(s.name) in the sandbox: \(r.passedCount)/\(r.cases.count) cases passed, cold start \(Int(r.coldStartMS)) ms, warm call \(Int(r.warmCallMS)) ms, cleanup \(r.cleanupOK ? "complete" : "INCOMPLETE"). Boundary: \(r.boundary)",
                  "\(s.name) sandbox'ta ölçüldü: \(r.passedCount)/\(r.cases.count) senaryo geçti, soğuk başlangıç \(Int(r.coldStartMS)) ms, sıcak çağrı \(Int(r.warmCallMS)) ms, temizlik \(r.cleanupOK ? "tamam" : "EKSİK"). Sınır: \(r.boundary)")
    }

    private func remove(_ name: String?, channel: InputSource, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        switch registry.requestRemoval(s.id) {
        case .inUse(let ids):
            let titles = ids.compactMap { taskTitle($0) }.prefix(2).joined(separator: ", ")
            return tr(l, "I cannot remove \(s.name) while it is used by \(titles.isEmpty ? "an active task" : "“\(titles)”"). Stop or finish that task first.", "\(s.name) \(titles.isEmpty ? "etkin bir görev" : "“\(titles)”") tarafından kullanılırken kaldırılamaz. Önce o görevi durdur veya bitir.")
        case .notFound: return notFound(name, l)
        case .requested:
            let o = registry.ownership(s.id)
            let other = o?.otherFilesInDirectory.isEmpty == false ? tr(l, " \(o!.otherFilesInDirectory.count) other file(s) next to it are not mine and stay.", " Yanındaki \(o!.otherFilesInDirectory.count) başka dosya benim değil ve kalır.") : ""
            return tr(l, "I created a removal request for \(s.name): it would delete only what JARVIS owns (\(o?.ownedFiles.count ?? 0) file(s), its registry entry and cache).\(other) Nothing is deleted until you press Approve in Capabilities — saying yes does not approve it.",
                      "\(s.name) için bir kaldırma isteği oluşturdum: yalnızca JARVIS'e ait olanı siler (\(o?.ownedFiles.count ?? 0) dosya, kayıt girdisi ve önbellek).\(other) Yetenekler ekranında Onayla'ya basmadan hiçbir şey silinmez — “evet” demek onaylamaz.")
        }
    }

    private func install(_ name: String?, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        guard s.status == .recommended else {
            return tr(l, "\(s.name) is \(s.status.label.lowercased()). Only a RECOMMENDED server can be registered — it must be inspected, benchmarked in the sandbox and clear the bar first.", "\(s.name) şu an \(s.status.label.lowercased()). Yalnızca ÖNERİLEN bir sunucu kaydedilebilir — önce incelenmeli, sandbox'ta ölçülmeli ve çıtayı geçmeli.")
        }
        guard registry.requestInstall(s.id, allowedProjects: projectKey().map { [$0] } ?? []) != nil else { return tr(l, "I could not create the request.", "İsteği oluşturamadım.") }
        return tr(l, "I created a registration request for \(s.name) showing exactly its permissions. It is not installed until you press Approve in Capabilities — saying yes does not approve it.", "\(s.name) için izinlerini tam olarak gösteren bir kayıt isteği oluşturdum. Yetenekler ekranında Onayla'ya basmadan kurulmaz — “evet” demek onaylamaz.")
    }

    private func update(_ name: String?, _ l: ReplyLanguage) -> String {
        guard let s = resolve(name) else { return notFound(name, l) }
        guard let v = s.discovery?.version, v != s.version, registry.requestUpdate(s.id, toVersion: v) != nil else {
            return tr(l, "I know of no newer version of \(s.name) than \(s.version). Updates are never automatic; a newer version creates a request and is benchmarked again before use.", "\(s.name) için \(s.version) sürümünden yenisini bilmiyorum. Güncellemeler asla otomatik değildir; yeni sürüm bir istek oluşturur ve kullanılmadan önce yeniden ölçülür.")
        }
        return tr(l, "I created an update request for \(s.name) (\(s.version) → \(v)). It needs your approval and a new benchmark before it is used.", "\(s.name) için güncelleme isteği oluşturdum (\(s.version) → \(v)). Kullanılmadan önce onayın ve yeni bir ölçüm gerekir.")
    }
}
