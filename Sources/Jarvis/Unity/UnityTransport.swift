import Darwin
import Foundation

/// How JARVIS talks to one Unity editor. The production transport is a LOCAL FILE SPOOL (no socket, no network, no permission);
/// tests inject a simulated editor (clearly labelled MOCK) behind the same protocol.
@MainActor
protocol UnityTransport: AnyObject {
    var root: String { get }
    /// The last status the editor published, or nil when none exists or its process is gone (a stale file is never "connected").
    func currentStatus() -> UnityStatusSnapshot?
    func send(_ op: UnityOperation, timeout: TimeInterval) async throws -> UnityResponse
    /// Suspends until `predicate` holds for a published status (returned) or the timeout passes (nil). Event-driven: woken by status changes.
    func waitForStatus(timeout: TimeInterval, _ predicate: @escaping (UnityStatusSnapshot) -> Bool) async -> UnityStatusSnapshot?
    /// Abandons every request that has no answer yet (cancellation).
    func cancelPending()
    var onStatusChange: ((UnityStatusSnapshot?) -> Void)? { get set }
    func close()
}

extension UnityProcessScanner {
    /// Test hook: unit tests of the file transport use their own process as the "editor". Product code never sets it.
    nonisolated(unsafe) static var editorCheckOverride: ((pid_t) -> Bool)?

    /// A pid that is alive AND is a Unity editor (a recycled pid of an unrelated process is not our editor).
    static func isUnityEditor(pid: pid_t) -> Bool {
        if let o = editorCheckOverride { return o(pid) }
        guard pid > 0, ProcessTree.isAlive(pid) else { return false }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return isUnityEditorExecutable(String(cString: buf))
    }
}

@MainActor
final class UnityFileSpoolTransport: UnityTransport {
    let root: String
    private let bridgeDir: String
    private var requestsDir: String { bridgeDir + "/requests" }
    private var responsesDir: String { bridgeDir + "/responses" }

    var onStatusChange: ((UnityStatusSnapshot?) -> Void)?
    private(set) var lastStatus: UnityStatusSnapshot?
    private var lastStatusStamp: Date?
    private var dirSource: DispatchSourceFileSystemObject?
    private var responsesSource: DispatchSourceFileSystemObject?
    private var processSource: DispatchSourceProcess?
    private var watchedPid: pid_t = 0

    private struct Pending { let continuation: CheckedContinuation<Result<UnityResponse, UnityBridgeError>, Never>; let timeout: Task<Void, Never>? }
    private var pending: [String: Pending] = [:]
    private struct Waiter { let predicate: (UnityStatusSnapshot) -> Bool; let continuation: CheckedContinuation<UnityStatusSnapshot?, Never>; let timeout: Task<Void, Never>?; let recheck: Task<Void, Never>? }
    private var waiters: [UUID: Waiter] = [:]

    init(root: String) {
        self.root = root
        self.bridgeDir = root + "/Library/JarvisBridge"
        refreshStatus()
        installWatchers()
    }

    // MARK: Status

    func currentStatus() -> UnityStatusSnapshot? {
        refreshStatus()
        guard let s = lastStatus, UnityProcessScanner.isUnityEditor(pid: s.pid) else { return nil }
        return s
    }

