import SwiftUI

/// Settings → Project Memory (V0.10). Few, conservative controls: no "remember everything" switch exists.
struct MemorySettingsSection: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Section("Project memory") {
            Toggle("Project Memory", isOn: $prefs.projectMemoryEnabled).accessibilityIdentifier("settings.memory")
            Text("Derived, source-backed knowledge about the current project (decisions, constraints, failures, research and asset decisions). Memory is context for agents and for your questions — never authority: current project files win, nothing here can approve an action, and forgetting a memory never rewrites Git, tasks or the audit trail. Off = nothing is read, written or injected.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Learn from finished tasks and verified research", isOn: $prefs.memoryAutoLearnEnabled).disabled(!prefs.projectMemoryEnabled)
            Text("Only meaningful outcomes are kept (a change that passed validation, a real failure, a verified research result). Trivial events and infrastructure failures are not remembered.").font(.caption).foregroundStyle(.secondary)
            Toggle("Ask a model to propose lessons after a task (uses one small model request)", isOn: $prefs.memoryModelLearningEnabled).disabled(!prefs.projectMemoryEnabled || !prefs.memoryAutoLearnEnabled)
            Text("A proposal is kept only if its quoted evidence appears in the task report; otherwise it is an unverified note. Models never write memory directly.").font(.caption).foregroundStyle(.secondary)
            Toggle("Semantic (meaning-based) search", isOn: $prefs.memorySemanticEnabled).disabled(!prefs.projectMemoryEnabled)
            LabeledContent("Embedding model") { Text(app.memory.embedding?.installProblem == nil ? "\(EmbeddingModel.id) · \(EmbeddingModel.license) · 118 MB" : "not installed").font(.system(.caption, design: .monospaced)) }
            Text(app.memory.embedding?.installProblem == nil ? "Runs locally, only when needed (idle unload after 2 minutes). No network, no API key, no paid service." : "Optional. Set it up once from System & Readiness; without it, search uses keywords and structure and says so.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
