import SwiftUI

// MARK: - Computer Use screen (V0.11): what JARVIS is doing to another application, why, and whether it was verified

struct ComputerSectionView: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        let model = app.computerModel
        ScrollView {
            VStack(spacing: Theme.Spacing.m) {
                header
                if let m = model.message { MessageBar(text: m) { model.message = nil } }
                if !model.isEnabled { disabledCard } else {
                    PermissionCard(model: model)
                    SessionCard(model: model)
                    TimelineCard(model: model)
                    HistoryCard(model: model)
                }
            }
            .frame(maxWidth: 860)
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("computer.section")
        .onAppear { model.refresh() }
        .onChange(of: app.computer.revision) { _, _ in model.revisionChanged() }
        .onChange(of: app.taskEngine.revision) { _, _ in model.revisionChanged() }
    }

    private var header: some View {
        HUDCard("Computer Use") {
            Tag(text: "TYPED · OBSERVED · VERIFIED", tint: Theme.Palette.violet)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("When no stronger tool exists, JARVIS can open applications, find windows, press named controls and choose menu items — one typed step at a time. It looks at the app, acts, and checks the result before it goes on.")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
                Text("It never reads password fields, types secrets, runs commands in Terminal, buys, sends, installs, signs in or grants permissions. Text inside an app is only data. Stop any time with the button below or hold ⌃⌥⌘.")
                    .font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }

    private var disabledCard: some View {
        HUDCard("Computer Use is off") {
            Text("Nothing observes or operates other applications. Turn it on in Settings → Computer Use.").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
        }
    }
}

private struct MessageBar: View {
    let text: String; let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(text).font(Theme.Typography.caption).foregroundStyle(Color.jarvisPrimary)
            Spacer()
            Button("OK", action: dismiss).buttonStyle(.hudSecondary).fixedSize()
        }
        .padding(Theme.Spacing.s).background(HUDCardBackground(accent: Theme.Palette.amber))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Permissions

private struct PermissionCard: View {
    let model: ComputerViewModel
    var body: some View {
        let p = model.permissions
        let visionOn = model.preferences.computerVisionEnabled
        let axGranted = p.accessibility == .granted
        let srGranted = p.screenRecording == .granted
        HUDCard("macOS permissions") {
            Button("REFRESH") { model.refresh() }.buttonStyle(.hudSecondary).fixedSize().accessibilityHint("Reads the current permission state; nothing is requested")
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                PermissionRow(name: "Accessibility", granted: axGranted, why: "Needed to see and press controls in other applications.",
                              buttonTitle: axGranted ? nil : "OPEN ACCESSIBILITY SETTINGS", run: { model.guideToAccessibility() })
                PermissionRow(name: "Screen Recording", granted: srGranted, why: visionOn ? "Needed for the window-scoped vision fallback you turned on." : "Not needed unless you turn on the vision fallback.",
                              buttonTitle: (visionOn && !srGranted) ? "OPEN SCREEN RECORDING SETTINGS" : nil, run: { model.guideToScreenCapture() })
                Text("JARVIS can only take you to the right System Settings page. Only you can allow it — it never changes a permission itself.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
            }
        }
    }
}

private struct PermissionRow: View {
    let name: String
    let granted: Bool
    let why: String
    let buttonTitle: String?
    let run: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Tag(text: granted ? "GRANTED" : "NOT GRANTED", tint: granted ? Theme.Palette.mint : Theme.Palette.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
                Text(why).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
            }
            Spacer(minLength: 0)
            if let buttonTitle { Button(buttonTitle, action: run).buttonStyle(.hudSecondary).fixedSize() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(granted ? "granted" : "not granted"). \(why)")
    }
}

// MARK: Current session

