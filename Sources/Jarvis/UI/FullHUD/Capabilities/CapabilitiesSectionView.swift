import SwiftUI

// MARK: - Capabilities screen (V0.14): MCP servers, skills and what they are allowed to do. A discovered server is a lead, never an installation; registering, updating and removing are decided HERE with buttons.

struct CapabilitiesSectionView: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let model = app.capabilitiesModel
        PageScaffold("Capabilities", subtitle: "MCP servers and skills: untrusted capabilities that are installed and enabled only after your approval.", maxContentWidth: 1320) {
            VStack(spacing: Theme.Grid.rowGap) {
                header(model)
                if let m = model.message { CapMessageBar(text: m) { model.message = nil } }
                if !model.pending.isEmpty { CapPendingCard(model: model) }
                Picker("", selection: Bindable(model).filter) { ForEach(CapabilitiesViewModel.Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Capability filter").accessibilityIdentifier("capabilities.filter")
                HStack {
                    TextField("Filter by name, area or status", text: Bindable(model).query).textFieldStyle(.roundedBorder).accessibilityIdentifier("capabilities.search")
                    Picker("Area", selection: Bindable(model).domain) { ForEach([MCPDomain.audio, .blender, .threeD, .animation, .design, .unity, .speech, .image], id: \.self) { Text($0.label).tag($0) } }.frame(maxWidth: 220).labelsHidden().accessibilityLabel("Research area")
                    Button("FIND MCPs") { Task { await model.discover() } }.buttonStyle(.hudSecondary).fixedSize().disabled(!model.discoveryEnabled || model.busy)
                        .accessibilityHint(model.discoveryEnabled ? "Researches candidates for the chosen area; installs nothing" : "Switched off in Settings")
                }
                if let s = model.selectedServer { ServerDetail(model: model, s: s) }
                if model.filter == .skills { SkillsHint() } else if model.visible.isEmpty { empty(model) } else { ServerList(model: model) }
                if !model.advice.isEmpty { AdviceCard(model: model) }
            }
        }
        .accessibilityIdentifier("capabilities.section")
        .onAppear { model.refresh() }
        .onChange(of: app.mcp.revision) { _, _ in model.refresh() }
        .onChange(of: app.adaptiveDecisions.revision) { _, _ in model.refresh() }
    }

    private func header(_ model: CapabilitiesViewModel) -> some View {
        HUDCard("Capabilities") {
            Tag(text: "MCPs · SKILLS · NATIVE", tint: Theme.Palette.violet)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("An MCP server gives JARVIS a capability. JARVIS stays the orchestrator: it reaches a server only through typed wrappers you approved, inside the permission envelope shown here, and treats everything a server says as data.")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                Text("Researching candidates installs nothing. Registering, updating or removing one needs a button press on this screen — saying “yes” cannot approve it. Servers start only when a task needs them and stop when idle.")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }
    private func empty(_ model: CapabilitiesViewModel) -> some View {
        HUDCard("Nothing here") {
            Text(model.servers.isEmpty ? "No MCP is registered or discovered. Pick an area above and press FIND MCPs, or ask: “find an MCP for audio”." : "Nothing matches this filter.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
        }
    }
}

private struct CapMessageBar: View {
    let text: String; let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(text).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("OK", action: dismiss).buttonStyle(.hudSecondary).fixedSize()
        }
        .padding(Theme.Spacing.s).background(HUDCardBackground(accent: Theme.Palette.amber))
        .accessibilityElement(children: .combine)
    }
}

private func statusTint(_ s: MCPStatus) -> Color {
    switch s { case .active: Theme.Palette.mint; case .degraded, .blocked, .rejected: Theme.Palette.coral; case .disabled, .discovered: Color.jarvisTertiary; default: Theme.Palette.amber }
}

