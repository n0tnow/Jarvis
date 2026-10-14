import Foundation

// MARK: - The MCP sandbox (V0.14, DEC-225) — and an HONEST statement of what it is
//
// macOS offers no container for an ordinary process. JARVIS combines what it can actually enforce:
//   • a sanitised environment (nothing inherited: no HOME, no SSH agent, no API keys, no tokens) and a private working directory;
//   • a Seatbelt profile through `sandbox-exec` (deprecated by Apple, but present and enforced by the kernel): no network (unless the registered envelope allows it), file writes
//     only inside the sandbox directory, reads of the user's home directory denied except the sandbox and the runtime's own folder, and a deny-list of the Keychain / security
//     daemons by Mach service name;
//   • its own process group, a wall-clock timeout, bounded output, resident-memory sampling with a kill limit, and removal of the directory afterwards.
// It is NOT: a separate user account, a VM, a CPU/memory cgroup, protection from reading world-readable system files, or an exhaustive Mach-service filter. `boundary` says so
// every time — JARVIS never claims isolation it does not have.

struct MCPSandboxBoundary: Codable, Equatable, Sendable {
    var method: String
    var kernelEnforced: [String]
    var jarvisEnforced: [String]
    var notEnforced: [String]
    var seatbeltVerified: Bool
    var summary: String {
        (kernelEnforced.isEmpty ? "No kernel-enforced boundary was available." : "Kernel-enforced (Seatbelt): " + kernelEnforced.joined(separator: "; ") + ".")
        + " Enforced by JARVIS: " + jarvisEnforced.joined(separator: "; ") + ". NOT enforced: " + notEnforced.joined(separator: "; ") + "."
    }
}

struct MCPSandboxLaunch: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String
    var directory: URL
    var boundary: MCPSandboxBoundary
}

enum MCPSandbox {
    static let sandboxExec = "/usr/bin/sandbox-exec"
    static var seatbeltPresent: Bool { FileManager.default.isExecutableFile(atPath: sandboxExec) }

