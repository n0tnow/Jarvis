import Foundation

// MARK: - MCP / capability registry (V0.14, DEC-224…)
//
// An MCP server provides CAPABILITIES to JARVIS; it is not an orchestrator and never an authority. Everything an MCP says (tool descriptions, schemas, results) is
// untrusted data. JARVIS reaches a server only through typed WRAPPERS the user approved, inside a registered permission envelope.

/// What kind of thing a capability is. The UI may group them; the types stay distinct.
enum CapabilityType: String, Codable, Sendable, CaseIterable {
    case mcpServer, nativeCapability, plugin, localTool, learnedWorkflow, learnedRule
    var label: String {
        switch self {
        case .mcpServer: "MCP server"; case .nativeCapability: "Native capability"; case .plugin: "Plugin / integration"; case .localTool: "Local tool"
        case .learnedWorkflow: "Learned workflow (Skill)"; case .learnedRule: "Learned rule"
        }
    }
}

enum MCPStatus: String, Codable, Sendable, CaseIterable {
    case discovered, inspected, sandboxed, benchmarked, recommended, approved, installed, active, degraded, disabled, removed, rejected, blocked
    var label: String { rawValue.uppercased() }
    var isLive: Bool { self == .active || self == .degraded }
    /// A discovered server never becomes ACTIVE by itself: the only way in is through INSTALLED after a HUD approval.
    var allowedNext: Set<MCPStatus> {
        switch self {
        case .discovered: [.inspected, .rejected, .blocked]
        case .inspected: [.sandboxed, .recommended, .rejected, .blocked]
        case .sandboxed: [.benchmarked, .inspected, .rejected, .blocked]
        case .benchmarked: [.recommended, .rejected, .blocked, .sandboxed]
        case .recommended: [.approved, .rejected, .blocked]
        case .approved: [.installed, .rejected]
        case .installed: [.active, .disabled, .removed, .blocked]
        case .active: [.degraded, .disabled, .removed, .inspected]
        case .degraded: [.active, .disabled, .removed, .inspected]
        case .disabled: [.active, .removed, .inspected]
        case .removed, .rejected: []
        case .blocked: [.inspected, .removed, .rejected]
        }
    }
    func canMove(to next: MCPStatus) -> Bool { allowedNext.contains(next) }
}

enum MCPHealth: String, Codable, Sendable { case available, starting, healthy, degraded, failed, disabled
    var label: String { rawValue }
}

/// The MAXIMUM a server may do, registered at approval. JARVIS cannot use a tool outside it.
enum MCPEnvelope: String, Codable, Sendable, CaseIterable, Comparable {
    case read, projectWrite, network, process, account, credential, destructive
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    var label: String {
        switch self {
        case .read: "Read"; case .projectWrite: "Write to the project"; case .network: "Network"; case .process: "Run processes"
        case .account: "Account"; case .credential: "Credentials"; case .destructive: "Destructive"
        }
    }
    /// Envelope parts that can never be part of an automatic capability: they need the user in the loop for every use.
    var isNeverAutomatic: Bool { self == .account || self == .credential || self == .destructive }
}

enum MCPToolRisk: String, Codable, Sendable, Comparable {
    case read, write, network, destructive, broad
    private var rank: Int { switch self { case .read: 0; case .write: 1; case .network: 2; case .destructive: 3; case .broad: 4 } }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    var envelope: MCPEnvelope {
        switch self { case .read: .read; case .write: .projectWrite; case .network: .network; case .destructive: .destructive; case .broad: .process }
    }
    var label: String { switch self { case .read: "read"; case .write: "write"; case .network: "network"; case .destructive: "destructive"; case .broad: "BROAD (arbitrary code / shell)" } }
}

struct MCPToolSchema: Codable, Equatable, Sendable {
    var name: String
    /// Sanitised and bounded (≤ 240 chars): tool descriptions are untrusted metadata and are never placed in a privileged prompt.
    var description: String
    /// The declared parameters (name → JSON type), bounded. The raw schema is not kept.
    var parameters: [String: String]
    var risk: MCPToolRisk
    var injectionNotes: Int = 0
}

/// A typed JARVIS capability backed by ONE server tool. This is the only thing agents ever see — never the raw tool.
struct MCPWrapper: Codable, Equatable, Sendable, Identifiable {
    var capability: String                   // e.g. "inspectFixture"
    var tool: String                         // the server tool it maps to
    var summary: String
    /// parameter name → JSON type ("string" | "number" | "boolean"), all required unless listed in `optionalParameters`
    var parameters: [String: String]
    var optionalParameters: [String] = []
    var maxStringLength = 200
    var envelope: MCPEnvelope
    var id: String { capability }
}

struct MCPLaunch: Codable, Equatable, Sendable {
    var executable: String
    var arguments: [String]
    /// Extra environment NAMES a server needs (never values from the user's environment; values come from a registered, non-secret table).
    var environment: [String: String] = [:]
    var persistent = false
    var idleSeconds: Double = 60
    /// Small TEXT files written into the sandbox work directory before the server starts (a benchmark score, a fixture). `{{WORK}}` inside `arguments` stands for that directory.
    var seedFiles: [String: String] = [:]
}

struct MCPSecurityFinding: Codable, Equatable, Sendable {
    enum Severity: String, Codable, Sendable { case info, warning, high }
    var severity: Severity
    var category: String
    var detail: String
    var location: String?
}

