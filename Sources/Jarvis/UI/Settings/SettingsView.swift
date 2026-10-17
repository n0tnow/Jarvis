import SwiftUI

/// The Settings categories (Full HUD → Settings). Every control here is a real, implemented preference — no placeholders.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, voice, providers, autonomy, computer, memory, appearance, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"; case .voice: "Voice & Wake Word"; case .providers: "AI & Providers"; case .autonomy: "Autonomy & Safety"
        case .computer: "Computer & Web"; case .memory: "Memory & Learning"; case .appearance: "Appearance & Developer"; case .about: "About & Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"; case .voice: "waveform.badge.mic"; case .providers: "cpu"; case .autonomy: "shield.lefthalf.filled"
        case .computer: "cursorarrow.rays"; case .memory: "brain.head.profile"; case .appearance: "paintpalette"; case .about: "info.circle"
        }
    }
    var summary: String {
        switch self {
        case .general: "Startup, notifications, replies"; case .voice: "Voice, Push-to-Talk, Wake Word"; case .providers: "Provider preference, local models"; case .autonomy: "Initiative and approvals"
        case .computer: "Computer Use, web research"; case .memory: "Project Memory, learning"; case .appearance: "Motion, window, developer"; case .about: "Version, diagnostics"
        }
    }
}

/// The content of ONE settings category, as a native grouped form on the HUD glass.
struct SettingsView: View {
    @Environment(AppContext.self) private var app
    let category: SettingsCategory

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

        VStack(alignment: .leading, spacing: Theme.Grid.rowGap) {
            switch category {
            case .general:
                DailySettingsSection()
                SettingsGroup("Global shortcuts") {
                    Toggle("Enable global shortcuts", isOn: $prefs.globalShortcutsEnabled)
                    LabeledContent("Compact HUD") { Text("⌥⌘").font(.system(size: 16, weight: .medium, design: .rounded)) }
                    Text("Hold Option, then press Command.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Full HUD") { Text("⌥⌘⌘").font(.system(size: 16, weight: .medium, design: .rounded)) }
                    Text("Hold Option, then press Command twice in quick succession (within 0.3 s). Either Command key works. Needs no macOS permission. Chords that include another key, a click, Shift or Control are ignored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .voice:
                VoiceSettingsSection()            // the switches and the overview are VoiceControlCards (above this form)
            case .providers:
                SettingsGroup("Intelligence provider") {
                    Picker("Preferred provider", selection: $prefs.providerPreference) {
                        ForEach(ProviderPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text("Auto routes by policy (see Routing). A specific choice never silently falls back to another provider. No paid API is ever used: a Claude or ChatGPT sign-in is a subscription, not API access.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(ProviderID.subscription, id: \.self) { id in providerRow(id, prefs: prefs) }
                    HStack {
                        Button("Refresh status") { Task { await app.refreshIntelligence() } }.disabled(app.providers.isRefreshing || app.openCode.isRefreshing)
                        if app.providers.isRefreshing || app.openCode.isRefreshing { ProgressView().controlSize(.small) }
                    }
                    Text("JARVIS uses your own signed-in Codex / Claude Code subscriptions. It never asks for API keys, passwords or tokens, and sign-in always happens through the vendor's own flow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                RoutingSettingsSection()
                OpenCodeSettingsSection()
                LocalModelSettingsSection()
            case .autonomy:
                SettingsGroup("Autonomy") {
                    Picker("Initiative", selection: $prefs.autonomyMode) {
                        ForEach(AutonomyMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("settings.autonomyMode")
                    Text(prefs.autonomyMode.explanation).font(.caption).foregroundStyle(.secondary)
                    Toggle("Notice things after a task (proactive reasoning)", isOn: $prefs.proactiveReasoningEnabled)
                    Toggle("Show proposals in the Tasks screen", isOn: $prefs.showProposals)
                }
                SettingsGroup("Approvals — what never changes") {
                    Text("Always, in every mode: critical actions (purchases, Git push, credentials, deployment, deleting) and design/product decisions need your explicit approval, and an approval is a button in the HUD.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Voice is never an approval source: saying “evet” or “approve” approves nothing, and neither does a typed yes. Wake word, Push-to-Talk, memory, web pages, screen text and AI output cannot grant a permission.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .computer:
                ComputerSettingsSection()
                WebResearchSettingsSection()
            case .memory:
                MemorySettingsSection()
                OperatorSettingsSection()
                AdaptiveSettingsSection()
            case .appearance:
                SettingsGroup("Appearance") {
                    Toggle("Reduce Motion", isOn: $prefs.reduceMotion)
                    if prefs.systemReduceMotion {
                        Text("macOS “Reduce motion” is also on, so animation is already reduced.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The central core and the background network are the only animated parts. They stop when the window is hidden and when Reduce Motion is on.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsGroup("Window") {
                    Text("JARVIS opens as a normal resizable window that fills the usable screen (not macOS full screen) and remembers the size and place you give it.").font(.caption).foregroundStyle(.secondary)
                    Button("Reset window size and position") { app.windowManager.resetFullHUDFrame() }
                }
                SettingsGroup("Developer") {
                    Toggle("Show Developer Controls", isOn: $prefs.showDeveloperControls)
                    Text("Shows developer diagnostics (paths, counters, key-monitor and voice lab details). The state simulator exists only in developer builds started with a demo flag — never in the installed app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .about:
                AboutSettingsSection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A titled group of settings on the HUD grid (replaces the system `Form` section, which would not fill the window). Controls inside read as rows: label left, control right.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        Card(title, prominence: .standard) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) { content }
                .toggleStyle(SettingsToggleStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.l) {
            configuration.label.font(Theme.Typography.rowTitle).foregroundStyle(Color.jarvisPrimary).frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}
