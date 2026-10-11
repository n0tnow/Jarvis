import Foundation

// MARK: - Typed project tools (no shell, no arbitrary command; capability + workspace checked)

enum ToolError: Error, Equatable, CustomStringConvertible {
    case capabilityDenied(TaskCapability)
    case workspace(WorkspaceGuard.Violation)
    case notFound(String)
    case notText(String)
    case tooLarge(String)
    case editRejected(String)
    case ioFailed(String)

    var description: String {
        switch self {
        case .capabilityDenied(let c): "capability \(c.rawValue) is not granted for this task"
        case .workspace(let v): v.description
        case .notFound(let p): "not found: \(p)"
        case .notText(let p): "not a readable text file: \(p)"
        case .tooLarge(let p): "file too large: \(p)"
        case .editRejected(let r): "edit rejected: \(r)"
        case .ioFailed(let r): "i/o failed: \(r)"
        }
    }

    var failureCategory: FailureCategory {
        switch self {
        case .capabilityDenied: .capabilityDenied
        case .workspace: .workspaceViolation
        case .editRejected: .validationFailed
        default: .toolFailed
        }
    }
}

struct FileSnapshot: Equatable, Sendable {
    var path: String
    var text: String
    var truncated: Bool
    var hash: String
}

struct SearchHit: Equatable, Sendable { var path: String; var line: Int; var snippet: String }

/// ReadFile / ListDirectory / SearchProject / ApplyEdits / DeletePath — each checks the task's capabilities and the workspace guard.
struct ProjectTools: Sendable {
    let workspace: WorkspaceGuard
    let capabilities: CapabilitySet
    static let maxReadBytes = 60_000
    static let maxFileBytes = 1_000_000

    private func require(_ c: TaskCapability) throws { guard capabilities.allows(c) else { throw ToolError.capabilityDenied(c) } }
    private func resolve(_ p: String) throws -> URL {
        do { return try workspace.resolve(p) } catch let v as WorkspaceGuard.Violation { throw ToolError.workspace(v) }
    }

    // MARK: Read

    static func looksBinary(_ data: Data) -> Bool { data.prefix(8192).contains(0) }

