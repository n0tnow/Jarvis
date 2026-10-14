import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "dev.jarvis.Jarvis", category: "app")
    static let windows = Logger(subsystem: "dev.jarvis.Jarvis", category: "windows")
    /// Provider DIAGNOSTICS only (exit codes, error classes). Never prompts, answers, clipboard text or credentials.
    static let providers = Logger(subsystem: "dev.jarvis.Jarvis", category: "providers")
}

enum AppInfo {
    /// The milestone this source tree implements. The bundle's Info.plist carries the same number (`scripts/package-app.sh` writes it); a bare binary falls back to the constants.
    static let sourceVersion = "0.15.0"
    static let milestone = "V0.15"
    static var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sourceVersion }
    static var build: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "dev" }
    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "dev.jarvis.Jarvis" }
    /// True when running from a real .app bundle (installed or staged), false for a bare `swift run` / test binary.
    static var isApplicationBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    /// The Git commit the package was built from (written by the packaging script; absent in a plain build). Developer diagnostics only.
    static var commit: String? { Bundle.main.object(forInfoDictionaryKey: "JarvisBuildCommit") as? String }
    static var versionLine: String { "\(version) · build \(build)" }
}
