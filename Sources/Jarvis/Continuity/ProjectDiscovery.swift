import Foundation

// MARK: - Project discovery and safe alias resolution (V1.0 reliability pass)
//
// "Hamam'ı aç" can only work if the registry knows a project by that name. Discovery finds CANDIDATES — folders that look like a project — under roots the user has approved (the registered projects' own
// folders, the configured project root, or a folder named on the command line). It is deliberately small:
//   · EXPLICIT and ON DEMAND: nothing here runs on a timer, at launch or while idle; a caller passes the roots;
//   · BOUNDED: a depth limit, a directory budget, a candidate cap, a skip list (build output, caches, VCS internals), no symlink is followed, and `/`, the home folder itself and system folders are refused as roots;
//   · READ-ONLY: it lists directories and stats marker files — nothing is opened, parsed, executed or written;
//   · A CANDIDATE IS NOT A REGISTERED PROJECT: it carries `registered` and `verification` (which markers exist RIGHT NOW); registering stays the user's explicit act. Nothing is auto-registered, and the
//     aliases it proposes are SUGGESTIONS (metadata) — an alias only counts once it is in the registry. No project name is hard-coded anywhere in this file.
//
// Alias resolution is exact: a spoken name matches a project name or alias, plus a closed Turkish suffix chain, and nothing else. A near miss produces a SUGGESTION to ask about, never an action.

