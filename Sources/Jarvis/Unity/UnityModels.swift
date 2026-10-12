import Foundation

// MARK: - Versions (V0.6 — DEC-047…)

/// A Unity editor version such as `6000.5.1f1` or `2022.3.12f1`. Parsed structurally; compared numerically.
struct UnityVersion: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    var major: Int, minor: Int, patch: Int
    var suffix: String                     // "f1", "b3", "a2", "f1c1"

    /// Accepts `6000.5.1f1`, `6000.5.1f1 (0d9463e84828)` and `m_EditorVersion: 6000.5.1f1`.
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = s.firstIndex(of: ":") { s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        if let sp = s.firstIndex(of: " ") { s = String(s[..<sp]) }
        let m = s.range(of: #"^(\d{1,4})\.(\d{1,2})\.(\d{1,3})([abfpc][0-9]{1,3}[A-Za-z0-9]*)?$"#, options: .regularExpression)
        guard m != nil else { return nil }
        let core = s.prefix { $0.isNumber || $0 == "." }
        let nums = core.split(separator: ".").compactMap { Int($0) }
        guard nums.count >= 3 else { return nil }
        major = nums[0]; minor = nums[1]; patch = nums[2]
        suffix = String(s.dropFirst(core.count))
    }

    var description: String { "\(major).\(minor).\(patch)\(suffix)" }
    static func < (a: UnityVersion, b: UnityVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        return a.suffix < b.suffix
    }
}

struct UnityEditorInstall: Equatable, Codable, Sendable, Identifiable {
    var version: UnityVersion
    var appPath: String                    // …/Unity.app
    var executablePath: String             // …/Unity.app/Contents/MacOS/Unity
    var available: Bool
    var lastCheckedAt: Date
    var id: String { appPath }
}

// MARK: - Connection state (truthful: never CONNECTED from discovery alone)

enum UnityConnectionState: String, Codable, Sendable, CaseIterable {
    case notConfigured, discovering, available, connecting, connected, busy, playMode, disconnected, error

    var label: String {
        switch self {
        case .notConfigured: "NOT CONFIGURED"; case .discovering: "DISCOVERING"; case .available: "AVAILABLE"; case .connecting: "CONNECTING"
        case .connected: "CONNECTED"; case .busy: "BUSY"; case .playMode: "PLAY MODE"; case .disconnected: "DISCONNECTED"; case .error: "ERROR"
        }
    }
}

// MARK: - Project descriptor (deterministic; never the whole project)

struct UnityProjectDescriptor: Equatable, Codable, Sendable {
    var workspace: String
    var projectName: String
    var declaredVersion: UnityVersion?
    var declaredVersionRaw: String?
    var renderPipeline: String              // "Built-in" | "Universal (URP)" | "High Definition (HDRP)" | "Scriptable"
    var packages: [String: String]          // from Packages/manifest.json (bounded)
    var hasTestFramework: Bool
    var testFrameworkVersion: String?
    var scenes: [String]                    // project-relative, bounded
    var buildScenes: [String]
    var assemblyDefinitions: [String]       // bounded
    var bridgeInstalled: Bool
    var bridgeVersion: String?
    var hasLibrary: Bool                    // the project was opened before

    static let maxPackages = 80, maxScenes = 100, maxAsmdefs = 100
}

// MARK: - Object identity (never name-only)

/// How a request addresses a GameObject. Mutations need `globalId` or `path`; a bare `name` is only valid for lookups.
struct UnityTarget: Codable, Equatable, Hashable, Sendable {
    var globalId: String?
    var path: String?
    var scene: String?
    var name: String?

    init(globalId: String? = nil, path: String? = nil, scene: String? = nil, name: String? = nil) {
        self.globalId = globalId; self.path = path; self.scene = scene; self.name = name
    }
    /// Enough to identify exactly one object (no guessing by name).
    var isPrecise: Bool { (globalId?.isEmpty == false) || (path?.isEmpty == false) }
    var display: String { path ?? name ?? globalId ?? "?" }

    init(_ ref: UnityObjectRef) { self.init(globalId: ref.globalId, path: ref.indexedPath ?? ref.path, scene: ref.scene) }
}

struct UnityObjectRef: Codable, Equatable, Hashable, Sendable {
    var name: String
    var scene: String
    var path: String
    var indexedPath: String?
    var globalId: String?
    var active: Bool

