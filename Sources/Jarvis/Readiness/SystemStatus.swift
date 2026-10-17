import Foundation

// MARK: - One system truth, spoken (V1.0 stabilisation fix 4)
//
// "Sistem durumunu söyler misin?" is answered from the SAME structured state the HUD shows (readiness records, preferences, the hands-free detector, the task engine, the agent hub) — never by a
// language model, which knows nothing about this installation and once answered "bunu söyleyemem". `SystemStatusSnapshot` is a plain value assembled from those sources; `SystemStatusComposer`
// turns it into a short spoken answer (and a longer one for “detaylı anlat”). Only fields the architecture really has are included; an unknown is said as unknown.

struct SystemStatusSnapshot: Equatable, Sendable {
    var state: JarvisState
    var versionLine: String
    var readiness: ReadinessSnapshot
    /// The selected project's folder name, nil when none is selected.
    var project: String?
    var activeTasks: Int
    var activeAgents: Int
    var voiceOn: Bool
    var pushToTalkOn: Bool
    var wakeEnabled: Bool
    var wakeDetector: WakeDetectorProbe
    var providerPreference: String
}

enum StatusScope: Equatable, Sendable {
    case all, running, features, wake
}

@MainActor
enum SystemStatusComposer {
    private static func t(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    /// `concise`: the short spoken form; `detailed`: the same facts plus the rest of the picture.
    static func compose(_ s: SystemStatusSnapshot, focus: StatusScope = .all, language l: ReplyLanguage, detailed: Bool) -> String {
        switch focus {
        case .wake: return wake(s, l)
        case .running: return running(s, l)
        case .features, .all: break
        }
        var parts: [String] = []
        parts.append(headline(s, l))
        if let p = providers(s, l) { parts.append(p) }
        if let q = localModel(s, l) { parts.append(q) }
        parts.append(voice(s, l))
        parts.append(permissions(s, l))
        parts.append(work(s, l))
        let needs = s.readiness.attention.filter { !["voice.input"].contains($0.id) }
        if !needs.isEmpty {
            parts.append(t(l, "Needs attention: \(needs.prefix(4).map { "\($0.name) — \(ReadinessAssistant.phrase($0.state, l))" }.joined(separator: "; ")).", "Dikkat gerektiren: \(needs.prefix(4).map { "\($0.name) — \(ReadinessAssistant.phrase($0.state, l))" }.joined(separator: "; ")).")) }
        if detailed {
            let tiles = s.readiness.tiles                          // the System page's three summary numbers, from the same snapshot
            parts.append(t(l, "Ready: \(tiles.ready) · needs attention: \(tiles.attention) · optional: \(tiles.optional).", "Hazır: \(tiles.ready) · dikkat gerektiren: \(tiles.attention) · isteğe bağlı: \(tiles.optional)."))
            parts.append(t(l, "Version \(s.versionLine).", "Sürüm \(s.versionLine)."))
            for id in ["unity.editor", "unity.bridge", "mcp.summary", "local.embedding", "local.whisper", "local.vision", "voice.stt", "startup.login", "perm.notifications"] {
                if let i = s.readiness.item(id) { parts.append("\(i.name): \(ReadinessAssistant.phrase(i.state, l)).") }
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func headline(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String {
        switch s.readiness.summary {
        case .ready: return t(l, "The system is ready.", "Sistem hazır.")
        case .usable: return t(l, "JARVIS is usable.", "JARVIS kullanılabilir durumda.")
        case .notReady(let why): return t(l, "Not ready: \(why).", "Hazır değil: \(why).")
        }
    }

    private static func providers(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String? {
        let ids = ["provider.claude", "provider.codex", "provider.opencode"]
        let items = ids.compactMap(s.readiness.item)
        guard !items.isEmpty else { return nil }
        let ready = items.filter { $0.state == .ready }.map(\.name)
        let rest = items.filter { $0.state != .ready }
        var out: [String] = []
        if !ready.isEmpty { out.append(t(l, "\(join(ready, l)) \(ready.count == 1 ? "is" : "are") ready", "\(join(ready, l)) hazır")) }
        for i in rest { out.append("\(i.name) \(ReadinessAssistant.phrase(i.state, l))") }
        return out.joined(separator: "; ") + "."
    }

    private static func localModel(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String? {
        guard let q = s.readiness.item("local.qwen") else { return nil }
        switch q.state {
        case .ready, .available: return t(l, "The local Qwen model is installed (it loads on demand).", "Yerel Qwen modeli kurulu (gerektiğinde yüklenir).")
        default: return t(l, "Local Qwen: \(ReadinessAssistant.phrase(q.state, l)).", "Yerel Qwen: \(ReadinessAssistant.phrase(q.state, l)).")
        }
    }

    private static func voice(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String {
        if !s.voiceOn { return t(l, "Voice input is off.", "Ses girişi kapalı.") }
        var out = t(l, "Voice input is on", "Ses girişi açık")
        out += s.pushToTalkOn ? t(l, "; Push-to-Talk is on", "; Push-to-Talk açık") : ""
        return out + ". " + wakeShort(s, l)
    }

    private static func wakeShort(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String {
        guard s.wakeEnabled else { return t(l, "The wake word is off.", "Wake word kapalı.") }
        switch s.wakeDetector {
        case .running: return t(l, "The wake word is running.", "Wake word çalışıyor.")
        case .starting: return t(l, "The wake word is starting.", "Wake word başlıyor.")
        case .paused: return t(l, "The wake word is paused (sleep mode).", "Wake word duraklatıldı (uyku modu).")
        case .stopped: return t(l, "The wake word is on but the detector is not running.", "Wake word açık ama algılayıcı çalışmıyor.")
        case .error(let why): return t(l, "The wake word has an error: \(why).", "Wake word hatalı: \(why).")
        }
    }

    private static func permissions(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String {
        func state(_ id: String) -> ReadinessState? { s.readiness.item(id)?.state }
        let ax = state("computer.ax") == .ready, sr = state("computer.screen") == .ready
        let mic = state("voice.mic")
        var parts: [String] = []
        switch (ax, sr) {
        case (true, true): parts.append(t(l, "Accessibility and Screen Recording are ready.", "Accessibility ve Screen Recording hazır."))
        case (true, false): parts.append(t(l, "Accessibility is ready; Screen Recording is not allowed.", "Accessibility hazır; Screen Recording izni yok."))
        case (false, true): parts.append(t(l, "Screen Recording is ready; Accessibility is not allowed, so I cannot operate other apps.", "Screen Recording hazır; Accessibility izni yok, bu yüzden diğer uygulamaları kullanamam."))
        case (false, false): parts.append(t(l, "Accessibility and Screen Recording are not allowed, so I cannot operate other apps.", "Accessibility ve Screen Recording izni yok, bu yüzden diğer uygulamaları kullanamam."))
        }
        if let mic, mic != .ready { parts.append(t(l, "Microphone: \(ReadinessAssistant.phrase(mic, l)).", "Mikrofon: \(ReadinessAssistant.phrase(mic, l)).")) }
        return parts.joined(separator: " ")
    }

    private static func work(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String {
        var out: [String] = []
        out.append(s.activeTasks == 0 ? t(l, "No active task", "Aktif görev yok") : t(l, "\(s.activeTasks) active task\(s.activeTasks == 1 ? "" : "s")", "\(s.activeTasks) aktif görev"))
        if s.activeAgents > 0 { out.append(t(l, "\(s.activeAgents) agent\(s.activeAgents == 1 ? "" : "s") running", "\(s.activeAgents) ajan çalışıyor")) }
        out.append(s.project.map { t(l, "project: \($0)", "proje: \($0)") } ?? t(l, "no project selected", "seçili proje yok"))
        return out.joined(separator: ", ").prefix(1).uppercased() + out.joined(separator: ", ").dropFirst() + "."
    }

    private static func wake(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String {
        var out = wakeShort(s, l)
        if s.wakeEnabled, s.wakeDetector == .running { out += " " + t(l, "Only a small local detector listens for “Jarvis”; nothing is transcribed before it hears the word.", "Yalnızca küçük yerel bir algılayıcı “Jarvis” kelimesini dinliyor; bu kelimeden önce hiçbir şey yazıya dökülmez.") }
        if let mic = s.readiness.item("voice.mic"), mic.state != .ready { out += " " + t(l, "Microphone: \(ReadinessAssistant.phrase(mic.state, l)).", "Mikrofon: \(ReadinessAssistant.phrase(mic.state, l)).") }
        return out
    }

    private static func running(_ s: SystemStatusSnapshot, _ l: ReplyLanguage) -> String {
        var on: [String] = []
        if s.activeTasks > 0 { on.append(t(l, "\(s.activeTasks) task\(s.activeTasks == 1 ? "" : "s")", "\(s.activeTasks) görev")) }
        if s.activeAgents > 0 { on.append(t(l, "\(s.activeAgents) agent\(s.activeAgents == 1 ? "" : "s")", "\(s.activeAgents) ajan")) }
        if s.voiceOn && s.pushToTalkOn { on.append("Push-to-Talk") }
        if s.wakeEnabled && s.wakeDetector == .running { on.append(t(l, "the wake-word detector", "wake word algılayıcısı")) }
        if on.isEmpty { return t(l, "Nothing is running right now: no task, no agent, no detector. JARVIS is idle and waiting.", "Şu an hiçbir şey çalışmıyor: görev, ajan ya da algılayıcı yok. JARVIS boşta ve bekliyor.") }
        return t(l, "Running now: \(join(on, l)).", "Şu an çalışan: \(join(on, l)).")
    }

    private static func join(_ names: [String], _ l: ReplyLanguage) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + t(l, " and ", " ve ") + names[1]
        default: return names.dropLast().joined(separator: ", ") + t(l, " and ", " ve ") + names[names.count - 1]
        }
    }
}
