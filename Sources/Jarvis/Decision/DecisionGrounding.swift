import Foundation

// MARK: - Grounded answers for the questions a model must never answer from imagination (V1.0 decision milestone)
//
//   · "Sesim geliyor mu?" / "Can you hear me?"            → `VoiceStatusComposer`        — from facts about the voice pipeline and about THIS utterance's own provenance
//   · "Safari'yi görebiliyor musun şu anda?"               → `ObservationGrounding`       — only from a FRESH Computer Use observation; otherwise "not verified"
//   · "Hamam projesini aç." / "En son çalıştığımız proje"   → `ProjectOpenResolver`        — from the project registry (names, paths, last seen) and the files on disk, asking when it is not unique
// All three are pure value logic: they read nothing, start nothing, and say "unknown" for what is unknown.

private func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

// MARK: - Voice status

enum MicrophoneFact: String, Equatable, Sendable { case granted, denied, notAsked, unknown }

struct VoiceStatusFacts: Equatable, Sendable {
    var voiceOn: Bool
    var pushToTalkOn: Bool
    var wakeEnabled: Bool
    var wakeRunning: Bool
    var microphone: MicrophoneFact
    /// nil = the speech recogniser's readiness was not checked.
    var recogniserReady: Bool?
    /// This very utterance arrived through the microphone and the recogniser — the only direct evidence that sound is getting through.
    var heardViaVoice: Bool
}

enum VoiceStatusComposer {
    static func compose(_ f: VoiceStatusFacts, language l: ReplyLanguage) -> String {
        var parts: [String] = []
        if f.heardViaVoice {
            parts.append(tr(l, "Yes, I can hear you — this sentence came in through the microphone and was transcribed.", "Evet, sizi duyuyorum: bu cümle mikrofondan geldi ve yazıya çevrildi."))
        } else if !f.voiceOn {
            parts.append(tr(l, "Voice input is off, so I am not listening. This message came in as text.", "Ses girişi kapalı, bu yüzden dinlemiyorum. Bu mesaj yazı olarak geldi."))
        } else {
            parts.append(tr(l, "This message came in as text, so I cannot tell from it whether I hear your voice.", "Bu mesaj yazı olarak geldi; sesinizi duyup duymadığımı bundan çıkaramam."))
        }
        switch f.microphone {
        case .granted: if !f.heardViaVoice { parts.append(tr(l, "The microphone permission is granted.", "Mikrofon izni verilmiş.")) }
        case .denied: parts.append(tr(l, "The microphone permission is denied for this app, so I cannot hear you until it is allowed in System Settings.", "Bu uygulama için mikrofon izni reddedilmiş; Sistem Ayarları'ndan izin verilene kadar sizi duyamam."))
        case .notAsked: parts.append(tr(l, "The microphone permission has not been asked yet; macOS asks the first time you use voice.", "Mikrofon izni henüz sorulmadı; sesi ilk kullandığınızda macOS soracak."))
        case .unknown: parts.append(tr(l, "I have not checked the microphone permission.", "Mikrofon iznini kontrol etmedim."))
        }
        if f.voiceOn {
            var on: [String] = []
            if f.pushToTalkOn { on.append(tr(l, "Push-to-Talk (hold the right ⌥ key)", "Push-to-Talk (sağ ⌥ tuşunu basılı tutun)")) }
            if f.wakeEnabled { on.append(f.wakeRunning ? tr(l, "the wake word is running", "wake word çalışıyor") : tr(l, "the wake word is on but not running", "wake word açık ama çalışmıyor")) }
            parts.append(on.isEmpty ? tr(l, "Voice input is on, but neither Push-to-Talk nor the wake word is enabled.", "Ses girişi açık, ama ne Push-to-Talk ne de wake word etkin.")
                                     : tr(l, "Voice input is on: \(on.joined(separator: "; ")).", "Ses girişi açık: \(on.joined(separator: "; "))."))
        }
        switch f.recogniserReady {
        case true?: break
        case false?: parts.append(tr(l, "The speech recogniser is not ready.", "Konuşma tanıyıcı hazır değil."))
        case nil: if !f.heardViaVoice { parts.append(tr(l, "The speech recogniser has not been checked yet.", "Konuşma tanıyıcı henüz kontrol edilmedi.")) }
        }
        if !f.heardViaVoice, f.voiceOn, f.microphone == .granted { parts.append(tr(l, "Say something with the voice key held and I will confirm.", "Ses tuşu basılıyken bir şey söyleyin, doğrulayayım.")) }
        return parts.joined(separator: " ")
    }
}