    init(name: String, scene: String, path: String, indexedPath: String? = nil, globalId: String? = nil, active: Bool = true) {
        self.name = name; self.scene = scene; self.path = path; self.indexedPath = indexedPath; self.globalId = globalId; self.active = active
    }
    init?(json d: [String: Any]) {
        guard let name = d["name"] as? String else { return nil }
        self.init(name: name, scene: d["scene"] as? String ?? "", path: d["path"] as? String ?? name, indexedPath: d["indexedPath"] as? String,
                  globalId: d["globalId"] as? String, active: d["active"] as? Bool ?? true)
    }
}

struct UnityComponentRef: Codable, Equatable, Hashable, Sendable {
    var type: String
    var fullType: String
    var index: Int
}

// MARK: - Scenes

struct UnitySceneInfo: Codable, Equatable, Sendable {
    var path: String
    var name: String
    var dirty: Bool
    var jarvisDirty: Bool
    var loaded: Bool
    /// Unsaved changes JARVIS did not make: the user's own work. Never saved over silently.
    var userDirty: Bool { dirty && !jarvisDirty }

    init(path: String, name: String, dirty: Bool, jarvisDirty: Bool = false, loaded: Bool = true) {
        self.path = path; self.name = name; self.dirty = dirty; self.jarvisDirty = jarvisDirty; self.loaded = loaded
    }
    init?(json d: [String: Any]) {
        guard let path = d["path"] as? String else { return nil }
        self.init(path: path, name: d["name"] as? String ?? "", dirty: d["dirty"] as? Bool ?? false, jarvisDirty: d["jarvisDirty"] as? Bool ?? false, loaded: d["loaded"] as? Bool ?? true)
    }
}

// MARK: - Status published by the bridge (status.json)

struct UnityTestRunSummary: Codable, Equatable, Sendable {
    var runId: String
    var mode: String
    var state: String                      // running | finished | cancelled | error | abandoned
    var total: Int
    var passed: Int
    var failed: Int
    var skipped: Int
    var inconclusive: Int
    var isFinished: Bool { ["finished", "cancelled", "error", "abandoned"].contains(state) }
}

struct UnityStatusSnapshot: Equatable, Sendable {
    var protocolVersion: Int
    var bridgeVersion: String
    var pid: Int32
    var session: String
    var owned: Bool
    var project: String
    var projectName: String
    var unityVersion: String
    var batchMode: Bool
    var state: String                      // edit | compiling | playing | paused | enteringPlay | importing
    var isCompiling: Bool
    var isPlaying: Bool
    var reloads: Int
    var compileGeneration: Int
    var compileFailed: Bool
    var compileRunning: Bool
    var activeScene: String
    var scenes: [UnitySceneInfo]
    var testRun: UnityTestRunSummary?
    var updatedAt: Date

    var userDirtyScenes: [UnitySceneInfo] { scenes.filter(\.userDirty) }
    var isIdleEdit: Bool { state == "edit" && !isCompiling && !compileRunning && !isPlaying }

    init(protocolVersion: Int = 1, bridgeVersion: String = "0.6.0", pid: Int32 = 0, session: String = "", owned: Bool = false, project: String = "", projectName: String = "",
         unityVersion: String = "", batchMode: Bool = true, state: String = "edit", isCompiling: Bool = false, isPlaying: Bool = false, reloads: Int = 0,
         compileGeneration: Int = 0, compileFailed: Bool = false, compileRunning: Bool = false, activeScene: String = "", scenes: [UnitySceneInfo] = [], testRun: UnityTestRunSummary? = nil, updatedAt: Date = Date()) {
        self.protocolVersion = protocolVersion; self.bridgeVersion = bridgeVersion; self.pid = pid; self.session = session; self.owned = owned; self.project = project
        self.projectName = projectName; self.unityVersion = unityVersion; self.batchMode = batchMode; self.state = state; self.isCompiling = isCompiling; self.isPlaying = isPlaying
        self.reloads = reloads; self.compileGeneration = compileGeneration; self.compileFailed = compileFailed; self.compileRunning = compileRunning; self.activeScene = activeScene; self.scenes = scenes
        self.testRun = testRun; self.updatedAt = updatedAt
    }

