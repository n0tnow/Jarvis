import Foundation

// MARK: - Staging a candidate for a sandboxed benchmark (V0.14, DEC-228)
//
// For an open-source candidate whose source JARVIS has inspected: download the repository snapshot (https, bounded, hashed — the V0.9 downloader), check the archive listing, extract it
// into a JARVIS-owned staging folder and — when it is a Rust program — build it INSIDE the Seatbelt profile: dependencies are fetched in one step (network allowed, writes confined to the
// staging folder, no build script runs), then built OFFLINE in a second step (network denied), so build scripts and procedural macros run without network and without your home directory.
// Nothing is installed anywhere else and nothing is registered: the result is a binary in the staging folder that the benchmark launches under the same sandbox.

struct MCPStageStep: Equatable, Sendable { var name: String; var ok: Bool; var seconds: Double; var detail: String }

struct MCPStage: Sendable {
    var directory: URL
    var source: URL
    var steps: [MCPStageStep] = []
    var binary: String?
    var sourceBytes: Int
    var archiveSHA256: String
    var seatbeltUsed: Bool
}

enum MCPStaging {
    /// Downloads and extracts the snapshot of the candidate's repository into a new staging folder under `root`. Returns nil on any refusal (listing unsafe, too large, not https…).
    static func downloadSource(of r: MCPDiscoveryRecord, discovery: MCPDiscovery, root: URL) async -> MCPStage? {
        guard let snapshot = MCPDiscovery.sourceSnapshotURL(of: r) else { return nil }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("sbx-" + UUID().uuidString.prefix(8), isDirectory: true)
        for sub in ["home", "tmp", "cargo-home", "target", "download"] { try? fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        var limits = DownloadLimits(); limits.maxBytes = 25_000_000; limits.sessionBudget = 25_000_000; limits.overallTimeout = 180
        let req = DownloadRequest(id: UUID(), url: snapshot.url, expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: "\(snapshot.name).zip")
        guard case .success(let result) = await Downloader(client: discovery.client).download(req, into: dir.appendingPathComponent("download"), limits: limits) else { _ = MCPSandbox.remove(dir, under: root); return nil }
        guard let listing = try? ArchiveInspector.listZIP(result.fileURL, limits: ArchiveLimits()), listing.count <= 8000, !listing.contains(where: { ArchiveInspector.unsafeReason($0.name) != nil }) else { _ = MCPSandbox.remove(dir, under: root); return nil }
        let out = dir.appendingPathComponent("src", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        guard let ex = await ManagedProcess.runOnce(executable: "/usr/bin/ditto", arguments: ["-x", "-k", result.fileURL.path, out.path], environment: ["PATH": "/usr/bin:/bin"], timeout: 90), ex.exitCode == 0,
              let top = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { _ = MCPSandbox.remove(dir, under: root); return nil }
        return MCPStage(directory: dir, source: top, sourceBytes: result.size, archiveSHA256: result.sha256, seatbeltUsed: MCPSandbox.seatbeltPresent)
    }

    /// Runs one command inside the stage's Seatbelt profile (no shell). `readableRoots` are the toolchain folders the command needs to read.
    static func run(_ stage: MCPStage, executable: String, arguments: [String], allowNetwork: Bool, readableRoots: [String], environment: [String: String] = [:], workingDirectory: URL? = nil, timeout: TimeInterval) async -> ManagedProcess.RunResult? {
        var env: [String: String] = ["PATH": ([ (executable as NSString).deletingLastPathComponent ] + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"), "HOME": stage.directory.appendingPathComponent("home").path,
                                     "TMPDIR": stage.directory.appendingPathComponent("tmp").path + "/", "LANG": "en_US.UTF-8", "JARVIS_MCP_SANDBOX": "1"]
        for (k, v) in environment { env[k] = v }
        let cwd = (workingDirectory ?? stage.source).path
        guard MCPSandbox.seatbeltPresent else { return nil }                                  // a build without a kernel boundary is not attempted
        let profile = MCPSandbox.profile(directory: stage.directory, allowNetwork: allowNetwork, readableRoots: readableRoots)
        return await ManagedProcess.runOnce(executable: MCPSandbox.sandboxExec, arguments: ["-p", profile, executable] + arguments, environment: env, workingDirectory: cwd, timeout: timeout, maxOutput: 48 * 1024)
    }

    /// Locates the installed Rust toolchain (`~/.rustup/toolchains/<name>/bin`) without running rustup. nil = no Rust toolchain.
    static func rustToolchainBin() -> String? {
        let root = MCPSandbox.realHome() + "/.rustup/toolchains"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for n in names.sorted() where FileManager.default.isExecutableFile(atPath: "\(root)/\(n)/bin/cargo") { return "\(root)/\(n)/bin" }
        return nil
    }

    /// fetch (network, no code runs) → build OFFLINE (network denied). Returns the stage with its steps and, on success, the binary.
    static func buildRust(_ stage: MCPStage, package: String, binary: String, toolchainBin: String) async -> MCPStage {
        var s = stage
        let cargo = toolchainBin + "/cargo"
        let toolchainRoot = (toolchainBin as NSString).deletingLastPathComponent
        let env = ["CARGO_HOME": stage.directory.appendingPathComponent("cargo-home").path, "CARGO_TARGET_DIR": stage.directory.appendingPathComponent("target").path, "RUSTUP_HOME": MCPSandbox.realHome() + "/.rustup", "CARGO_TERM_COLOR": "never", "CARGO_NET_RETRY": "3"]
        let t0 = Date()
        let f = await run(stage, executable: cargo, arguments: ["fetch", "--locked"], allowNetwork: true, readableRoots: [toolchainRoot], environment: env, timeout: 600)
        s.steps.append(MCPStageStep(name: "cargo fetch --locked (network allowed, nothing built or run)", ok: f?.exitCode == 0, seconds: Date().timeIntervalSince(t0), detail: String(((f?.errorOutput ?? "") + (f?.output ?? "")).suffix(240))))
        guard f?.exitCode == 0 else { return s }
        let t1 = Date()
        let b = await run(stage, executable: cargo, arguments: ["build", "--release", "--locked", "--offline", "-p", package, "--bin", binary], allowNetwork: false, readableRoots: [toolchainRoot], environment: env, timeout: 1500)
        let path = stage.directory.appendingPathComponent("target/release/\(binary)").path
        let built = b?.exitCode == 0 && FileManager.default.isExecutableFile(atPath: path)
        s.steps.append(MCPStageStep(name: "cargo build --release --locked --offline (network DENIED, writes confined to the stage)", ok: built, seconds: Date().timeIntervalSince(t1), detail: String(((b?.errorOutput ?? "") + (b?.output ?? "")).suffix(240))))
        if built { s.binary = path }
        return s
    }

    static func remove(_ stage: MCPStage, under root: URL) { _ = MCPSandbox.remove(stage.directory, under: root) }
}