/// Everything JARVIS learned about a candidate before it is installed. UNKNOWN stays UNKNOWN (nil / "unknown").
struct MCPDiscoveryRecord: Codable, Equatable, Sendable {
    var name: String
    var type: CapabilityType = .mcpServer
    var domain: String
    var sourceURL: String
    var repository: String?
    var publisher: String?
    var license: String?
    var licenseKnown: Bool { !(license ?? "").isEmpty && license != "NOASSERTION" }
    var version: String?
    var lastRelease: Date?
    var lastPush: Date?
    var stars: Int?
    var installMethod: String?                // npm · pip/uv · binary · docker · source
    var runtime: String?
    var networkRequirement: String            // none · required · unknown
    var credentialRequirement: String         // none · api key · oauth · account · unknown
    var filesystemRequirement: String
    var processRequirement: String
    var declaredTools: [String]
    var declaredResources: [String]
    var declaredPrompts: [String]
    var knownRisks: [String]
    var price: String                         // free · paid · freemium · unknown (unknown is never free)
    var apiRequirements: String
    var macOS: String                         // yes · no · unknown
    var appleSilicon: String
    var overlap: [String]
    var expectedBenefit: String
    var evidenceFetchedAt: Date
    var sourceKind: String                    // official registry · vendor · repository · community lead
    var findings: [MCPSecurityFinding] = []

    /// Free to USE as verified: an open-source licence on the code. “free code; a service behind it may be paid”, “unknown” and anything else are NOT free.
    var isVerifiablyFree: Bool { price == "free" || price.hasPrefix("free (") }

    func freshness(now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(evidenceFetchedAt) / 86_400)
        return days <= 0 ? "today" : "\(days) day(s) ago"
    }
}

struct MCPBenchmarkResult: Codable, Equatable, Sendable {
    struct Case: Codable, Equatable, Sendable { var name: String; var passed: Bool; var detail: String; var latencyMS: Double }
    var at: Date
    var cases: [Case]
    var coldStartMS: Double
    var warmCallMS: Double
    var peakRSSMB: Double?
    var deterministic: Bool
    var permissionsObserved: [String]
    var networkObserved: Bool
    var cleanupOK: Bool
    var findings: [MCPSecurityFinding]
    var boundary: String
    var passedCount: Int { cases.filter(\.passed).count }
    var successRate: Double { cases.isEmpty ? 0 : Double(passedCount) / Double(cases.count) }
}

struct MCPServerRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String                           // slug, e.g. "jarvis-fixture"
    var name: String
    var type: CapabilityType = .mcpServer
    var domain: String
    var status: MCPStatus
    var version: String
    var executableHash: String?              // hash of the launched artifact; a change means REVALIDATION REQUIRED
    var launch: MCPLaunch
    var tools: [MCPToolSchema]
    var wrappers: [MCPWrapper]
    var envelope: Set<MCPEnvelope>
    var allowedProjects: [String]            // empty = no project access; "*" never allowed
    var network: String                      // none · required · unknown
    var credentialRequirement: String
    var health: MCPHealth
    var benchmark: MCPBenchmarkResult?
    var discovery: MCPDiscoveryRecord?
    var provenance: String                   // where it came from / how it was installed
    var installDirectory: String?            // JARVIS-owned; nothing outside it is ever deleted
    var ownedFiles: [String] = []            // exact JARVIS-owned relative paths inside installDirectory
    var approvalID: String?
    var revalidationRequired = false
    var revalidationReason: String?
    /// The version an UPDATE request asks for (set when the request is made, bound into the approval hash, cleared when it executes).
    var pendingVersion: String?
    var registeredAt = Date()
    var statusChangedAt = Date()
    var lastUsedAt: Date?
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var successCount = 0
    var failureCount = 0
    var consecutiveFailures = 0
    var averageLatencyMS: Double?
    var isFixture = false
    var dangerous: Bool { tools.contains { $0.risk == .broad } }
    var envelopeLabels: [String] { envelope.sorted().map(\.label) }
}

struct MCPActivityRecord: Equatable, Sendable, Identifiable {
    var id = UUID()
    var serverID: String
    var capability: String
    var taskID: UUID?
    var role: String?
    var projectKey: String?
    var startedAt: Date
    var endedAt: Date?
    var status: String                       // ok · failed · refused
    var latencyMS: Double?
    var envelope: String?
    var error: String?
    var validated: Bool
}

// MARK: - Tool risk classification (static, from names and declared parameters — never from the server's own claims of safety)

enum MCPToolClassifier {
    private static func has(_ text: String, _ words: [String]) -> Bool {
        let t = text.lowercased()
        return words.contains { t.contains($0) }
    }
    /// A tool that runs arbitrary code or a shell is BROAD and never auto-exposed to agents.
    static func risk(name: String, description: String, parameters: [String: String]) -> MCPToolRisk {
        let n = name.lowercased(), params = parameters.keys.joined(separator: " ").lowercased()
        let broadNames = ["exec", "shell", "bash", "terminal", "run_command", "runcommand", "eval", "run_python", "execute_python", "python", "run_script", "script", "subprocess", "system", "cmd"]
        if broadNames.contains(where: { n.contains($0) }) { return .broad }
        if has(params, ["command", "shell", "code", "script", "expression"]) && has(n, ["run", "execute", "exec", "call", "invoke"]) { return .broad }
        if has(n, ["delete", "remove", "drop", "wipe", "erase", "destroy", "uninstall", "purge", "truncate", "rm_"]) { return .destructive }
        if has(n, ["fetch", "http", "download", "upload", "request", "browse", "web_", "search_web", "post_", "send", "publish"]) || has(params, ["url", "uri", "endpoint"]) { return .network }
        if has(n, ["create", "write", "save", "set", "update", "add", "edit", "modify", "export", "import", "generate", "move", "rename", "apply", "render", "make", "build", "insert", "put"]) { return .write }
        return .read
    }
    /// The envelope a server's declared tools need at minimum.
    static func envelope(for tools: [MCPToolSchema]) -> Set<MCPEnvelope> { Set(tools.map { $0.risk.envelope }).union([.read]) }
}
