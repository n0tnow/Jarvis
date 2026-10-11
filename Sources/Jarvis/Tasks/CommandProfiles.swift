import Foundation

// MARK: - Approved build/test command profiles (never a shell, never a free-form command)

struct CommandProfile: Codable, Equatable, Sendable {
    var label: String                         // "swift test"
    var executable: String                    // approved basename ("swift", "python3", …)
    var arguments: [String]
    var timeoutSeconds = 300
    /// Optional workspace-relative working directory.
    var subdirectory: String?

    var display: String { ([executable] + arguments).joined(separator: " ") }
}

enum CommandPolicyError: Error, Equatable, CustomStringConvertible {
    case executableNotApproved(String)
    case executableNotFound(String)
    case argumentRejected(String)
    case workspace(String)

    var description: String {
        switch self {
        case .executableNotApproved(let e): "the executable \"\(e)\" is not on the approved build/test list"
        case .executableNotFound(let e): "\(e) was not found in the standard tool locations"
        case .argumentRejected(let a): "the argument \"\(a)\" is not allowed for build/test commands"
        case .workspace(let w): w
        }
    }
}

/// The ONLY executables a task may start for build/test. Resolved from fixed system locations (never from the workspace, never via
/// `env`/a shell), with a per-tool argument policy so a "test command" cannot become arbitrary code execution (`python -c`, `node -e`, …).
enum ApprovedExecutables {
    static let names: Set<String> = ["swift", "python3", "pytest", "make", "npm", "node", "cargo", "go", "dotnet", "xcodebuild"]
    static let searchDirectories = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Library/Developer/CommandLineTools/usr/bin"]
    /// Test hook: extra directories (fixtures with fake tools). Product code never sets it.
    nonisolated(unsafe) static var extraSearchDirectories: [String] = []

    static func resolve(_ name: String) throws -> String {
        guard names.contains(name) else { throw CommandPolicyError.executableNotApproved(name) }
        for dir in extraSearchDirectories + searchDirectories {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw CommandPolicyError.executableNotFound(name)
    }

    private static let safeArgument = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_./=:+@,-]{1,160}$"#)

    static func validate(_ profile: CommandProfile, workspace: WorkspaceGuard) throws {
        guard names.contains(profile.executable) else { throw CommandPolicyError.executableNotApproved(profile.executable) }
        guard (1...3600).contains(profile.timeoutSeconds) else { throw CommandPolicyError.argumentRejected("timeout") }
        for a in profile.arguments {
            let range = NSRange(a.startIndex..., in: a)
            guard safeArgument.firstMatch(in: a, range: range) != nil, !a.hasPrefix("/"), a != "..", !a.contains("../"), !a.hasSuffix("/..") else { throw CommandPolicyError.argumentRejected(a) }
        }
        let args = profile.arguments
        func firstIs(_ allowed: Set<String>) -> Bool { args.first.map(allowed.contains) ?? false }
        switch profile.executable {
        case "swift": guard firstIs(["build", "test"]) else { throw CommandPolicyError.argumentRejected(args.first ?? "") }
        case "python3":
            if args.first == "-m" {
                guard args.count >= 2, ["unittest", "pytest"].contains(args[1]) else { throw CommandPolicyError.argumentRejected(args.dropFirst().first ?? "-m") }
            } else {
                // a project script (relative, inside the workspace, .py) — the project's own test runner
                guard let script = args.first, script.hasSuffix(".py"), (try? workspace.resolve(script)) != nil else { throw CommandPolicyError.argumentRejected(args.first ?? "") }
            }
            for a in args where a == "-c" || a == "-S" || a == "-i" { throw CommandPolicyError.argumentRejected(a) }
        case "pytest": for a in args where a.hasPrefix("--rootdir") || a.hasPrefix("-p") { throw CommandPolicyError.argumentRejected(a) }
        case "make": for a in args where a.hasPrefix("-") || a.contains("=") { throw CommandPolicyError.argumentRejected(a) }
        case "npm": guard (args.first == "test") || (args.first == "run" && args.count == 2 && ["test", "build", "lint"].contains(args[1])) else { throw CommandPolicyError.argumentRejected(args.joined(separator: " ")) }
        case "node": guard let script = args.first, script.hasSuffix(".js") || script.hasSuffix(".mjs"), (try? workspace.resolve(script)) != nil else { throw CommandPolicyError.argumentRejected(args.first ?? "") }
        case "cargo": guard firstIs(["build", "test", "check"]) else { throw CommandPolicyError.argumentRejected(args.first ?? "") }
        case "go": guard firstIs(["build", "test", "vet"]) else { throw CommandPolicyError.argumentRejected(args.first ?? "") }
        case "dotnet": guard firstIs(["build", "test"]) else { throw CommandPolicyError.argumentRejected(args.first ?? "") }
        case "xcodebuild": guard firstIs(["build", "test", "-scheme", "-project", "-workspace"]) else { throw CommandPolicyError.argumentRejected(args.first ?? "") }
        default: throw CommandPolicyError.executableNotApproved(profile.executable)
        }
        if let sub = profile.subdirectory { do { _ = try workspace.resolve(sub) } catch { throw CommandPolicyError.workspace("working directory outside the workspace: \(sub)") } }
    }
}

