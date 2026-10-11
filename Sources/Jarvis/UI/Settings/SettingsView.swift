import SwiftUI

/// Minimal V0.1 settings. Deliberately tiny — no fake options.
struct SettingsView: View {
    @Environment(AppContext.self) private var app

    @ViewBuilder
    private func providerRow(_ id: ProviderID, prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        let status = app.providers.status(id)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(id.displayName) {
                HStack(spacing: 6) {
                    Text(status.state.label).font(.system(.caption, design: .monospaced)).foregroundStyle(status.state.isUsable ? .green : .orange)
                    if let v = status.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                }
            }
            switch status.state {
            case .authenticationRequired:
                Text("Sign in with the official flow: run  \(id.loginCommand)  in Terminal, then Refresh.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            case .notInstalled:
                Text(id == .codex ? "Codex ships inside the ChatGPT app (or install the Codex CLI)." : "Install Claude Code from Anthropic, then Refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            case .unavailable(let why), .failed(let why):
                Text("Couldn't check: \(why).").font(.caption).foregroundStyle(.secondary)
            case .rateLimited:
                Text("Usage limit reached for now.").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
            if prefs.showDeveloperControls, let path = status.executablePath {
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TextField("Custom executable path (optional)", text: id == .claudeCode ? $prefs.claudePathOverride : $prefs.codexPathOverride)
                .textFieldStyle(.roundedBorder).font(.caption)
        }
    }

    var body: some View {
        @Bindable var prefs = app.preferences

        Form {
            Section {
                Toggle("Launch at Login", isOn: .constant(false))
                    .disabled(!prefs.launchAtLoginIsAvailable)
                Text("Not implemented in V0.1. Planned for a later milestone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Reduce Motion", isOn: $prefs.reduceMotion)
                if prefs.systemReduceMotion {
                    Text("macOS “Reduce motion” is also on, so animation is already reduced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show Developer Controls", isOn: $prefs.showDeveloperControls)
                Text("Shows the state simulator in the Compact and Full HUD.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Intelligence provider") {
                Picker("Preferred provider", selection: $prefs.providerPreference) {
                    ForEach(ProviderPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Auto routes by policy (see Routing). A specific choice never silently falls back to another provider.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ProviderID.subscription, id: \.self) { id in providerRow(id, prefs: prefs) }
                HStack {
                    Button("Refresh status") { Task { await app.refreshIntelligence() } }.disabled(app.providers.isRefreshing || app.openCode.isRefreshing)
                    if app.providers.isRefreshing || app.openCode.isRefreshing { ProgressView().controlSize(.small) }
                }
                Text("JARVIS uses your own signed-in Codex / Claude Code subscriptions. It never asks for API keys, passwords or tokens, and sign-in always happens through the vendor's own flow. Providers run with tools disabled (conversation only).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RoutingSettingsSection()
            OpenCodeSettingsSection()
            LocalModelSettingsSection()
            Section("Global shortcuts") {
                Toggle("Enable global shortcuts", isOn: $prefs.globalShortcutsEnabled)
                LabeledContent("Compact HUD") { Text("⌥⌘").font(.system(size: 16, weight: .medium, design: .rounded)) }
                Text("Hold Option, then press Command.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Full HUD") { Text("⌥⌘⌘").font(.system(size: 16, weight: .medium, design: .rounded)) }
                Text("Hold Option, then press Command twice in quick succession (within 0.3 s). Either Command key works.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Needs no macOS permission. Chords that include another key, a click, Shift or Control are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.milestone))")
                LabeledContent("Permissions", value: "None requested")
                LabeledContent("Data", value: app.database == nil ? "persistence unavailable" : "SQLite · Application Support/JARVIS")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 860)
    }
}