    func readFile(_ path: String, maxBytes: Int = ProjectTools.maxReadBytes) throws -> FileSnapshot {
        try require(.readProject)
        let url = try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ToolError.notFound(path) }
        guard !isDir.boolValue else { throw ToolError.notText(path) }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ToolError.ioFailed("cannot read \(path)") }
        guard !Self.looksBinary(data), data.count <= Self.maxFileBytes else { throw data.count > Self.maxFileBytes ? ToolError.tooLarge(path) : ToolError.notText(path) }
        let head = data.prefix(maxBytes)
        guard let text = String(data: head, encoding: .utf8) ?? String(data: data.prefix(maxBytes - 3), encoding: .utf8) else { throw ToolError.notText(path) }
        return FileSnapshot(path: workspace.relative(url), text: text, truncated: data.count > maxBytes, hash: Redactor.sha256(data))
    }

    func fileHash(_ path: String) throws -> String? {
        try require(.readProject)
        let url = try resolve(path)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return Redactor.sha256(data)
    }

    func exists(_ path: String) throws -> Bool { FileManager.default.fileExists(atPath: try resolve(path).path) }

    /// Bounded, sorted tree of the project (no ignored/protected entries).
    func projectTree(maxEntries: Int = 220, maxDepth: Int = 5) throws -> String {
        try require(.readProject)
        var lines: [String] = []
        var count = 0
        func walk(_ dir: String, _ depth: Int) {
            guard depth <= maxDepth, count < maxEntries,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir).sorted() else { return }
            for name in names where count < maxEntries {
                if WorkspaceGuard.isProtected([name]) { continue }
                let full = dir + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if WorkspaceGuard.ignoredDirectories.contains(name) || name.hasPrefix(".") && name != ".jarvis" { continue }
                    // do not follow symlinked directories out of the workspace
                    if let real = realpathString(full), !(real == workspace.root || real.hasPrefix(workspace.root + "/")) { continue }
                    lines.append(String(repeating: "  ", count: depth) + name + "/"); count += 1
                    walk(full, depth + 1)
                } else {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: full)[.size]) as? Int) ?? 0
                    lines.append(String(repeating: "  ", count: depth) + name + " (\(size) B)"); count += 1
                }
            }
        }
        walk(workspace.root, 0)
        if count >= maxEntries { lines.append("… (listing truncated)") }
        return lines.joined(separator: "\n")
    }

    private func realpathString(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// Workspace-relative paths of text files (sorted), bounded.
    func listFiles(maxFiles: Int = 400) throws -> [String] {
        try require(.readProject)
        var out: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            guard depth <= 8, out.count < maxFiles, let names = try? FileManager.default.contentsOfDirectory(atPath: dir).sorted() else { return }
            for name in names where out.count < maxFiles {
                if WorkspaceGuard.isProtected([name]) { continue }
                let full = dir + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if WorkspaceGuard.ignoredDirectories.contains(name) || (name.hasPrefix(".") && name != ".jarvis") { continue }
                    if let real = realpathString(full), !(real == workspace.root || real.hasPrefix(workspace.root + "/")) { continue }
                    walk(full, depth + 1)
                } else if let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size]) as? Int, size <= Self.maxFileBytes {
                    out.append(workspace.relative(URL(fileURLWithPath: full)))
                }
            }
        }
        walk(workspace.root, 0)
        return out
    }

    /// Case-insensitive substring search over text files (bounded). Used to find the files relevant to a step.
    func search(terms: [String], maxHits: Int = 40) throws -> [SearchHit] {
        try require(.readProject)
        let needles = terms.map { $0.lowercased() }.filter { $0.count >= 3 }
        guard !needles.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for rel in try listFiles(maxFiles: 400) where hits.count < maxHits {
            guard let snap = try? readFile(rel, maxBytes: 200_000) else { continue }
            var n = 0
            for (i, line) in snap.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where hits.count < maxHits && n < 3 {
                let l = line.lowercased()
                if needles.contains(where: l.contains) { hits.append(SearchHit(path: rel, line: i + 1, snippet: String(line.trimmingCharacters(in: .whitespaces).prefix(160)))); n += 1 }
            }
        }
        return hits
    }

    // MARK: Write (apply edits atomically)

    struct PreparedFile: Equatable, Sendable {
        var path: String            // workspace-relative
        var before: String?         // nil = new file
        var after: String
        var beforeHash: String?
        var afterHash: String { Redactor.sha256(Data(after.utf8)) }
    }

    /// Computes the resulting content of every touched file WITHOUT writing anything. All-or-nothing: any rejected block rejects the set.
    func prepare(_ blocks: [EditBlock]) throws -> [PreparedFile] {
        try require(.readProject); try require(.writeProject)
        guard !blocks.isEmpty else { throw ToolError.editRejected("no edits were found in the answer") }
        var files: [String: PreparedFile] = [:]
        var order: [String] = []
        for b in blocks {
            let url = try resolve(b.path)
            let rel = workspace.relative(url)
            var current: PreparedFile
            if let f = files[rel] { current = f }
            else if FileManager.default.fileExists(atPath: url.path) {
                guard let data = FileManager.default.contents(atPath: url.path), !Self.looksBinary(data), data.count <= Self.maxFileBytes,
                      let text = String(data: data, encoding: .utf8) else { throw ToolError.notText(rel) }
                current = PreparedFile(path: rel, before: text, after: text, beforeHash: Redactor.sha256(data))
            } else { current = PreparedFile(path: rel, before: nil, after: "", beforeHash: nil) }
            switch b.operation {
            case .replace(let find, let replacement):
                guard current.before != nil || files[rel] != nil else { throw ToolError.editRejected("\(rel) does not exist; use a CREATE block for new files") }
                guard !find.isEmpty else { throw ToolError.editRejected("empty SEARCH text for \(rel)") }
                current.after = try Self.replaceOnce(in: current.after, find: find, with: replacement, path: rel)
            case .create(let content):
                if current.before != nil && files[rel] == nil, current.before == content { throw ToolError.editRejected("\(rel) already has exactly this content") }
                current.after = content.hasSuffix("\n") || content.isEmpty ? content : content + "\n"
            }
            if files[rel] == nil { order.append(rel) }
            files[rel] = current
        }
        let result = order.compactMap { files[$0] }.filter { $0.before != $0.after }
        guard !result.isEmpty else { throw ToolError.editRejected("the edits do not change any file") }
        return result
    }

    /// Exact match required to be UNIQUE; falls back to a trailing-whitespace-insensitive line match (still unique).
    static func replaceOnce(in text: String, find: String, with replacement: String, path: String) throws -> String {
        let ranges = allRanges(of: find, in: text)
        if ranges.count == 1, let r = ranges.first { return text.replacingCharacters(in: r, with: replacement) }
        if ranges.count > 1 { throw ToolError.editRejected("SEARCH text appears \(ranges.count) times in \(path); include more surrounding lines so it is unique") }
        // line-normalised fallback
        let lines = text.components(separatedBy: "\n")
        let needle = find.components(separatedBy: "\n").map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        let trimmedNeedle = needle.drop(while: { $0.isEmpty }).reversed().drop(while: { $0.isEmpty }).reversed().map { $0 }
        guard !trimmedNeedle.isEmpty, lines.count >= trimmedNeedle.count else { throw ToolError.editRejected("SEARCH text was not found in \(path)") }
        var matches: [Int] = []
        for start in 0...(lines.count - trimmedNeedle.count) {
            var ok = true
            for (k, n) in trimmedNeedle.enumerated() where lines[start + k].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) != n { ok = false; break }
            if ok { matches.append(start) }
        }
        guard matches.count == 1, let s = matches.first else {
            throw ToolError.editRejected(matches.isEmpty ? "SEARCH text was not found in \(path)" : "SEARCH text is ambiguous in \(path)")
        }
        var out = lines
        out.replaceSubrange(s..<(s + trimmedNeedle.count), with: replacement.components(separatedBy: "\n"))
        return out.joined(separator: "\n")
    }

    private static func allRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: needle, range: from..<text.endIndex) { result.append(r); from = r.upperBound; if result.count > 2 { break } }
        return result
    }

    /// Writes prepared files atomically (temp + rename, permissions kept). The caller holds the write leases.
    func apply(_ files: [PreparedFile], stepKey: String, preexisting: Set<String>) throws -> [TaskFileChange] {
        try require(.writeProject)
        var changes: [TaskFileChange] = []
        var written: [PreparedFile] = []
        do {
            for f in files {
                let url = try resolve(f.path)                                  // re-validate at write time (symlinks may have changed)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try Data(f.after.utf8).write(to: url, options: .atomic) } catch { throw ToolError.ioFailed("cannot write \(f.path)") }
                written.append(f)
                if let perm = attrs?[.posixPermissions] { try? FileManager.default.setAttributes([.posixPermissions: perm], ofItemAtPath: url.path) }
                changes.append(TaskFileChange(path: f.path, changeType: f.before == nil ? "created" : "modified", beforeHash: f.beforeHash, afterHash: f.afterHash,
                                              stepKey: stepKey, preexistingUserChange: preexisting.contains(f.path)))
            }
        } catch {
            // All-or-nothing: undo what was already written (restore the previous content, remove files this call created).
            for f in written.reversed() {
                guard let url = try? resolve(f.path) else { continue }
                if let before = f.before { try? Data(before.utf8).write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
            }
            throw error
        }
        return changes
    }

    /// Destructive: callers must hold an APPROVED approval for exactly this path (checked by the engine, not here).
    func delete(_ path: String) throws -> TaskFileChange {
        try require(.writeProject); try require(.destructiveFileOperation)
        let url = try resolve(path)
        guard url.path != workspace.root else { throw ToolError.workspace(.protected(path)) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.notFound(path) }
        let before = FileManager.default.contents(atPath: url.path).map(Redactor.sha256)
        do { try FileManager.default.removeItem(at: url) } catch { throw ToolError.ioFailed("cannot delete \(path)") }
        return TaskFileChange(path: workspace.relative(url), changeType: "deleted", beforeHash: before, afterHash: nil, stepKey: "", preexistingUserChange: false)
    }
}