// MARK: - Observation freshness

/// What Computer Use really observed: an application and when. Nothing else is ever treated as evidence that something is on screen.
struct ObservedApp: Equatable, Sendable {
    var name: String
    var at: Date
}

enum VisibilityAnswer: Equatable, Sendable {
    case seen(ageSeconds: Int)
    case notInFreshObservation(ageSeconds: Int)
    case stale(ageSeconds: Int)
    case noObservation
    /// True only for a claim JARVIS may make ("yes, I see it").
    var mayClaimVisible: Bool { if case .seen = self { return true }; return false }
}

enum ObservationGrounding {
    /// A visibility claim about "right now" needs an observation at most this old.
    static let freshSeconds: TimeInterval = 20

    static func fold(_ s: String) -> String { DecisionText.fold(s).filter { $0.isLetter || $0.isNumber } }

    /// `observations`: the recent application observations (newest last). `target`: the application / thing asked about.
    static func evaluate(target: String, observations: [ObservedApp], now: Date, fresh: TimeInterval = freshSeconds) -> VisibilityAnswer {
        guard let newest = observations.max(by: { $0.at < $1.at }) else { return .noObservation }
        let age = max(0, Int(now.timeIntervalSince(newest.at)))
        if now.timeIntervalSince(newest.at) > fresh { return .stale(ageSeconds: age) }
        let want = fold(target)
        let hit = observations.contains { o in now.timeIntervalSince(o.at) <= fresh && !want.isEmpty && (fold(o.name) == want || fold(o.name).contains(want) || want.contains(fold(o.name)) && fold(o.name).count >= 4) }
        return hit ? .seen(ageSeconds: age) : .notInFreshObservation(ageSeconds: age)
    }

    /// `running`: a structured fact from the application list (true / false / nil = unknown). It is reported as exactly that — never as visibility.
    static func reply(_ a: VisibilityAnswer, target: String, running: Bool?, language l: ReplyLanguage) -> String {
        let runLine: String = {
            switch running {
            case true?: return tr(l, " The application list says \(target) is running — that does not mean it is visible on screen.", " Uygulama listesine göre \(target) çalışıyor — bu, ekranda göründüğü anlamına gelmez.")
            case false?: return tr(l, " The application list says \(target) is not running.", " Uygulama listesine göre \(target) çalışmıyor.")
            case nil: return ""
            }
        }()
        switch a {
        case .seen(let age):
            return tr(l, "Yes — my last observation, \(age) s ago, showed \(target).", "Evet — \(age) sn önceki son gözlemim \(target) uygulamasını gösteriyordu.")
        case .notInFreshObservation(let age):
            return tr(l, "My last observation, \(age) s ago, did not show \(target).", "\(age) sn önceki son gözlemimde \(target) görünmüyordu.") + runLine
        case .stale(let age):
            return tr(l, "My last observation is \(age) s old, so I cannot say whether \(target) is visible right now. Say “look at my screen” and I will check.", "Son gözlemim \(age) sn önce yapıldı; \(target) şu an görünüyor mu söyleyemem. “Ekranıma bak” derseniz bakıp doğrularım.") + runLine
        case .noObservation:
            return tr(l, "I have not observed the screen yet, so I cannot say whether \(target) is visible. Say “look at my screen” and I will check.", "Henüz ekranı gözlemlemedim; \(target) görünüyor mu bilmiyorum. “Ekranıma bak” derseniz bakıp doğrularım.") + runLine
        }
    }
}

// MARK: - Project open

struct KnownProject: Equatable, Sendable {
    var key: String
    var name: String
    var rootPath: String?
    var kind: String
    var lastSeen: Date
    var aliases: [String] = []
}