private struct CapPendingCard: View {
    let model: CapabilitiesViewModel
    var body: some View {
        HUDCard("Waiting for your decision", trailing: { Tag(text: "BUTTONS ONLY", tint: Theme.Palette.amber) }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(model.pending) { q in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(q.summary).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary); Tag(text: q.kind.isDestructive ? "DESTRUCTIVE" : q.risk.rawValue.uppercased(), tint: q.risk >= .high ? Theme.Palette.coral : Theme.Palette.amber); Spacer(minLength: 0) }
                        Text(q.detail).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(q.kind.isDestructive ? "APPROVE REMOVAL" : "APPROVE") { Task { await model.approve(q) } }.buttonStyle(q.kind.isDestructive ? .hudDestructive : .hudPrimary).fixedSize().accessibilityIdentifier("capabilities.approve")
                            Button("DECLINE") { model.deny(q) }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("capabilities.decline")
                            Text("A spoken or typed “yes” does not approve this.").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SkillsHint: View {
    var body: some View { HUDCard("Skills") { Text("Skills (built in and learned) are listed under Learning → Skills. A Skill is a validated workflow, not a program: it never runs by itself.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary) } }
}

private struct ServerList: View {
    let model: CapabilitiesViewModel
    var body: some View {
        HUDCard("MCP servers", trailing: { Text("\(model.visible.count)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(model.visible, id: \.id) { s in
                    Button { model.selected = s.id } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.Spacing.s) {
                                Text(s.name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                                Tag(text: s.status.label, tint: statusTint(s.status))
                                if s.revalidationRequired { Tag(text: "REVALIDATE", tint: Theme.Palette.coral) }
                                if model.running.contains(s.id) { Tag(text: "RUNNING", tint: Theme.Palette.mint) }
                                Spacer(minLength: 0)
                                Text("v\(s.version.isEmpty ? "?" : s.version)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
                            }
                            Text("\(s.domain) · \(s.envelopeLabels.joined(separator: ", ")) · health \(s.health.label) · \(model.trust(s))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.jarvisSecondary).lineLimit(2)
                            Text("source: \(s.discovery?.sourceKind ?? s.provenance) · last used \(s.lastUsedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "never") · \(s.successCount)✓ \(s.failureCount)✗")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.jarvisTertiary).lineLimit(1)
                        }
                        .padding(.vertical, 3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("capabilities.row")
                    .accessibilityLabel("\(s.name), \(s.status.label.lowercased()), health \(s.health.label), permissions \(s.envelopeLabels.joined(separator: ", "))")
                }
            }
        }
    }
}

private struct ServerDetail: View {
    let model: CapabilitiesViewModel; let s: MCPServerRecord
    var body: some View {
        HUDCard(s.name, trailing: { Button("CLOSE") { model.selected = nil }.buttonStyle(.hudSecondary).fixedSize() }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                row("Overview", "\(s.discovery?.expectedBenefit ?? s.domain) · \(s.status.label)\(s.revalidationRequired ? " · REVALIDATION REQUIRED: \(s.revalidationReason ?? "")" : "")")
                row("Typed capabilities offered to agents", s.wrappers.isEmpty ? "none" : s.wrappers.map { "\($0.capability) [\($0.envelope.label)]" }.joined(separator: ", "))
                row("Server tools (never exposed raw)", s.tools.isEmpty ? "unknown until it has been run in the sandbox" : s.tools.map { "\($0.name) [\($0.risk.label)]" }.joined(separator: ", "))
                row("Permissions (maximum)", s.envelopeLabels.joined(separator: ", "))
                row("Projects", s.allowedProjects.isEmpty ? "none" : s.allowedProjects.joined(separator: ", "))
                row("Credentials / network", "credentials: \(s.credentialRequirement) · network: \(s.network) — JARVIS never reads or stores a credential")
                row("Health", "\(s.health.label) · \(s.consecutiveFailures) failure(s) in a row · avg latency \(s.averageLatencyMS.map { "\(Int($0)) ms" } ?? "—")")
                if let b = s.benchmark { row("Benchmark (\(b.at.formatted(date: .abbreviated, time: .shortened)))", "\(b.passedCount)/\(b.cases.count) passed · cold \(Int(b.coldStartMS)) ms · warm \(Int(b.warmCallMS)) ms · deterministic \(b.deterministic ? "yes" : "no") · cleanup \(b.cleanupOK ? "complete" : "INCOMPLETE")\n\(b.boundary)") }
                else { row("Benchmark", "not run") }
                row("Source / provenance", "\(s.provenance)\(s.discovery.map { " · licence \($0.license ?? "unknown") · price \($0.price) · evidence \($0.freshness())" } ?? "")")
                let findings = (s.discovery?.findings ?? []) + (s.benchmark?.findings ?? [])
                row("Security findings (static evidence, not a verdict)", findings.isEmpty ? "none recorded" : Set(findings.map { "[\($0.severity.rawValue)] \($0.category): \($0.detail)" }).sorted().prefix(6).joined(separator: "\n"))
                if let o = model.ownership(s), o.installDirectory != nil { row("What would be removed", "\(o.ownedFiles.count) JARVIS-owned file(s) in \(o.installDirectory ?? "") · \(o.otherFilesInDirectory.count) other file(s) there stay") }
                let act = model.activity(s)
                row("Recent activity", act.isEmpty ? "none" : act.prefix(5).map { "\($0.startedAt.formatted(date: .omitted, time: .standard)) \($0.capability) → \($0.status)\($0.latencyMS.map { " \(Int($0)) ms" } ?? "")" }.joined(separator: "\n"))
                HStack {
                    if s.status == .disabled || s.status == .installed { Button("ENABLE") { Task { await model.setEnabled(s, true) } }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("capabilities.enable") }
                    if s.status.isLive { Button("DISABLE") { Task { await model.setEnabled(s, false) } }.buttonStyle(.hudSecondary).fixedSize().accessibilityIdentifier("capabilities.disable") }
                    if !s.launch.executable.isEmpty, s.status != .removed { Button("BENCHMARK") { Task { await model.benchmark(s) } }.buttonStyle(.hudSecondary).fixedSize().disabled(model.busy).accessibilityIdentifier("capabilities.benchmark") }
                    if s.status.isLive || s.status == .disabled { Button("CHECK FOR CHANGES") { model.checkDrift(s) }.buttonStyle(.hudSecondary).fixedSize() }
                    if s.status == .recommended { Button("REGISTER…") { model.requestInstall(s) }.buttonStyle(.hudPrimary).fixedSize().accessibilityIdentifier("capabilities.register") }
                    if s.discovery?.version != nil, s.discovery?.version != s.version, s.status.isLive || s.status == .disabled { Button("UPDATE…") { model.requestUpdate(s) }.buttonStyle(.hudSecondary).fixedSize() }
                    if [.discovered, .inspected, .sandboxed, .benchmarked, .recommended].contains(s.status) { Button("REJECT") { model.reject(s) }.buttonStyle(.hudSecondary).fixedSize() }
                    if [.installed, .active, .degraded, .disabled].contains(s.status) { Button("REMOVE…") { model.requestRemoval(s) }.buttonStyle(.hudDestructive).fixedSize().accessibilityIdentifier("capabilities.remove") }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
            Text(v).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AdviceCard: View {
    let model: CapabilitiesViewModel
    var body: some View {
        HUDCard("Needs attention", trailing: { Text("advice only — nothing is removed for you").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(model.advice.enumerated()), id: \.offset) { _, a in
                    Text("• \(a.detail)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
