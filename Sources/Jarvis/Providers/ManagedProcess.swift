import Darwin
import Foundation

/// Descendant discovery via libproc (public API) so cancellation can kill the whole tree and leave no orphans.
enum ProcessTree {
    /// NOTE: with a buffer, `proc_listchildpids` returns the NUMBER OF PIDS (verified empirically), not a byte count.
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 1024)
        let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(min(count, Int32(buffer.count)))).filter { $0 > 0 }
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = [], queue = children(of: pid)
        while let next = queue.popLast() {
            if result.contains(next) { continue }
            result.append(next)
            queue.append(contentsOf: children(of: next))
        }
        return result
    }

    /// Resident memory of a process in bytes (nil if gone). For reporting a provider's memory impact — never for control flow.
    static func residentBytes(of pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    /// Total CPU time (user + system) of a process in seconds — read via libproc, no process is spawned. Reporting only.
    static func cpuSeconds(of pid: pid_t) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Double(info.pti_total_user + info.pti_total_system) / 1_000_000_000
    }

    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Current parent pid (nil if the process is gone). Used to make sure a snapshotted pid still belongs to the family
    /// we are cleaning up and was not recycled by an unrelated process.
    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}

/// Every live provider process, so application termination can clean up.
final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var live: [ObjectIdentifier: ManagedProcess] = [:]

    func add(_ p: ManagedProcess) { lock.lock(); live[ObjectIdentifier(p)] = p; lock.unlock() }
    func remove(_ p: ManagedProcess) { lock.lock(); live[ObjectIdentifier(p)] = nil; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return live.count }
    /// Executable names (no arguments, no paths) of the live processes — diagnostics for the live tests.
    var names: [String] { lock.lock(); defer { lock.unlock() }; return live.values.map { $0.executableName } }

    /// Synchronous and final (SIGKILL tree): used when the app is quitting.
    func killAll() {
        lock.lock(); let all = Array(live.values); lock.unlock()
        for p in all { p.killTreeNow() }
    }
}

/// One child process with: stdin prompt, byte-safe stdout line stream, bounded stderr, exit status, and REAL cancellation.
/// Never uses a shell; the caller passes an executable URL + argument array.
final class ManagedProcess: @unchecked Sendable {
    static let stderrLimit = 16 * 1024