private struct SessionCard: View {
    let model: ComputerViewModel
    var body: some View {
        let t = model.currentTask
        let rt = model.runtime
        HUDCard("Current session") {
            if let t, t.task.state.isStoppable { Button("STOP") { model.stop() }.buttonStyle(.hudPrimary).fixedSize().accessibilityIdentifier("computer.stop").accessibilityHint("Stops at once; leaves the application as it is") }
        } content: {
            if let t {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(spacing: Theme.Spacing.s) {
                        Tag(text: t.task.state.label, tint: tint(t.task.state))
                        if let a = rt.currentApp { Tag(text: "CONTROLLING · \(a.uppercased())") }
                        Spacer(minLength: 0)
                    }
                    Text(t.task.title).font(Theme.Typography.headline).foregroundStyle(Color.jarvisPrimary)
                    if let step = t.currentStep { Text("Step: \(step.title)").font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary) }
                    if !t.task.activity.isEmpty { Text(t.task.activity).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
                    Group {
                        line("Capability", rt.lastCapability ?? "—")
                        line("Last observation", rt.lastObservation ?? "—")
                        line("Last action", rt.lastActionLine ?? "—")
                        line("Verification", rt.lastVerification ?? "—")
                        line("Risk", t.task.risk.rawValue.uppercased())
                    }
                    if let a = t.pendingApproval {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AWAITING YOUR APPROVAL").jarvisLabel(Theme.Opacity.textSecondary)
                            Text(a.action).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary)
                            Text(a.reason).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary)
                            HStack {
                                Button("APPROVE THIS ONE ACTION") { model.decide(a.id, approved: true) }.buttonStyle(.hudPrimary).fixedSize()
                                Button("DENY") { model.decide(a.id, approved: false) }.buttonStyle(.hudSecondary).fixedSize()
                            }
                        }
                        .padding(Theme.Spacing.s).background(HUDCardBackground(accent: Theme.Palette.amber))
                    }
                    if model.preferences.computerDiagnosticsEnabled, let o = rt.lastObservation { Text("Diagnostics: \(o)").font(.system(.caption, design: .monospaced)).foregroundStyle(Color.jarvisTertiary) }
                    if t.task.state == .interrupted {
                        Button("RESUME (OBSERVES EVERYTHING AGAIN FIRST)") { model.resume(t.id) }.buttonStyle(.hudPrimary).fixedSize().accessibilityHint("Nothing is clicked from the old session; JARVIS re-checks the app, the window and the permission before it acts")
                    }
                }
            } else {
                Text("No computer session yet. Ask, for example: “open Xcode”, “show the microphone permission page”, “reveal the project folder in Finder”.")
                    .font(Theme.Typography.body).foregroundStyle(Color.jarvisSecondary)
            }
        }
    }
    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k.uppercased()).jarvisLabel(Theme.Opacity.textTertiary).frame(width: 130, alignment: .leading)
            Text(v).font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
    private func tint(_ s: TaskState) -> Color {
        switch s { case .completed: Theme.Palette.mint; case .failed: Theme.Palette.coral; case .waitingForApproval, .interrupted, .cancelled: Theme.Palette.amber; default: Theme.Palette.accent }
    }
}

// MARK: Timeline

private struct TimelineCard: View {
    let model: ComputerViewModel
    var body: some View {
        let entries = model.runtime.timeline
        HUDCard("Action timeline") {
            Text("OBSERVED · RESOLVED · ACTED · VERIFIED").jarvisLabel(Theme.Opacity.textTertiary)
        } content: {
            if entries.isEmpty { Text("Nothing yet.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
            else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries.suffix(40)) { e in
                        HStack(alignment: .top, spacing: Theme.Spacing.s) {
                            Text(e.at, format: .dateTime.hour().minute().second()).font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.jarvisTertiary).frame(width: 64, alignment: .leading)
                            Text(e.text).font(Theme.Typography.caption).foregroundStyle(e.warning ? Theme.Palette.amber : Color.jarvisSecondary).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityIdentifier("computer.timeline")
    }
}

// MARK: History

private struct HistoryCard: View {
    let model: ComputerViewModel
    var body: some View {
        HUDCard("Earlier sessions") {
            Text("\(model.sessions.count)").jarvisLabel(Theme.Opacity.textTertiary)
        } content: {
            if model.sessions.isEmpty { Text("None.").font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary) }
            else {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(model.sessions.prefix(8)) { s in
                        let open = model.selectedSession == s.id
                        Button { model.selectedSession = open ? nil : s.id } label: {
                            HStack(spacing: Theme.Spacing.s) {
                                Tag(text: s.status.label, tint: s.status == .completed ? Theme.Palette.mint : (s.status == .failed ? Theme.Palette.coral : Theme.Palette.amber))
                                Text(s.goal).font(Theme.Typography.body).foregroundStyle(Color.jarvisPrimary).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(s.startedAt, format: .dateTime.month().day().hour().minute()).font(Theme.Typography.caption).foregroundStyle(Color.jarvisTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(s.goal), \(s.status.label)")
                        if open {
                            VStack(alignment: .leading, spacing: 2) {
                                if let c = s.capability { Text("Capability: \(c)").font(Theme.Typography.caption).foregroundStyle(Color.jarvisSecondary) }
                                ForEach(model.actions.filter { $0.kind != "observe" }.prefix(30)) { a in
                                    Text("\(a.kind) \(a.target ?? "") · \(a.status) · risk \(a.risk)\(a.verification.map { " · \($0)" } ?? "")\(a.textClass.map { " · text \($0), \(a.textLength ?? 0) chars" } ?? "")")
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(Color.jarvisTertiary)
                                }
                                if let f = s.failure { Text(f).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.amber) }
                            }.padding(.leading, Theme.Spacing.m)
                        }
                    }
                }
            }
        }
    }
}