enum DiscoveredProjectKind: String, Codable, CaseIterable, Sendable, Comparable {
    case unity, xcode, swiftPackage, git
    private var rank: Int { switch self { case .unity: 0; case .xcode: 1; case .swiftPackage: 2; case .git: 3 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

struct DiscoveryEntry: Equatable, Sendable {
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
}

/// The only way discovery touches the disk. The default lists a directory and reads a modification date; tests inject a fake.
protocol DiscoveryFileSystem: Sendable {
    func children(_ path: String) -> [DiscoveryEntry]?
    func exists(_ path: String) -> Bool
    func modified(_ path: String) -> Date?
}

struct DefaultDiscoveryFileSystem: DiscoveryFileSystem {
    func children(_ path: String) -> [DiscoveryEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return names.map { name in
            let full = path + "/" + name
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            let type = attrs?[.type] as? FileAttributeType
            return DiscoveryEntry(name: name, isDirectory: type == .typeDirectory, isSymlink: type == .typeSymbolicLink)
        }
    }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func modified(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
}

struct DiscoveryLimits: Equatable, Sendable {
    var maxDepth = 3
    var maxDirectories = 1500
    var maxCandidates = 50
    var skipNames: Set<String> = [".build", "node_modules", "Library", "Temp", "Obj", "Build", "Builds", "Logs", "DerivedData", "Pods", ".git", "venv", ".venv", ".Trash", ".cache", "__pycache__", "Caches"]
}

struct ProjectCandidate: Equatable, Sendable {
    var path: String
    var folderName: String
    var kind: DiscoveredProjectKind
    /// Every marker that exists right now (“Assets”, “ProjectSettings/ProjectVersion.txt”, “.git”, “Package.swift”, “X.xcodeproj”).
    var markers: [String]
    /// Proposed spoken forms derived from the folder's OWN name (spaced words, folded joined form). Suggestions only: an alias counts once the user registers it.
    var suggestedAliases: [String]
    var lastWorked: Date?
    /// True when the registry already holds this path.
    var registered: Bool
    /// The last time the REGISTRY saw it, when registered.
    var lastOpened: Date?
    /// A Unity project is only "verified" with its version file; others with their defining marker.
    var verified: Bool
}

struct DiscoveryReport: Equatable, Sendable {
    var candidates: [ProjectCandidate] = []
    var refusedRoots: [String] = []
    var missingRoots: [String] = []
    var directoriesVisited = 0
    /// True when a budget stopped the walk early: the list is then a sample, not everything.
    var truncated = false
}

enum ProjectDiscovery {
    /// Folders that are never scanned as a root: they are not "a place the user keeps projects".
    static func isRefusedRoot(_ root: String, home: String = NSHomeDirectory()) -> Bool {
        let r = (root as NSString).standardizingPath
        guard r.hasPrefix("/"), r != "/", r != (home as NSString).standardizingPath else { return true }
        // whole system trees are never roots; the top of /private, /var and /tmp themselves are not either (a per-user temp folder BELOW them, or a project folder, is a legitimate root)
        for system in ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/dev", "/Applications", "/Volumes"] where r == system || r.hasPrefix(system + "/") { return true }
        return ["/private", "/var", "/tmp", "/opt", "/cores"].contains(r)
    }

    static func scan(roots: [String], registered: [String: Date] = [:], limits: DiscoveryLimits = DiscoveryLimits(), fs: DiscoveryFileSystem = DefaultDiscoveryFileSystem(), home: String = NSHomeDirectory()) -> DiscoveryReport {
        var report = DiscoveryReport()
        var seen = Set<String>()
        for root in roots {
            let r = (root as NSString).standardizingPath
            if isRefusedRoot(r, home: home) { report.refusedRoots.append(root); continue }
            guard fs.exists(r) else { report.missingRoots.append(root); continue }
            walk(r, depth: 0, limits: limits, fs: fs, registered: registered, seen: &seen, report: &report)
            if report.truncated { break }
        }
        report.candidates.sort { ($0.kind, $0.folderName.lowercased()) < ($1.kind, $1.folderName.lowercased()) }
        return report
    }

    private static func walk(_ path: String, depth: Int, limits: DiscoveryLimits, fs: DiscoveryFileSystem, registered: [String: Date], seen: inout Set<String>, report: inout DiscoveryReport) {
        guard !report.truncated else { return }
        if report.directoriesVisited >= limits.maxDirectories || report.candidates.count >= limits.maxCandidates { report.truncated = true; return }
        report.directoriesVisited += 1
        guard let children = fs.children(path) else { return }
        if let candidate = classify(path, children: children, fs: fs, registered: registered), seen.insert(path).inserted {
            report.candidates.append(candidate)
            return                                                    // a project's own subfolders are not separate projects
        }
        guard depth < limits.maxDepth else { return }
        for child in children.sorted(by: { $0.name < $1.name }) where child.isDirectory && !child.isSymlink && !limits.skipNames.contains(child.name) && !child.name.hasPrefix(".") {
            walk(path + "/" + child.name, depth: depth + 1, limits: limits, fs: fs, registered: registered, seen: &seen, report: &report)
            if report.truncated { return }
        }
    }

    static func classify(_ path: String, children: [DiscoveryEntry], fs: DiscoveryFileSystem, registered: [String: Date]) -> ProjectCandidate? {
        let names = Set(children.map(\.name))
        var markers: [String] = []
        var kinds: [DiscoveredProjectKind] = []
        var verified = false
        if names.contains("Assets"), names.contains("ProjectSettings") {
            markers.append("Assets"); markers.append("ProjectSettings")
            kinds.append(.unity)
            if fs.exists(path + "/ProjectSettings/ProjectVersion.txt") { markers.append("ProjectSettings/ProjectVersion.txt"); verified = true }
        }
        if let x = children.first(where: { $0.isDirectory && ($0.name.hasSuffix(".xcodeproj") || $0.name.hasSuffix(".xcworkspace")) }) { markers.append(x.name); kinds.append(.xcode); verified = true }
        if names.contains("Package.swift") { markers.append("Package.swift"); kinds.append(.swiftPackage); verified = true }
        if names.contains(".git") { markers.append(".git"); kinds.append(.git); verified = verified || kinds.count == 1 }
        guard let kind = kinds.min() else { return nil }
        let folder = (path as NSString).lastPathComponent
        let mod = [fs.modified(path + "/.git/HEAD"), fs.modified(path + "/ProjectSettings/ProjectSettings.asset"), fs.modified(path)].compactMap { $0 }.max()
        return ProjectCandidate(path: path, folderName: folder, kind: kind, markers: markers, suggestedAliases: suggestedAliases(forFolder: folder), lastWorked: mod, registered: registered[path] != nil, lastOpened: registered[path], verified: verified)
    }

    /// Proposed spoken forms from the folder's own name: “TurkishHammamSimulator” → “Turkish Hammam Simulator”; “hammam-sim” → “hammam sim”. Never a single generic word, never a guess at a nickname.
    static func suggestedAliases(forFolder folder: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { words.append(current); current = "" } }
        var previousLower = false
        for ch in folder {
            if ch == "-" || ch == "_" || ch == " " || ch == "." { flush(); previousLower = false; continue }
            if ch.isUppercase, previousLower { flush() }
            current.append(ch); previousLower = ch.isLowercase || ch.isNumber
        }
        flush()
        guard words.count > 1 else { return [] }
        let spaced = words.joined(separator: " ")
        return spaced == folder ? [] : [spaced]
    }
}

// MARK: - Exact alias resolution (fuzzy only suggests)

struct AliasEntry: Equatable, Sendable {
    var key: String
    var name: String
    var aliases: [String]
}

enum AliasResolution: Equatable, Sendable {
    case exact(String)
    /// Several projects answer to the same spoken name: ask.
    case ambiguous([String])
    /// No exact match; near names to ASK about (never executed on).
    case none(suggestions: [String])
}

enum ProjectAliasResolver {
    private static func fold(_ s: String) -> String { DecisionText.fold(s).filter { $0.isLetter || $0.isNumber } }

    static func resolve(spoken: String, among entries: [AliasEntry]) -> AliasResolution {
        let want = fold(spoken)
        guard !want.isEmpty else { return .none(suggestions: []) }
        let hits = entries.filter { e in ([e.name] + e.aliases).contains { ProjectOpenResolver.nameMatches(spoken: spoken, name: $0) } }
        if hits.count == 1 { return .exact(hits[0].key) }
        if hits.count > 1 { return .ambiguous(hits.map(\.key)) }
        return .none(suggestions: suggestions(for: spoken, among: entries))
    }

    /// Names within a small edit distance of the spoken one (after removing a closed suffix chain). For a QUESTION only: “Did you mean …?”.
    static func suggestions(for spoken: String, among entries: [AliasEntry], limit: Int = 3) -> [String] {
        let want = fold(spoken)
        guard want.count >= 4 else { return [] }
        let maxDistance = want.count >= 8 ? 2 : 1
        var scored: [(String, Int)] = []
        for e in entries {
            var best = Int.max
            for name in [e.name] + e.aliases {
                let n = fold(name)
                guard n.count >= 4 else { continue }
                best = min(best, distance(want, n))
                // the spoken form may carry a case suffix the name does not
                for cut in 1...4 where want.count - cut >= 3 && TurkishMorphology.isClosedChain(String(want.suffix(cut))) { best = min(best, distance(String(want.dropLast(cut)), n)) }
            }
            if best <= maxDistance, best > 0 { scored.append((e.name, best)) }
        }
        return Array(scored.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.prefix(limit).map(\.0))
    }

    /// Levenshtein distance (bounded inputs: names are short).
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[y.count]
    }
}
