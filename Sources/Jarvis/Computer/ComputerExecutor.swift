import Foundation
import CoreGraphics
import AppKit

// MARK: - OBSERVE → RESOLVE → CHECK POLICY → ACT → OBSERVE → VERIFY  (DEC-129)
//
// One typed action at a time. Nothing here is a macro: every wait is a condition with a bounded timeout, every target is re-resolved from a fresh
// observation, every action has a postcondition, and "the event was dispatched" is never reported as success.

/// Shared by the engine, the HUD Stop button and the emergency shortcut. Once stopped, the executor sends no further event, key, click or request.
final class ComputerStopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var why = ""
    private var stoppedAt: Date?
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var reason: String { lock.lock(); defer { lock.unlock() }; return why }
    var stoppedTime: Date? { lock.lock(); defer { lock.unlock() }; return stoppedAt }
    func stop(_ reason: String) { lock.lock(); if !stopped { stopped = true; why = reason; stoppedAt = Date() }; lock.unlock() }
    func reset() { lock.lock(); stopped = false; why = ""; stoppedAt = nil; lock.unlock() }
}

/// Permission-free reading of "is the user typing/clicking right now?" (seconds since the last real input event of the session).
protocol UserActivityProbe: Sendable {
    func secondsSinceKeyOrClick() -> TimeInterval
    /// Includes plain pointer movement (a coordinate click moves the pointer, so it must not happen while the user is using the mouse).
    func secondsSinceAnyPointerOrKeyInput() -> TimeInterval
}
struct SystemActivityProbe: UserActivityProbe {
    func secondsSinceAnyPointerOrKeyInput() -> TimeInterval {
        let s = CGEventSourceStateID.combinedSessionState
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged].map { CGEventSource.secondsSinceLastEventType(s, eventType: $0) }.min() ?? .infinity
    }
    func secondsSinceKeyOrClick() -> TimeInterval {
        let s = CGEventSourceStateID.combinedSessionState
        return [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel].map { CGEventSource.secondsSinceLastEventType(s, eventType: $0) }.min() ?? .infinity
    }
}
struct NoUserActivity: UserActivityProbe { func secondsSinceKeyOrClick() -> TimeInterval { .infinity }; func secondsSinceAnyPointerOrKeyInput() -> TimeInterval { .infinity } }

struct ComputerApprovalRequest: Sendable {
    var action: ComputerAction
    var prompt: String
    var risk: RiskClass
    var consequence: Consequence
    /// Binds the approval to THIS action instance only; an approval never travels to another action.
    var nonce = UUID()
}