    /// Reads status.json when it changed. Publishes a change event only when the content differs.
    private func refreshStatus() {
        let path = bridgeDir + "/status.json"
        var snapshot: UnityStatusSnapshot?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let m = attrs[.modificationDate] as? Date {
            if m == lastStatusStamp, lastStatus != nil { return }
            lastStatusStamp = m
            if let data = FileManager.default.contents(atPath: path), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                snapshot = UnityStatusSnapshot(json: obj)
                if let s = snapshot, canonical(s.project) != canonical(root) { snapshot = nil }       // another project's status: never ours
            }
        } else { lastStatusStamp = nil }
        guard snapshot != lastStatus else { return }
        lastStatus = snapshot
        if let s = snapshot { watchProcess(s.pid) }
        onStatusChange?(snapshot)
        evaluateWaiters()
    }

    private func canonical(_ p: String) -> String { UnityProcessScanner.canonical(p) }

    private func watchProcess(_ pid: pid_t) {
        guard pid > 0, pid != watchedPid else { return }
        processSource?.cancel()
        watchedPid = pid
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.editorExited(pid) } }
        src.resume()
        processSource = src
    }

    private func editorExited(_ pid: pid_t) {
        guard pid == watchedPid else { return }
        processSource?.cancel(); processSource = nil; watchedPid = 0
        lastStatus = nil; lastStatusStamp = nil
        for (id, p) in pending { p.timeout?.cancel(); try? FileManager.default.removeItem(atPath: requestsDir + "/\(id).json"); p.continuation.resume(returning: .failure(.editorExited)) }
        pending.removeAll()
        onStatusChange?(nil)
        evaluateWaiters()
    }

    // MARK: Watching (vnode sources fire only when something changes — nothing runs while idle)

    private func installWatchers() {
        if dirSource == nil, FileManager.default.fileExists(atPath: bridgeDir) { dirSource = makeSource(bridgeDir) { [weak self] in self?.refreshStatus() } }
        if responsesSource == nil, FileManager.default.fileExists(atPath: responsesDir) { responsesSource = makeSource(responsesDir) { [weak self] in self?.collectResponses() } }
    }

    private func makeSource(_ path: String, _ handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { handler() } }
        src.setCancelHandler { _ = Darwin.close(fd) }
        src.resume()
        return src
    }

    func close() {
        cancelPending()
        dirSource?.cancel(); dirSource = nil
        responsesSource?.cancel(); responsesSource = nil
        processSource?.cancel(); processSource = nil; watchedPid = 0
        for (_, w) in waiters { w.timeout?.cancel(); w.recheck?.cancel(); w.continuation.resume(returning: nil) }
        waiters.removeAll()
    }

    // MARK: Requests

    func send(_ op: UnityOperation, timeout: TimeInterval) async throws -> UnityResponse {
        installWatchers()
        guard FileManager.default.fileExists(atPath: requestsDir) else { throw UnityBridgeError.notConnected("The JARVIS Unity bridge has not started for this project.") }
        guard let st = currentStatus() else { throw UnityBridgeError.notConnected("No Unity editor with the JARVIS bridge is running for this project.") }
        _ = st
        let request = UnityRequest(id: UnityRequest.makeID(), operation: op)
        let data: Data
        do { data = try request.data() } catch { throw UnityBridgeError.malformed("request could not be encoded") }
        let tmp = requestsDir + "/\(request.id).json.tmp", final = requestsDir + "/\(request.id).json"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            try FileManager.default.moveItem(atPath: tmp, toPath: final)
        } catch { throw UnityBridgeError.notConnected("The request could not be queued: \(error.localizedDescription)") }

        let id = request.id
        let result: Result<UnityResponse, UnityBridgeError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<UnityResponse, UnityBridgeError>, Never>) in
                if Task.isCancelled { cont.resume(returning: .failure(.cancelled)); try? FileManager.default.removeItem(atPath: final); return }
                let t = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, let self, let p = self.pending.removeValue(forKey: id) else { return }
                    try? FileManager.default.removeItem(atPath: final)               // a request nobody waits for must not run later
                    p.continuation.resume(returning: .failure(.timedOut("\(op.wireName) after \(Int(timeout)) s")))
                }
                pending[id] = Pending(continuation: cont, timeout: t)
                collectResponses()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(id) }
        }
        return try result.get()
    }

    private func abandon(_ id: String) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timeout?.cancel()
        try? FileManager.default.removeItem(atPath: requestsDir + "/\(id).json")
        p.continuation.resume(returning: .failure(.cancelled))
    }

    func cancelPending() { for id in Array(pending.keys) { abandon(id) } }

    private func collectResponses() {
        guard !pending.isEmpty else { return }
        for id in Array(pending.keys) {
            let path = responsesDir + "/\(id).json"
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            guard let response = UnityResponse(data: data) else {
                // Half-written is impossible (the bridge renames atomically); unreadable content is a protocol error.
                try? FileManager.default.removeItem(atPath: path)
                if let p = pending.removeValue(forKey: id) { p.timeout?.cancel(); p.continuation.resume(returning: .failure(.malformed("response"))) }
                continue
            }
            try? FileManager.default.removeItem(atPath: path)
            if let p = pending.removeValue(forKey: id) { p.timeout?.cancel(); p.continuation.resume(returning: .success(response)) }
        }
    }

    // MARK: Waiting for status

    func waitForStatus(timeout: TimeInterval, _ predicate: @escaping (UnityStatusSnapshot) -> Bool) async -> UnityStatusSnapshot? {
        installWatchers()
        if let s = currentStatus(), predicate(s) { return s }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<UnityStatusSnapshot?, Never>) in
                if Task.isCancelled { cont.resume(returning: nil); return }
                let t = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, let self, let w = self.waiters.removeValue(forKey: id) else { return }
                    w.recheck?.cancel(); w.continuation.resume(returning: nil)           // a timeout is NOT a satisfied predicate
                }
                // Safety net for a missed vnode event (and for a bridge directory that does not exist yet): re-read once a second, ONLY while waiting.
                let r = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.waiters[id] != nil else { return }
                        self.installWatchers(); self.lastStatusStamp = nil; self.refreshStatus(); self.evaluateWaiters()
                    }
                }
                waiters[id] = Waiter(predicate: predicate, continuation: cont, timeout: t, recheck: r)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let w = self.waiters.removeValue(forKey: id) else { return }
                w.timeout?.cancel(); w.recheck?.cancel(); w.continuation.resume(returning: nil)
            }
        }
    }

    private func evaluateWaiters() {
        guard !waiters.isEmpty, let s = lastStatus, UnityProcessScanner.isUnityEditor(pid: s.pid) else { return }
        for (id, w) in waiters where w.predicate(s) {
            waiters.removeValue(forKey: id)
            w.timeout?.cancel(); w.recheck?.cancel()
            w.continuation.resume(returning: s)
        }
    }
}