    /// Nothing is inherited. The sandbox directory is the whole world the server may write to.
    static func environment(directory: URL, extra: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory.appendingPathComponent("home").path, "TMPDIR": directory.appendingPathComponent("tmp").path + "/",
                                     "LANG": "en_US.UTF-8", "JARVIS_MCP_SANDBOX": "1"]
        for (k, v) in extra where isSafeEnvironmentName(k) && !looksSecret(k, v) { env[k] = v }
        return env
    }
    static func isSafeEnvironmentName(_ n: String) -> Bool { n.range(of: "^[A-Z][A-Z0-9_]{1,40}$", options: .regularExpression) != nil && !["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SSH_AUTH_SOCK"].contains(n) }
    static func looksSecret(_ name: String, _ value: String) -> Bool {
        let n = name.lowercased()
        return ["key", "token", "secret", "password", "passwd", "credential", "auth", "cookie", "session"].contains { n.contains($0) } || OutputSanitizer.containsSecret(value)
    }

    static func realHome() -> String { getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory() }

    /// The Seatbelt profile text. Paths are escaped; nothing else is interpolated.
    static func profile(directory: URL, allowNetwork: Bool, readableRoots: [String]) -> String {
        func q(_ p: String) -> String { "\"" + p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let home = realHome()
        let dir = ProcessInfoPath.canonical(directory.path)
        var lines = ["(version 1)", "(allow default)"]
        if !allowNetwork { lines.append("(deny network*)") }
        // Writes: only the sandbox directory (and the few device nodes a process needs to run).
        lines.append("(deny file-write*)")
        lines.append("(allow file-write* (subpath \(q(dir))) (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (literal \"/dev/tty\") (regex #\"^/dev/fd/\"))")
        // Reads: the user's home is closed except the sandbox, the runtime folders given, and metadata (so paths can be resolved).
        lines.append("(deny file-read* (subpath \(q(ProcessInfoPath.canonical(home)))))")
        lines.append("(allow file-read-metadata)")
        lines.append("(allow file-read* (subpath \(q(dir)))\(readableRoots.map { " (subpath \(q(ProcessInfoPath.canonical($0))))" }.joined()))")
        // Keychain / security daemons by name (best effort; not an exhaustive Mach filter).
        for svc in ["com.apple.SecurityServer", "com.apple.securityd", "com.apple.secd", "com.apple.security.agent", "com.apple.security.authhost", "com.apple.ctkd.token-client", "com.apple.pasteboard.1"] {
            lines.append("(deny mach-lookup (global-name \(q(svc))))")
        }
        return lines.joined(separator: "\n")
    }

    static func boundary(seatbelt: Bool, allowNetwork: Bool) -> MCPSandboxBoundary {
        var kernel: [String] = []
        if seatbelt {
            kernel = ["file writes only inside the sandbox directory", "reads of your home directory denied except the sandbox and the runtime's folder", "Keychain and security daemons denied by service name (best effort)"]
            kernel.insert(allowNetwork ? "network ALLOWED by the registered envelope" : "network denied", at: 0)
        }
        return MCPSandboxBoundary(method: seatbelt ? "sandbox-exec (Seatbelt) + sanitised environment" : "sanitised environment only (sandbox-exec not available)",
                                  kernelEnforced: kernel,
                                  jarvisEnforced: ["environment contains no inherited variables (no HOME, SSH_AUTH_SOCK, API keys or tokens)", "private working directory removed afterwards", "own process tree killed on stop or timeout", "wall-clock timeout and bounded output"],
                                  notEnforced: ["CPU and memory are sampled and killed on excess, not capped by the kernel", "world-readable system files outside your home remain readable", "the Mach-service deny-list is not exhaustive", "same macOS user account (not a VM or a separate account)"],
                                  seatbeltVerified: seatbelt)
    }

    /// Creates the private directory and the launch description. `readableRoots` should contain the folder of the executable and its runtime (e.g. a Node install).
    static func prepare(root: URL, executable: String, arguments rawArguments: [String], allowNetwork: Bool, readableRoots: [String] = [], extraEnvironment: [String: String] = [:], useSeatbelt: Bool = true, seedFiles: [String: String] = [:]) throws -> MCPSandboxLaunch {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("sbx-" + UUID().uuidString.prefix(8), isDirectory: true)
        for sub in ["home", "tmp", "work"] { try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let work = ProcessInfoPath.canonical(dir.appendingPathComponent("work").path)
        let arguments = rawArguments.map { $0.replacingOccurrences(of: "{{WORK}}", with: work) }
        for (name, text) in seedFiles where !name.contains("..") && !name.hasPrefix("/") && text.utf8.count <= 64 * 1024 {
            let url = dir.appendingPathComponent("work").appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let seatbelt = useSeatbelt && seatbeltPresent
        let env = environment(directory: dir, extra: extraEnvironment)
        let roots = readableRoots + [(executable as NSString).deletingLastPathComponent]
        var exe = executable, args = arguments
        if seatbelt {
            exe = sandboxExec
            args = ["-p", profile(directory: dir, allowNetwork: allowNetwork, readableRoots: roots), executable] + arguments
        }
        return MCPSandboxLaunch(executable: exe, arguments: args, environment: env, workingDirectory: dir.appendingPathComponent("work").path, directory: dir, boundary: boundary(seatbelt: seatbelt, allowNetwork: allowNetwork))
    }

    /// Removes a sandbox directory — only a real directory directly inside the given root whose name starts with `sbx-`.
    @discardableResult
    static func remove(_ dir: URL, under root: URL) -> Bool {
        let d = ProcessInfoPath.canonical(dir.path), r = ProcessInfoPath.canonical(root.path)
        guard d.hasPrefix(r + "/"), dir.lastPathComponent.hasPrefix("sbx-"), (d as NSString).deletingLastPathComponent == r else { return false }
        try? FileManager.default.removeItem(atPath: dir.path)
        return !FileManager.default.fileExists(atPath: dir.path)
    }
}

enum ProcessInfoPath {
    static func canonical(_ p: String) -> String { (realpath(p, nil).map { String(cString: $0) }) ?? p }
}
