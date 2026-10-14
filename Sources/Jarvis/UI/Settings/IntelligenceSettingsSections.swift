import SwiftUI

private func mono(_ t: String, _ tint: Color = .secondary) -> some View {
    Text(t).font(.system(.caption, design: .monospaced)).foregroundStyle(tint)
}

/// Routing mode + switches + the last decision (why a provider was chosen).
struct RoutingSettingsSection: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        Section("Routing") {
            Toggle("Use the local model in Auto", isOn: $prefs.allowLocalInAuto)
            Toggle("Use verified-free OpenCode models in Auto", isOn: $prefs.allowFreeCloudInAuto)
            Text("Auto: lightweight → Local, then OpenCode free, then Claude Code / Codex · development & knowledge work → OpenCode free (only models that passed the benchmarks) → Claude Code / Codex · architecture, security, complex → Claude Code / Codex. A specific choice above never falls back.")
                .font(.caption).foregroundStyle(.secondary)
            if let d = app.coordinator.lastDecision {
                LabeledContent("Last decision") { mono(d.summary) }
            }
            Text("No paid API is ever used. Anything not verified as free, sensitive text, and (unless zero-retention) project code never go to free cloud models.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OpenCodeSettingsSection: View {
    @Environment(AppContext.self) private var app

    private var freeModels: [ModelRecord] { app.openCode.models.filter { $0.engine == .openCode && $0.provider == "opencode" && $0.isFreePoolMember } }
    private var others: [ModelRecord] { app.openCode.models.filter { !($0.provider == "opencode" && $0.isFreePoolMember) } }

    private func dataLabel(_ p: DataPolicy) -> (String, Color) {
        switch p {
        case .zeroRetention: ("ZERO-RETENTION", .green)
        case .mayTrain: ("MAY TRAIN ON DATA", .orange)
        case .trialLogged: ("TRIAL · LOGGED", .orange)
        case .unknown: ("DATA POLICY UNKNOWN", .orange)
        }
    }

    private func benchmarkLine(_ m: ModelRecord) -> String {
        _ = app.benchmarkRevision
        let parts = BenchmarkGroup.allCases.map { g -> String in
            let s = app.supervisor.benchmarkSummary(m.id, g)
            return "\(g.rawValue.prefix(3)) \(s?.label ?? "–")"
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        @Bindable var prefs = app.preferences
        Section("OpenCode (verified-free models)") {
            let state = app.openCode.state
            LabeledContent("OpenCode") {
                HStack(spacing: 6) {
                    mono(state.label, state == .ready ? .green : .orange)
                    if let v = app.openCode.version { Text(v).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if case .notInstalled = state { Text("Install OpenCode (opencode.ai), then Refresh.").font(.caption).foregroundStyle(.secondary) }
            if case .unknown = state {
                Text("Not checked yet. JARVIS reads OpenCode's prices only when needed (or when you press Refresh) — doing so may start OpenCode's own background service.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .unavailable(let why) = state { Text("Couldn't check: \(why).").font(.caption).foregroundStyle(.secondary) }
            TextField("Custom executable path (optional)", text: $prefs.openCodePathOverride).textFieldStyle(.roundedBorder).font(.caption)

            if app.openCode.state == .ready || !freeModels.isEmpty {
                if app.openCode.state != .ready { Text("Showing the last verified list — refresh before it can be used.").font(.caption2).foregroundStyle(.tertiary) }
                if freeModels.isEmpty {
                    Text("No model is currently verified as free (price 0 in the provider's data). Nothing will be sent to OpenCode automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(freeModels, id: \.id) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(m.displayName).font(.system(.body, design: .default))
                            Spacer()
                            Toggle("", isOn: Binding(get: { m.enabled }, set: { app.openCode.setEnabled(m.id, $0) })).labelsHidden().controlSize(.small)
                        }
                        HStack(spacing: 8) {
                            mono("FREE ✓", .green)
                            let d = dataLabel(m.dataPolicy); mono(d.0, d.1)
                            if let ctx = m.contextLimit { mono("\(ctx / 1000)k ctx") }
                        }
                        HStack {
                            mono(benchmarkLine(m))
                            Spacer()
                            if let p = app.benchmarkProgress[m.id] {
                                ProgressView().controlSize(.mini); mono(p)
                            } else {
                                Button("Benchmark") { Task { await app.benchmark(modelID: m.id) } }.controlSize(.small)
                            }
                        }
                        if let at = m.freeVerifiedAt { Text("Price verified \(at.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 2)
                }
                if !others.isEmpty {
                    DisclosureGroup("Not eligible (\(others.count))") {
                        ForEach(others, id: \.id) { m in
                            HStack {
                                Text(m.id).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                                Spacer()
                                Text(m.blockedReason ?? "not free-verified").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.font(.caption)
                }
            }
            HStack {
                Button("Refresh models") { Task { await app.supervisor.openCode.refresh(remote: true); app.supervisor.invalidateBenchmarks() } }
                    .disabled(app.openCode.isRefreshing)
                Button("Benchmark all free models") { Task { await app.benchmarkAllFreeModels() } }
                    .disabled(freeModels.isEmpty || !app.benchmarkProgress.isEmpty)
                if app.openCode.isRefreshing { ProgressView().controlSize(.small) }
            }
            Text("“Free” means OpenCode's current provider data lists every price component as 0 and the model is on its keyless free tier — never the model's name. Free models only serve Auto requests after passing the benchmark suite. Some free models may use prompts to improve the model; JARVIS never sends sensitive text, and project code only to zero-retention models. Models run with every tool rejected (conversation only).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LocalModelSettingsSection: View {
    @Environment(AppContext.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        let rt = app.localRuntime
        Section("Local model (lightweight tasks only)") {
            LabeledContent("Qwen3.5 4B (MLX 4-bit)") { mono(rt.state.label, rt.state.isUsableForRouting || rt.state == .running ? .green : .orange) }
            switch rt.state {
            case .runtimeMissing:
                Text("Press Set Up in System & Readiness once (creates an isolated runtime; no model is downloaded).").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            case .modelMissing:
                Text("Model folder not found. Point to an MLX model directory below. JARVIS never downloads models.").font(.caption).foregroundStyle(.secondary)
            case .failed(let why), .unavailable(let why):
                Text("Problem: \(why).").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
            TextField("Model folder", text: $prefs.localModelPath).textFieldStyle(.roundedBorder).font(.caption)
            let m = rt.metrics
            if m.jobsCompleted > 0 || m.loadSeconds != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let l = m.loadSeconds { mono("load \(String(format: "%.1f", l)) s") }
                    if let f = m.firstTokenSeconds, let t = m.generationTokensPerSecond {
                        mono("first token \(String(format: "%.2f", f)) s · \(String(format: "%.0f", t)) tok/s")
                    }
                    if let g = m.peakMemoryGB { mono("peak memory \(String(format: "%.1f", g)) GB") }
                    if let rss = rt.workerResidentBytes { mono("worker resident \(rss / 1_048_576) MB") }
                }
            }
            Stepper(value: $prefs.localIdleUnloadSeconds, in: 60...1800, step: 60) {
                Text("Unload after \(Int(prefs.localIdleUnloadSeconds / 60)) min idle")
            }
            HStack {
                Button("Test local model") { Task { await app.testLocalModel() } }.disabled(app.isTestingLocal || !rt.state.isUsableForRouting)
                Button("Unload now") { Task { await rt.unload() } }.disabled(rt.state != .ready)
                if app.isTestingLocal { ProgressView().controlSize(.small) }
                if let r = app.localTestResult { mono(r) }
            }
            Text("The local model is only used for small, bounded tasks (chat, classification, short summaries, formatting). It is never used for coding, tests, repository changes, code review, debugging, architecture, Unity or security work. It starts automatically when needed and unloads itself when idle or when memory is tight.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
