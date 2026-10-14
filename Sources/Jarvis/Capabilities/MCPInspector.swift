import Foundation

// MARK: - Static inspection of an MCP candidate's SOURCE (V0.14, DEC-227)
//
// Looks for the behaviours that matter before anything is installed or run: shell / child processes, credential and environment reads, Keychain, browser cookies, SSH, network
// destinations, telemetry, auto-update, install scripts, download-on-run, dynamic code, destructive deletes, persistence, remote code loading. It is STATIC EVIDENCE: a clean scan is
// not proof of safety, and a hit is not proof of malice. Nothing is executed and nothing is installed by this.

struct MCPInspection: Codable, Equatable, Sendable {
    var findings: [MCPSecurityFinding]
    var filesScanned: Int
    var truncated: Bool
    var hosts: [String]
    var installScripts: [String]
    var dependencyCount: Int
    var dependenciesScanned = false
    var disclaimer = "Static evidence only: a clean scan is not proof of safety; dependencies are listed, not scanned."

    var highCount: Int { findings.filter { $0.severity == .high }.count }
    var categories: Set<String> { Set(findings.map(\.category)) }
    func has(_ category: String) -> Bool { categories.contains(category) }
}

enum MCPInspector {
    private static let urlPattern = try! NSRegularExpression(pattern: "https?://([A-Za-z0-9.\\-]+)")
    static let sourceExtensions: Set<String> = ["js", "mjs", "cjs", "ts", "py", "sh", "rb", "go", "rs", "swift", "toml", "cfg", "json"]
    static let skipDirectories: Set<String> = ["node_modules", ".git", "dist", "build", "__pycache__", ".venv", "venv", "target", ".next"]

    /// Scans one text. `name` appears in the finding location.
    static func scan(text: String, name: String) -> [MCPSecurityFinding] {
        var out: [MCPSecurityFinding] = []
        let ns = text as NSString
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lineStarts: [Int] = []; var o = 0
        for l in lines { lineStarts.append(o); o += (l as NSString).length + 1 }
        for r in rules {
            guard let m = r.pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let line = (lineStarts.lastIndex { $0 <= m.range.location } ?? 0) + 1
            out.append(MCPSecurityFinding(severity: r.severity, category: r.category, detail: r.detail, location: "\(name):\(line)"))
        }
        return out
    }

    /// Scans a source directory (bounded: 400 files × 512 KB; dependency folders are skipped and counted, not scanned).
    static func scan(directory: URL) -> MCPInspection {
        let fm = FileManager.default
        var findings: [MCPSecurityFinding] = [], hosts = Set<String>(), scripts: [String] = []
        var files = 0, truncated = false, deps = 0
        let base = directory.path
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return MCPInspection(findings: [], filesScanned: 0, truncated: false, hosts: [], installScripts: [], dependencyCount: 0) }
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { if skipDirectories.contains(url.lastPathComponent) { if url.lastPathComponent == "node_modules" { deps += ((try? fm.contentsOfDirectory(atPath: url.path))?.count ?? 0) }; e.skipDescendants() }; continue }
            guard sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if files >= 400 { truncated = true; break }
            guard let data = FileManager.default.contents(atPath: url.path), data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { continue }
            files += 1
            let rel = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count + 1)) : url.lastPathComponent
            findings += scan(text: text, name: rel)
            for m in urlPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).prefix(40) { hosts.insert((text as NSString).substring(with: m.range(at: 1)).lowercased()) }
            if url.lastPathComponent == "package.json" { scripts += installScripts(inPackageJSON: text); deps += dependencyNames(inPackageJSON: text).count }
            if url.lastPathComponent == "pyproject.toml" || url.lastPathComponent == "requirements.txt" { deps += text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.count }
            if url.lastPathComponent == "setup.py" && text.contains("cmdclass") { scripts.append("setup.py cmdclass (runs code at install)") }
        }
        for s in scripts { findings.append(MCPSecurityFinding(severity: .high, category: "install-script", detail: "runs code at install time: \(s)", location: "package manifest")) }
        // Collapse to the first hit per category per file location to keep the list readable.
        var seen = Set<String>(); findings = findings.filter { seen.insert("\($0.category)|\($0.location ?? "")").inserted }
        return MCPInspection(findings: findings, filesScanned: files, truncated: truncated, hosts: hosts.sorted().prefix(30).map { $0 }, installScripts: scripts, dependencyCount: deps)
    }

    static func installScripts(inPackageJSON text: String) -> [String] {
        guard let obj = JSONValue.parse(text)?.object, let s = obj["scripts"]?.object else { return [] }
        return ["preinstall", "install", "postinstall", "prepare", "prepublish"].compactMap { k in s[k]?.string.map { "\(k): \(String($0.prefix(80)))" } }
    }
    static func dependencyNames(inPackageJSON text: String) -> [String] {
        guard let obj = JSONValue.parse(text)?.object else { return [] }
        return ["dependencies", "optionalDependencies"].flatMap { (obj[$0]?.object ?? [:]).keys }.sorted()
    }

    /// Everything a tool's declared metadata tells JARVIS, with injection-shaped descriptions flagged (never forwarded as instructions).
    static func toolFindings(_ tools: [MCPToolSchema]) -> [MCPSecurityFinding] {
        var out: [MCPSecurityFinding] = []
        for t in tools {
            if t.risk == .broad { out.append(MCPSecurityFinding(severity: .high, category: "broad-tool", detail: "“\(t.name)” runs arbitrary code or shell commands — never exposed to agents automatically", location: t.name)) }
            if t.risk == .destructive { out.append(MCPSecurityFinding(severity: .warning, category: "destructive-tool", detail: "“\(t.name)” can delete or destroy", location: t.name)) }
            if t.injectionNotes > 0 { out.append(MCPSecurityFinding(severity: .warning, category: "tool-description-injection", detail: "the description of “\(t.name)” contains instruction-shaped text (kept as data, never followed)", location: t.name)) }
        }
        return out
    }

    /// A short, honest verdict for the UI: counts by severity, never “safe”.
    static func verdict(_ findings: [MCPSecurityFinding]) -> String {
        let high = findings.filter { $0.severity == .high }.count, warn = findings.filter { $0.severity == .warning }.count
        if findings.isEmpty { return "No findings in the static scan — that is not proof of safety." }
        return "\(high) high-risk and \(warn) warning finding(s) — static evidence, not a verdict on intent."
    }
}