    init?(json d: [String: Any]) {
        guard let project = d["project"] as? String, let session = d["session"] as? String else { return nil }
        func int(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        var run: UnityTestRunSummary?
        if let t = d["testRun"] as? [String: Any], let id = t["runId"] as? String {
            func n(_ k: String) -> Int { (t[k] as? NSNumber)?.intValue ?? 0 }
            run = UnityTestRunSummary(runId: id, mode: t["mode"] as? String ?? "", state: t["state"] as? String ?? "", total: n("total"), passed: n("passed"), failed: n("failed"),
                                      skipped: n("skipped"), inconclusive: n("inconclusive"))
        }
        self.init(protocolVersion: int("protocol"), bridgeVersion: d["bridgeVersion"] as? String ?? "", pid: Int32(truncatingIfNeeded: int("pid")), session: session,
                  owned: d["owned"] as? Bool ?? false, project: project, projectName: d["projectName"] as? String ?? "", unityVersion: d["unityVersion"] as? String ?? "",
                  batchMode: d["batchMode"] as? Bool ?? false, state: d["state"] as? String ?? "edit", isCompiling: d["isCompiling"] as? Bool ?? false,
                  isPlaying: d["isPlaying"] as? Bool ?? false, reloads: int("reloads"), compileGeneration: int("compileGeneration"), compileFailed: d["compileFailed"] as? Bool ?? false, compileRunning: d["compileRunning"] as? Bool ?? false,
                  activeScene: d["activeScene"] as? String ?? "", scenes: (d["scenes"] as? [[String: Any]] ?? []).compactMap(UnitySceneInfo.init(json:)), testRun: run,
                  updatedAt: Date(timeIntervalSince1970: Double((d["updatedAt"] as? NSNumber)?.int64Value ?? 0) / 1000))
    }
}

// MARK: - Console

enum UnityLogType: String, Codable, Sendable { case log = "Log", warning = "Warning", error = "Error", exception = "Exception", assert = "Assert"
    var isError: Bool { self == .error || self == .exception || self == .assert }
}

/// One Console line. Text is sanitized when the entry is created: there is no initializer taking raw text.
struct UnityConsoleEntry: Codable, Equatable, Sendable {
    var seq: Int64
    var time: Date
    var type: UnityLogType
    var message: String
    var stackSummary: String

    static let maxMessage = 500, maxStack = 300

    init(seq: Int64, time: Date = Date(), type: UnityLogType, rawMessage: String, rawStack: String = "") {
        self.seq = seq; self.time = time; self.type = type
        self.message = OutputSanitizer.sanitize(String(rawMessage.prefix(Self.maxMessage)))
        // The first stack frames only: they identify the source without carrying a full trace into persistence.
        self.stackSummary = OutputSanitizer.sanitize(String(rawStack.split(separator: "\n").prefix(3).joined(separator: " ⏎ ").prefix(Self.maxStack)))
    }

    init?(json d: [String: Any]) {
        guard let seq = (d["seq"] as? NSNumber)?.int64Value, let t = d["type"] as? String, let type = UnityLogType(rawValue: t) else { return nil }
        self.init(seq: seq, time: Date(timeIntervalSince1970: Double((d["t"] as? NSNumber)?.int64Value ?? 0) / 1000), type: type,
                  rawMessage: d["message"] as? String ?? "", rawStack: d["stack"] as? String ?? "")
    }

