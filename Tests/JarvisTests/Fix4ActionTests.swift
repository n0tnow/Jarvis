import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 4 — actions are typed, executed, VERIFIED, and reported from an ActionReceipt. No receipt, no completion claim.

@MainActor
final class FakeAppLauncher: ApplicationLaunching {
    var installed: [String: URL] = [:]
    var running: Set<String> = []
    var front: String?
    var launchError: String?
    /// true: a launch makes the app appear running (and frontmost); false: the request is accepted but nothing happens.
    var launchWorks = true
    var openedFolders: [URL] = []
    var folderOpens = true
    private(set) var launched: [URL] = []
    func applicationURL(bundleID: String) -> URL? { installed[bundleID] }
    func launch(url: URL) async -> LaunchResult {
        launched.append(url)
        if let launchError { return LaunchResult(error: launchError) }
        if launchWorks, let id = installed.first(where: { $0.value == url })?.key { running.insert(id); front = id }
        return LaunchResult(error: nil)
    }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func frontmostBundleID() -> String? { front }
    func open(folder: URL) -> Bool { openedFolders.append(folder); if folderOpens { front = "com.apple.finder" }; return folderOpens }
}

@MainActor
final class HUDFakeWindows: JarvisWindowControlling {
    let hud = HUDState()
    var isCompactHUDOpen = false
    var isFullHUDOpen = false
    var ignoreNavigation = false
    func showCompactHUD() { isCompactHUDOpen = true; isFullHUDOpen = false }
    func hideCompactHUD() { isCompactHUDOpen = false }
    func toggleCompactHUD() {}
    func showFullHUD(section: HUDSection?) { if let section, !ignoreNavigation { hud.section = section }; isFullHUDOpen = true; isCompactHUDOpen = false }
    func hideFullHUD() { isFullHUDOpen = false }
    func toggleFullHUD() {}
    func bringFullHUDForward() {}
    func showSettings() { showFullHUD(section: .settings) }
}

@MainActor
private final class ActionRig {
    let launcher = FakeAppLauncher()
    let windows = HUDFakeWindows()
    let service: ActionService
    let svc: ConversationService
    let conv = ConversationStore()
    let resolver = FixedReplyResolver("Tamam efendim, hallettim.")          // a model that would happily claim it did something
    var logged: [String] = []
    init() {
        service = ActionService(launcher: launcher, windows: windows, selfState: { [windows] in SelfUIState(section: windows.hud.section, fullOpen: windows.isFullHUDOpen, compactOpen: windows.isCompactHUDOpen) })
        service.verificationTimeout = 0.15; service.pollInterval = 0.02
        service.installedLookup = { _ in nil }
        svc = ConversationService(store: JarvisStore(), conversation: conv, windows: windows, resolver: resolver)
        svc.actionService = service
        launcher.installed["com.apple.Safari"] = URL(fileURLWithPath: "/Applications/Safari.app")
        launcher.installed["com.apple.finder"] = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        service.log = { [weak self] m, _ in self?.logged.append(m) }
    }
    @discardableResult func say(_ text: String) async -> String {
        svc.submit(text)
        await svc.waitUntilIdle()
        let end = Date().addingTimeInterval(2)
        while Date() < end, conv.last?.role != .jarvis || svc.isAnswering { try? await Task.sleep(for: .milliseconds(20)) }
        return conv.last?.content ?? ""
    }
    var modelCalls: Int { resolver.prompts.count }
}

@Suite("Fix 4 · natural language becomes a typed action")
struct ActionGrammarTests {
    func p(_ s: String) -> ActionIntent? { ActionIntentParser.parse(s) }
    let safari = ActionIntent.launchApp(AppTarget(display: "Safari", bundleID: "com.apple.Safari"))

    @Test("every polite Turkish and English form of ‘open Safari’ is the same action — including the question forms")
    func safariForms() {
        for s in ["Safari'yi aç.", "Safari'yi açar mısın?", "Safari'yi açabilir misin?", "Safari'yi açabilir misin lütfen?", "Safariyi aç", "Jarvis, Safari'yi aç", "Open Safari.", "Can you open Safari?", "Could you open Safari please", "Launch Safari", "Safari'yi başlat"] {
            #expect(p(s) == safari, "“\(s)” → \(String(describing: p(s)))")
        }
        #expect(p("Finder'ı açar mısın?") == .launchApp(AppTarget(display: "Finder", bundleID: "com.apple.finder")))
        #expect(p("Open Finder.") == .launchApp(AppTarget(display: "Finder", bundleID: "com.apple.finder")))
        #expect(p("System Settings'i aç") == .launchApp(AppTarget(display: "System Settings", bundleID: "com.apple.systempreferences")), "System Settings is an application, not JARVIS' System page")
        #expect(p("Sistem ayarlarını aç") == .launchApp(AppTarget(display: "System Settings", bundleID: "com.apple.systempreferences")))
    }

