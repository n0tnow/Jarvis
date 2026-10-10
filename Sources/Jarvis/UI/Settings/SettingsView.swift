import SwiftUI

/// Minimal V0.1 settings. Deliberately tiny — no fake options.
struct SettingsView: View {
    @Environment(AppContext.self) private var app

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
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 650)
    }
}
