import AppKit
import Foundation

// MARK: - Executing and verifying typed actions (V1.0 stabilisation fix 4)
//
// natural language → ActionIntent → safety classification → executor → VERIFICATION → ActionReceipt → response.
// Deterministic first: applications are launched through NSWorkspace (never a shell, never a model, never Computer Use vision); JARVIS' own HUD is changed through the same window controller
// everything else uses and read back; folders are opened by URL. The receipt says what was verified — or that nothing could be.

/// Launching applications. The real implementation uses NSWorkspace; tests inject a fake.
@MainActor
protocol ApplicationLaunching: AnyObject {
    /// Application bundle URL for an identifier, nil when it is not installed.
    func applicationURL(bundleID: String) -> URL?
    func launch(url: URL) async -> LaunchResult
    /// Running, finished launching, not terminated.
    func isRunning(bundleID: String) -> Bool
    func frontmostBundleID() -> String?
    func open(folder: URL) -> Bool
}

struct LaunchResult: Sendable { var error: String? }

@MainActor
final class SystemApplicationLauncher: ApplicationLaunching {
    func applicationURL(bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    func launch(url: URL) async -> LaunchResult {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return await withCheckedContinuation { cont in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in cont.resume(returning: LaunchResult(error: error.map { String($0.localizedDescription.prefix(160)) })) }
        }
    }

    func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated && $0.isFinishedLaunching }
    }
    func frontmostBundleID() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    func open(folder: URL) -> Bool { NSWorkspace.shared.open(folder) }
}

/// A launcher for automated runs: it never touches the system and says so.
@MainActor
final class StubbedApplicationLauncher: ApplicationLaunching {
    func applicationURL(bundleID: String) -> URL? { nil }
    func launch(url: URL) async -> LaunchResult { LaunchResult(error: "automated run: no real application is opened") }
    func isRunning(bundleID: String) -> Bool { false }
    func frontmostBundleID() -> String? { nil }
    func open(folder: URL) -> Bool { false }
}

/// What the action service needs to know about JARVIS' own window state to verify a navigation.
struct SelfUIState: Equatable, Sendable {
    var section: HUDSection; var fullOpen: Bool; var compactOpen: Bool
    /// What the Full HUD view reports it is drawing (nil = nothing reported). Compared only when `requiresRenderAck` — i.e. when a real view exists to report (the installed app); a state-only harness leaves it off.
    var renderedSection: HUDSection? = nil
    var requiresRenderAck = false
}

@MainActor
final class ActionService {
    let launcher: any ApplicationLaunching
    let ledger: ActionLedger
    unowned let windows: any JarvisWindowControlling
    var selfState: () -> SelfUIState
    /// Activity feed (honest, bounded: one line per request and one per outcome).
    var log: (String, ActivityKind) -> Void = { _, _ in }
    /// Bounded waits (single-shot, only while an action is being verified — never while idle).
    var verificationTimeout: TimeInterval = 2.0
    var pollInterval: TimeInterval = 0.1
    /// After a navigation reads back correctly, wait this long and read again: a selection that something resets a moment later (the page that was drawn is not the page that was asked for) is not "open".
    var navigationSettle: TimeInterval = 0.15
    var now: () -> Date = { Date() }
    /// V1.0 Phase B: opens a Unity project in the user's editor (nil: a Unity project falls back to revealing its folder).
    var unityOpener: (any UnityProjectOpening)?
    var isUnityProject: (String) -> Bool = { UnityProjectDetector.isUnityProject(root: $0) }
    var installedLookup: ActionIntentParser.InstalledAppLookup = { name in AppCatalog.installed(named: name).map { AppTarget(display: $0.name ?? name, bundleID: $0.bundleID ?? "") } }

    init(launcher: any ApplicationLaunching, windows: any JarvisWindowControlling, ledger: ActionLedger? = nil, selfState: @escaping () -> SelfUIState) {
        self.launcher = launcher; self.windows = windows; self.ledger = ledger ?? ActionLedger(); self.selfState = selfState
    }