    @Test("JARVIS' own pages are typed UI actions, in both languages")
    func ownUI() {
        #expect(p("System panelini aç.") == .navigate(.system))
        #expect(p("Sistem sayfasını aç") == .navigate(.system))
        #expect(p("Dashboard'a dön.") == .navigate(.dashboard))
        #expect(p("Ana ekrana dön") == .navigate(.dashboard))
        #expect(p("Görevleri göster") == .navigate(.tasks))
        #expect(p("Ajanlar sayfasını aç") == .navigate(.agents))
        #expect(p("Hafızayı aç") == .navigate(.memory))
        #expect(p("Raporu aç") == .navigate(.report))
        #expect(p("Ayarları aç") == .navigate(.settings))
        #expect(p("Open the system page") == .navigate(.system))
        #expect(p("Go back to the dashboard") == .navigate(.dashboard))
        #expect(p("Tam JARVIS ekranını aç.") == .showFullHUD)
        #expect(p("Kompakt görünümü aç") == .showCompactHUD)
        #expect(p("JARVIS'i kapat") == .closeHUD)
    }

    @Test("a folder")
    func folders() {
        #expect(p("Downloads klasörünü aç") == .openFolder(.downloads))
        #expect(p("İndirilenler klasörünü açar mısın?") == .openFolder(.downloads))
        #expect(p("Open the Documents folder") == .openFolder(.documents))
    }

    @Test("things that are NOT actions keep their route (questions about Safari, settings switches, unknown objects, compound requests)")
    func notActions() {
        for s in ["Safari nedir?", "Safari'yi nasıl açarım?", "Dosya okuyabiliyor musun?", "Wake word'ü aç", "Wake word'ü kapat", "Bildirimleri aç", "Launch at Login'i aç", "Sistem durumunu söyle",
                  "Sistem durumunu göster", "Bunu aç", "Dosyayı aç", "Safari'yi aç ve YouTube'a git", "Ekranıma bak", "Videoyu durdur", "Hamam ne durumda?", "Konuşma hızını arttır", "Görevi durdur", "Uyku moduna geç"] {
            #expect(p(s) == nil, "“\(s)” was taken for an action: \(String(describing: p(s)))")
        }
    }

    @Test("an installed application without an alias is found by its exact name through the injected lookup")
    func installedByName() {
        let lookup: ActionIntentParser.InstalledAppLookup = { $0 == "sketchbook" ? AppTarget(display: "Sketchbook", bundleID: "com.example.sketch") : nil }
        #expect(ActionIntentParser.parse("Sketchbook'u aç", installed: lookup) == .launchApp(AppTarget(display: "Sketchbook", bundleID: "com.example.sketch")))
        #expect(ActionIntentParser.parse("Nothingapp'i aç", installed: lookup) == nil)
    }
}

@Suite("Fix 4 · verification and the receipt invariant")
@MainActor
struct ActionReceiptTests {
    @Test("a launch is a success only after the application is seen running; the words come from the receipt")
    func launchSuccess() async {
        let r = ActionRig()
        let text = await r.say("Safari'yi açar mısın?")
        #expect(text == "Safari açık.", Comment(rawValue: text))
        let receipt = r.service.ledger.last!
        #expect(receipt.status == .succeeded && receipt.successIsClaimable && receipt.executor == "NSWorkspace" && receipt.verification?.passed == true)
        #expect(receipt.startedAt != nil && receipt.finishedAt != nil && receipt.target == "Safari" && receipt.kind == .launchApp)
        #expect(r.launcher.launched.count == 1 && r.modelCalls == 0, "no model, exactly one launch")
        #expect(r.logged.contains("Safari launch requested") && r.logged.contains("Safari launch succeeded"))
    }

    @Test("the executor failing is said as a failure, never as completion")
    func launchFailure() async {
        let r = ActionRig()
        r.launcher.launchError = "the application could not be started"
        let text = await r.say("Safari'yi açabilir misin?")
        #expect(text.contains("açılamadı") && !text.contains("açık") && !text.lowercased().contains("açtım"), Comment(rawValue: text))
        #expect(r.service.ledger.last?.status == .failed && r.service.ledger.last?.successIsClaimable == false)
        #expect(r.logged.contains { $0.hasPrefix("Safari launch failed") })
    }

    @Test("an application that is not installed fails honestly")
    func notInstalled() async {
        let r = ActionRig()
        r.launcher.installed["com.apple.Safari"] = nil
        let text = await r.say("Open Safari")
        #expect(text.contains("could not open Safari") && text.contains("not installed"), Comment(rawValue: text))
    }

