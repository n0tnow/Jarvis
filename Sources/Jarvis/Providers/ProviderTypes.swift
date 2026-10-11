import Foundation

/// The subscription-backed providers JARVIS can drive (see docs/PROVIDER_RESEARCH.md). No API-key providers exist.
enum ProviderID: String, CaseIterable, Codable, Sendable {
    case claudeCode, codex

    var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    var shortName: String { self == .claudeCode ? "CLAUDE CODE" : "CODEX" }
    var executableName: String { self == .claudeCode ? "claude" : "codex" }
    /// What the user should run themselves to sign in through the vendor's own flow (JARVIS never handles credentials).
    var loginCommand: String { self == .claudeCode ? "claude auth login" : "codex login" }
}

enum ProviderPreference: String, CaseIterable, Codable, Sendable {
    case auto, codex, claudeCode

    var displayName: String {
        switch self { case .auto: "Auto"; case .codex: "Codex"; case .claudeCode: "Claude Code" }
    }
    var providerID: ProviderID? {
        switch self { case .auto: nil; case .codex: .codex; case .claudeCode: .claudeCode }
    }
}

/// "installed" is NOT "usable": only `.ready` can serve a request.
enum ProviderState: Equatable, Sendable {
    case unknown                       // not checked yet
    case notInstalled
    case authenticationRequired        // installed, not signed in
    case ready
    case running
    case rateLimited(until: Date?)
    case unavailable(String)           // installed but couldn't be checked / offline
    case failed(String)

    var label: String {
        switch self {
        case .unknown: "CHECKING"
        case .notInstalled: "NOT INSTALLED"
        case .authenticationRequired: "SIGN-IN REQUIRED"
        case .ready: "READY"
        case .running: "RUNNING"
        case .rateLimited: "LIMIT REACHED"
        case .unavailable: "UNAVAILABLE"
        case .failed: "FAILED"
        }
    }

    var isUsable: Bool { self == .ready }
}

struct ProviderStatus: Equatable, Sendable {
    var id: ProviderID
    var state: ProviderState = .unknown
    var version: String?
    var executablePath: String?
}

/// Typed failures. `userMessage` is concise and never contains raw process output.
enum ProviderError: Error, Equatable, Sendable {
    case notInstalled(ProviderID)
    case authenticationRequired(ProviderID)
    case rateLimited(ProviderID, resetsAt: Date?)
    case unavailable(ProviderID, String)
    case networkUnavailable(ProviderID)
    case processFailed(ProviderID, exitCode: Int32)
    case malformedOutput(ProviderID)
    case timedOut(ProviderID)
    case sessionLost(ProviderID)
    case cancelled
    case noProviderReady(summary: String)
    case busy
    /// An error that is not one of the above (never shows raw details).
    case generic

    func userMessage(_ l: ReplyLanguage = .en) -> String {
        func p(_ en: String, _ tr: String) -> String { l == .tr ? tr : en }
        switch self {
        case .notInstalled(let id):
            return p("\(id.displayName) isn't installed on this Mac.", "\(id.displayName) bu Mac'te kurulu değil.")
        case .authenticationRequired(let id):
            return p("\(id.displayName) is installed but needs authentication. Run `\(id.loginCommand)` in Terminal, then refresh in Settings.",
                     "\(id.displayName) kurulu ama oturum açılması gerekiyor. Terminal'de `\(id.loginCommand)` çalıştırın, sonra Ayarlar'dan yenileyin.")
        case .rateLimited(let id, _):
            return p("\(id.displayName) has reached its usage limit for now. Try again later or pick another provider in Settings.",
                     "\(id.displayName) şu an kullanım sınırına ulaştı. Daha sonra deneyin ya da Ayarlar'dan başka bir sağlayıcı seçin.")
        case .unavailable(let id, _):
            return p("\(id.displayName) isn't currently available.", "\(id.displayName) şu an kullanılamıyor.")
        case .networkUnavailable(let id):
            return p("\(id.displayName) couldn't reach the network. Check your connection and try again.", "\(id.displayName) ağa erişemedi. Bağlantınızı kontrol edip tekrar deneyin.")
        case .processFailed(let id, _):
            return p("\(id.displayName) stopped unexpectedly. Nothing was changed.", "\(id.displayName) beklenmedik şekilde durdu. Hiçbir şey değiştirilmedi.")
        case .malformedOutput(let id):
            return p("\(id.displayName) returned output JARVIS couldn't read.", "\(id.displayName) JARVIS'in okuyamadığı bir çıktı döndürdü.")
        case .timedOut(let id):
            return p("\(id.displayName) took too long and was stopped.", "\(id.displayName) çok uzun sürdü ve durduruldu.")
        case .sessionLost:
            return p("The previous provider session could not be resumed.", "Önceki sağlayıcı oturumu sürdürülemedi.")
        case .cancelled:
            return p("Cancelled.", "İptal edildi.")
        case .noProviderReady(let summary):
            return p("No intelligence provider is ready. \(summary)", "Hazır bir zekâ sağlayıcısı yok. \(summary)")
        case .busy:
            return p("I'm still answering. Press Stop generation first.", "Hâlâ yanıt veriyorum. Önce yanıtı durdurun.")
        case .generic:
            return p("The intelligence provider failed.", "Zekâ sağlayıcısı başarısız oldu.")
        }
    }
}
