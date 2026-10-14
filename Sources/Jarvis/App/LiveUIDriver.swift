import AppKit

// MARK: - Real clicks on JARVIS' OWN Full HUD for the V0.14 live tests
//
// An Accessibility action on one's own process runs on the calling thread and trips SwiftUI's main-actor check, so the clicks come from a CHILD process: the same binary started with
// `--live-ui-child <parent pid>` reads one command per line from stdin and answers one JSON line, using the product's Accessibility backend against the parent. The parent is made a
// regular application for the duration of the test so the backend can list it. Nothing here is a product code path; it exists only for `--mcp-live-test` / `--adaptive-live-test`.

struct LiveUIElement: Sendable { var role: String; var title: String; var value: String }

struct LiveUISnapshot: Sendable {
    var elements: [LiveUIElement]
    var nodeCount: Int { elements.count }
    func find(_ title: String, role: String? = nil, contains: Bool = false) -> LiveUIElement? {
        elements.first { e in (role == nil || e.role == role) && (contains ? e.title.contains(title) : e.title == title) }
    }
    func titles(role: String) -> [String] { elements.filter { $0.role == role }.map(\.title).filter { !$0.isEmpty } }
    func has(_ text: String) -> Bool { elements.contains { $0.title.contains(text) || $0.value.contains(text) } }
}

@MainActor
final class LiveUIDriver {
    private let log: (String) -> Void
    private var child: ManagedProcess?
    private var lines: AsyncStream<Data>.Iterator?
    private var policyChanged = false
    private(set) var trusted = false

    init(log: @escaping (String) -> Void) { self.log = log; trusted = AXBackend().accessibilityTrusted() }

    func start(show: () -> Void) async {
        NSApp.setActivationPolicy(.regular); policyChanged = true
        show()
        try? await Task.sleep(for: .milliseconds(1500))
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = ManagedProcess(executable: exe, arguments: ["--live-ui-child", "\(getpid())"], environment: ProcessInfo.processInfo.environment, workingDirectory: "/")
        if let stream = try? p.start(stdin: nil, keepStdinOpen: true) { child = p; lines = stream.makeAsyncIterator() }
        _ = await command(["activate"])
    }
    func stop() {
        if policyChanged { NSApp.setActivationPolicy(.accessory); policyChanged = false }
        child?.killTreeNow(); child = nil
    }

    /// One command, one JSON answer (10 s).
    func command(_ parts: [String]) async -> [String: Any] {
        guard let child, var it = lines else { return ["ok": false, "detail": "no child"] }
        let data = (try? JSONSerialization.data(withJSONObject: parts)) ?? Data()
        child.send(data + Data("\n".utf8))
        let answer: [String: Any]? = await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { await it.next().flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        lines = it
        return answer ?? ["ok": false, "detail": "no answer"]
    }

    func snapshot() async -> LiveUISnapshot {
        let r = await command(["snapshot"])
        let rows = (r["elements"] as? [[String]]) ?? []
        return LiveUISnapshot(elements: rows.map { LiveUIElement(role: $0.count > 0 ? $0[0] : "", title: $0.count > 1 ? $0[1] : "", value: $0.count > 2 ? $0[2] : "") })
    }
    @discardableResult
    func press(_ title: String, role: String? = nil, contains: Bool = false, settle: Int = 700) async -> Bool {
        let r = await command(["press", role ?? "*", title, contains ? "1" : "0"])
        let ok = (r["ok"] as? Bool) ?? false
        if !ok { log("   press “\(title)”: \((r["detail"] as? String) ?? "failed")") }
        try? await Task.sleep(for: .milliseconds(settle))
        return ok
    }
    @discardableResult
    func type(_ text: String) async -> Bool {
        let r = await command(["type", text])
        try? await Task.sleep(for: .milliseconds(600))
        return (r["ok"] as? Bool) ?? false
    }
}

enum LiveUIChild {
    /// Called from main.swift before any UI exists.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--live-ui-child"), i + 1 < args.count, let parent = Int32(args[i + 1]) else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let backend = AXBackend()
            func snap() async -> AXSnapshot? {
                let wins = await backend.windows(pid: parent)
                guard let w = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.index else { return nil }
                return try? await backend.snapshot(pid: parent, scope: .window(index: w), budget: AXBudget(maxNodes: 1200, maxDepth: 26, timeBudget: 5, maxChildrenPerNode: 160))
            }
            func reply(_ d: [String: Any]) { if let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) { print(s); fflush(stdout) } }
            while let line = readLine(strippingNewline: true) {
                guard let parts = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String], let cmd = parts.first else { reply(["ok": false, "detail": "bad command"]); continue }
                switch cmd {
                case "activate": _ = await backend.activateApplication(pid: parent); reply(["ok": true])
                case "snapshot":
                    let s = await snap()
                    reply(["ok": s != nil, "elements": (s?.elements ?? []).map { [$0.role, String($0.title.prefix(1200)), String(($0.value ?? "").prefix(1200))] }])
                case "press":
                    guard parts.count >= 4, let s = await snap() else { reply(["ok": false, "detail": "no window"]); continue }
                    let role = parts[1], title = parts[2], contains = parts[3] == "1"
                    guard let e = s.elements.first(where: { (role == "*" || $0.role == role) && (contains ? $0.title.contains(title) : $0.title == title) }) else { reply(["ok": false, "detail": "no control titled “\(title)”"]); continue }
                    do { try await backend.perform(.press, on: e.handle); reply(["ok": true]) } catch { reply(["ok": false, "detail": "\(error)"]) }       // the press may have worked even when the answer is an error: callers verify the STATE
                case "type":
                    guard parts.count >= 2, let s = await snap(), let e = s.elements.first(where: { $0.role == "AXTextField" }) else { reply(["ok": false, "detail": "no field"]); continue }
                    do {
                        try? await backend.perform(.focus, on: e.handle)
                        try? await Task.sleep(for: .milliseconds(200))
                        try await backend.typeText(parts[1], toPID: parent, shouldContinue: { true })           // real key events: the field's binding updates like a person typing
                        reply(["ok": true])
                    } catch { reply(["ok": false, "detail": "\(error)"]) }
                default: reply(["ok": false, "detail": "unknown command"])
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}
