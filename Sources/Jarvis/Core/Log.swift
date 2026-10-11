import os

enum Log {
    static let app = Logger(subsystem: "dev.jarvis.Jarvis", category: "app")
    static let windows = Logger(subsystem: "dev.jarvis.Jarvis", category: "windows")
    /// Provider DIAGNOSTICS only (exit codes, error classes). Never prompts, answers, clipboard text or credentials.
    static let providers = Logger(subsystem: "dev.jarvis.Jarvis", category: "providers")
}

enum AppInfo {
    static let version = "0.1.1"
    static let milestone = "V0.1.1"
}
