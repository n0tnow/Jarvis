import os

enum Log {
    static let app = Logger(subsystem: "dev.jarvis.Jarvis", category: "app")
    static let windows = Logger(subsystem: "dev.jarvis.Jarvis", category: "windows")
}

enum AppInfo {
    static let version = "0.1.0"
    static let milestone = "V0.1"
}
