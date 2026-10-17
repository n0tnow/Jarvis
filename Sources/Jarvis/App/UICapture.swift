import AppKit
import SwiftUI

/// `Jarvis --ui-capture <dir> [--section x]`: renders the Full HUD of a production-mode app (no demo data, isolated storage) to PNG files so the design can be judged by looking at it.
/// Shows only honest empty / real states; the permission and wake states are produced by injecting probe answers into the READ-ONLY readiness service (nothing is granted, nothing started).
@MainActor
enum UICapture {
    static func run(directory: String, context: AppContext, only: HUDSection?) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func settle(_ ms: Int = 700) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func shot(_ name: String) { DevCapture.snapshot(of: NSApp.windows.first { $0 is FullHUDWindow }, name: name, in: directory) }
        context.preferences.reduceMotion = true
        context.windows.showFullHUD(section: only ?? .dashboard); await settle(1200)
        if let w = NSApp.windows.first(where: { $0 is FullHUDWindow }) { print("full HUD frame \(w.frame) · visible screen \(w.screen?.visibleFrame ?? .zero)") }
        // permission-needed + wake-running readiness (injected answers; read-only)
        var p = context.readiness.probes
        p.accessibility = { .notDetermined }
        p.screenRecording = { .notDetermined }
        p.identity = { CodeIdentity(appPath: "/Applications/JARVIS.app", bundleID: AppInfo.bundleIdentifier, signingIdentifier: AppInfo.bundleIdentifier, cdhash: "a1b2c3d4e5f6", adHoc: true, teamID: nil) }
        p.identityChanged = { true }
        context.readiness.probes = p
        context.readiness.refresh()
        for section in HUDSection.allCases where only == nil || only == section {
            context.hud.section = section
            if section == .settings { for c in SettingsCategory.allCases { context.hud.settingsCategory = c; await settle(500); shot("ui_settings_\(c.rawValue)") } }
            else { await settle(800); shot("ui_\(section.rawValue)") }
        }
        // conversation with a few real-looking (typed) messages
        if only == nil {
            context.hud.section = .dashboard
            context.conversation.appendUser("Sistem durumunu kısaca özetle")
            context.conversation.appendJarvis("JARVIS kullanılabilir durumda. Ayrıntı için “detaylı anlat” deyin.", route: .local)
            context.conversation.appendUser("Ekranımı görebiliyor musun?")
            context.conversation.appendJarvis("Evet, siz istediğinizde. Bilgisayar Kontrolü ile önce Erişilebilirlik üzerinden bir uygulama penceresinin yapısını okurum. Ekranınızı sürekli izlemem ve şu anda ona bakmıyorum.", route: .local)
            await settle(900); shot("ui_dashboard_conversation")
            context.windows.showCompactHUD(); await settle(800)
            DevCapture.snapshot(of: NSApp.windows.first { $0 is HUDPanel }, name: "ui_compact", in: directory)
        }
        print("UI CAPTURE DONE")
        NSApp.terminate(nil)
    }
}