struct ProjectProfiles: Equatable, Sendable {
    var build: CommandProfile?
    var test: CommandProfile?
    var source: String            // where it came from: "declared (.jarvis/project.json)", "SwiftPM", …
}

enum ProfileDiscovery {
    /// Declared profile first (the user's own `.jarvis/project.json`), then well-known project markers. Nothing is invented.
    static func discover(_ workspace: WorkspaceGuard) -> ProjectProfiles {
        let root = workspace.root
        func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root + "/" + rel) }
        func read(_ rel: String) -> String? { FileManager.default.contents(atPath: root + "/" + rel).flatMap { String(data: $0, encoding: .utf8) } }

        if let data = FileManager.default.contents(atPath: root + "/.jarvis/project.json"),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            func profile(_ key: String) -> CommandProfile? {
                guard let d = obj[key] as? [String: Any], let exe = d["executable"] as? String else { return nil }
                return CommandProfile(label: (d["label"] as? String) ?? exe, executable: exe, arguments: (d["arguments"] as? [String]) ?? [],
                                      timeoutSeconds: (d["timeoutSeconds"] as? Int) ?? 300, subdirectory: d["subdirectory"] as? String)
            }
            let p = ProjectProfiles(build: profile("build"), test: profile("test"), source: "declared in .jarvis/project.json")
            if p.build != nil || p.test != nil { return p }
        }
        if exists("Package.swift") {
            return ProjectProfiles(build: CommandProfile(label: "swift build", executable: "swift", arguments: ["build"], timeoutSeconds: 900),
                                   test: CommandProfile(label: "swift test", executable: "swift", arguments: ["test"], timeoutSeconds: 900), source: "SwiftPM (Package.swift)")
        }
        if exists("Cargo.toml") {
            return ProjectProfiles(build: CommandProfile(label: "cargo build", executable: "cargo", arguments: ["build"], timeoutSeconds: 900),
                                   test: CommandProfile(label: "cargo test", executable: "cargo", arguments: ["test"], timeoutSeconds: 900), source: "Cargo.toml")
        }
        if exists("go.mod") {
            return ProjectProfiles(build: CommandProfile(label: "go build", executable: "go", arguments: ["build", "./..."], timeoutSeconds: 600),
                                   test: CommandProfile(label: "go test", executable: "go", arguments: ["test", "./..."], timeoutSeconds: 600), source: "go.mod")
        }
        if let pkg = read("package.json"), pkg.contains("\"test\"") {
            return ProjectProfiles(build: pkg.contains("\"build\"") ? CommandProfile(label: "npm run build", executable: "npm", arguments: ["run", "build"], timeoutSeconds: 600) : nil,
                                   test: CommandProfile(label: "npm test", executable: "npm", arguments: ["test"], timeoutSeconds: 600), source: "package.json")
        }
        if let mk = read("Makefile"), mk.range(of: #"(?m)^test\s*:"#, options: .regularExpression) != nil {
            let hasBuild = mk.range(of: #"(?m)^(build|all)\s*:"#, options: .regularExpression) != nil
            return ProjectProfiles(build: hasBuild ? CommandProfile(label: "make build", executable: "make", arguments: [mk.range(of: #"(?m)^build\s*:"#, options: .regularExpression) != nil ? "build" : "all"], timeoutSeconds: 600) : nil,
                                   test: CommandProfile(label: "make test", executable: "make", arguments: ["test"], timeoutSeconds: 600), source: "Makefile")
        }
        let files = (try? ProjectTools(workspace: workspace, capabilities: .readOnly).listFiles(maxFiles: 300)) ?? []
        if files.contains(where: { ($0 as NSString).lastPathComponent.hasPrefix("test") && $0.hasSuffix(".py") || $0.hasSuffix("_test.py") }) || exists("pytest.ini") || exists("conftest.py") {
            let usesPytest = exists("pytest.ini") || exists("conftest.py")
            return ProjectProfiles(build: nil, test: usesPytest
                                   ? CommandProfile(label: "pytest", executable: "python3", arguments: ["-m", "pytest", "-q"], timeoutSeconds: 600)
                                   : CommandProfile(label: "python unittest", executable: "python3", arguments: ["-m", "unittest", "discover"], timeoutSeconds: 600),
                                   source: "Python tests")
        }
        return ProjectProfiles(build: nil, test: nil, source: "none found")
    }
}

// MARK: - Execution

struct CommandResult: Equatable, Sendable {
    var exitCode: Int32
    var timedOut: Bool
    var cancelled: Bool
    var durationSeconds: Double
    var tail: String                          // sanitized, bounded
    var testCounts: TestCounts?

    var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

struct TestCounts: Equatable, Sendable {
    var total: Int?
    var passed: Int?
    var failed: Int?
    var summary: String { [total.map { "\($0) test\($0 == 1 ? "" : "s")" }, passed.map { "\($0) passed" }, failed.map { "\($0) failed" }].compactMap { $0 }.joined(separator: ", ") }

    /// Counts are only reported when the tool printed them (never inferred from the exit code).
    static func parse(_ output: String) -> TestCounts? {
        func first(_ pattern: String) -> Int? {
            guard let r = output.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(output[r].filter(\.isNumber))
        }
        var c = TestCounts()
        if let n = first(#"(?m)^Ran \d+ tests?"#) { c.total = n }                                               // unittest
        else if let n = first(#"Executed \d+ tests?"#) { c.total = n }                                          // XCTest
        else if let n = first(#"Test run with \d+ tests?"#) { c.total = n }                                     // Swift Testing
        else if let n = first(#"\d+ passed"#) { c.passed = n; c.total = (first(#"\d+ failed"#) ?? 0) + n }      // pytest
        if let f = first(#"failures=\d+"#) ?? first(#"\d+ failed"#) ?? first(#"with \d+ failures?"#) { c.failed = f }
        if c.total != nil, c.passed == nil, let t = c.total { c.passed = t - (c.failed ?? 0) }
        return c.total == nil && c.failed == nil ? nil : c
    }
}

enum CommandRunner {
    static let tailLimit = 12_000

    /// Runs one APPROVED profile through `ManagedProcess` (argv, no shell). Output is sanitized before it reaches the console, the
    /// returned tail or anything persistent. Cancellation kills the whole process tree through the existing cancel path.
    @MainActor
    static func run(_ profile: CommandProfile, workspace: WorkspaceGuard, sink: SafeToolOutput) async throws -> CommandResult {
        try ApprovedExecutables.validate(profile, workspace: workspace)
        let exe = try ApprovedExecutables.resolve(profile.executable)
        var cwd = workspace.root
        if let sub = profile.subdirectory, let url = try? workspace.resolve(sub) { cwd = url.path }
        var env = ProviderEnvironment.make(extraPath: ApprovedExecutables.extraSearchDirectories + ["/opt/homebrew/bin", "/usr/local/bin"])
        env["PYTHONDONTWRITEBYTECODE"] = "1"; env["PYTHONUNBUFFERED"] = "1"; env["CI"] = "1"; env["GIT_TERMINAL_PROMPT"] = "0"
        let proc = ManagedProcess(executable: exe, arguments: profile.arguments, environment: env, workingDirectory: cwd, mergeStderr: true)
        let started = Date()
        let stream: AsyncStream<Data>
        do { stream = try proc.start(stdin: nil) } catch { throw CommandPolicyError.executableNotFound(profile.executable) }
        let timedOut = AtomicFlag()
        let userCancelled = AtomicFlag()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(profile.timeoutSeconds))
            if !Task.isCancelled { timedOut.set(); await proc.cancel() }
        }
        await withTaskCancellationHandler {
            for await line in stream { sink.feed(String(decoding: line, as: UTF8.self)) }
        } onCancel: {
            userCancelled.set()
            Task.detached { await proc.cancel() }
        }
        watchdog.cancel()
        let code = await proc.waitForExit()
        sink.finish()
        let tail = sink.tail
        return CommandResult(exitCode: code, timedOut: timedOut.value, cancelled: userCancelled.value || Task.isCancelled,
                             durationSeconds: Date().timeIntervalSince(started), tail: tail, testCounts: TestCounts.parse(tail))
    }
}
