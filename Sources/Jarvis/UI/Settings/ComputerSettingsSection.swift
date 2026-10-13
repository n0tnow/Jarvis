import SwiftUI

/// Settings → Computer Use (V0.11). Conservative: acting still needs a task you started and the macOS permission; nothing here grants anything.
struct ComputerSettingsSection: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        let p = app.computer.permissions
        Section("Computer Use") {
            Toggle("Computer Use", isOn: $prefs.computerUseEnabled).accessibilityIdentifier("settings.computer")
            Text("Lets JARVIS operate native macOS applications — open, focus, press named controls, choose menu items — when no stronger tool (project tools, the Unity bridge, web research) exists. Every step is observed, policy-checked and verified; it only ever runs inside a task you started. Off = nothing is observed or operated.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Accessibility") { Text(p.accessibility == .granted ? "granted" : "not granted").font(.system(.caption, design: .monospaced)).foregroundStyle(p.accessibility == .granted ? Color.green : Color.orange) }
            if p.accessibility != .granted {
                Button("Open Accessibility settings…") { app.computer.guideToAccessibility() }
                Text("macOS shows its own prompt; only you can allow JARVIS. JARVIS never grants itself a permission.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Vision fallback (window-scoped screenshot + on-device text recognition)", isOn: $prefs.computerVisionEnabled).disabled(!prefs.computerUseEnabled)
            Text("Only for controls that Accessibility cannot see (custom-drawn UI). It captures ONE window at a time, in memory, never stores or sends the picture, recognises text on the device, and JARVIS validates freshness and bounds before any click. Off by default; needs Screen Recording.")
                .font(.caption).foregroundStyle(.secondary)
            if prefs.computerVisionEnabled {
                LabeledContent("Screen Recording") { Text(p.screenRecording == .granted ? "granted" : "not granted").font(.system(.caption, design: .monospaced)).foregroundStyle(p.screenRecording == .granted ? Color.green : Color.orange) }
                if p.screenRecording != .granted { Button("Open Screen Recording settings…") { app.computer.guideToScreenCapture() } }
            }
            LabeledContent("Emergency stop") { Text(EmergencyStopWatcher.chordDescription).font(.system(.caption, design: .rounded)) }
            Text("Works only while a computer session is running, needs no permission, and stops every action at once. The Stop button on the Computer screen and “stop” by voice also work.").font(.caption).foregroundStyle(.secondary)
            Toggle("Developer diagnostics (counts and timings on the Computer screen)", isOn: $prefs.computerDiagnosticsEnabled).disabled(!prefs.computerUseEnabled)
            Button("Refresh permission state") { app.computer.refreshPermissions() }
        }
    }
}
