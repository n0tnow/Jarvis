import Foundation

// MARK: - “Is Claude ready?” “Ses sistemi hazır mı?” “MCP’ler sağlıklı mı?” — answered from the readiness picture (V0.15)
//
// Deterministic, EN + TR, typed and spoken alike (voice is only another input source). It reads `ReadinessService`; it starts nothing, installs nothing and approves nothing. A negative state is
// always said as it is.

enum ReadinessIntent: Equatable, Sendable {
    case overall
    case provider(String)           // claude | codex | opencode
    case voice
    case mcp
    case permissions
    case localModels(String?)       // qwen | whisper | vision | nil
    case unity
    case version
}

@MainActor
protocol ReadinessConversing: AnyObject {
    func recognizes(_ text: String) -> ReadinessIntent?
    func reply(to intent: ReadinessIntent, language: ReplyLanguage) -> String
}

enum ReadinessIntentParser {
    private static func tokens(_ raw: String) -> [String] {
        let f = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        return String(f.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ").map(String.init)
    }

    static func recognize(_ raw: String) -> ReadinessIntent? {
        let t = tokens(raw), f = t.joined(separator: " ")
        guard !t.isEmpty, t.count <= 12 else { return nil }
        func has(_ w: String...) -> Bool { w.contains { t.contains($0) } }
        func hasPrefix(_ p: String...) -> Bool { t.contains { w in p.contains { w.hasPrefix($0) } } }
        func phrase(_ p: String...) -> Bool { p.contains { f.contains($0) } }

        if phrase("hangi surum", "what version", "which version", "surumun ne", "your version", "surumunuz") { return .version }
        // A question about readiness / health / installation. Plain "is it running" questions belong to the MCP and agent status handlers.
        let asks = hasPrefix("hazir", "ready", "saglikli", "healthy", "health", "kurulu", "installed", "calisir", "usable", "kullanilabilir") || phrase("var mi", "is there", "do i have", "sahip miyim")
        guard asks else { return nil }

        if has("claude") { return .provider("claude") }
        if has("codex") { return .provider("codex") }
        if has("opencode") || phrase("open code") { return .provider("opencode") }
        if hasPrefix("mcp") { return .mcp }
        if has("qwen") { return .localModels("qwen") }
        if has("whisper") { return .localModels("whisper") }
        if phrase("yerel model", "local model") { return .localModels(nil) }
        if phrase("gorsel model", "vision model", "visual model") || has("vision") { return .localModels("vision") }
        if has("unity") { return .unity }
        if hasPrefix("izin") || has("permissions", "permission", "accessibility", "erisilebilirlik") || phrase("ekran kaydi", "screen recording") { return .permissions }
        if has("ses", "voice", "mikrofon", "microphone", "konusma", "speech", "tts", "stt") { return .voice }
        if phrase("sistem", "her sey", "everything", "system", "jarvis", "all systems", "sistemler") { return .overall }
        return nil
    }
}

@MainActor
final class ReadinessAssistant: ReadinessConversing {
    let service: ReadinessService
    init(service: ReadinessService) { self.service = service }

    func recognizes(_ text: String) -> ReadinessIntent? { ReadinessIntentParser.recognize(text) }

    private func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    static func phrase(_ s: ReadinessState, _ l: ReplyLanguage) -> String {
        func p(_ en: String, _ trk: String) -> String { l == .tr ? trk : en }
        switch s {
        case .ready: return p("ready", "hazır")
        case .available: return p("installed, not verified yet", "kurulu, henüz doğrulanmadı")
        case .notInstalled: return p("not installed", "kurulu değil")
        case .signInRequired: return p("installed but needs you to sign in", "kurulu ama oturum açmanız gerekiyor")
        case .permissionNeeded: return p("needs a permission", "izin gerekiyor")
        case .optionalAbsent: return p("not set up (optional)", "kurulmamış (isteğe bağlı)")
        case .notRunning: return p("not running (idle, as expected)", "çalışmıyor (beklenen boşta durumu)")
        case .degraded(let w): return p("degraded — \(w)", "sorunlu — \(w)")
        case .stale(let w): return p("last known state is old — \(w)", "son bilinen durum eski — \(w)")
        case .unknown: return p("not checked yet", "henüz kontrol edilmedi")
        case .unavailable(let w): return p("unavailable — \(w)", "kullanılamıyor — \(w)")
        }
    }

    private func line(_ id: String, _ l: ReplyLanguage, snapshot: ReadinessSnapshot) -> String? {
        guard let i = snapshot.item(id) else { return nil }
        return "\(i.name): \(Self.phrase(i.state, l))."
    }

    func reply(to intent: ReadinessIntent, language l: ReplyLanguage) -> String {
        let snap = service.refresh()
        func join(_ ids: [String]) -> String { ids.compactMap { line($0, l, snapshot: snap) }.joined(separator: " ") }
        switch intent {
        case .version:
            return tr(l, "JARVIS \(AppInfo.versionLine) (\(AppInfo.milestone)).", "JARVIS \(AppInfo.versionLine) (\(AppInfo.milestone)).")
        case .provider(let which):
            let id = "provider." + which
            guard let i = snap.item(id) else { return tr(l, "I have not checked the providers in this run.", "Bu çalıştırmada sağlayıcıları kontrol etmedim.") }
            var out = "\(i.name): \(Self.phrase(i.state, l))."
            if i.state == .ready, which != "opencode" { out += tr(l, " Checked with a safe status command; no model request was made.", " Güvenli bir durum komutuyla doğrulandı; model isteği yapılmadı.") }
            if i.state == .signInRequired { out += tr(l, " JARVIS cannot sign in for you.", " Sizin yerinize oturum açamam.") }
            return out
        case .voice:
            return join(["voice.mic", "voice.stt", "voice.neural", "voice.wake"]) + " " + snap.items.filter { $0.id.hasPrefix("voice.tts.") }.prefix(2).map { "\($0.name): \(Self.phrase($0.state, l))." }.joined(separator: " ")
        case .mcp:
            return join(["mcp.summary"])
        case .permissions:
            return join(["voice.mic", "computer.ax", "computer.screen", "perm.notifications"])
        case .localModels(let kind):
            switch kind {
            case "qwen": return join(["local.qwen"])
            case "whisper": return join(["local.whisper"])
            case "vision": return join(["local.vision"])
            default: return join(["local.qwen", "local.vision", "local.whisper", "local.embedding"])
            }
        case .unity:
            return join(["unity.editor", "unity.bridge"])
        case .overall:
            let attention = snap.attention
            var parts: [String] = []
            switch snap.summary {
            case .ready: parts.append(tr(l, "Everything I can check is ready.", "Kontrol edebildiğim her şey hazır."))
            case .usable: parts.append(tr(l, "JARVIS is usable.", "JARVIS kullanılabilir durumda."))
            case .notReady(let why): parts.append(tr(l, "Not ready: \(why).", "Hazır değil: \(why)."))
            }
            for i in attention.prefix(5) { parts.append("\(i.name): \(Self.phrase(i.state, l)).") }
            let providers = snap.items(in: .intelligence).filter { $0.id != "provider.paid" }
            if !providers.isEmpty { parts.append(tr(l, "Providers — ", "Sağlayıcılar — ") + providers.map { "\($0.name) \(Self.phrase($0.state, l))" }.joined(separator: ", ") + ".") }
            return parts.joined(separator: " ")
        }
    }
}
