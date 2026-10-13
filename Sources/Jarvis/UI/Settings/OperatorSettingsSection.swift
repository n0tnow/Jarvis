import SwiftUI

/// Settings → Project operator (V0.13). One switch for now; the visual and experiment switches arrive with those features. Nothing here grants anything.
struct OperatorSettingsSection: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Section("Project operator") {
            Toggle("Project continuation (“where are we?”, “continue”)", isOn: $prefs.projectContinuationEnabled).accessibilityIdentifier("settings.continuation")
            Text("JARVIS answers project status questions from the current files, Git, tasks, the last checkpoint and project memory (memory never outranks the files), and “continue” starts ONE bounded session (about 30 minutes, a few correction rounds) through the normal task engine. It grants no permission: approvals stay in the HUD, nothing is bought, pushed or redesigned. Off = those phrases are ordinary chat.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Visual grounding", selection: $prefs.visualGroundingMode) { ForEach(VisualGroundingMode.allCases, id: \.self) { Text($0.label).tag($0) } }.accessibilityIdentifier("settings.visualMode")
            Picker("Local vision model", selection: $prefs.visualModel) { ForEach(LocalVLMModel.allCases, id: \.self) { Text($0.label).tag($0) } }.disabled(prefs.visualGroundingMode == .off)
            LabeledContent("Local model") { Text(app.visionRuntime.isInstalled ? "installed · loads on demand, unloads when idle" : "not installed (run scripts/setup_vision_ai.sh)").font(.system(.caption, design: .monospaced)) }
            Text("Used only as a FALLBACK when a control is not reachable through Accessibility (icon-only buttons, custom-drawn or 3D views) and to look at a render of your Unity project. Everything runs on this Mac: no picture leaves it, nothing is stored, no API key. The model only proposes where something is — JARVIS validates freshness, bounds and policy before any click, and text inside a picture is never an instruction. It is not kept in memory: it loads for a task and leaves again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
