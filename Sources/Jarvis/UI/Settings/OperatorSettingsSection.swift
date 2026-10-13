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
        }
    }
}