    /// Names of applications this Mac has (known catalog + a directory listing), cached for a minute; read-only, never launches anything.
    private var appCandidatesCache: (at: Date, apps: [AppTarget])?
    var candidateApps: () -> [AppTarget] = {
        var apps = AppCatalog.known.map { AppTarget(display: $0.display, bundleID: $0.bundleID) }
        for d in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for item in items.prefix(400) where item.hasSuffix(".app") {
                if let b = Bundle(path: d + "/" + item)?.bundleIdentifier, !apps.contains(where: { $0.bundleID == b }) { apps.append(AppTarget(display: String(item.dropLast(4)), bundleID: b)) }
            }
        }
        return apps
    }
    /// Spoken corrections of an application name for THIS conversation only (“Sofany değil, Safari dedim”): bounded, expiring, never global vocabulary, never persisted.
    private(set) var sessionCorrections: [(heard: String, app: AppTarget, at: Date)] = []
    static let correctionLifetime: TimeInterval = 30 * 60

    private func phoneticLookup(_ name: String) -> AppTarget? {
        let key = ComputerText.fold(name)
        let cutoff = now().addingTimeInterval(-Self.correctionLifetime)
        sessionCorrections.removeAll { $0.at < cutoff }
        if let c = sessionCorrections.first(where: { $0.heard == key }) { var a = c.app; a.heardAs = name; return a }
        if appCandidatesCache == nil || now().timeIntervalSince(appCandidatesCache!.at) > 60 { appCandidatesCache = (now(), candidateApps()) }
        return PhoneticAppResolver.resolve(heard: name, candidates: appCandidatesCache?.apps ?? [])
    }

    func recognizes(_ text: String) -> ActionIntent? {
        let intent = ActionIntentParser.parse(text, installed: installedLookup, phonetic: { [unowned self] in self.phoneticLookup($0) })
        // A restated name is remembered for this conversation so the same mis-hearing resolves next time (bounded, expiring).
        if case .launchApp(let app)? = intent, let wrong = app.heardAs, ComputerText.tokens(text).contains(where: { $0 == "dedim" || $0 == "demistim" || $0 == "said" }) {
            let key = ComputerText.fold(wrong)
            if !key.isEmpty {
                sessionCorrections.removeAll { $0.heard == key }
                sessionCorrections.append((key, AppTarget(display: app.display, bundleID: app.bundleID), now()))
                if sessionCorrections.count > 16 { sessionCorrections.removeFirst(sessionCorrections.count - 16) }
            }
        }
        return intent
    }
    /// Display names of the applications on this Mac (cached with the phonetic candidates).
    func candidateAppNames() -> [String] {
        if appCandidatesCache == nil || now().timeIntervalSince(appCandidatesCache!.at) > 60 { appCandidatesCache = (now(), candidateApps()) }
        return appCandidatesCache?.apps.map(\.display) ?? []
    }
    func clearSessionCorrections() { sessionCorrections.removeAll() }

    /// Performs one action end to end and returns its receipt (also recorded in the ledger and the activity feed).
    func perform(_ intent: ActionIntent) async -> ActionReceipt {
        var r = ActionReceipt(kind: intent.kind, target: intent.targetName, executor: executorName(intent), now: now())
        ledger.record(r)
        log("\(verbPhrase(intent)) requested", .command)
        r.start(now: now())
        ledger.record(r)
        switch intent {
        case .launchApp(let app): await launch(app, into: &r)
        case .openFolder(let folder): await openFolder(folder, into: &r)
        case .navigate(let section): await navigate(section, into: &r)
        case .showFullHUD: showFull(into: &r)
        case .showCompactHUD: showCompact(into: &r)
        case .closeHUD: closeHUD(into: &r)
        case .openProject(let name, let path):
            if usesUnity(path) { await openUnityProject(name: name, path: path, into: &r) } else { await openProjectFolder(name: name, path: path, into: &r) }
        }
        ledger.record(r)
        switch r.status {
        case .succeeded: log("\(verbPhrase(intent)) succeeded", .success)
        case .failed: log("\(verbPhrase(intent)) failed: \(r.error ?? "unknown")", .error)
        case .unverified: log("\(verbPhrase(intent)) sent, not verified", .warning)
        default: break
        }
        return r
    }

    private func executorName(_ i: ActionIntent) -> String {
        switch i {
        case .openProject(_, let path): usesUnity(path) ? "Unity Editor (NSWorkspace)" : "NSWorkspace"
        case .launchApp, .openFolder: "NSWorkspace"
        default: "JARVIS HUD" }
    }
    private func verbPhrase(_ i: ActionIntent) -> String {
        switch i {
        case .launchApp(let a): "\(a.display) launch"; case .openFolder(let f): "\(f.display) folder open"; case .navigate(let s): "Open \(s.rawValue.capitalized) page"
        case .showFullHUD: "Show Full HUD"; case .showCompactHUD: "Show Compact HUD"; case .closeHUD: "Close HUD"; case .openProject(let n, _): "\(n) project open"
        }
    }

    // MARK: Applications

    private func launch(_ app: AppTarget, into r: inout ActionReceipt) async {
        // Safety first: password managers and the keychain UI are never opened on the user's behalf by voice.
        if SurfacePolicy.isCredentialApp(app.bundleID) { r.fail("JARVIS does not open password managers or the keychain for you"); return }
        guard let url = launcher.applicationURL(bundleID: app.bundleID) else { r.fail("\(app.display) is not installed on this Mac"); return }
        let wasRunning = launcher.isRunning(bundleID: app.bundleID)
        let result = await launcher.launch(url: url)
        if let e = result.error { r.fail(e); return }
        // VERIFY: the application must be running (and, when we started it, frontmost soon). The launch call alone is not proof.
        let ok = await waitUntil { self.launcher.isRunning(bundleID: app.bundleID) }
        guard ok else { r.markUnverified(ActionVerification(method: "running-application list", passed: nil, detail: "the launch request was accepted but \(app.display) did not appear as running within \(Int(verificationTimeout)) s"), now: now()); return }
        let front = await waitUntil { self.launcher.frontmostBundleID() == app.bundleID }
        r.succeed(ActionVerification(method: "running-application list", passed: true,
                                     detail: "\(app.display) is running\(wasRunning ? " (was already open)" : "")\(front ? " and frontmost" : ", not frontmost")"), now: now())
    }

    private func openFolder(_ folder: KnownFolder, into r: inout ActionReceipt) async {
        guard FileManager.default.fileExists(atPath: folder.url.path) else { r.fail("the \(folder.display) folder does not exist"); return }
        guard launcher.open(folder: folder.url) else { r.fail("macOS could not open the \(folder.display) folder"); return }
        let ok = await waitUntil { self.launcher.frontmostBundleID() == "com.apple.finder" }
        if ok { r.succeed(ActionVerification(method: "frontmost application", passed: true, detail: "Finder is frontmost, showing \(folder.display)"), now: now()) }
        else { r.markUnverified(ActionVerification(method: "frontmost application", passed: nil, detail: "the folder was opened but Finder did not become frontmost"), now: now()) }
    }

    private func usesUnity(_ path: String) -> Bool { unityOpener != nil && !path.isEmpty && isUnityProject(path) }

    /// A Unity project in the user's editor (Phase B). Success needs an editor process whose -projectPath is this project AND its Temp/UnityLockfile; anything less is UNVERIFIED or FAILED, never "open".
    private func openUnityProject(name: String, path: String, into r: inout ActionReceipt) async {
        guard let opener = unityOpener else { r.fail("Unity cannot be opened from here"); return }
        guard case .allowed = ComputerPathPolicy.validate(path, quarantineRoot: nil, forReveal: true) else { r.fail("that folder is in a protected location"); return }
        switch await opener.open(projectRoot: path) {
        case .alreadyOpen(let pid, _, let front):
            if front { r.succeed(ActionVerification(method: "Unity editor process with this -projectPath + frontmost", passed: true, detail: "an editor (pid \(pid)) already had \(name) open and is now frontmost"), now: now()) }
            else { r.markUnverified(ActionVerification(method: "Unity editor process with this -projectPath", passed: nil, detail: "an editor (pid \(pid)) has \(name) open, but it did not become frontmost"), now: now()) }
        case .launched(let pid, let version, let lock):
            if lock { r.succeed(ActionVerification(method: "Unity editor process with this -projectPath + Temp/UnityLockfile", passed: true, detail: "Unity \(version) (pid \(pid)) is running with \(name) and holds the project"), now: now()) }
            else { r.markUnverified(ActionVerification(method: "Unity editor process with this -projectPath", passed: nil, detail: "Unity \(version) (pid \(pid)) started with \(name) but the project is not confirmed open yet (it may still be importing or waiting for a licence/sign-in)"), now: now()) }
        case .notAUnityProject: r.fail("that folder is not a Unity project any more")
        case .noEditorInstalled(let declared): r.fail("no Unity editor is installed for this project (it declares \(declared ?? "an unknown version"))")
        case .needsUpgradeApproval(let declared, let candidate): r.fail("this project needs Unity \(declared), which is not installed; Unity \(candidate) is, but opening it there would upgrade the project, so I did not")
        case .unknownDeclaredVersion: r.fail("I cannot read which Unity version this project uses")
        case .launchFailed(let why): r.fail("macOS could not start Unity: \(why)")
        case .processNotFound: r.markUnverified(ActionVerification(method: "Unity editor process with this -projectPath", passed: nil, detail: "I asked macOS to start Unity, but no editor with \(name) appeared"), now: now())
        }
    }

    /// A known project: the path comes from the project registry and is re-checked here (current truth: the folder must exist). Revealing it in Finder is read-only; nothing in the project is touched.
    private func openProjectFolder(name: String, path: String, into r: inout ActionReceipt) async {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { r.fail("the folder of \(name) is not on disk"); return }
        guard case .allowed(let real) = ComputerPathPolicy.validate(path, quarantineRoot: nil, forReveal: true) else { r.fail("that folder is in a protected location"); return }
        guard launcher.open(folder: URL(fileURLWithPath: real, isDirectory: true)) else { r.fail("macOS could not open the folder of \(name)"); return }
        let ok = await waitUntil { self.launcher.frontmostBundleID() == "com.apple.finder" }
        if ok { r.succeed(ActionVerification(method: "frontmost application", passed: true, detail: "Finder is frontmost, showing the folder of \(name)"), now: now()) }
        else { r.markUnverified(ActionVerification(method: "frontmost application", passed: nil, detail: "the folder was opened but Finder did not become frontmost"), now: now()) }
    }

    // MARK: JARVIS' own HUD — direct state changes, read back

    private func navigate(_ section: HUDSection, into r: inout ActionReceipt) async {
        windows.showFullHUD(section: section)
        var s = selfState()
        // 1. the canonical selection (HUDState.section) and the window: what the model of the UI says
        guard s.fullOpen, s.section == section else { r.fail("the \(section.rawValue) page is not selected (it shows \(s.section.rawValue))"); return }
        // 2. the view's own acknowledgement that it draws that page (installed app). "System is open" is never claimed from a prediction or from a state nobody drew.
        if s.requiresRenderAck {
            let drawn = await waitUntil { let x = self.selfState(); return x.fullOpen && x.section == section && x.renderedSection == section }
            s = selfState()
            guard drawn else {
                if s.section != section { r.fail("the \(section.rawValue) page is not selected (it shows \(s.section.rawValue))") }
                else { r.markUnverified(ActionVerification(method: "HUD render acknowledgement", passed: nil, detail: "the selection says \(section.rawValue) but the window reports it draws \(s.renderedSection?.rawValue ?? "nothing yet")"), now: now()) }
                return
            }
        }
        // 3. read back once more after a short settle: a later reset to another page is a failure, not a success
        if navigationSettle > 0 { try? await Task.sleep(for: .seconds(navigationSettle)) }
        s = selfState()
        guard s.fullOpen, s.section == section, !s.requiresRenderAck || s.renderedSection == section else {
            r.markUnverified(ActionVerification(method: "HUD state read-back (settled)", passed: nil, detail: "the page changed to \(s.section.rawValue) right after it was selected"), now: now())
            return
        }
        r.succeed(ActionVerification(method: s.requiresRenderAck ? "HUD state read-back + render acknowledgement" : "HUD state read-back", passed: true, detail: "selected page is \(s.section.rawValue)\(s.requiresRenderAck ? ", and the window draws it" : "")"), now: now())
    }

    private func showFull(into r: inout ActionReceipt) {
        windows.showFullHUD(section: nil)
        let s = selfState()
        if s.fullOpen { r.succeed(ActionVerification(method: "HUD state read-back", passed: true, detail: "the Full HUD is open on \(s.section.rawValue)"), now: now()) } else { r.fail("the Full HUD did not open") }
    }

    private func showCompact(into r: inout ActionReceipt) {
        windows.showCompactHUD()
        let s = selfState()
        if s.compactOpen && !s.fullOpen { r.succeed(ActionVerification(method: "HUD state read-back", passed: true, detail: "the Compact HUD is open"), now: now()) } else { r.fail("the Compact HUD did not open") }
    }

    private func closeHUD(into r: inout ActionReceipt) {
        windows.hideFullHUD(); windows.hideCompactHUD()
        let s = selfState()
        if !s.fullOpen && !s.compactOpen { r.succeed(ActionVerification(method: "HUD state read-back", passed: true, detail: "no HUD window is open; JARVIS keeps running in the menu bar"), now: now()) } else { r.fail("a HUD window is still open") }
    }

    // MARK: Bounded wait

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        if condition() { return true }
        let end = Date().addingTimeInterval(verificationTimeout)
        while Date() < end {
            try? await Task.sleep(for: .seconds(pollInterval))
            if condition() { return true }
        }
        return condition()
    }
}

