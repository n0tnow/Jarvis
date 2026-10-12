import Testing
import Foundation
@testable import Jarvis

/// The REAL file-spool transport against a scripted "editor" that speaks the same file protocol (MOCK editor; the real one is `--unity-live-test`).
@MainActor
final class SpoolEditor {
    let root: String
    let dir: String
    var pid: Int32
    var answers: Bool = true
    private var loop: Task<Void, Never>?
    private(set) var seen: [String] = []

    init(pid: Int32 = getpid()) {
        root = UnityProcessScanner.canonical(UnityFixture.make())
        dir = root + "/Library/JarvisBridge"
        self.pid = pid
        for d in ["requests", "responses", "tests"] { try! FileManager.default.createDirectory(atPath: dir + "/" + d, withIntermediateDirectories: true) }
    }

    func writeStatus(state: String = "edit", playing: Bool = false, compiling: Bool = false, project: String? = nil, generation: Int = 0) {
        let obj: [String: Any] = ["protocol": 1, "bridgeVersion": "0.6.0", "pid": Int(pid), "session": "sess", "owned": true, "project": project ?? root, "projectName": "p", "unityVersion": "6000.5.1f1",
                                  "batchMode": true, "state": state, "isCompiling": compiling, "isPlaying": playing, "reloads": 0, "compileGeneration": generation, "compileFailed": false,
                                  "compileRunning": false, "activeScene": "", "scenes": [], "updatedAt": Int(Date().timeIntervalSince1970 * 1000)]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        try! data.write(to: URL(fileURLWithPath: dir + "/status.json.tmp"))
        _ = try? FileManager.default.removeItem(atPath: dir + "/status.json")
        try! FileManager.default.moveItem(atPath: dir + "/status.json.tmp", toPath: dir + "/status.json")
    }

    func startAnswering(result: @escaping (String, [String: Any]) -> [String: Any] = { op, _ in ["echo": op] }) {
        loop = Task { @MainActor in
            while !Task.isCancelled {
                if answers, let files = try? FileManager.default.contentsOfDirectory(atPath: dir + "/requests").filter({ $0.hasSuffix(".json") }).sorted() {
                    for f in files {
                        guard let d = FileManager.default.contents(atPath: dir + "/requests/" + f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = o["id"] as? String, let op = o["op"] as? String else { continue }
                        seen.append(op)
                        let resp: [String: Any] = ["id": id, "ok": true, "result": result(op, o["params"] as? [String: Any] ?? [:]), "session": "sess", "reloads": 0]
                        try? JSONSerialization.data(withJSONObject: resp).write(to: URL(fileURLWithPath: dir + "/responses/\(id).json.tmp"))
                        try? FileManager.default.moveItem(atPath: dir + "/responses/\(id).json.tmp", toPath: dir + "/responses/\(id).json")
                        try? FileManager.default.removeItem(atPath: dir + "/requests/" + f)
                    }
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    func stop() { loop?.cancel() }
    var pendingRequests: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir + "/requests")) ?? []).filter { $0.hasSuffix(".json") } }
}

@Suite("Unity file-spool transport", .serialized)
@MainActor
struct UnityTransportTests {
    init() { UnityProcessScanner.editorCheckOverride = { $0 == getpid() } }