@MainActor
final class ComputerExecutor {
    let backend: UIBackend
    var vision: VisionProposing
    var activity: UserActivityProbe = NoUserActivity()
    var quarantineRoot: String?
    var stop = ComputerStopToken()
    var events: (ComputerEvent) -> Void = { _ in }
    var approve: (ComputerApprovalRequest) async -> Bool = { _ in false }
    var visionAllowed: () -> Bool = { false }
    /// Test hook: replaces real waiting.
    var pause: (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) }
    var maxRetries = ComputerLimits.maxRetries
    var launchTimeout = ComputerLimits.launchTimeout
    var windowTimeout = ComputerLimits.windowTimeout
    var verifyTimeout = ComputerLimits.verifyTimeout
    /// How long an 'unsupported' answer from an Accessibility action is cross-checked against the state it should have produced (read-only).
    var unsupportedLookTimeout: TimeInterval = 1.5
    /// Metadata hooks for the session record (counts and sizes only).
    var observed: (AXSnapshot) -> Void = { _ in }
    var screenObserved: (ScreenObservation) -> Void = { _ in }
    var interferenceGrace: TimeInterval = 0.35
    var interferenceWait: TimeInterval = 2.5

    private(set) var lastSnapshot: AXSnapshot?
    private(set) var lastScreen: ScreenObservation?
    private(set) var lastApprovalIDs: [UUID] = []

    init(backend: UIBackend, vision: VisionProposing = UnavailableModelVision()) { self.backend = backend; self.vision = vision }

    // MARK: Entry

    func perform(_ a: ComputerAction) async -> ActionResult {
        var run = Run(started: Date(), action: a)
        if stop.isStopped { return finish(&run, .cancelled, detail: "stopped before it started") }
        events(.actionProposed(a.summary))

        let needsAX = ![.openSettingsPane, .launchApplication, .openFile, .revealFile, .captureWindow].contains(a.kind) || a.kind == .captureWindow
        if needsAX, !backend.accessibilityTrusted() {
            events(.permissionMissing("Accessibility"))
            return finish(&run, .permissionRequired, detail: "Accessibility permission is required. Open System Settings → Privacy & Security → Accessibility and allow JARVIS, then try again.")
        }
        // Policy that needs no observation at all (blocked kinds, secrets, terminals by app, paths).
        let appRef = a.target.app
        let pre = ComputerPolicy.assess(a, in: ActionPolicyContext(bundleID: appRef.bundleID, windowTitle: a.target.windowTitle, element: nil, quarantineRoot: quarantineRoot))
        run.assessment = pre
        if case .blocked(let why, let cat) = pre.verdict { events(.blocked(why)); return finish(&run, .blocked, detail: why, category: cat) }

        switch a.kind {
        case .observe: return await observe(&run)
        case .launchApplication: return await launch(&run)
        case .activateApplication: return await activate(&run)
        case .quitApplication: return await quit(&run)
        case .focusWindow, .minimizeWindow, .restoreWindow, .closeWindow: return await windowAction(&run)
        case .pressElement: return await pressElement(&run)
        case .selectMenuItem: return await selectMenu(&run)
        case .setText: return await setText(&run)
        case .typeText: return await typeText(&run)
        case .pressKey, .pressShortcut: return await pressKey(&run)
        case .scroll: return await scroll(&run)
        case .openFile, .revealFile: return await openOrReveal(&run)
        case .openSettingsPane: return await openPane(&run)
        case .captureWindow: return await captureAction(&run)
        case .visionPress: return await visionPress(&run)
        }
    }

    // MARK: Run state & results

    struct Run {
        var started: Date
        var action: ComputerAction
        var assessment: ActionAssessment?
        var mechanism: ComputerMechanism = .accessibility
        var resolution: ResolutionState?
        var verification: VerificationResult?
        var attempts = 0
        var app: ApplicationSnapshot?
        var window: String?
        var target = ""
        var approvalID: UUID?
        var textClass: TextClass?
        var textLength: Int?
        var category: FailureCategory?
    }

    private func finish(_ r: inout Run, _ status: ActionStatus, detail: String, category: FailureCategory? = nil) -> ActionResult {
        r.category = category
        let risk = r.assessment?.risk ?? .low
        if status == .verified, let v = r.verification { events(.verificationPassed(r.action.summary)); _ = v }
        else if status == .notVerified { events(.verificationFailed(r.action.summary)) }
        if r.action.kind.sendsKeystrokes || r.action.kind == .setText { r.textClass = r.textClass ?? TextPolicy.classify(r.action.text ?? ""); r.textLength = r.action.text?.count }
        return ActionResult(action: r.action, status: status, mechanism: r.mechanism, risk: risk, resolution: r.resolution, verification: r.verification,
                            detail: OutputSanitizer.sanitize(String(detail.prefix(500))), attempts: r.attempts, durationMS: Date().timeIntervalSince(r.started) * 1000, approvalID: r.approvalID,
                            app: r.app?.name, window: r.window.map { OutputSanitizer.sanitize(String($0.prefix(80))) }, targetDescription: OutputSanitizer.sanitize(String((r.target.isEmpty ? r.action.target.description : r.target).prefix(120))),
                            textClass: r.textClass, textLength: r.textLength, category: r.category)
    }

    // MARK: Waiting (conditions, never fixed sleeps)

    private func waitUntil(_ timeout: TimeInterval, initial: TimeInterval = 0.08, max maxDelay: TimeInterval = 0.4, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var delay = initial
        repeat {
            if stop.isStopped { return false }
            if await cond() { return true }
            await pause(delay)
            delay = min(delay * 1.6, maxDelay)
        } while Date() < deadline
        if stop.isStopped { return false }
        return await cond()
    }

    // MARK: Applications

    private func findApp(_ ref: AppRef) async -> ApplicationSnapshot? {
        let apps = await backend.runningApplications()
        if ref.bundleID == nil && ref.name == nil { return await backend.frontmostApplication() }
        return apps.first { ref.matches($0) }
    }

    private func launch(_ r: inout Run) async -> ActionResult {
        let ref = r.action.target.app
        if let running = await findApp(ref) { r.app = running; events(.appResolved(running.name, running: true)); r.verification = VerificationResult(passed: true, checks: ["already running"], detail: "\(running.name) was already running"); return finish(&r, .verified, detail: "already running") }
        guard let bundle = await backend.installedBundleID(for: ref) else { events(.appResolved(ref.display, running: false)); return finish(&r, .notFound, detail: "\(ref.display) is not installed (or cannot be launched by JARVIS)") }
        events(.appResolved(ref.display, running: false))
        r.attempts = 1
        do { _ = try await backend.launchApplication(bundleID: bundle) } catch { return finish(&r, .failed, detail: "\(error)") }
        var seen: ApplicationSnapshot?
        let ok = await waitUntil(launchTimeout, initial: 0.15, max: 0.6) { seen = await self.findApp(AppRef(bundleID: bundle, name: ref.name)); return seen?.isFinishedLaunching == true }
        if stop.isStopped { return finish(&r, .cancelled, detail: "stopped while waiting for the launch") }
        r.app = seen
        r.verification = VerificationResult(passed: ok, checks: ["\(bundle) is running"], detail: ok ? "running" : "not running after \(Int(launchTimeout)) s")
        return ok ? finish(&r, .verified, detail: "launched") : finish(&r, .timedOut, detail: "\(ref.display) did not finish launching within \(Int(launchTimeout)) s")
    }

    private func activate(_ r: inout Run) async -> ActionResult {
        guard let app = await findApp(r.action.target.app) else { return finish(&r, .notFound, detail: "\(r.action.target.app.display) is not running") }
        r.app = app
        if app.isActive, let f = await backend.frontmostApplication(), f.pid == app.pid { r.verification = VerificationResult(passed: true, checks: ["already frontmost"], detail: "already frontmost"); return finish(&r, .verified, detail: "already frontmost") }
        guard await backend.isResponsive(pid: app.pid) else { return finish(&r, .appUnresponsive, detail: "\(app.name) is not responding (JARVIS will not force-quit it)") }
        r.attempts = 1
        _ = await backend.activateApplication(pid: app.pid)
        let ok = await waitUntil(windowTimeout) { await self.backend.frontmostApplication()?.pid == app.pid }
        if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
        r.verification = VerificationResult(passed: ok, checks: ["\(app.name) is frontmost"], detail: ok ? "frontmost" : "another application kept the focus")
        return ok ? finish(&r, .verified, detail: "frontmost") : finish(&r, .notVerified, detail: "\(app.name) did not become frontmost (macOS may have refused the focus change)")
    }

    private func quit(_ r: inout Run) async -> ActionResult {
        guard let app = await findApp(r.action.target.app) else { return finish(&r, .notFound, detail: "not running") }
        r.app = app
        guard let a = r.assessment, case .needsApproval(let prompt) = a.verdict else { return finish(&r, .blocked, detail: "quitting needs approval") }
        guard await ask(&r, a, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "quitting was not approved") }
        r.attempts = 1
        _ = await backend.quitApplication(pid: app.pid)
        let gone = await waitUntil(windowTimeout) { await self.findApp(AppRef(bundleID: app.bundleID, name: app.name)) == nil }
        r.verification = VerificationResult(passed: gone, checks: ["\(app.name) quit"], detail: gone ? "quit" : "still running (it may be asking about unsaved work — JARVIS does not force-quit)")
        return gone ? finish(&r, .verified, detail: "quit") : finish(&r, .notVerified, detail: "\(app.name) is still running; it may be asking to save. JARVIS does not force-quit.")
    }

    // MARK: Observation

    private func snapshot(of app: ApplicationSnapshot, scope: SnapshotScope = .modalFirst) async throws -> AXSnapshot {
        guard await backend.isResponsive(pid: app.pid) else { throw BackendError.timedOut }
        let s = try await backend.snapshot(pid: app.pid, scope: scope, budget: AXBudget())
        lastSnapshot = s
        events(.observed(app: app.name, windows: s.windows.count, nodes: s.nodeCount, truncated: s.truncated))
        observed(s)
        return s
    }

    /// Which window to look at: the one the user named (several similar windows are told apart by title, never by z-order), else the dialog / front window.
    private func scope(for app: ApplicationSnapshot, windowTitle: String?) async -> (scope: SnapshotScope, state: ResolutionState?, reason: String?) {
        guard let t = windowTitle, !t.isEmpty else { return (.modalFirst, nil, nil) }
        let res = TargetResolver.resolveWindow(title: t, in: await backend.windows(pid: app.pid))
        guard res.state.isActionable, let w = res.window else { return (.modalFirst, res.state, res.reason) }
        return (.window(index: w.index), res.state, nil)
    }

    /// Would an action based on `obs` still be legal right now? (the live test and the vision path use the same answer)
    func checkStale(_ obs: ScreenObservation) async -> StaleVerdict {
        var fp: UInt64?
        if let cid = obs.cgWindowID { fp = (try? await backend.captureWindow(cgWindowID: cid, windowFrame: obs.windowFrame))?.fingerprint }
        let wins = await backend.windows(pid: obs.pid)
        return StaleCheck.validate(obs, currentWindow: wins.first { $0.cgWindowID == obs.cgWindowID } ?? wins.first { $0.title == obs.windowTitle }, frontmostPID: await backend.frontmostApplication()?.pid, currentFingerprint: fp)
    }

    private func observe(_ r: inout Run) async -> ActionResult {
        guard let app = await findApp(r.action.target.app) else { return finish(&r, .notFound, detail: "\(r.action.target.app.display) is not running") }
        r.app = app
        if SurfacePolicy.isCredentialApp(app.bundleID) { return finish(&r, .blocked, detail: "password managers are not observed", category: .interactionRequired) }
        do {
            let s = try await snapshot(of: app)
            r.window = s.window?.title
            r.attempts = 1
            r.verification = VerificationResult(passed: true, checks: ["observed"], detail: "\(s.nodeCount) elements")
            return finish(&r, .verified, detail: summary(of: s))
        } catch let e as BackendError { return finish(&r, e == .timedOut ? .appUnresponsive : e == .permissionDenied ? .permissionRequired : .failed, detail: "\(e)") }
        catch { return finish(&r, .failed, detail: "\(error)") }
    }

    /// Labels only — window titles and control names, bounded. Document text never leaves the application.
    func summary(of s: AXSnapshot) -> String {
        let wins = s.windows.prefix(4).map { "“\($0.title.prefix(40))”\($0.isModal ? " (dialog)" : "")\($0.isMinimized ? " (minimized)" : "")" }.joined(separator: ", ")
        let controls = s.elements.filter { ["button", "radiobutton", "checkbox", "tab", "popupbutton", "menubutton"].contains(ComputerPolicy.shortRole($0.role)) && !$0.title.isEmpty }.prefix(10).map { $0.title.prefix(24) }.joined(separator: ", ")
        return "\(s.app.name): \(s.windows.count) window\(s.windows.count == 1 ? "" : "s") [\(wins)]; \(s.nodeCount) elements\(s.truncated ? " (bounded)" : "")" + (controls.isEmpty ? "" : "; controls: \(controls)")
    }

    /// What a planning model may see: window titles and control LABELS (bounded). No document text, no values of text fields, nothing from secure fields.
    func planningObservation(_ s: AXSnapshot) -> String {
        var l = [summary(of: s)]
        let interesting = s.elements.filter { !$0.isSecure && !$0.title.isEmpty && ["button", "radiobutton", "checkbox", "tab", "popupbutton", "menubutton", "row", "outlinerow", "textfield", "link", "statictext", "menuitem", "disclosuretriangle"].contains(ComputerPolicy.shortRole($0.role)) }
        for e in interesting.prefix(60) {
            l.append("- \(ComputerPolicy.shortRole(e.role)) “\(e.title.prefix(40))”\(e.selected ? " [selected]" : "")\(e.enabled ? "" : " [disabled]")\(e.inModal ? " [in dialog]" : "")\(e.ancestorTitles.first.map { " (in \($0.prefix(24)))" } ?? "")")
        }
        return l.joined(separator: "\n")
    }

    // MARK: Window actions

    private func windowAction(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard let app = await findApp(a.target.app) else { return finish(&r, .notFound, detail: "\(a.target.app.display) is not running") }
        r.app = app
        var wins = await backend.windows(pid: app.pid)
        if wins.isEmpty && a.kind != .restoreWindow { return finish(&r, .notFound, detail: "\(app.name) has no window") }
        let res = TargetResolver.resolveWindow(title: a.target.windowTitle, in: wins)
        r.resolution = res.state
        guard res.state.isActionable, let w = res.window else {
            events(.targetResolved("window", res.state))
            return finish(&r, res.state == .ambiguous ? .ambiguous : .notFound, detail: res.reason)
        }
        events(.windowResolved(w.title)); r.window = w.title; r.target = "window “\(w.title.prefix(40))”"
        var assessment = ComputerPolicy.assess(a, in: ActionPolicyContext(bundleID: app.bundleID, windowTitle: w.title, element: nil, modalPresent: w.isModal, quarantineRoot: quarantineRoot))
        if a.kind == .closeWindow {
            // A window that has a dialog open, or a document-style title, may hold unsaved work: ask (the default).
            assessment.verdict = .needsApproval("Close the window “\(w.title.prefix(50))”? It may hold unsaved work.")
        }
        r.assessment = assessment
        if case .needsApproval(let prompt) = assessment.verdict { guard await ask(&r, assessment, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "not approved") } }
        if case .blocked(let why, let cat) = assessment.verdict { return finish(&r, .blocked, detail: why, category: cat) }
        r.attempts = 1
        do {
            switch a.kind {
            case .focusWindow:
                _ = await backend.activateApplication(pid: app.pid)
                try await backend.windowOperation(.raise, pid: app.pid, windowIndex: w.index)
            case .minimizeWindow: try await backend.windowOperation(.minimize, pid: app.pid, windowIndex: w.index)
            case .restoreWindow: try await backend.windowOperation(.restore, pid: app.pid, windowIndex: w.index)
            default: try await backend.windowOperation(.close, pid: app.pid, windowIndex: w.index)
            }
        } catch let e as BackendError { return finish(&r, e == .timedOut ? .appUnresponsive : .failed, detail: "\(e)") } catch { return finish(&r, .failed, detail: "\(error)") }
        let kind = a.kind, title = w.title, idx = w.index
        let ok = await waitUntil(windowTimeout) {
            let now = await self.backend.windows(pid: app.pid)
            switch kind {
            case .minimizeWindow: return now.first { $0.title == title }?.isMinimized == true
            case .restoreWindow: return now.first { $0.title == title }?.isMinimized == false
            case .closeWindow: return !now.contains { $0.title == title }
            default: return await self.backend.frontmostApplication()?.pid == app.pid && (now.first { $0.index == idx || $0.title == title }.map { $0.isMain || $0.isFocused } ?? false)
            }
        }
        _ = wins; wins = []
        r.verification = VerificationResult(passed: ok, checks: [a.kind.label + " “\(title.prefix(30))”"], detail: ok ? "done" : "the window did not change as expected")
        return ok ? finish(&r, .verified, detail: "done") : finish(&r, .notVerified, detail: "the window did not change as expected")
    }

    // MARK: Approvals

    private func ask(_ r: inout Run, _ a: ActionAssessment, prompt: String) async -> Bool {
        events(.approvalRequired(prompt))
        let req = ComputerApprovalRequest(action: r.action, prompt: prompt, risk: a.risk, consequence: a.consequence)
        r.approvalID = req.nonce
        lastApprovalIDs.append(req.nonce)
        let ok = await approve(req)
        return ok && !stop.isStopped
    }

    // MARK: Context for policy (UI text is untrusted: it can only raise risk)

    private func context(app: ApplicationSnapshot?, snap: AXSnapshot?, element: UIElementSnapshot?) -> ActionPolicyContext {
        var texts: [String] = []
        if let snap, let win = snap.window {
            if snap.hasModal || win.isModal { texts += snap.elements.filter { $0.inModal && ComputerPolicy.shortRole($0.role) == "statictext" }.map(\.title) }
            texts.append(win.title)
        }
        return ActionPolicyContext(bundleID: app?.bundleID, windowTitle: snap?.window?.title, element: element, contextTexts: texts, modalPresent: snap?.hasModal ?? false,
                                 defaultButtonLabel: snap?.windows.first(where: { $0.isModal || $0.isSheet })?.defaultButton ?? snap?.window?.defaultButton, quarantineRoot: quarantineRoot)
    }

    // MARK: Interference (the user always wins)

    private func yieldToUser(_ r: inout Run, app: ApplicationSnapshot) async -> Bool {
        guard let front = await backend.frontmostApplication(), front.pid == app.pid else { return true }
        var waited = 0.0
        while activity.secondsSinceKeyOrClick() < interferenceGrace {
            if stop.isStopped { return false }
            if waited == 0 { events(.userInterference("you are typing or clicking in \(app.name)")) }
            if waited >= interferenceWait { return false }
            await pause(0.15); waited += 0.15
        }
        return true
    }

    // MARK: Press (accessibility first)

    private func pressElement(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard var app = await findApp(a.target.app) else { return finish(&r, .notFound, detail: "\(a.target.app.display) is not running") }
        r.app = app
        if SurfacePolicy.isCredentialApp(app.bundleID) { return finish(&r, .blocked, detail: "password managers are the user's to operate", category: .interactionRequired) }
        if await backend.frontmostApplication()?.pid != app.pid {
            _ = await backend.activateApplication(pid: app.pid)
            _ = await waitUntil(windowTimeout) { await self.backend.frontmostApplication()?.pid == app.pid }
            app = await findApp(a.target.app) ?? app
        }
        var approved: ActionFingerprint?
        var lastError = ""
        for attempt in 1...(maxRetries + 1) {
            if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
            r.attempts = attempt
            let snap: AXSnapshot
            let sc = await scope(for: app, windowTitle: a.target.windowTitle)
            if let st = sc.state, !st.isActionable { r.resolution = st; return finish(&r, st == .ambiguous ? .ambiguous : .notFound, detail: sc.reason ?? "the window was not found") }
            do { snap = try await snapshot(of: app, scope: sc.scope) }
            catch let e as BackendError { return finish(&r, e == .timedOut ? .appUnresponsive : e == .permissionDenied ? .permissionRequired : .failed, detail: "\(e)") }
            catch { return finish(&r, .failed, detail: "\(error)") }
            r.window = snap.window?.title
            // modal first: never act on a window a dialog is covering
            var target = a.target
            let res = TargetResolver.resolve(target, in: snap)
            r.resolution = res.state
            events(.targetResolved(a.target.description, res.state))
            if snap.hasModal, let e = res.element, !e.inModal {
                let d = snap.windows.first { $0.isModal || $0.isSheet }
                return finish(&r, .modalPresent, detail: "a dialog (“\((d?.title ?? "").prefix(40))”) is open and covers “\(e.title.prefix(40))”. It must be dealt with first.")
            }
            guard res.state.isActionable, let el = res.element else {
                if snap.hasModal, res.state == .notFound {
                    let d = snap.windows.first { $0.isModal || $0.isSheet }
                    return finish(&r, .modalPresent, detail: "a dialog (“\((d?.title ?? "").prefix(40))”) is open and “\((a.target.title ?? a.target.description).prefix(40))” is not in it. The dialog must be dealt with first; JARVIS does not click the window underneath.")
                }
                if res.state == .ambiguous { return finish(&r, .ambiguous, detail: res.reason + ": " + res.candidates.prefix(3).map { "\($0.role) “\($0.title.prefix(24))” in \($0.ancestorTitles.first ?? "?")" }.joined(separator: "; ")) }
                // not exposed through Accessibility: the window-scoped vision fallback, if it is on and allowed
                if a.target.title != nil, visionAllowed(), (a.target.role == nil || a.target.role == "button") {
                    events(.visionFallback("“\((a.target.title ?? "").prefix(30))” is not exposed through Accessibility"))
                    var v = a
                    v.kind = .visionPress
                    var sub = Run(started: r.started, action: v)
                    sub.app = app; sub.attempts = r.attempts
                    return await visionPress(&sub)
                }
                lastError = res.reason
                if attempt <= maxRetries { await pause(0.4); continue }
                return finish(&r, .notFound, detail: lastError)
            }
            target.title = el.title
            r.target = "\(el.role.replacingOccurrences(of: "AX", with: "")) “\(el.title.prefix(40))”"
            if el.isSecure { return finish(&r, .blocked, detail: "this is a secure field — enter it yourself", category: .interactionRequired) }
            guard el.enabled else { return finish(&r, .failed, detail: "“\(el.title.prefix(40))” is disabled") }
            let ctx = context(app: app, snap: snap, element: el)
            let assessment = ComputerPolicy.assess(a, in: ctx)
            r.assessment = assessment
            switch assessment.verdict {
            case .blocked(let why, let cat): events(.blocked(why)); return finish(&r, .blocked, detail: why, category: cat)
            case .needsApproval(let prompt):
                let fp = ActionFingerprint.of(el, in: snap)
                if approved?.role != fp.role || approved?.title != fp.title || approved?.windowTitle != fp.windowTitle {
                    guard await ask(&r, assessment, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "not approved") }
                    approved = fp
                    continue                                                      // re-observe: the world may have changed while waiting
                }
            case .allow: break
            }
            guard await yieldToUser(&r, app: app) else { return finish(&r, .userInterference, detail: "you were typing or clicking in \(app.name); JARVIS stepped back") }
            // fingerprint: still the same control right before acting?
            let fp = ActionFingerprint.of(el, in: snap)
            if let fresh = try? await backend.snapshot(pid: app.pid, scope: sc.scope, budget: AXBudget()), let again = TargetResolver.resolve(target, in: fresh).element {
                if case .stale(let why) = fp.stillValid(in: fresh, element: again) { events(.targetResolved("\(el.title)", .stale)); lastError = why; if attempt <= maxRetries { continue }; return finish(&r, .stale, detail: why) }
                lastSnapshot = fresh
                return await actOnElement(&r, app: app, element: again, before: fresh, assessment: assessment)
            }
            return await actOnElement(&r, app: app, element: el, before: snap, assessment: assessment)
        }
        return finish(&r, .notFound, detail: lastError)
    }

    private func actOnElement(_ r: inout Run, app: ApplicationSnapshot, element el: UIElementSnapshot, before: AXSnapshot, assessment: ActionAssessment) async -> ActionResult {
        let a = r.action
        let idem = ComputerPolicy.idempotency(of: a, consequence: assessment.consequence)
        let checks = effectiveChecks(a)
        var attempts = 0
        var currentElement = el
        var currentBefore = before
        for _ in 0...(maxRetries + 1) {
            if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
            attempts += 1; r.attempts = max(r.attempts, attempts)
            do {
                let short = ComputerPolicy.shortRole(currentElement.role)
                if currentElement.actions.contains("Press") { try await backend.perform(.press, on: currentElement.handle) }
                else if ["row", "outlinerow", "cell", "radiobutton", "tab"].contains(short) { try await backend.perform(.select, on: currentElement.handle) }
                else if currentElement.actions.contains("Confirm") { try await backend.perform(.confirm, on: currentElement.handle) }
                else { try await backend.perform(.press, on: currentElement.handle) }
            } catch let e as BackendError {
                // what the world looked like when the action was refused (bundle ids and numbers only): the evidence for JARVIS-V13-7
                let front = await backend.frontmostApplication()
                let world = " [frontmost \(front?.bundleID ?? "?")\(front?.pid == app.pid ? " = target" : " ≠ target"); input idle \({ let t = activity.secondsSinceAnyPointerOrKeyInput(); return t.isFinite ? "\(Int(t)) s" : "no activity probe" }())]"
                // JARVIS-V13-7: an Accessibility ACTION's return code is not its outcome. An application can report "not supported / not implemented" for a press that its handler nevertheless ran
                // (the fixture counted the click). So an "unsupported" answer is never taken at face value in either direction: the state the action was meant to produce is looked for (read-only,
                // short), and the action is NEVER repeated (it may already have happened).
                if case .unsupported = e {
                    // no snapshot ⇒ no evidence (verify() would call an unreadable UI "unchanged-OK"; here an unreadable UI proves nothing)
                    let readable = (try? await snapshot(of: app)) != nil
                    let seen = readable ? await verify(checks, app: app, before: currentBefore, timeout: unsupportedLookTimeout, windowTitle: a.target.windowTitle) : VerificationResult(passed: false, checks: [], detail: "the UI could not be read")
                    if seen.passed && !seen.checks.isEmpty {
                        r.verification = seen
                        return finish(&r, .verified, detail: "pressed “\(el.title.prefix(40))”: the application answered “\(e)” but the expected state was observed, so the press took effect (not repeated)" + world)
                    }
                    return finish(&r, .failed, detail: "\(e)" + world + " — and the expected state was not observed either")
                }
                return finish(&r, e == .timedOut ? .appUnresponsive : e == .permissionDenied ? .permissionRequired : .failed, detail: "\(e)" + world)
            } catch { return finish(&r, .failed, detail: "\(error)") }
            events(.actionExecuted(a.summary, .accessibility))
            let v = await verify(checks, app: app, before: currentBefore, windowTitle: a.target.windowTitle)
            r.verification = v
            if v.passed { return finish(&r, .verified, detail: "pressed “\(el.title.prefix(40))” and verified") }
            if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
            // retry only what is safe to repeat, only while the target is still the same, within the budget
            guard attempts <= maxRetries, idem != .unsafe, assessment.consequence != .quit else { return finish(&r, .notVerified, detail: v.detail) }
            guard let fresh = try? await snapshot(of: app), let again = TargetResolver.resolve(a.target, in: fresh).element, ActionFingerprint.of(el, in: before).stillValid(in: fresh, element: again) == .fresh else {
                return finish(&r, .notVerified, detail: v.detail + " (the control changed, so JARVIS did not repeat the action)")
            }
            if idem == .verifyFirst, await verify(checks, app: app, before: currentBefore, timeout: 0.01, windowTitle: a.target.windowTitle).passed { r.verification = VerificationResult(passed: true, checks: v.checks, detail: "the state had already changed"); return finish(&r, .verified, detail: "verified") }
            currentElement = again; currentBefore = fresh
        }
        return finish(&r, .notVerified, detail: "the retry budget ended without the expected state")
    }

    private var stateProbe = ""

    private func effectiveChecks(_ a: ComputerAction) -> [Check] { a.checks.isEmpty && !a.kind.isReadOnly ? [.stateChanged] : a.checks }

    // MARK: Menus

    private func selectMenu(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard let app = await findApp(a.target.app) else { return finish(&r, .notFound, detail: "\(a.target.app.display) is not running") }
        r.app = app
        if await backend.frontmostApplication()?.pid != app.pid {
            _ = await backend.activateApplication(pid: app.pid)
            _ = await waitUntil(windowTimeout) { await self.backend.frontmostApplication()?.pid == app.pid }
        }
        guard await backend.isResponsive(pid: app.pid) else { return finish(&r, .appUnresponsive, detail: "\(app.name) is not responding") }
        var path = a.target.menuPath
        guard !path.isEmpty else { return finish(&r, .failed, detail: "no menu path") }
        let before = try? await snapshot(of: app)
        do {
            if path.first == "@app" {
                let titles = try await backend.menuBarTitles(pid: app.pid)
                guard titles.count > 1 else { return finish(&r, .notFound, detail: "the application menu was not found") }
                path[0] = titles[1]
            }
            // resolve each level against the real menu (folded titles, "…" ignored); settings/preferences and similar spellings are tolerated
            var resolved: [String] = []
            for (i, want) in path.enumerated() {
                let items: [MenuItemSnapshot] = i == 0 ? (try await backend.menuBarTitles(pid: app.pid)).map { MenuItemSnapshot(title: $0, enabled: true, hasSubmenu: true, isSeparator: false, checked: false) } : try await backend.menuItems(pid: app.pid, path: resolved)
                let wanted = Self.menuSynonyms(want)
                let hit = items.first { it in wanted.contains(ComputerText.menuKey(it.title)) }
                guard let h = hit else { events(.targetResolved(path.joined(separator: " → "), .notFound)); return finish(&r, .notFound, detail: "no menu item “\(want)” under \(resolved.joined(separator: " → ").isEmpty ? "the menu bar" : resolved.joined(separator: " → "))") }
                guard h.enabled else { return finish(&r, .failed, detail: "the menu item “\(h.title)” is disabled") }
                resolved.append(h.title)
            }
            r.resolution = .exact; r.target = resolved.joined(separator: " → ")
            events(.targetResolved(r.target, .exact))
            let assessment = ComputerPolicy.assess(a, in: ActionPolicyContext(bundleID: app.bundleID, windowTitle: before?.window?.title, element: nil, modalPresent: before?.hasModal ?? false, quarantineRoot: quarantineRoot).withMenuLeaf(resolved.last ?? ""))
            r.assessment = assessment
            switch assessment.verdict {
            case .blocked(let why, let cat): events(.blocked(why)); return finish(&r, .blocked, detail: why, category: cat)
            case .needsApproval(let prompt): guard await ask(&r, assessment, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "not approved") }
            case .allow: break
            }
            guard await yieldToUser(&r, app: app) else { return finish(&r, .userInterference, detail: "you were typing or clicking; JARVIS stepped back") }
            if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
            r.attempts = 1
            try await backend.pressMenuPath(pid: app.pid, path: resolved)
            events(.actionExecuted(a.summary, .accessibility))
        } catch let e as BackendError { return finish(&r, e == .timedOut ? .appUnresponsive : e == .permissionDenied ? .permissionRequired : e == .elementGone ? .notFound : .failed, detail: "\(e)") }
        catch { return finish(&r, .failed, detail: "\(error)") }
        let v = await verify(effectiveChecks(a), app: app, before: before, windowTitle: a.target.windowTitle)
        r.verification = v
        return v.passed ? finish(&r, .verified, detail: "chose \(r.target)") : finish(&r, .notVerified, detail: v.detail)
    }

    static func menuSynonyms(_ want: String) -> Set<String> {
        let k = ComputerText.menuKey(want)
        switch k {
        case "settings", "preferences", "ayarlar", "tercihler": return ["settings", "preferences", "system settings", "ayarlar", "tercihler"]
        case "quit": return ["quit", "cik"]
        default: return [k]
        }
    }

    // MARK: Text

    private func fieldTarget(_ r: inout Run) async -> (ApplicationSnapshot, AXSnapshot, UIElementSnapshot)? {
        let a = r.action
        guard let app = await findApp(a.target.app) else { _ = finish(&r, .notFound, detail: "\(a.target.app.display) is not running"); return nil }
        r.app = app
        let sc = await scope(for: app, windowTitle: a.target.windowTitle)
        if let st = sc.state, !st.isActionable { r.resolution = st; return nil }
        guard let snap = try? await snapshot(of: app, scope: sc.scope) else { return nil }
        r.window = snap.window?.title
        let res = TargetResolver.resolve(a.target, in: snap)
        r.resolution = res.state
        events(.targetResolved(a.target.description, res.state))
        if res.state == .notFound, a.target.title == nil, a.target.role == nil, let f = snap.focusedElement.flatMap({ i in snap.elements.first { $0.id == i } }) { return (app, snap, f) }
        guard res.state.isActionable, let el = res.element else { return nil }
        return (app, snap, el)
    }

    private func setText(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard let text = a.text else { return finish(&r, .failed, detail: "no text") }
        r.textClass = TextPolicy.classify(text); r.textLength = text.count
        guard let (app, snap, el) = await fieldTarget(&r) else {
            if r.resolution == .ambiguous { return finish(&r, .ambiguous, detail: "more than one field matches") }
            return finish(&r, .notFound, detail: "the text field was not found")
        }
        r.target = "\(el.role.replacingOccurrences(of: "AX", with: "")) “\(el.title.prefix(40))”"
        let ctx = context(app: app, snap: snap, element: el)
        let assessment = ComputerPolicy.assess(a, in: ctx)
        r.assessment = assessment
        switch assessment.verdict {
        case .blocked(let why, let cat): events(.blocked(why)); return finish(&r, .blocked, detail: why, category: cat)
        case .needsApproval(let prompt): guard await ask(&r, assessment, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "not approved") }
        case .allow: break
        }
        guard ["textfield", "textarea", "combobox", "searchfield"].contains(ComputerPolicy.shortRole(el.role)) else { return finish(&r, .failed, detail: "the target is not a text field") }
        guard await yieldToUser(&r, app: app) else { return finish(&r, .userInterference, detail: "you were typing; JARVIS stepped back") }
        r.attempts = 1
        do {
            try? await backend.perform(.focus, on: el.handle)
            do { try await backend.setValue(text, on: el.handle) }
            catch BackendError.unsupported { // the control does not accept a direct value: type it (select-all first, replacing the content)
                try await backend.postKey(KeyChord("a", [.command]), toPID: app.pid)
                try await backend.typeText(text, toPID: app.pid, shouldContinue: { [stop] in !stop.isStopped })
            }
            events(.actionExecuted(a.summary, .accessibility))
        } catch let e as BackendError { return finish(&r, e == .secureField ? .blocked : .failed, detail: "\(e)", category: e == .secureField ? .interactionRequired : nil) } catch { return finish(&r, .failed, detail: "\(error)") }
        if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
        // verify by reading it back (only possible for non-secure fields, which is all we ever touch)
        var readBack: String?
        let ok = await waitUntil(verifyTimeout) { readBack = (try? await self.backend.readValue(el.handle)) ?? nil; return readBack == text }
        r.verification = VerificationResult(passed: ok, checks: ["the field holds the \(text.count) typed characters"], detail: ok ? "value matches" : "the field's value differs from what was entered")
        return ok ? finish(&r, .verified, detail: "text entered (\(text.count) characters)") : finish(&r, .notVerified, detail: "the field's value does not match what was entered")
    }

    private func typeText(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard let text = a.text else { return finish(&r, .failed, detail: "no text") }
        r.textClass = TextPolicy.classify(text); r.textLength = text.count
        guard let app = await findApp(a.target.app) else { return finish(&r, .notFound, detail: "\(a.target.app.display) is not running") }
        r.app = app
        guard await backend.frontmostApplication()?.pid == app.pid else { return finish(&r, .stale, detail: "\(app.name) is not in front; JARVIS will not type into another application") }
        guard let snap = try? await snapshot(of: app), let f = snap.focusedElement.flatMap({ i in snap.elements.first { $0.id == i } }) else { return finish(&r, .notFound, detail: "no text field has the focus") }
        guard ["textfield", "textarea", "combobox", "searchfield"].contains(ComputerPolicy.shortRole(f.role)) else { return finish(&r, .failed, detail: "the focused element is not a text field") }
        r.window = snap.window?.title; r.target = "focused \(f.role.replacingOccurrences(of: "AX", with: "")) “\(f.title.prefix(30))”"
        let assessment = ComputerPolicy.assess(a, in: context(app: app, snap: snap, element: f))
        r.assessment = assessment
        switch assessment.verdict {
        case .blocked(let why, let cat): events(.blocked(why)); return finish(&r, .blocked, detail: why, category: cat)
        case .needsApproval(let prompt): guard await ask(&r, assessment, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "not approved") }
        case .allow: break
        }
        guard await yieldToUser(&r, app: app) else { return finish(&r, .userInterference, detail: "you were typing; JARVIS stepped back") }
        r.attempts = 1
        do { try await backend.typeText(text, toPID: app.pid, shouldContinue: { [stop] in !stop.isStopped }) }
        catch let e as BackendError { return finish(&r, .failed, detail: "\(e)") } catch { return finish(&r, .failed, detail: "\(error)") }
        if stop.isStopped { return finish(&r, .cancelled, detail: "stopped; no further keys were sent") }
        events(.actionExecuted(a.summary, .accessibility))
        let ok = await waitUntil(verifyTimeout) { (try? await self.backend.readValue(f.handle)).flatMap { $0 }?.contains(text) == true }
        r.verification = VerificationResult(passed: ok, checks: ["the field contains the typed text"], detail: ok ? "typed" : "the typed text was not seen in the field")
        return ok ? finish(&r, .verified, detail: "typed \(text.count) characters") : finish(&r, .notVerified, detail: "the typed text was not seen in the field")
    }

    // MARK: Keys

    private func pressKey(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard let chord = a.chord else { return finish(&r, .failed, detail: "no key") }
        guard let app = await findApp(a.target.app) else { return finish(&r, .notFound, detail: "\(a.target.app.display) is not running") }
        r.app = app
        guard await backend.frontmostApplication()?.pid == app.pid else { return finish(&r, .stale, detail: "\(app.name) is not in front; keys go only to the application they were planned for") }
        let before = try? await snapshot(of: app)
        r.window = before?.window?.title
        let assessment = ComputerPolicy.assess(a, in: context(app: app, snap: before, element: before?.focusedElement.flatMap { i in before?.elements.first { $0.id == i } }))
        r.assessment = assessment
        switch assessment.verdict {
        case .blocked(let why, let cat): events(.blocked(why)); return finish(&r, .blocked, detail: why, category: cat)
        case .needsApproval(let prompt): guard await ask(&r, assessment, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "not approved") }
        case .allow: break
        }
        guard await yieldToUser(&r, app: app) else { return finish(&r, .userInterference, detail: "you were typing; JARVIS stepped back") }
        if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
        r.attempts = 1
        do { try await backend.postKey(chord, toPID: app.pid) } catch let e as BackendError { return finish(&r, .failed, detail: "\(e)") } catch { return finish(&r, .failed, detail: "\(error)") }
        events(.actionExecuted(a.summary, .accessibility))
        let v = await verify(effectiveChecks(a), app: app, before: before, windowTitle: a.target.windowTitle)
        r.verification = v
        return v.passed ? finish(&r, .verified, detail: "pressed \(chord.display)") : finish(&r, .notVerified, detail: v.detail)
    }

    // MARK: Scroll (bounded)

    private func scroll(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard let app = await findApp(a.target.app) else { return finish(&r, .notFound, detail: "\(a.target.app.display) is not running") }
        r.app = app
        let spec = a.scroll ?? ScrollSpec()
        let limit = min(max(1, spec.maxAttempts), ComputerLimits.maxScrollAttempts)
        var snap: AXSnapshot
        let sc = await scope(for: app, windowTitle: a.target.windowTitle)
        if let st = sc.state, !st.isActionable { r.resolution = st; return finish(&r, st == .ambiguous ? .ambiguous : .notFound, detail: sc.reason ?? "the window was not found") }
        do { snap = try await snapshot(of: app, scope: sc.scope) } catch { return finish(&r, .failed, detail: "\(error)") }
        r.window = snap.window?.title
        func area(_ s: AXSnapshot) -> UIElementSnapshot? {
            if let t = a.target.within {
                let hit = s.elements.first { ComputerPolicy.shortRole($0.role) == "scrollarea" && ($0.title.localizedCaseInsensitiveContains(t) || $0.ancestorTitles.contains { $0.localizedCaseInsensitiveContains(t) }) }
                if hit != nil { return hit }
            }
            return s.elements.first { ComputerPolicy.shortRole($0.role) == "scrollarea" && $0.frame != nil }
        }
        guard let scrollArea = area(snap), let frame = scrollArea.frame else { return finish(&r, .notFound, detail: "no scroll area in the window") }
        r.target = "scroll area"
        // what are we looking for? (a labelled element becoming visible, or simply "the content moved")
        let wantTitle = a.target.title
        /// An element that exists in the tree is not necessarily VISIBLE: it must lie (mostly) inside the scroll area's current frame.
        func visible(_ e: UIElementSnapshot, in s: AXSnapshot) -> Bool {
            guard let ef = e.frame else { return true }
            guard let af = (area(s)?.frame) ?? scrollArea.frame else { return true }
            let overlap = ef.intersection(af)
            return !overlap.isNull && overlap.height >= ef.height * 0.6 && overlap.width >= min(ef.width, af.width) * 0.3
        }
        func found(_ s: AXSnapshot) -> UIElementSnapshot? {
            guard let t = wantTitle else { return nil }
            var tgt = a.target; tgt.title = t; tgt.within = nil
            let res = TargetResolver.resolve(tgt, in: s)
            guard res.state.isActionable, let e = res.element, visible(e, in: s) else { return nil }
            return e
        }
        /// The element exists but is scrolled out of view: ask the application to bring it into view natively first (AXScrollToVisible).
        func existsOffscreen(_ s: AXSnapshot) -> UIElementSnapshot? {
            guard let t = wantTitle else { return nil }
            var tgt = a.target; tgt.title = t; tgt.within = nil
            let res = TargetResolver.resolve(tgt, in: s)
            return res.state.isActionable ? res.element : nil
        }
        if let hit = found(snap) { r.verification = VerificationResult(passed: true, checks: ["“\(hit.title.prefix(30))” is visible"], detail: "already visible"); r.attempts = 0; return finish(&r, .verified, detail: "already visible") }
        guard await yieldToUser(&r, app: app) else { return finish(&r, .userInterference, detail: "you were scrolling or typing; JARVIS stepped back") }
        // 1. the native way: the element exists but is scrolled out of view → move the scroll area's own scroll bar by the distance the geometry says (one jump, then verify)
        func extent(_ s: AXSnapshot, _ a: UIElementSnapshot) -> CGFloat? {
            guard !a.title.isEmpty else { return nil }
            let inside = s.elements.filter { $0.id != a.id && $0.ancestorTitles.contains(a.title) }.compactMap(\.frame)
            guard let lo = inside.map(\.minY).min(), let hi = inside.map(\.maxY).max() else { return nil }
            return hi - lo
        }
        if !snap.truncated, let off = existsOffscreen(snap), let ef = off.frame, let content = extent(snap, scrollArea), content > frame.height {     // (a bounded tree cannot tell how long the content is)
            r.attempts = 1
            let needed = Double((ef.midY - frame.midY) / (content - frame.height))
            if abs(needed) > 0.001, (try? await backend.scrollBy(scrollArea.handle, direction: needed > 0 ? .down : .up, step: abs(needed))) != nil {
                events(.actionExecuted("Scroll “\(off.title.prefix(24))” into view", .accessibility))
                var seen: UIElementSnapshot?
                let ok = await waitUntil(verifyTimeout) { if let s2 = try? await self.snapshot(of: app, scope: sc.scope), let e = found(s2) { seen = e; return true }; return false }
                if ok, let seen { r.verification = VerificationResult(passed: true, checks: ["“\(seen.title.prefix(30))” is visible"], detail: "scrolled into view through the scroll bar"); return finish(&r, .verified, detail: "the scroll bar brought “\(seen.title.prefix(30))” into view") }
            }
        }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var lastHash = snap.hash(includeFrames: true)
        for i in 1...limit {
            if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
            r.attempts = i
            // the native way first: the scroll area's own scroll bar; synthetic wheel events only when it has none
            var scrolledNatively = false
            if let ar = area(snap) {
                if let _ = try? await backend.scrollBy(ar.handle, direction: spec.direction, step: 0.12) { scrolledNatively = true }
            }
            if !scrolledNatively {
                do { try await backend.postScroll(direction: spec.direction, lines: 8, atGlobal: centre, toPID: app.pid) } catch { return finish(&r, .failed, detail: "\(error)") }
            }
            events(.actionExecuted("Scroll \(spec.direction.rawValue) \(i)/\(limit)", .accessibility))
            await pause(0.15)
            guard let now = try? await snapshot(of: app, scope: sc.scope) else { return finish(&r, .failed, detail: "could not observe after scrolling") }
            snap = now
            if let hit = found(now) {
                r.verification = VerificationResult(passed: true, checks: ["“\(hit.title.prefix(30))” found after \(i) scroll(s)"], detail: "found")
                return finish(&r, .verified, detail: "found after \(i) scroll\(i == 1 ? "" : "s")")
            }
            if now.hash(includeFrames: true) == lastHash {                                      // nothing moved: the end of the content — stop, do not keep scrolling
                r.verification = VerificationResult(passed: wantTitle == nil && i > 1, checks: ["the content stopped moving"], detail: "the end of the content")
                return wantTitle == nil ? finish(&r, i > 1 ? .verified : .notVerified, detail: "reached the end of the content") : finish(&r, .notFound, detail: "“\(wantTitle ?? "")” was not found before the content ended")
            }
            lastHash = now.hash(includeFrames: true)
        }
        if wantTitle == nil { r.verification = VerificationResult(passed: true, checks: ["scrolled \(limit) time(s)"], detail: "scrolled"); return finish(&r, .verified, detail: "scrolled \(limit) times") }
        return finish(&r, .notFound, detail: "“\(wantTitle ?? "")” was not found within \(limit) scroll steps")
    }

    // MARK: Files & Settings (typed destinations)

    private func openOrReveal(_ r: inout Run) async -> ActionResult {
        let a = r.action
        let verdict = ComputerPathPolicy.validate(a.path ?? "", quarantineRoot: quarantineRoot, forReveal: a.kind == .revealFile)
        guard case .allowed(let real) = verdict else { if case .refused(let why) = verdict { return finish(&r, .blocked, detail: why) }; return finish(&r, .blocked, detail: "path refused") }
        r.target = (real as NSString).lastPathComponent
        r.attempts = 1
        let name = (real as NSString).lastPathComponent
        do {
            if a.kind == .revealFile { try await backend.revealInFinder(path: real) }
            else { try await backend.openFile(path: real, withBundleID: a.target.app.bundleID) }
        } catch let e as BackendError { return finish(&r, .failed, detail: "\(e)") } catch { return finish(&r, .failed, detail: "\(error)") }
        events(.actionExecuted(a.summary, .accessibility))
        var app: ApplicationSnapshot?
        let want = a.kind == .revealFile ? AppRef(bundleID: SurfacePolicy.finder, name: "Finder") : (a.target.app.bundleID != nil ? a.target.app : AppRef())
        let ok = await waitUntil(windowTimeout, initial: 0.15) {
            app = want.bundleID != nil ? await self.findApp(want) : await self.backend.frontmostApplication()
            guard let app else { return false }
            guard await self.backend.frontmostApplication()?.pid == app.pid else { return false }
            if a.kind == .revealFile || a.target.app.bundleID != nil {
                let wins = await self.backend.windows(pid: app.pid)
                let base = ComputerText.fold(name.replacingOccurrences(of: ".xcodeproj", with: "").replacingOccurrences(of: ".xcworkspace", with: ""))
                return wins.contains { ComputerText.fold($0.title).contains(base) } || (a.kind == .openFile && !wins.isEmpty && ComputerText.fold(a.path ?? "").contains("package.swift") )
            }
            return true
        }
        r.app = app
        r.verification = VerificationResult(passed: ok, checks: a.kind == .revealFile ? ["Finder shows “\(name.prefix(40))”"] : ["the file is open in the application"], detail: ok ? "visible" : "the expected window did not appear")
        return ok ? finish(&r, .verified, detail: a.kind == .revealFile ? "Finder shows it" : "opened") : finish(&r, .notVerified, detail: "the window for “\(name.prefix(40))” did not appear in time")
    }

    private func openPane(_ r: inout Run) async -> ActionResult {
        guard let pane = r.action.pane else { return finish(&r, .failed, detail: "no pane") }
        r.target = "System Settings · \(pane.titleHint)"
        r.attempts = 1
        do { try await backend.openSettingsPane(pane) } catch { return finish(&r, .failed, detail: "\(error)") }
        events(.actionExecuted(r.action.summary, .accessibility))
        var app: ApplicationSnapshot?
        let ok = await waitUntil(windowTimeout, initial: 0.2) {
            app = await self.findApp(AppRef(bundleID: SurfacePolicy.systemSettings, name: "System Settings"))
            guard let app, await self.backend.frontmostApplication()?.pid == app.pid else { return false }
            return !(await self.backend.windows(pid: app.pid)).isEmpty
        }
        r.app = app
        r.verification = VerificationResult(passed: ok, checks: ["System Settings is frontmost with a window"], detail: ok ? "open" : "System Settings did not come to the front")
        return ok ? finish(&r, .verified, detail: "opened the \(pane.titleHint) pane (JARVIS does not change any setting)") : finish(&r, .notVerified, detail: "System Settings did not appear in time")
    }

    // MARK: Screen (vision fallback)

    private func targetWindow(_ app: ApplicationSnapshot, title: String?) async -> (WindowSnapshot, [WindowSnapshot])? {
        let wins = await backend.windows(pid: app.pid)
        let res = TargetResolver.resolveWindow(title: title, in: wins)
        guard res.state.isActionable, let w = res.window else { return nil }
        return (w, wins)
    }

    private func observeScreen(_ app: ApplicationSnapshot, window w: WindowSnapshot) async throws -> (ScreenObservation, CapturedWindow) {
        guard backend.screenCaptureAllowed() else { throw BackendError.captureUnavailable("Screen Recording permission is not granted") }
        guard let id = w.cgWindowID, !w.isMinimized else { throw BackendError.captureUnavailable("the window is not visible") }
        let cap = try await backend.captureWindow(cgWindowID: id, windowFrame: w.frame)
        let obs = ScreenObservation(pid: app.pid, bundleID: app.bundleID, windowTitle: w.title, windowFrame: w.frame, cgWindowID: id, scale: cap.scale,
                                    pixelSize: CGSize(width: cap.image.width, height: cap.image.height), capturedAt: cap.capturedAt, fingerprint: cap.fingerprint, generation: (lastScreen?.generation ?? 0) + 1)
        lastScreen = obs
        screenObserved(obs)
        return (obs, cap)
    }

    private func captureAction(_ r: inout Run) async -> ActionResult {
        guard visionAllowed() else { return finish(&r, .blocked, detail: "the vision fallback is off or unavailable (Settings → Computer Use, or memory pressure)") }
        guard backend.screenCaptureAllowed() else { events(.permissionMissing("Screen Recording")); return finish(&r, .permissionRequired, detail: "Screen Recording permission is required for window screenshots. Open System Settings → Privacy & Security → Screen & System Audio Recording.") }
        guard let app = await findApp(r.action.target.app), let (w, _) = await targetWindow(app, title: r.action.target.windowTitle) else { return finish(&r, .notFound, detail: "no window to capture") }
        r.app = app; r.window = w.title; r.mechanism = .vision; r.attempts = 1
        do {
            let (obs, _) = try await observeScreen(app, window: w)
            r.verification = VerificationResult(passed: true, checks: ["captured one window (\(Int(obs.pixelSize.width))×\(Int(obs.pixelSize.height)) px, memory only)"], detail: "captured")
            return finish(&r, .verified, detail: "captured “\(w.title.prefix(40))” — \(Int(obs.pixelSize.width))×\(Int(obs.pixelSize.height)) px, not stored")
        } catch { return finish(&r, .failed, detail: "\(error)") }
    }

    private func visionPress(_ r: inout Run) async -> ActionResult {
        let a = r.action
        guard visionAllowed() else { return finish(&r, .blocked, detail: "the vision fallback is off or unavailable (Settings → Computer Use, or memory pressure)") }
        guard backend.screenCaptureAllowed() else { events(.permissionMissing("Screen Recording")); return finish(&r, .permissionRequired, detail: "Screen Recording permission is required for the vision fallback.") }
        guard let label = a.target.title, !label.isEmpty else { return finish(&r, .failed, detail: "the vision fallback needs a visible label to look for") }
        var found = r.app
        if found == nil { found = await findApp(a.target.app) }
        guard let app = found else { return finish(&r, .notFound, detail: "\(a.target.app.display) is not running") }
        r.app = app
        if SurfacePolicy.isCredentialApp(app.bundleID) { return finish(&r, .blocked, detail: "password managers are not captured", category: .interactionRequired) }
        if await backend.frontmostApplication()?.pid != app.pid {
            _ = await backend.activateApplication(pid: app.pid)
            _ = await waitUntil(windowTimeout) { await self.backend.frontmostApplication()?.pid == app.pid }
        }
        var lastWhy = ""
        await vision.prepare(label: label)                                    // a cold model loads BEFORE the picture is taken (never counted against the screenshot's age)
        for attempt in 1...2 {                                                // a stale screen is re-observed once, never clicked
            if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
            r.attempts = attempt
            guard let (w, _) = await targetWindow(app, title: a.target.windowTitle) else { return finish(&r, .notFound, detail: "no visible window to look at") }
            r.window = w.title
            let obs: ScreenObservation, cap: CapturedWindow
            do { (obs, cap) = try await observeScreen(app, window: w) } catch { return finish(&r, .failed, detail: "\(error)") }
            r.mechanism = .vision
            let proposals = await vision.propose(label: label, image: cap.image, scale: cap.scale)
            events(.visionFallback("looked for “\(label.prefix(30))” with \(vision.name): \(proposals.count) candidate\(proposals.count == 1 ? "" : "s")"))
            guard !proposals.isEmpty else { return finish(&r, .notFound, detail: "“\(label.prefix(40))” was not found in the window screenshot") }
            guard proposals.count == 1 else { r.resolution = .ambiguous; return finish(&r, .ambiguous, detail: "\(proposals.count) places in the window match “\(label.prefix(30))”") }
            let p = proposals[0]
            r.resolution = .strong; r.target = "“\(p.label.prefix(30))” (vision)"
            // policy: the SAME consequence rules, on the recognised text (it is untrusted text like any other)
            let assessment = ComputerPolicy.assess(a, in: ActionPolicyContext(bundleID: app.bundleID, windowTitle: w.title, element: nil, contextTexts: [w.title], quarantineRoot: quarantineRoot).withLabel(p.label))
            r.assessment = assessment
            switch assessment.verdict {
            case .blocked(let why, let cat): events(.blocked(why)); return finish(&r, .blocked, detail: why, category: cat)
            case .needsApproval(let prompt):
                if r.approvalID == nil { guard await ask(&r, assessment, prompt: prompt) else { return finish(&r, .approvalDenied, detail: "not approved") }; continue }
            case .allow: break
            }
            // coordinates: window-relative → global, validated; then the screen must STILL be the one the proposal came from
            let layout = backend.displays()
            guard case .ok(let global) = Coordinates.clickPoint(relative: Coordinates.centre(of: p.box), windowFrame: obs.windowFrame, layout: layout) else {
                if case .refused(let why) = Coordinates.clickPoint(relative: Coordinates.centre(of: p.box), windowFrame: obs.windowFrame, layout: layout) { return finish(&r, .blocked, detail: why) }
                return finish(&r, .blocked, detail: "the point was refused")
            }
            var nowFingerprint: UInt64?
            if let cid = obs.cgWindowID { nowFingerprint = (try? await backend.captureWindow(cgWindowID: cid, windowFrame: obs.windowFrame))?.fingerprint }
            let windowsNow = await backend.windows(pid: app.pid)
            let verdict = StaleCheck.validate(obs, currentWindow: windowsNow.first { $0.cgWindowID == obs.cgWindowID } ?? windowsNow.first { $0.title == obs.windowTitle },
                                              frontmostPID: await backend.frontmostApplication()?.pid, currentFingerprint: nowFingerprint)
            if case .stale(let why) = verdict { events(.targetResolved(label, .stale)); r.resolution = .stale; lastWhy = why; continue }
            // occlusion: the click goes to whatever window is on top at that point — it must be the one that was captured
            if let expected = obs.cgWindowID, await backend.topWindowID(atGlobal: global) != expected {
                events(.targetResolved(label, .stale)); r.resolution = .stale; lastWhy = "another window covers that part of \(app.name)"; continue
            }
            // a coordinate click moves the pointer: not while the user is using the mouse or the keyboard
            var calm = false
            for _ in 0..<Int(interferenceWait / 0.15) + 1 { if activity.secondsSinceAnyPointerOrKeyInput() >= interferenceGrace { calm = true; break }; if stop.isStopped { break }; events(.userInterference("you are using the mouse or keyboard")); await pause(0.15) }
            guard calm else { return finish(&r, stop.isStopped ? .cancelled : .userInterference, detail: stop.isStopped ? "stopped" : "you were using the mouse or keyboard; JARVIS stepped back") }
            if stop.isStopped { return finish(&r, .cancelled, detail: "stopped") }
            r.mechanism = .rawCoordinates
            do { try await backend.postClick(atGlobal: global) } catch { return finish(&r, .failed, detail: "\(error)") }
            events(.actionExecuted(a.summary, .rawCoordinates))
            // verify: the declared postcondition, or at least that the window changed
            let beforeSnap = lastSnapshot
            var checks = a.checks
            if checks.isEmpty { checks = [.stateChanged] }
            var v = await verify(checks.filter { $0 != .stateChanged }, app: app, before: beforeSnap)
            if checks.contains(.stateChanged) || v.checks.isEmpty {
                let changed = await waitUntil(verifyTimeout) {
                    guard let id = obs.cgWindowID, let c = try? await self.backend.captureWindow(cgWindowID: id, windowFrame: obs.windowFrame) else { return false }
                    return (c.fingerprint ^ obs.fingerprint).nonzeroBitCount > 0
                }
                v = VerificationResult(passed: v.passed && (changed || !v.checks.isEmpty), checks: v.checks + ["the window content changed"], detail: v.detail)
            }
            r.verification = v
            return v.passed ? finish(&r, .verified, detail: "pressed “\(p.label.prefix(30))” through the window-scoped vision fallback") : finish(&r, .notVerified, detail: v.detail)
        }
        r.resolution = .stale
        return finish(&r, .stale, detail: "the window changed under JARVIS twice (\(lastWhy)); it will not click on an old screenshot")
    }

    // MARK: Verification

    func verify(_ checks: [Check], app: ApplicationSnapshot?, before: AXSnapshot?, timeout: TimeInterval? = nil, windowTitle: String? = nil) async -> VerificationResult {
        guard !checks.isEmpty else { return VerificationResult(passed: true, checks: [], detail: "no postcondition declared") }
        let beforeTitles = Set((before?.windows ?? []).map(\.title))
        let beforeCount = before?.windows.count ?? 0
        let beforeHash = before?.stateHash
        var failures: [String] = []
        var polls = 0
        let started = Date()
        stateProbe = ""
        let ok = await waitUntil(timeout ?? verifyTimeout) {
            polls += 1
            failures = []
            for c in checks { if !(await self.evaluate(c, app: app, beforeTitles: beforeTitles, beforeCount: beforeCount, beforeHash: beforeHash, windowTitle: windowTitle)) { failures.append(c.summary) } }
            return failures.isEmpty
        }
        // A failed verification says WHAT it saw (counts and flags only — no UI text): the root cause of JARVIS-V13-7 was found from exactly this.
        let why = ok ? "" : " [\(polls) poll(s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms; before: \(before?.nodeCount ?? -1) nodes\(before?.truncated == true ? " TRUNCATED" : ""), generation \(before?.generation ?? -1)\(stateProbe.isEmpty ? "" : "; " + stateProbe)]"
        return VerificationResult(passed: ok, checks: checks.map(\.summary), detail: ok ? "all postconditions hold" : "not observed: " + failures.joined(separator: "; ") + why)
    }

    private func evaluate(_ c: Check, app: ApplicationSnapshot?, beforeTitles: Set<String>, beforeCount: Int, beforeHash: Int?, windowTitle: String?) async -> Bool {
        /// element checks look at the SAME window the action was about (an application can have several)
        func look(_ a: ApplicationSnapshot) async -> AXSnapshot? {
            let sc = await scope(for: a, windowTitle: windowTitle)
            return try? await snapshot(of: a, scope: sc.state.map { $0.isActionable } == false ? .modalFirst : sc.scope)
        }
        // a check that names no bundle id means "the application this step is about"
        func target(_ b: String) async -> ApplicationSnapshot? { b.isEmpty ? app : await findApp(AppRef(bundleID: b)) }
        switch c {
        case .appRunning(let b): return await target(b) != nil
        case .appFrontmost(let b): return await backend.frontmostApplication().map { f in b.isEmpty ? f.pid == app?.pid : AppRef(bundleID: b).matches(f) } ?? false
        case .windowExists(let b, let t):
            guard let a = await target(b) else { return false }
            return (await backend.windows(pid: a.pid)).contains { ComputerText.fold($0.title).contains(ComputerText.fold(t)) }
        case .windowGone(let b, let t):
            guard let a = await target(b) else { return true }
            return !(await backend.windows(pid: a.pid)).contains { ComputerText.fold($0.title).contains(ComputerText.fold(t)) }
        case .elementExists(let b, let role, let title):
            guard let a = await target(b), let s = await look(a) else { return false }
            return TargetResolver.resolve(ActionTarget(app: AppRef(bundleID: b), role: role, title: title), in: s).state != .notFound
        case .elementValue(let b, let role, let title, let equals):
            guard let a = await target(b), let s = await look(a) else { return false }
            let res = TargetResolver.resolve(ActionTarget(app: AppRef(bundleID: b), role: role, title: title), in: s)
            guard let e = res.element, !e.isSecure else { return false }
            if e.value == equals { return true }
            let live = (try? await backend.readValue(e.handle)) ?? nil
            return live == equals
        case .elementSelected(let b, let role, let title):
            guard let a = await target(b), let s = await look(a) else { return false }
            let e = TargetResolver.resolve(ActionTarget(app: AppRef(bundleID: b), role: role, title: title), in: s).element
            return (e?.selected ?? false) || e?.value == "1"
        case .stateChanged:
            guard let a = app, let s = await look(a), let h = beforeHash else { return true }
            stateProbe = "after: hash \(s.stateHash == h ? "UNCHANGED" : "changed"), \(s.nodeCount) nodes\(s.truncated ? " TRUNCATED" : ""), \(s.windows.count) window(s), generation \(s.generation)"
            return s.stateHash != h
        case .newWindow(let b):
            guard let a = await target(b) else { return false }
            let now = await backend.windows(pid: a.pid)
            return now.count > beforeCount || now.contains { !beforeTitles.contains($0.title) }
        case .finderShows(let name):
            guard let f = await findApp(AppRef(bundleID: SurfacePolicy.finder, name: "Finder")) else { return false }
            return (await backend.windows(pid: f.pid)).contains { ComputerText.fold($0.title) == ComputerText.fold(name) }
        case .settingsPane(let t):
            guard let s = await findApp(AppRef(bundleID: SurfacePolicy.systemSettings)) else { return false }
            return (await backend.windows(pid: s.pid)).contains { ComputerText.fold($0.title).contains(ComputerText.fold(t)) }
        }
    }
}

extension ActionPolicyContext {
    /// The menu leaf title is the "label" the consequence classifier looks at (a menu item has no element snapshot).
    func withMenuLeaf(_ title: String) -> ActionPolicyContext {
        var c = self
        c.element = UIElementSnapshot(id: -1, role: "AXMenuItem", subrole: nil, title: title, help: "", value: nil, valueLength: nil, enabled: true, focused: false, selected: false, identifier: nil, actions: ["Press"],
                                      frame: nil, parent: nil, depth: 0, childCount: 0, isSecure: false, handle: ElementHandle(pid: 0, generation: 0, index: -1))
        return c
    }
    func withLabel(_ title: String) -> ActionPolicyContext {
        var c = withMenuLeaf(title)
        c.element?.role = "AXButton"
        return c
    }
}