// MARK: - Words (the ONLY place an action outcome becomes a sentence)

enum ActionPhrasebook {
    private static func t(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    /// The sentence for a receipt. Success wording exists ONLY for a verified success.
    static func render(_ r: ActionReceipt, language l: ReplyLanguage) -> String {
        let name = r.target
        switch r.status {
        case .planned, .running:
            return label(r, l, inProgress: true)
        case .succeeded where r.successIsClaimable:
            switch r.kind {
            case .launchApp: return t(l, "\(name) is open.", "\(name) açık.")
            case .openFolder: return t(l, "The \(name) folder is open.", "\(name) klasörü açık.")
            case .navigate: return t(l, "The \(name) page is open.", "\(trPageTitle(name)) sayfası açık.")
            case .openProject:
                return r.executor.hasPrefix("Unity") ? t(l, "\(name) is open in Unity.", "\(name) Unity'de açık.") : t(l, "The \(name) project folder is open in Finder.", "\(name) proje klasörü Finder'da açık.")
            case .showFullHUD: return t(l, "The full JARVIS screen is open.", "Tam JARVIS ekranı açık.")
            case .showCompactHUD: return t(l, "The compact view is open.", "Kompakt görünüm açık.")
            case .closeHUD: return t(l, "Closed. I'm still here in the menu bar.", "Kapattım. Menü çubuğunda çalışmaya devam ediyorum.")
            case .computerGoal: return t(l, "Done and verified.", "Yapıldı ve doğrulandı.")
            }
        case .succeeded:
            // A "succeeded" receipt without a passing verification is never worded as success.
            return t(l, "I sent the request for \(name), but I could not confirm the result.", "\(name) için isteği gönderdim ama sonucu doğrulayamadım.")
        case .unverified:
            return t(l, "I sent the request for \(name), but I could not confirm that it worked (\(r.verification?.detail ?? "no way to check")).", "\(name) için isteği gönderdim ama çalıştığını doğrulayamadım (\(r.verification?.detail ?? "kontrol yolu yok")).")
        case .failed:
            return failure(r, l)
        case .cancelled:
            return t(l, "Cancelled: \(name).", "İptal edildi: \(name).")
        case .needsApproval:
            return t(l, "\(name) needs your approval in the HUD (saying yes does not approve it).", "\(name) için HUD'da onayınız gerekiyor (“evet” demek onay vermez).")
        }
    }

    /// Turkish names of JARVIS' own pages (the receipt carries the English page name).
    private static func trPageTitle(_ name: String) -> String {
        ["dashboard": "Dashboard", "tasks": "Görevler", "agents": "Ajanlar", "research": "Araştırma", "report": "Rapor", "system": "Sistem", "memory": "Hafıza",
         "computer": "Bilgisayar", "learning": "Öğrenme", "capabilities": "Yetenekler", "settings": "Ayarlar"][name.lowercased()] ?? name
    }

    private static func label(_ r: ActionReceipt, _ l: ReplyLanguage, inProgress: Bool) -> String {
        switch r.kind {
        case .launchApp: return t(l, "Opening \(r.target)…", "\(r.target) açılıyor…")
        case .openFolder: return t(l, "Opening the \(r.target) folder…", "\(r.target) klasörünü açıyorum…")
        case .navigate: return t(l, "Opening the \(r.target) page…", "\(trPageTitle(r.target)) sayfasını açıyorum…")
        default: return t(l, "Working on it…", "Yapıyorum…")
        }
    }

    private static func failure(_ r: ActionReceipt, _ l: ReplyLanguage) -> String {
        let why = r.error ?? t(l, "unknown reason", "bilinmeyen neden")
        switch r.kind {
        case .launchApp: return t(l, "I could not open \(r.target): \(why).", "\(r.target) açılamadı: \(why).")
        case .openFolder: return t(l, "I could not open the \(r.target) folder: \(why).", "\(r.target) klasörü açılamadı: \(why).")
        case .navigate: return t(l, "I could not open the \(r.target) page: \(why).", "\(r.target) sayfası açılamadı: \(why).")
        case .openProject: return t(l, "I could not open \(r.target): \(why).", "\(r.target) açılamadı: \(why).")
        default: return t(l, "I could not do that: \(why).", "Bu yapılamadı: \(why).")
        }
    }
}