    @Test func aRequestIsAnsweredThroughTheSpoolAndTheAnswerIsConsumed() async throws {
        let e = SpoolEditor(); defer { e.stop(); try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus(); e.startAnswering()
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        let r = try await t.send(.ping, timeout: 5)
        #expect(r.ok && r.result["echo"] as? String == "ping")
        #expect(e.pendingRequests.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: e.dir + "/responses")) ?? []).isEmpty)
        #expect(t.currentStatus()?.state == "edit")
    }

    @Test func noEditorMeansNotConnectedNotATimeout() async {
        let e = SpoolEditor(); defer { try? FileManager.default.removeItem(atPath: e.root) }
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        #expect(t.currentStatus() == nil)
        await #expect(throws: UnityBridgeError.self) { _ = try await t.send(.ping, timeout: 1) }
    }

    @Test func aStatusFileOfAnotherProjectOrADeadProcessIsNeverTreatedAsConnected() {
        let e = SpoolEditor(); defer { try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus(project: "/somewhere/else")
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        #expect(t.currentStatus() == nil)
        e.pid = 2_000_000_000                                              // not a process
        e.writeStatus()
        let t2 = UnityFileSpoolTransport(root: e.root); defer { t2.close() }
        #expect(t2.currentStatus() == nil)
    }

    @Test func aTimedOutRequestIsWithdrawnSoItCannotRunLater() async throws {
        let e = SpoolEditor(); defer { try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus()                                                      // alive but never answers
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        do { _ = try await t.send(.getProjectInfo, timeout: 0.3); Issue.record("should time out") }
        catch let err as UnityBridgeError { if case .timedOut = err {} else { Issue.record("wrong error \(err)") } }
        #expect(e.pendingRequests.isEmpty)
    }

    @Test func cancellingARequestWithdrawsItImmediately() async throws {
        let e = SpoolEditor(); defer { try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus()
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        let task = Task { try await t.send(.getProjectInfo, timeout: 30) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(e.pendingRequests.count == 1)
        let started = Date()
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(started) < 2 && e.pendingRequests.isEmpty)
    }

    @Test func statusChangesWakeWaitersWithoutPollingAndTimeoutsReturnNil() async throws {
        let e = SpoolEditor(); defer { try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus()
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        var changes = 0
        t.onStatusChange = { _ in changes += 1 }
        let waiter = Task { await t.waitForStatus(timeout: 10) { $0.isPlaying } }
        try await Task.sleep(for: .milliseconds(200))
        let t0 = Date()
        e.writeStatus(state: "playing", playing: true)
        let s = await waiter.value
        #expect(s?.isPlaying == true && Date().timeIntervalSince(t0) < 1.5)
        #expect(changes >= 1)
        #expect(await t.waitForStatus(timeout: 0.3, { $0.state == "never" }) == nil)             // a timeout is NOT a satisfied predicate
    }

    @Test func garbageInAResponseIsAProtocolErrorNotASuccess() async throws {
        let e = SpoolEditor(); defer { e.stop(); try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus()
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        let task = Task { try await t.send(.ping, timeout: 5) }
        try await Task.sleep(for: .milliseconds(150))
        let id = e.pendingRequests.first!.replacingOccurrences(of: ".json", with: "")
        try "{not json".write(toFile: e.dir + "/responses/\(id).json", atomically: true, encoding: .utf8)
        do { _ = try await task.value; Issue.record("accepted garbage") } catch let err as UnityBridgeError { if case .malformed = err {} else { Issue.record("wrong error \(err)") } }
    }

    @Test func aDyingEditorFailsPendingRequestsAndFlipsTheStateEventDriven() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        UnityProcessScanner.editorCheckOverride = { ProcessTree.isAlive($0) && $0 == child.processIdentifier }
        defer { if child.isRunning { child.terminate() }; UnityProcessScanner.editorCheckOverride = { $0 == getpid() } }
        let e = SpoolEditor(pid: child.processIdentifier); defer { try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus()
        let t = UnityFileSpoolTransport(root: e.root); defer { t.close() }
        #expect(t.currentStatus() != nil)
        var lastNil = false
        t.onStatusChange = { lastNil = ($0 == nil) }
        let pending = Task { try await t.send(.getProjectInfo, timeout: 30) }
        try await Task.sleep(for: .milliseconds(200))
        child.terminate()
        do { _ = try await pending.value; Issue.record("should fail") } catch let err as UnityBridgeError { #expect(err == .editorExited) }
        #expect(lastNil && t.currentStatus() == nil)
    }

    @Test func theConnectionFollowsTheTransportAndSanitizesWhatComesBack() async throws {
        let e = SpoolEditor(); defer { e.stop(); try? FileManager.default.removeItem(atPath: e.root) }
        e.writeStatus(); e.startAnswering { _, _ in ["message": "token sk-proj-FAKE0123456789abcdefghijkl", "globalId": "GlobalObjectId_V1-2-4319735414d274d1e8cb4bceb60d4f02-1-0"] }
        let t = UnityFileSpoolTransport(root: e.root)
        let conn = UnityConnection(root: e.root, transport: t); defer { t.close() }
        #expect(conn.state == .connected)
        let session = UnityToolSession(capabilities: CapabilitySet(granted: TaskCapability.unityInspection), taskID: nil, runID: nil, hub: nil, destructiveRequested: false)
        let r = try await conn.perform(.getProjectInfo, session: session)
        #expect(!(r.result["message"] as? String ?? "").contains("FAKE0123") && (r.result["globalId"] as? String ?? "").hasPrefix("GlobalObjectId_V1"))
        e.writeStatus(state: "playing", playing: true)
        #expect(await t.waitForStatus(timeout: 5, { $0.isPlaying }) != nil)
        #expect(conn.state == .playMode)
        await #expect(throws: UnityToolError.self) { _ = try await conn.perform(.addComponent(UnityTarget(path: "A"), componentType: "X", ifAbsent: true), session: session) }
    }
}