// MARK: - Edit blocks (what the CodingAgent returns)

struct EditBlock: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case replace(find: String, with: String)
        case create(String)
    }
    var path: String
    var operation: Operation
}

/// Parses SEARCH/REPLACE and CREATE blocks. Plain text on purpose: code in JSON strings is error-prone for models.
///
///     <<<<<<< SEARCH path/to/file.py
///     old text
///     =======
///     new text
///     >>>>>>> REPLACE
///
///     <<<<<<< CREATE path/to/new_file.py
///     whole file
///     >>>>>>> END
enum EditParser {
    static func parse(_ text: String) -> (blocks: [EditBlock], problems: [String]) {
        var blocks: [EditBlock] = []
        var problems: [String] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        func header(_ line: String) -> (String, String)? {                // ("SEARCH"|"CREATE", path)
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("<<<<<<<") else { return nil }
            let rest = t.dropFirst(7).trimmingCharacters(in: .whitespaces)
            for kw in ["SEARCH", "CREATE"] where rest.uppercased().hasPrefix(kw) {
                var path = String(rest.dropFirst(kw.count)).trimmingCharacters(in: .whitespaces)
                if path.lowercased().hasPrefix("file:") { path = String(path.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                path = path.trimmingCharacters(in: CharacterSet(charactersIn: "`'\" "))
                return (kw, path)
            }
            return nil
        }
        while i < lines.count {
            guard let (kind, path) = header(lines[i]) else { i += 1; continue }
            if path.isEmpty { problems.append("a \(kind) block has no file path"); i += 1; continue }
            i += 1
            var first: [String] = [], second: [String] = []
            var inSecond = false, closed = false
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if kind == "SEARCH" {
                    if t == "=======" && !inSecond { inSecond = true; i += 1; continue }
                    if t.hasPrefix(">>>>>>>") { closed = true; i += 1; break }
                } else if t.hasPrefix(">>>>>>>") { closed = true; i += 1; break }
                if inSecond { second.append(lines[i]) } else { first.append(lines[i]) }
                i += 1
            }
            if !closed { problems.append("the \(kind) block for \(path) is not closed"); continue }
            if kind == "SEARCH" {
                if !inSecond { problems.append("the SEARCH block for \(path) has no ======= divider"); continue }
                blocks.append(EditBlock(path: path, operation: .replace(find: first.joined(separator: "\n"), with: second.joined(separator: "\n"))))
            } else {
                blocks.append(EditBlock(path: path, operation: .create(first.joined(separator: "\n"))))
            }
        }
        return (blocks, problems)
    }
}

// MARK: - Unified diff (line based; bounded)

enum UnifiedDiff {
    static func make(path: String, before: String?, after: String?, context: Int = 3, maxLines: Int = 3000) -> String {
        let a = before.map { $0.components(separatedBy: "\n") } ?? []
        let b = after.map { $0.components(separatedBy: "\n") } ?? []
        var out = ["--- \(before == nil ? "/dev/null" : "a/" + path)", "+++ \(after == nil ? "/dev/null" : "b/" + path)"]
        guard a.count <= maxLines, b.count <= maxLines else { out.append("(diff omitted: file too large — \(a.count) → \(b.count) lines)"); return out.joined(separator: "\n") }
        // LCS table
        let n = a.count, m = b.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) { for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            } }
        }
        enum Op { case same(String), del(String), add(String) }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { ops.append(.same(a[i])); i += 1; j += 1 }
            else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { ops.append(.add(b[j])); j += 1 }
            else { ops.append(.del(a[i])); i += 1 }
        }
        // hunks with context
        let changed = ops.enumerated().filter { if case .same = $0.element { return false }; return true }.map(\.offset)
        guard !changed.isEmpty else { return out.joined(separator: "\n") }
        var ranges: [(Int, Int)] = []
        for c in changed {
            let lo = max(0, c - context), hi = min(ops.count - 1, c + context)
            if let last = ranges.last, lo <= last.1 + 1 { ranges[ranges.count - 1].1 = max(last.1, hi) } else { ranges.append((lo, hi)) }
        }
        for (lo, hi) in ranges {
            out.append("@@ hunk @@")
            for k in lo...hi {
                switch ops[k] { case .same(let s): out.append(" " + s); case .del(let s): out.append("-" + s); case .add(let s): out.append("+" + s) }
            }
        }
        return out.joined(separator: "\n")
    }
}