    @Test("a request that was accepted but cannot be confirmed is UNVERIFIED — a different sentence from FAILED and from success")
    func unverified() async {
        let r = ActionRig()
        r.launcher.launchWorks = false
        let text = await r.say("Safari'yi aç")
        #expect(text.contains("doğrulayamadım") && !text.contains("açık."), Comment(rawValue: text))
        #expect(r.service.ledger.last?.status == .unverified && r.service.ledger.last?.successIsClaimable == false)
        let failed = ActionPhrasebook.render({ var x = ActionReceipt(kind: .launchApp, target: "Safari", executor: "t"); x.fail("boom"); return x }(), language: .tr)
        #expect(failed != text && failed.contains("açılamadı"))
    }

    @Test("a receipt marked succeeded WITHOUT a passing verification is never worded as success")
    func successNeedsEvidence() {
        var x = ActionReceipt(kind: .launchApp, target: "Safari", executor: "t")
        x.status = .succeeded                                                             // forged: no verification at all
        #expect(!x.successIsClaimable)
        #expect(!ActionPhrasebook.render(x, language: .tr).contains("Safari açık"))
        x.succeed(ActionVerification(method: "m", passed: nil, detail: "cannot check"))
        #expect(x.status == .unverified, "succeed() without a passing check can only produce UNVERIFIED")
        x.succeed(ActionVerification(method: "m", passed: true, detail: "ok"))
        #expect(x.status == .succeeded && x.successIsClaimable)
    }

    @Test("every status has its own wording and none of the non-success ones claims completion")
    func statusWording() {
        for lang in [ReplyLanguage.tr, .en] {
            var texts: [ReceiptStatus: String] = [:]
            for st in [ReceiptStatus.planned, .running, .failed, .cancelled, .needsApproval, .unverified] {
                var x = ActionReceipt(kind: .launchApp, target: "Safari", executor: "t"); x.status = st; if st == .failed { x.error = "x" }
                texts[st] = ActionPhrasebook.render(x, language: lang)
                let lowered = texts[st]!.lowercased()
                #expect(!lowered.contains("açık.") && !lowered.hasSuffix("is open."), "\(st): \(lowered)")
            }
            #expect(Set(texts.values).count >= 5)
        }
    }

    @Test("JARVIS' own pages are navigated directly and read back; no model, no Computer Use")
    func ownNavigation() async {
        let r = ActionRig()
        var text = await r.say("System panelini aç.")
        #expect(r.windows.hud.section == .system && text == "Sistem sayfası açık.", Comment(rawValue: text))
        text = await r.say("Dashboard'a dön.")
        #expect(r.windows.hud.section == .dashboard && text == "Dashboard sayfası açık.", Comment(rawValue: text))
        text = await r.say("Tam JARVIS ekranını aç.")
        #expect(r.windows.isFullHUDOpen && text.contains("Tam JARVIS ekranı açık"))
        #expect(r.modelCalls == 0)
        #expect(r.service.ledger.receipts.allSatisfy { $0.executor == "JARVIS HUD" && $0.status == .succeeded })
    }

    @Test("if the page did not actually change, it is a failure (the claim must match the state)")
    func navigationReadBack() async {
        let r = ActionRig()
        r.windows.ignoreNavigation = true
        let text = await r.say("System panelini aç")
        #expect(text.contains("açılamadı"), Comment(rawValue: text))
        #expect(r.service.ledger.last?.status == .failed)
    }

    @Test("a folder is opened and Finder must come forward to count as verified")
    func folder() async {
        let r = ActionRig()
        let text = await r.say("Downloads klasörünü aç")
        #expect(text.contains("klasörü açık") && r.launcher.openedFolders.count == 1, Comment(rawValue: text))
        r.launcher.folderOpens = false
        let failed = await r.say("Documents klasörünü aç")
        #expect(failed.contains("açılamadı"), Comment(rawValue: failed))
    }

    @Test("password managers are never opened by voice or text")
    func credentialAppsRefused() async {
        let r = ActionRig()
        r.launcher.installed["com.1password.1password"] = URL(fileURLWithPath: "/Applications/1Password.app")
        let target = AppTarget(display: "1Password", bundleID: "com.1password.1password")
        let receipt = await r.service.perform(.launchApp(target))
        #expect(receipt.status == .failed && r.launcher.launched.isEmpty)
    }

    @Test("an automated run's launcher can never open a real application")
    func stubbedLauncher() async {
        let l = StubbedApplicationLauncher()
        #expect(l.applicationURL(bundleID: "com.apple.Safari") == nil && !l.isRunning(bundleID: "com.apple.Safari"))
        #expect((await l.launch(url: URL(fileURLWithPath: "/Applications/Safari.app"))).error != nil)
    }
}