    private let process = Process()
    private let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "jarvis.managedprocess.stdin")
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var stderrBuffer = Data()
    private var outSplitter = LineSplitter()
    private var continuation: AsyncStream<Data>.Continuation?
    private var started = false
    private(set) var wasCancelled = false

    /// `mergeStderr`: build/test tools print their diagnostics (compiler errors, unittest summaries) on stderr; merging keeps one
    /// interleaved line stream so nothing is lost and everything passes through the same sanitization boundary. Providers keep a separate stderr.
    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, mergeStderr: Bool = false) {
        signal(SIGPIPE, SIG_IGN)   // writing a prompt to a process that already exited must not kill JARVIS
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = mergeStderr ? outPipe : errPipe
    }

    var executableName: String { process.executableURL?.lastPathComponent ?? "?" }
    var processIdentifier: pid_t { process.processIdentifier }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return started && exitCode == nil }
    /// Last bytes of stderr. DIAGNOSTICS ONLY — never shown as an answer.
    var stderrTail: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stderrBuffer, as: UTF8.self) }

    /// Launches and returns complete stdout lines (raw bytes; decode per line).
    /// `keepStdinOpen` is for long-lived workers (the local model): the initial data is written, stdin stays open and
    /// `send(_:)` / `closeStdin()` talk to the process afterwards.
    func start(stdin: Data?, keepStdinOpen: Bool = false) throws -> AsyncStream<Data> {
        let stream = AsyncStream<Data> { cont in
            lock.lock(); continuation = cont; lock.unlock()
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { handle.readabilityHandler = nil; return }
            let data = handle.availableData
            self.lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
                let rest = self.outSplitter.flush()
                let cont = self.continuation; self.continuation = nil
                self.lock.unlock()
                if let rest { cont?.yield(rest) }
                cont?.finish()
            } else {
                let lines = self.outSplitter.feed(data)
                let cont = self.continuation
                self.lock.unlock()
                for l in lines { cont?.yield(l) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { handle.readabilityHandler = nil; return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock()
            self.stderrBuffer.append(data)
            if self.stderrBuffer.count > Self.stderrLimit { self.stderrBuffer = Data(self.stderrBuffer.suffix(Self.stderrLimit)) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            self.exitCode = proc.terminationStatus
            let waiters = self.exitWaiters; self.exitWaiters = []
            self.lock.unlock()
            ProcessRegistry.shared.remove(self)
            for w in waiters { w.resume(returning: proc.terminationStatus) }
            // A grandchild that inherited stdout could keep the pipe open forever: don't hang the consumer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.forceFinishOutput() }
        }

        // Register only AFTER a successful launch: a concurrent killAll() must never read the pid of an unlaunched Process.
        try process.run()
        lock.lock(); started = true; let alreadyExited = exitCode != nil; lock.unlock()
        if !alreadyExited { ProcessRegistry.shared.add(self) }
        let input = inPipe.fileHandleForWriting
        writeQueue.async {
            if let stdin, !stdin.isEmpty { try? input.write(contentsOf: stdin) }
            if !keepStdinOpen { try? input.close() }
        }
        return stream
    }

    /// Writes to a process started with `keepStdinOpen` (serialised; a dead process just drops the bytes).
    func send(_ data: Data) {
        let input = inPipe.fileHandleForWriting
        writeQueue.async { try? input.write(contentsOf: data) }
    }

    func closeStdin() {
        let input = inPipe.fileHandleForWriting
        writeQueue.async { try? input.close() }
    }

    private func forceFinishOutput() {
        lock.lock(); let rest = outSplitter.flush(); let cont = continuation; continuation = nil; lock.unlock()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil     // a grandchild holding stderr must not keep this fd/handler alive
        if let rest { cont?.yield(rest) }
        cont?.finish()
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let code = exitCode { lock.unlock(); cont.resume(returning: code) }
            else { exitWaiters.append(cont); lock.unlock() }
        }
    }

    private func waitUntilExited(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !isRunning
    }

    /// Marks the process cancelled if it is still running (sync helper: locks must not be taken in async code).
    private func beginCancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let running = started && exitCode == nil
        if running { wasCancelled = true }
        return running
    }

    /// REAL cancellation: SIGINT (graceful turn end) → SIGTERM → SIGKILL, plus every descendant seen at any point.
    /// Resolves only once the process is gone and no snapshotted descendant survives. Idempotent.
    func cancel() async {
        guard beginCancel() else { return }
        let pid = processIdentifier
        var family = ProcessTree.descendants(of: pid)          // snapshot BEFORE signalling (children re-parent once the parent dies)
        kill(pid, SIGINT)
        if await waitUntilExited(timeout: 1.5) { reap(family, parent: pid); return }
        family += ProcessTree.descendants(of: pid)
        kill(pid, SIGTERM)
        if await waitUntilExited(timeout: 1.0) { reap(family, parent: pid); return }
        family += ProcessTree.descendants(of: pid)
        for k in family { kill(k, SIGKILL) }
        kill(pid, SIGKILL)
        _ = await waitUntilExited(timeout: 1.0)
        reap(family, parent: pid)
    }

    /// Any helper that outlived the parent is killed (SIGKILL), so cancelling can never leave orphans behind.
    /// PID-reuse safe: a snapshotted pid is only killed while its parent is still the original process, one of its
    /// family, or launchd (re-parented orphan) — never an unrelated process that happened to get the same number.
    private func reap(_ pids: [pid_t], parent original: pid_t) {
        let family = Set(pids)
        for k in family where ProcessTree.isAlive(k) {
            guard let pp = ProcessTree.parent(of: k), pp == 1 || pp == original || family.contains(pp) else { continue }
            kill(k, SIGKILL)
        }
    }

    /// Synchronous SIGKILL of the process and all descendants (also used at app termination).
    func killTreeNow() {
        let pid = processIdentifier
        guard pid > 0 else { return }
        let kids = ProcessTree.descendants(of: pid)
        for k in kids { kill(k, SIGKILL) }
        kill(pid, SIGKILL)
        for k in ProcessTree.descendants(of: pid) { kill(k, SIGKILL) }
    }

    // MARK: One-shot helper (version / auth checks)

    /// `errorOutput` matters: real `codex login status` prints its verdict on stderr. Diagnostics/status parsing only.
    struct RunResult: Sendable { var exitCode: Int32; var output: String; var errorOutput: String = ""; var timedOut: Bool }

    static func runOnce(executable: String, arguments: [String], environment: [String: String],
                        workingDirectory: String = NSTemporaryDirectory(), timeout: TimeInterval, maxOutput: Int = 64 * 1024) async -> RunResult? {
        let p = ManagedProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
        guard let stream = try? p.start(stdin: nil) else { return nil }
        let collector = Task { () -> String in
            var text = ""
            for await line in stream { text += String(decoding: line, as: UTF8.self) + "\n"; if text.utf8.count > maxOutput { break } }
            return text
        }
        let timeoutTask = Task { try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled { await p.cancel() } }
        let code = await p.waitForExit()
        timeoutTask.cancel()
        let out = await collector.value
        return RunResult(exitCode: code, output: out, errorOutput: p.stderrTail, timedOut: p.wasCancelled)
    }
}
