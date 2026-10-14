import SwiftUI

/// Settings → Adaptive learning (V0.14). Conservative defaults. Nothing here grants authority: a learned rule only adds requirements, and no MCP is ever installed or updated without a button press.
struct AdaptiveSettingsSection: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Section("Adaptive learning") {
            Toggle("Adaptive learning", isOn: $prefs.adaptiveLearningEnabled).accessibilityIdentifier("settings.adaptive")
            Toggle("Learn from completed tasks", isOn: $prefs.learnFromTasks).disabled(!prefs.adaptiveLearningEnabled)
            Toggle("Learn from my corrections", isOn: $prefs.learnFromCorrections).disabled(!prefs.adaptiveLearningEnabled)
            Toggle("Detect capability gaps", isOn: $prefs.capabilityGapDetection).disabled(!prefs.adaptiveLearningEnabled)
            Toggle("Safe disposable experiments for candidates", isOn: $prefs.safeLearningExperiments).disabled(!prefs.adaptiveLearningEnabled)
            Toggle("Auto-promote low-risk workflow rules", isOn: $prefs.autoPromoteLowRiskWorkflows).disabled(!prefs.adaptiveLearningEnabled).accessibilityIdentifier("settings.autopromote")
            Text("OFF by default. Even when on: only LOW-risk WORKFLOWS that passed their test, never a rule, a preference or anything touching security. Every promotion is recorded as made by policy.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Self-improvement level", selection: $prefs.selfImprovementLevel) { ForEach(SelfImprovementLevel.allCases, id: \.self) { Text("\($0.rawValue) · \($0.label)").tag($0) } }
                .disabled(!prefs.adaptiveLearningEnabled).accessibilityIdentifier("settings.selflevel")
            Text(prefs.selfImprovementLevel.explanation).font(.caption).foregroundStyle(.secondary)
            Text("There is no level above 4. JARVIS never changes its own source because it found an idea.").font(.caption).foregroundStyle(.secondary)
        }
        Section("MCP and skills") {
            Toggle("MCP discovery (research on request)", isOn: $prefs.mcpDiscoveryEnabled).accessibilityIdentifier("settings.mcpdiscovery")
            Toggle("Recommend MCP updates", isOn: $prefs.mcpUpdateRecommendations)
            LabeledContent("Automatic production MCP installation") { Text("never").font(.system(.caption, design: .monospaced)) }
            LabeledContent("Automatic MCP update") { Text("off (not available)").font(.system(.caption, design: .monospaced)) }
            Text("Researching a candidate installs nothing. Registering, updating or removing an MCP needs a button press in Capabilities; a servers starts only when a task needs it, runs in a sandbox with no inherited secrets, and stops when idle. Typed or spoken “yes” never approves.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
