import Darwin
import Foundation

/// Which Unity editors are running and which project each one has open — so a command is NEVER sent to "the first Unity process".
/// Read-only libproc/sysctl introspection; nothing is started, signalled or modified here.
enum UnityProcessScanner {
    struct Editor: Equatable, Sendable {
        var pid: pid_t
        var executable: String
        var projectPath: String?          // canonical absolute path, when the editor was started with -projectPath
    }

    static func isUnityEditorExecutable(_ path: String) -> Bool { path.hasSuffix("/Unity.app/Contents/MacOS/Unity") }

    /// All running editors (bounded scan of the process table).
    static func editors() -> [Editor] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        var out: [Editor] = []
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard len > 0 else { continue }
            let exe = String(cString: pathBuf)
            guard isUnityEditorExecutable(exe) else { continue }
            let args = arguments(of: pid)
            out.append(Editor(pid: pid, executable: exe, projectPath: args.flatMap(projectPath(from:)).map(canonical)))
        }
        return out
    }

    /// The editor that has `projectPath` open, if any (compared on canonical paths).
    static func editor(for projectPath: String, among editors: [Editor]) -> Editor? {
        let target = canonical(projectPath)
        return editors.first { $0.projectPath == target }
    }

    static func canonical(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    // MARK: argv

    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 2_000_000 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Data(buf.prefix(size)))?.args
    }

    /// Pure parser of the KERN_PROCARGS2 layout: argc (Int32), executable path, NUL padding, argc argument strings, then the environment (ignored).
    static func parseProcArgs(_ data: Data) -> (executable: String, args: [String])? {
        guard data.count > 8 else { return nil }
        let argc = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 512 else { return nil }
        var i = 4
        func readString() -> String {
            let start = i
            while i < data.count && data[i] != 0 { i += 1 }
            let s = String(decoding: data[start..<i], as: UTF8.self)
            return s
        }
        let exe = readString()
        while i < data.count && data[i] == 0 { i += 1 }
        var args: [String] = []
        for _ in 0..<Int(argc) {
            guard i < data.count else { break }
            args.append(readString()); i += 1
        }
        return (exe, args)
    }

    static func projectPath(from args: [String]) -> String? {
        for (i, a) in args.enumerated() where a.lowercased() == "-projectpath" && i + 1 < args.count { return args[i + 1] }
        return nil
    }
}