enum ProjectOpenResolution: Equatable, Sendable {
    case resolved(KnownProject)
    /// Not unique: the system asks instead of guessing.
    case ambiguous([KnownProject])
    case unknown(String, known: [String])
    case noKnownProjects
    /// The registry knows the project but its folder is not on disk any more (nothing is guessed in its place).
    case pathMissing(KnownProject)
}

enum ProjectOpenResolver {
    /// Closed Turkish case suffixes a spoken name may carry ("Hamam'ı", "Hamam'da"), and the engine kinds a name may stand for ("Unity projesi").
    private static let suffixes = ["", "i", "u", "yi", "yu", "in", "un", "nin", "nun", "e", "a", "ye", "ya", "de", "da", "te", "ta", "den", "dan", "ten", "tan", "la", "le", "yla", "yle", "ndan", "nden", "nda", "nde", "si", "su"]
    static let engineKinds: Set<String> = ["unity", "unreal", "godot", "swift", "xcode", "node", "python"]
    /// Two projects whose last-seen times are closer than this are not "the most recent" one.
    static let recencyMargin: TimeInterval = 60

    static func markerExists(root: String, kind: String) -> Bool {
        switch kind {
        case "unity": return FileManager.default.fileExists(atPath: root + "/ProjectSettings/ProjectVersion.txt")
        case "swift": return FileManager.default.fileExists(atPath: root + "/Package.swift")
        default: return false
        }
    }

    static func resolve(name: String?, wantsLast: Bool, projects: [KnownProject], currentRoot: String?,
                        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                        isKind: (String, String) -> Bool = { markerExists(root: $0, kind: $1) }) -> ProjectOpenResolution {
        var seen = Set<String>()
        let all = projects.filter { $0.rootPath != nil && seen.insert($0.key).inserted }
        guard !all.isEmpty else { return .noKnownProjects }
        func finish(_ p: KnownProject) -> ProjectOpenResolution { pathExists(p.rootPath ?? "") ? .resolved(p) : .pathMissing(p) }

        if wantsLast {
            let byRecency = all.sorted { $0.lastSeen > $1.lastSeen }
            let top = byRecency[0]
            if byRecency.count > 1, top.lastSeen.timeIntervalSince(byRecency[1].lastSeen) < recencyMargin { return .ambiguous(Array(byRecency.prefix(3))) }
            return finish(top)
        }
        guard let raw = name, !fold(raw).isEmpty else {
            if let root = currentRoot, let p = all.first(where: { $0.rootPath == root }) { return finish(p) }
            return all.count == 1 ? finish(all[0]) : .ambiguous(Array(all.sorted { $0.lastSeen > $1.lastSeen }.prefix(4)))
        }
        let want = fold(raw)
        // 1. a project's own name or alias (case suffixes tolerated)
        let named = all.filter { p in ([p.name] + p.aliases).contains { matches(want, fold($0)) } }
        if named.count == 1 { return finish(named[0]) }
        if named.count > 1 { return .ambiguous(named) }
        // 2. an engine kind ("Unity projesi"): decided by the files on disk, never by memory
        if engineKinds.contains(want) {
            let ofKind = all.filter { isKind($0.rootPath ?? "", want) }
            if ofKind.count == 1 { return finish(ofKind[0]) }
            if ofKind.count > 1 { return .ambiguous(ofKind.sorted { $0.lastSeen > $1.lastSeen }) }
        }
        return .unknown(raw, known: Array(Set(all.map(\.name))).sorted().prefix(6).map { $0 })
    }

    private static func fold(_ s: String) -> String { DecisionText.fold(s).filter { $0.isLetter || $0.isNumber } }

    /// `spoken` equals `name`, or is `name` plus one closed case suffix. Prefix matches are NOT accepted ("ham" must not open "hamam"): a guess about a project is a wrong project.
    private static func matches(_ spoken: String, _ name: String) -> Bool {
        guard name.count >= 2 else { return false }
        return suffixes.contains { spoken == name + $0 }
    }
}
