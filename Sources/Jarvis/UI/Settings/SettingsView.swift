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
            Section {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.milestone))")
                LabeledContent("Permissions", value: "None requested")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 300)
    }
}