    /// Stable key for "is this the same error as before": digits (line numbers, ids, timings) and hex are collapsed.
    var fingerprint: String {
        let collapsed = message.replacingOccurrences(of: #"0x[0-9a-fA-F]+|[0-9]+"#, with: "#", options: .regularExpression)
        return type.rawValue + ":" + String(collapsed.prefix(160))
    }
}

/// What the Console looked like before a task started, so errors the task did not cause are never blamed on it.
struct UnityConsoleBaseline: Codable, Equatable, Sendable {
    var lastSeq: Int64
    var errorFingerprints: [String]
    var capturedAt: Date
}

struct UnityConsoleDelta: Codable, Equatable, Sendable {
    var newErrors: [UnityConsoleEntry]           // errors that did not exist before (by fingerprint)
    var repeatedPreExisting: [UnityConsoleEntry] // an error that was already in the baseline and appeared again
    var warnings: Int
    var logs: Int
    var lastSeq: Int64
    var hasNewErrors: Bool { !newErrors.isEmpty }
}

enum UnityConsoleAnalysis {
    static func baseline(_ entries: [UnityConsoleEntry], lastSeq: Int64) -> UnityConsoleBaseline {
        UnityConsoleBaseline(lastSeq: lastSeq, errorFingerprints: Array(Set(entries.filter { $0.type.isError }.map(\.fingerprint))).sorted().prefix(200).map { $0 }, capturedAt: Date())
    }
    static func delta(_ entries: [UnityConsoleEntry], since baseline: UnityConsoleBaseline) -> UnityConsoleDelta {
        let known = Set(baseline.errorFingerprints)
        let fresh = entries.filter { $0.seq > baseline.lastSeq }
        var new: [UnityConsoleEntry] = [], repeated: [UnityConsoleEntry] = []
        for e in fresh where e.type.isError { if known.contains(e.fingerprint) { repeated.append(e) } else { new.append(e) } }
        return UnityConsoleDelta(newErrors: Array(new.prefix(20)), repeatedPreExisting: Array(repeated.prefix(10)), warnings: fresh.filter { $0.type == .warning }.count,
                                 logs: fresh.filter { $0.type == .log }.count, lastSeq: max(baseline.lastSeq, fresh.map(\.seq).max() ?? baseline.lastSeq))
    }
}

// MARK: - Compilation and tests

struct UnityCompilerError: Codable, Equatable, Sendable {
    var file: String
    var line: Int
    var message: String

    init(file: String, line: Int, rawMessage: String) {
        self.file = OutputSanitizer.sanitize(String(file.prefix(200))); self.line = line; self.message = OutputSanitizer.sanitize(String(rawMessage.prefix(300)))
    }
    var display: String { "\(file):\(line) \(message)" }
}

struct UnityCompilationState: Codable, Equatable, Sendable {
    var isCompiling: Bool
    var generation: Int
    var failed: Bool
    var errors: [UnityCompilerError]
    var warnings: Int
    var reloads: Int
}

struct UnityTestCase: Codable, Equatable, Sendable {
    var name: String
    var status: String                      // Passed | Failed | Skipped | Inconclusive
    var message: String                     // sanitized
}

struct UnityTestResult: Codable, Equatable, Sendable {
    var mode: String                        // editMode | playMode
    var requestedScope: String              // human description of what was asked
    var actualTotal: Int
    var passed: Int
    var failed: Int
    var skipped: Int
    var inconclusive: Int
    var durationSeconds: Double
    var cases: [UnityTestCase]              // bounded
    var state: String                       // finished | cancelled | error | abandoned | timedOut
    var succeeded: Bool { state == "finished" && failed == 0 && actualTotal > 0 && inconclusive == 0 }
    var summary: String { "\(mode == "playMode" ? "PlayMode" : "EditMode") \(passed)/\(actualTotal) passed" + (failed > 0 ? ", \(failed) failed" : "") + (skipped > 0 ? ", \(skipped) skipped" : "") }
}

// MARK: - Dynamic values (serialized properties)

/// A JSON-representable property value (the only kinds a serialized property edit may carry).
enum UnityValue: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    case bool(Bool), number(Double), string(String), array([UnityValue]), null

    var any: Any {
        switch self {
        case .bool(let b): b; case .number(let n): n; case .string(let s): s; case .array(let a): a.map(\.any); case .null: NSNull()
        }
    }
    init?(any raw: Any?) {
        guard let raw, !(raw is NSNull) else { self = .null; return }
        if let n = raw as? NSNumber {
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        } else if let s = raw as? String { self = .string(s) }
        else if let a = raw as? [Any] {
            var items: [UnityValue] = []
            for x in a { guard let v = UnityValue(any: x) else { return nil }; items.append(v) }
            self = .array(items)
        } else { return nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([UnityValue].self) { self = .array(a) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported value") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .bool(let b): try c.encode(b); case .number(let n): try c.encode(n); case .string(let s): try c.encode(s); case .array(let a): try c.encode(a); case .null: try c.encodeNil() }
    }
    var description: String {
        switch self {
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): "\"\(s)\""
        case .array(let a): "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .null: "null"
        }
    }
    /// Numbers compare with a small tolerance (floats round-trip through Unity).
    func matches(_ other: UnityValue) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)): abs(a - b) < 1e-5
        case (.array(let a), .array(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.matches($1) }
        default: self == other
        }
    }
}
