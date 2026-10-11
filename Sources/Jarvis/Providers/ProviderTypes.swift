import Foundation

/// What using a provider costs the user (DEC-022). `paidAPI` exists ONLY so it can be refused — nothing may route to it.
enum CostClass: String, Codable, Sendable { case local, freeCloud, subscription, paidAPI, tool }

/// Every engine JARVIS can run a request on. `claudeCode`/`codex` are the user's own subscription CLIs (V0.3);
/// `openCode` runs ONLY verified-free models (V0.3.1); `local` is the on-device lightweight model (V0.3.1).
/// No API-key provider exists (DEC-017/020).
enum ProviderID: String, CaseIterable, Codable, Sendable {
    case claudeCode, codex, openCode, local
    /// V0.4: a deterministic JARVIS tool run (build/test/file tool). NOT a model provider: it is never routed, never appears
    /// in `allCases` (provider cards, routing, pickers) and costs nothing.
    case tool

    static var allCases: [ProviderID] { [.claudeCode, .codex, .openCode, .local] }

    /// The two subscription CLIs managed by `ProviderManager` (V0.3 behaviour, unchanged).
    static let subscription: [ProviderID] = [.claudeCode, .codex]

    var displayName: String {
        switch self { case .claudeCode: "Claude Code"; case .codex: "Codex"; case .openCode: "OpenCode"; case .local: "Local Qwen"; case .tool: "JARVIS Tools" }
    }
    var shortName: String {
        switch self { case .claudeCode: "CLAUDE CODE"; case .codex: "CODEX"; case .openCode: "OPENCODE"; case .local: "LOCAL"; case .tool: "TOOL" }
    }
    var executableName: String {
        switch self { case .claudeCode: "claude"; case .codex: "codex"; case .openCode: "opencode"; case .local: "python3"; case .tool: "jarvis" }
    }
    var costClass: CostClass {
        switch self { case .claudeCode, .codex: .subscription; case .openCode: .freeCloud; case .local: .local; case .tool: .tool }
    }
    /// What the user should run themselves to sign in through the vendor's own flow (JARVIS never handles credentials).
    var loginCommand: String {
        switch self {
        case .claudeCode: "claude auth login"
        case .codex: "codex login"
        case .openCode: "opencode providers login"
        case .local: "scripts/setup_local_ai.sh"
        case .tool: ""
        }
    }
}

/// The user's explicit choice (Settings). Anything but `.auto` NEVER silently falls back to another engine.
enum ProviderPreference: String, CaseIterable, Codable, Sendable {
    case auto, local, openCodeFree, claudeCode, codex

    var displayName: String {
        switch self {
        case .auto: "Auto"; case .local: "Local"; case .openCodeFree: "OpenCode Free"; case .claudeCode: "Claude Code"; case .codex: "Codex"
        }
    }
    var providerID: ProviderID? {
        switch self {
        case .auto: nil; case .local: .local; case .openCodeFree: .openCode; case .claudeCode: .claudeCode; case .codex: .codex
        }
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
    /// The router refused the request (explicit mode can't be honoured, privacy gate, …). Carries the user-facing text.
    case refused(String)
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
        case .refused(let text):
            return text
        case .busy:
            return p("I'm still answering. Press Stop generation first.", "Hâlâ yanıt veriyorum. Önce yanıtı durdurun.")
        case .generic:
            return p("The intelligence provider failed.", "Zekâ sağlayıcısı başarısız oldu.")
        }
    }
}
