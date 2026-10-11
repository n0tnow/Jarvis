import Foundation

/// Finds provider executables WITHOUT trusting the PATH of a GUI app (which is not the Terminal's PATH).
/// Ordered, de-duplicated candidates: user override → PATH → well-known install locations → app bundles.
/// Pure over an injected file system so it is unit-tested.
struct ExecutableLocator: Sendable {
    var home: String
    var path: String
    var isExecutableFile: @Sendable (String) -> Bool
    var directoryContents: @Sendable (String) -> [String]
    var resolveSymlinks: @Sendable (String) -> String

    static func forThisMac(environment: [String: String] = ProcessInfo.processInfo.environment) -> ExecutableLocator {
        ExecutableLocator(
            home: environment["HOME"] ?? NSHomeDirectory(),
            path: environment["PATH"] ?? "",
            isExecutableFile: { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
            },
            directoryContents: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            resolveSymlinks: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        )
    }

    /// Candidate paths in priority order (existing executables only, symlink-resolved duplicates removed).
    func candidates(for id: ProviderID, override: String? = nil) -> [String] {
        let name = id.executableName
        var raw: [String] = []
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty { raw.append(override.hasPrefix("~") ? home + override.dropFirst() : override) }
        raw += path.split(separator: ":").map { "\($0)/\(name)" }
        raw += [
            "\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
            "\(home)/.claude/local/\(name)", "\(home)/.npm-global/bin/\(name)", "\(home)/.cargo/bin/\(name)", "\(home)/.bun/bin/\(name)",
        ]
        // nvm-installed global npm packages
        let nvm = "\(home)/.nvm/versions/node"
        for v in directoryContents(nvm).sorted(by: >) { raw.append("\(nvm)/\(v)/bin/\(name)") }
        if id == .codex {
            // The official Codex CLI ships inside the ChatGPT desktop app and is NOT on PATH.
            for app in ["/Applications/ChatGPT.app", "\(home)/Applications/ChatGPT.app", "/Applications/Codex.app", "\(home)/Applications/Codex.app"] {
                raw.append("\(app)/Contents/Resources/codex")
            }
        }
        var seen = Set<String>(), out: [String] = []
        for p in raw where isExecutableFile(p) {
            let real = resolveSymlinks(p)
            if seen.insert(real).inserted { out.append(p) }
        }
        return out
    }

    /// Extra PATH directories a provider might need to run (e.g. node for npm-installed CLIs).
    func extraPathDirectories() -> [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        for v in directoryContents(nvm).sorted(by: >) { dirs.append("\(nvm)/\(v)/bin") }
        return dirs
    }

    /// Parses "2.1.277 (Claude Code)" / "codex-cli 0.153.4" → [2,1,277].
    static func parseVersion(_ text: String) -> (display: String, parts: [Int])? {
        guard let range = text.range(of: #"\d+\.\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
        let display = String(text[range])
        return (display, display.split(separator: ".").compactMap { Int($0) })
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
