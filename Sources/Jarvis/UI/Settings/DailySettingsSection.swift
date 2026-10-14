import AppKit
import SwiftUI

/// Settings → Startup, Daily JARVIS (presentation and follow-ups) and About. Presentation settings can never change what JARVIS is allowed to do.
struct DailySettingsSection: View {
    @Environment(AppContext.self) private var app
    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?
    var body: some View {
        @Bindable var prefs = app.preferences
        Section("Startup") {
            Toggle("Launch JARVIS at Login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { on in loginError = LaunchAtLogin.set(on); loginStatus = LaunchAtLogin.status })).disabled(loginStatus == .unsupported)
                .accessibilityIdentifier("settings.launchAtLogin")
            Text("Now: \(loginStatus.label). Off by default. This uses macOS Login Items, so you can also see and remove it in System Settings → General → Login Items; JARVIS installs no background service of its own.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = loginError { Text(e).font(.caption).foregroundStyle(.orange) }
            if loginStatus == .requiresApproval { Button("Open Login Items Settings") { LaunchAtLogin.openLoginItemsSettings() } }
            Toggle("Open the Compact HUD when JARVIS starts", isOn: $prefs.openCompactOnLaunch)
        }
        Section("Daily JARVIS") {
            Picker("Response style", selection: $prefs.responseStyle) { ForEach(ResponseStyle.allCases, id: \.self) { Text($0.label).tag($0) } }
                .accessibilityIdentifier("settings.responseStyle")
            Text("How much JARVIS says by default. Ask “detaylı anlat” / “explain in detail” for more, or “kısa söyle” for less, any time. A failure, a refusal or a decision is never cut.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Address (“efendim”)", selection: $prefs.addressStyle) { ForEach(AddressStyle.allCases, id: \.self) { Text($0.label).tag($0) } }
                .accessibilityIdentifier("settings.addressStyle")
            Text("Natural uses it now and then in Turkish (never twice in a short exchange); Minimal only when called or when a decision is needed; Off never.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Conversational follow-ups (“onu kullan”, “ikincisini dene”)", isOn: $prefs.conversationFollowUps).accessibilityIdentifier("settings.followUps")
            HStack {
                Button("Clear current conversation context") { app.conversationService.workingContext.clear() }
                    .accessibilityHint("Forgets what “it” and “the second one” mean right now. Project Memory is not touched.")
            }
            Text("A small, short-lived set of things you just talked about (max 16, 30 minutes). It never approves or grants anything and is not saved to Project Memory.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Notify me when a long task finishes or needs a decision", isOn: Binding(
                get: { prefs.notifyOnTaskEvents },
                set: { on in
                    prefs.notifyOnTaskEvents = on
                    if on { Task { _ = await app.notifier.requestAuthorization(); app.readiness.refresh() } }
                })).accessibilityIdentifier("settings.notify")
            Text("macOS asks for permission only when you switch this on. Notifications say only that a task finished or needs you — never its content.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Speak task acknowledgements", isOn: $prefs.voiceSpeakTaskAcks)
            Toggle("Speak task completions", isOn: $prefs.voiceSpeakCompletions)
            let warnings = app.readiness.snapshot.attention.count
            if warnings > 0 {
                Text("\(warnings) thing\(warnings == 1 ? "" : "s") in System & Readiness need\(warnings == 1 ? "s" : "") a look.").font(.caption).foregroundStyle(.orange)
            }
            Button("Open System & Readiness") { app.windows.showFullHUD(section: .system) }
        }
        .onAppear { loginStatus = LaunchAtLogin.status; app.readiness.refresh() }
    }
}

struct AboutSettingsSection: View {
    @Environment(AppContext.self) private var app
    @State private var report: String?

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.milestone))")
            LabeledContent("Build", value: AppInfo.build)
            LabeledContent("Running as", value: AppInfo.isApplicationBundle ? "installed application" : "development build")
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            LabeledContent("Architecture", value: DiagnosticsReport.hardware())
            LabeledContent("Database", value: app.database.map { "schema v\($0.schemaVersion)" } ?? "persistence unavailable")
            LabeledContent("Permissions", value: app.preferences.voiceEnabled ? "Microphone (only while you hold Push-to-Talk)" : "None requested")
            LabeledContent("Data", value: "Application Support/JARVIS")
            if app.preferences.showDeveloperControls, let c = AppInfo.commit { LabeledContent("Commit", value: c) }
            Button(report == nil ? "Show Diagnostics" : "Hide Diagnostics") {
                report = report == nil ? DiagnosticsReport.build(snapshot: app.readiness.refresh(), schema: app.database?.schemaVersion, installed: AppInfo.isApplicationBundle) : nil
            }.accessibilityHint("Shows versions and the state of each component. No paths, accounts, credentials or content.")
            if let report {
                Text(report).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("Select the text and copy it with ⌘C. It contains versions and component states only — no paths, accounts or content.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
