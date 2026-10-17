import Foundation
import Observation

// MARK: Probes — what the readiness picture is built from. Every probe is a read of something JARVIS already knows (or a cheap, non-prompting system query). Tests inject fakes.

enum PermissionStatus: String, Equatable, Sendable {
    case granted, notDetermined, denied, restricted, unsupported
    var label: String {
        switch self { case .granted: "Granted"; case .notDetermined: "Not asked yet"; case .denied: "Denied"; case .restricted: "Restricted"; case .unsupported: "Unavailable" }
    }
}

struct ProviderProbeResult: Equatable, Sendable {
    var id: String                 // "claude", "codex"
    var name: String
    var state: ProviderState
    var version: String?
    var path: String?
    var loginHint: String?
}

struct LocalModelProbe: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case notConfigured, runtimeMissing, modelMissing, ready(loaded: Bool), failed(String) }
    var kind: Kind
    var modelPath: String
}

struct UnityProbe: Equatable, Sendable {
    var editorVersions: [String]
    var hubInstalled: Bool
    var connectedProject: String?
    var bridge: String?             // "connected" / "not connected" / nil
    var editorRunning: Bool
}

struct MCPProbe: Equatable, Sendable {
    var installed: Int
    var active: Int
    var degraded: Int
    var recommended: Int
    var newestHealthCheck: Date?
}

enum LoginItemStatus: String, Equatable, Sendable {
    case enabled, disabled, requiresApproval, notFound, unsupported
    var label: String {
        switch self { case .enabled: "On"; case .disabled: "Off"; case .requiresApproval: "Waiting for your approval in System Settings"; case .notFound: "Not available for this copy of the app"; case .unsupported: "Unavailable" }
    }
}

/// What the wake-word DETECTOR is actually doing (not what the switch says).
enum WakeDetectorProbe: Equatable, Sendable {
    case running, starting, stopped, paused
    case error(String)
}

struct ReadinessProbes {
    var now: () -> Date = { Date() }
    var versionLine: () -> String = { AppInfo.versionLine }
    var installedMode: () -> Bool = { AppInfo.isApplicationBundle }
    var schemaVersion: () -> Int? = { nil }
    var persistenceError: () -> String? = { nil }
    var activeTasks: () -> Int = { 0 }
    var providers: () -> [ProviderProbeResult] = { [] }
    var openCode: () -> (state: ProviderState, freeModels: Int, found: Bool) = { (.unknown, 0, false) }
    var localQwen: () -> LocalModelProbe = { LocalModelProbe(kind: .notConfigured, modelPath: "") }
    var vision: () -> (installed: Bool, problem: String?) = { (false, nil) }
    var memoryEmbedding: () -> (installed: Bool, problem: String?) = { (false, nil) }
    var whisper: () -> STTAvailability = { .unavailable("not checked") }
    /// nil = the recogniser list has not been evaluated yet (reported as NOT CHECKED, never as broken).
    var appleSTT: () -> STTAvailability? = { nil }
    var naturalVoice: () -> (installed: Bool, detail: String) = { (false, "") }
    var wakeWord: () -> (installed: Bool, enabled: Bool, detail: String) = { (false, false, "") }
    /// The real detector state, if known. nil keeps the older "switch + helper installed" reading (tests, stubbed runs).
    var wakeDetector: (() -> WakeDetectorProbe)? = nil
    /// The running process' signature identity (nil when it cannot be read) and whether this build is new since JARVIS last ran.
    var identity: () -> CodeIdentity? = { nil }
    var identityChanged: () -> Bool = { false }
    var tts: () -> [(name: String, available: TTSAvailability)] = { [] }
    var voiceEnabled: () -> Bool = { false }
    /// Voice and Push-to-Talk as the user switched them, and whether the key monitor is running with a handler attached.
    var pushToTalk: () -> (voiceOn: Bool, pttOn: Bool, monitorRunning: Bool, handlerAttached: Bool) = { (false, true, false, false) }
    var microphone: () -> PermissionStatus = { .notDetermined }
    var accessibility: () -> PermissionStatus = { .notDetermined }
    var screenRecording: () -> PermissionStatus = { .notDetermined }
    var notifications: () -> PermissionStatus = { .notDetermined }
    var computerUseEnabled: () -> Bool = { true }
    var visionFallbackEnabled: () -> Bool = { false }
    var unity: () -> UnityProbe = { UnityProbe(editorVersions: [], hubInstalled: false, connectedProject: nil, bridge: nil, editorRunning: false) }
    var mcp: () -> MCPProbe = { MCPProbe(installed: 0, active: 0, degraded: 0, recommended: 0, newestHealthCheck: nil) }
    var launchAtLogin: () -> LoginItemStatus = { .disabled }
    /// A stub run (tests, captures) reports it plainly instead of pretending the real providers were checked.
    var stubbed: () -> Bool = { false }
}

// MARK: Service

@MainActor @Observable
final class ReadinessService {
    private(set) var snapshot = ReadinessSnapshot(items: [], at: .distantPast)
    private(set) var revision = 0
    @ObservationIgnored var probes: ReadinessProbes
    @ObservationIgnored var onEvent: ((String, ActivityKind) -> Void)?

    init(probes: ReadinessProbes = ReadinessProbes()) { self.probes = probes }

    /// Re-reads the probes. Starts nothing, asks for nothing.
    @discardableResult
    func refresh() -> ReadinessSnapshot {
        snapshot = Self.build(probes)
        revision &+= 1
        return snapshot
    }

    // MARK: Building

    static func build(_ p: ReadinessProbes) -> ReadinessSnapshot {
        let now = p.now()
        var items: [ReadinessItem] = []
        func add(_ id: String, _ c: ReadinessCategory, _ name: String, _ state: ReadinessState, _ detail: String = "", required: Bool = false, action: SetupAction? = nil, installed: Bool? = nil) {
            items.append(ReadinessItem(id: id, category: c, name: name, state: state, detail: detail, required: required, action: action, checkedAt: now, installed: installed))
        }

        // Core
        add("core.app", .core, "JARVIS app", .ready, "\(p.versionLine()) · \(p.installedMode() ? "installed application" : "development build")", required: true)
        if let err = p.persistenceError() { add("core.database", .core, "Database", .unavailable(err), "JARVIS could not open its database.", required: true) }
        else if let v = p.schemaVersion() { add("core.database", .core, "Database", .ready, "schema v\(v) · Application Support/JARVIS", required: true) }
        else { add("core.database", .core, "Database", .unavailable("not open"), "", required: true) }
        add("core.tasks", .core, "Task engine", .ready, p.activeTasks() == 0 ? "idle" : "\(p.activeTasks()) task(s) active", required: true)

        // Intelligence — a verified state needs a probe that ran; an executable that exists is only AVAILABLE.
        if p.stubbed() {
            add("provider.stub", .intelligence, "Providers", .unknown, "This is an automated run: no real provider is contacted.")
        } else {
            for r in p.providers() {
                let id = "provider." + r.id
                switch r.state {
                case .ready, .running: add(id, .intelligence, r.name, .ready, [r.version.map { "version \($0)" }, "checked with a safe status command — no model call"].compactMap { $0 }.joined(separator: " · "), installed: true)
                case .notInstalled: add(id, .intelligence, r.name, .notInstalled, "No executable was found in the usual places.", installed: false)
                case .authenticationRequired: add(id, .intelligence, r.name, .signInRequired, r.loginHint.map { "Sign in with `\($0)` in Terminal, then recheck." } ?? "Sign in, then recheck.", action: .recheck, installed: true)
                case .rateLimited: add(id, .intelligence, r.name, .degraded("usage limit reached for now"), "Installed and signed in; it is waiting for its limit to reset.")
                case .unknown: add(id, .intelligence, r.name, r.path == nil ? .unknown : .available, r.path == nil ? "" : "Found at \(r.path ?? ""); not checked yet.", action: .recheck, installed: r.path != nil ? true : nil)
                case .unavailable(let why), .failed(let why): add(id, .intelligence, r.name, .unavailable(why), "Installed, but the safe status check did not succeed.", action: .recheck)
                }
            }
            let oc = p.openCode()
            switch oc.state {
            case .ready, .running: add("provider.opencode", .intelligence, "OpenCode", .ready, "\(oc.freeModels) model(s) with verified-free price data", installed: true)
            case .notInstalled: add("provider.opencode", .intelligence, "OpenCode", .notInstalled, installed: false)
            case .unknown: add("provider.opencode", .intelligence, "OpenCode", .unknown, oc.found ? "Found on disk; not checked yet. Checking may start OpenCode's background service, so it happens only when you press Recheck or a task needs it." : "Not checked yet. Checking may start OpenCode's background service, so it happens only when you press Recheck or a task needs it.", installed: oc.found ? true : nil)
            default: add("provider.opencode", .intelligence, "OpenCode", .unavailable(oc.state.label.lowercased()), installed: oc.found ? true : nil)
            }
            add("provider.paid", .intelligence, "Paid API", .notRunning, "Not used and not possible: a Claude or ChatGPT sign-in is a subscription, never permission to use a metered API.")
        }

        // Local AI
        let q = p.localQwen()
        switch q.kind {
        case .ready(let loaded): add("local.qwen", .localAI, "Local model (Qwen)", loaded ? .ready : .available, "\(q.modelPath) · loads on demand, unloads when idle")
        case .runtimeMissing: add("local.qwen", .localAI, "Local model (Qwen)", .optionalAbsent, "The runtime is not set up. The model is found at \(q.modelPath.isEmpty ? "—" : q.modelPath) when it exists.", action: .installLocalModelRuntime)
        case .modelMissing: add("local.qwen", .localAI, "Local model (Qwen)", .optionalAbsent, "The runtime is ready but no model was found at \(q.modelPath.isEmpty ? "the configured path" : q.modelPath).", action: .chooseLocalModelFolder)
        case .notConfigured: add("local.qwen", .localAI, "Local model (Qwen)", .optionalAbsent, "Not configured.", action: .installLocalModelRuntime)
        case .failed(let why): add("local.qwen", .localAI, "Local model (Qwen)", .degraded(why), "", action: .recheck)
        }
        let v = p.vision()
        add("local.vision", .localAI, "Visual model", v.installed ? .available : .optionalAbsent, v.installed ? "loads on demand, unloads when idle" : (v.problem ?? "Not installed. Only needed for icon-only controls; text labels are read without it."), action: v.installed ? nil : .installVisionHelper)
        let w = p.whisper()
        switch w {
        case .ready: add("local.whisper", .localAI, "Whisper (local speech recognition)", .available, "installed · loads on demand")
        case .needsSetup(let why): add("local.whisper", .localAI, "Whisper (local speech recognition)", .optionalAbsent, why, action: .installSpeechRecognizer)
        case .unavailable(let why): add("local.whisper", .localAI, "Whisper (local speech recognition)", .optionalAbsent, why, action: .installSpeechRecognizer)
        }
        let e = p.memoryEmbedding()
        add("local.embedding", .localAI, "Memory search helper", e.installed ? .available : .optionalAbsent, e.installed ? "on demand, offline" : (e.problem ?? "Not installed. Memory still works with keyword search."), action: e.installed ? nil : .installMemoryHelper)

        // Voice
        // Push-to-Talk is a SWITCH the user flips, not a permission: every voice dependency can be READY while Voice is OFF and the hold of the right ⌥ key does nothing. Say so first.
        let ptt = p.pushToTalk()
        if !ptt.voiceOn {
            add("voice.input", .voice, "Voice input · Push-to-Talk (hold right ⌥)", .off, "Voice is switched OFF in Settings, so holding the right ⌥ key does nothing. Turn it on to talk to JARVIS; the microphone opens only while you hold the key.", action: .turnOnVoice)
        } else if !ptt.pttOn {
            add("voice.input", .voice, "Voice input · Push-to-Talk (hold right ⌥)", .off, "Voice is on but Push-to-Talk is switched off in Settings → Voice.", action: .turnOnVoice)
        } else if !ptt.monitorRunning || !ptt.handlerAttached {
            add("voice.input", .voice, "Voice input · Push-to-Talk (hold right ⌥)", .degraded("the key monitor is not running"), "Voice is on, but JARVIS is not watching the right ⌥ key. Switching Voice off and on again in Settings restarts it.", action: .recheck)
        } else {
            add("voice.input", .voice, "Voice input · Push-to-Talk (hold right ⌥)", .ready, "On. Hold the right ⌥ key for a moment, speak, release. The key is read without any extra macOS permission.")
        }
        let mic = p.microphone()
        add("voice.mic", .voice, "Microphone permission", mic == .granted ? .ready : (mic == .notDetermined ? .optionalAbsent : .permissionNeeded),
            mic == .granted ? "Allowed (the permission only — it does not mean Push-to-Talk is on). The microphone is open only while you hold the key (or when wake mode is on)." : (mic == .notDetermined ? "Not asked yet. macOS asks the first time you use voice." : "Not allowed — voice input is unavailable; typing is unaffected."),
            action: mic == .notDetermined ? .allowMicrophone : (mic == .granted ? nil : .openMicrophoneSettings))
        let apple = p.appleSTT()
        switch apple {
        case nil: add("voice.stt", .voice, "Speech recognition (Apple, on this Mac)", .unknown, "Not evaluated yet — press Recheck.", action: .recheck)
        case .ready?: add("voice.stt", .voice, "Speech recognition (Apple, on this Mac)", .ready, "on-device · no network")
        case .needsSetup(let why)?: add("voice.stt", .voice, "Speech recognition (Apple, on this Mac)", .optionalAbsent, why)
        case .unavailable(let why)?: add("voice.stt", .voice, "Speech recognition (Apple, on this Mac)", .unavailable(why))
        }
        let ttsList = p.tts()
        if ttsList.isEmpty { add("voice.tts", .voice, "Speech output", .unknown) }
        for t in ttsList { add("voice.tts." + t.name.lowercased().replacingOccurrences(of: " ", with: "-"), .voice, "Voice: " + t.name, t.available == .ready ? .ready : .unavailable({ if case .unavailable(let w) = t.available { return w }; return "unavailable" }())) }
        let nv = p.naturalVoice()
        add("voice.neural", .voice, "Natural JARVIS voice", nv.installed ? .available : .optionalAbsent, nv.installed ? nv.detail : "Not installed — JARVIS speaks with the Apple system voice. The final custom voice is not selected yet.", action: nv.installed ? nil : .installNaturalVoice)
        let wk = p.wakeWord()
        if let detector = p.wakeDetector?() {
            // The switch and the detector are different facts: ON + RUNNING is READY; ON but not running is said as it is (never "not running" for a detector that is fine, never "ready" for one that is not).
            switch (wk.enabled, detector) {
            case (false, _):
                add("voice.wake", .voice, "Wake word “Jarvis”", .off, "Off. Switch it on in Settings → Voice (or say “wake word'ü aç”). Push-to-Talk (hold right ⌥) works either way.", action: .turnOnWake)
            case (true, .running): add("voice.wake", .voice, "Wake word “Jarvis”", .ready, "On and RUNNING: a small local detector listens for the word. Nothing is transcribed, stored or sent before it hears it.")
            case (true, .starting): add("voice.wake", .voice, "Wake word “Jarvis”", .unknown, "On — the detector is starting.")
            case (true, .paused): add("voice.wake", .voice, "Wake word “Jarvis”", .notRunning, "On, but paused by “Uyku moduna geç”. The microphone is closed until you resume it (menu bar → Resume Wake Listening).")
            case (true, .stopped): add("voice.wake", .voice, "Wake word “Jarvis”", .degraded("the detector is not running"), "The switch is on but the detector is not running. Press Recheck; if it stays stopped, turn Wake Word off and on again in Settings → Voice.", action: .recheck)
            case (true, .error(let why)): add("voice.wake", .voice, "Wake word “Jarvis”", .degraded(why), "ERROR — \(why).", action: .recheck)
            }
        } else {
            add("voice.wake", .voice, "Wake word “Jarvis”", wk.enabled ? (wk.installed ? .ready : .unavailable("detector not installed")) : .notRunning, wk.enabled ? wk.detail : "Off by default. Push-to-Talk (hold right ⌥) always works.")
        }

        // Computer Use — PERMISSION, FEATURE and ACTIVITY are three different facts and are reported as three different rows.
        let id = p.identity()
        if let id {
            let where_ = id.isCanonicalInstall ? "" : " — NOT the installed copy (/Applications/JARVIS.app); macOS judges this copy separately"
            add("core.identity", .permissions, "This JARVIS (what macOS judges)", id.isCanonicalInstall ? .ready : .degraded("not the installed copy"),
                "\(id.appPath)\(where_) · \(id.bundleID) · \(id.adHoc ? "ad-hoc signature \(id.shortHash)" : "signed \(id.teamID ?? id.signingIdentifier)")" + (id.adHoc ? ". An ad-hoc signature changes with every build, so macOS treats each build as a new app: permissions given to an earlier build do not carry over." : ""))
        }
        let identityNote: String = {
            guard let id, id.adHoc else { return "" }
            return (p.identityChanged() ? " This build is new since JARVIS last ran (signature \(id.shortHash))." : "") + " If JARVIS already appears switched ON in System Settings, that entry belongs to an earlier build: remove it with − and add \(id.isCanonicalInstall ? "/Applications/JARVIS.app" : id.appPath) again, then press Recheck."
        }()
        let ax = p.accessibility()
        add("computer.ax", .computer, "Accessibility permission", ax == .granted ? .ready : (p.computerUseEnabled() ? .permissionNeeded : .optionalAbsent),
            ax == .granted ? "macOS allows this build of JARVIS to operate other apps through their controls (Computer Use). Allowed ≠ running: nothing is controlled until you ask." : "macOS does not allow this build of JARVIS to control other apps. Needed only for Computer Use. JARVIS never grants it to itself." + identityNote,
            action: ax == .granted ? nil : .allowAccessibility)
        let sr = p.screenRecording()
        add("computer.screen", .computer, "Screen Recording permission", sr == .granted ? .ready : .optionalAbsent,
            sr == .granted ? "macOS allows window pictures. JARVIS takes one only when you ask for it, scoped to one window, in memory, read on this Mac." : "Optional. Accessibility gives semantic control; Screen Recording only adds visual understanding when controls have no labels. If you just allowed it in System Settings, macOS applies Screen Recording only after JARVIS restarts (Restart JARVIS)." + identityNote,
            action: sr == .granted ? nil : .allowScreenRecording)
        add("computer.capture", .computer, "Window capture", sr == .granted ? .notRunning : .optionalAbsent,
            sr == .granted ? "Idle — available when a task needs a window picture. No continuous capture exists." : "Not available until the Screen Recording permission is on.")

        // Unity
        let u = p.unity()
        add("unity.editor", .unity, "Unity Editor", u.editorVersions.isEmpty ? (u.hubInstalled ? .optionalAbsent : .optionalAbsent) : .available,
            u.editorVersions.isEmpty ? (u.hubInstalled ? "Unity Hub is installed but no editor was found." : "No Unity installation found.") : "Installed: \(u.editorVersions.joined(separator: ", ")). JARVIS starts one only when a Unity task needs it.")
        add("unity.bridge", .unity, "Editor bridge", u.connectedProject != nil && u.bridge == "connected" ? .ready : .notRunning,
            u.connectedProject.map { u.bridge == "connected" ? "Connected to \($0)." : "Project \($0): editor not connected." } ?? (u.editorRunning ? "An editor is running but no project is connected." : "No project connected; no editor running."))

        // MCP
        let m = p.mcp()
        let mcpState: ReadinessState = m.degraded > 0 ? .degraded("\(m.degraded) server(s) degraded") : (m.installed == 0 ? .optionalAbsent : .notRunning)
        var mcpDetail = m.installed == 0 ? "None registered. MCP servers are only added after a benchmark and your approval." : "\(m.installed) registered · \(m.active) active · no server runs while idle"
        if let t = m.newestHealthCheck { mcpDetail += " · last health check \(Self.age(t, now: now)) ago (stored, not live)" }
        add("mcp.summary", .mcp, "MCP servers", mcpState, mcpDetail)

        // Permissions (notifications; the others are listed in their own categories above)
        let nt = p.notifications()
        add("perm.notifications", .permissions, "Notifications", nt == .granted ? .ready : (nt == .denied ? .permissionNeeded : .optionalAbsent),
            nt == .granted ? "Allowed — used for long-task completion and decisions only." : (nt == .denied ? "Denied in System Settings." : "Not asked yet. Only requested when you turn task notifications on."),
            action: nt == .granted ? nil : (nt == .denied ? .openNotificationSettings : .allowNotifications))

        // Startup
        let l = p.launchAtLogin()
        add("startup.login", .startup, "Launch at Login", l == .enabled ? .ready : (l == .requiresApproval ? .permissionNeeded : .notRunning), l.label)

        return ReadinessSnapshot(items: items, at: now)
    }

    static func age(_ t: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(t))
        if s < 90 { return "\(Int(s)) s" }
        if s < 5_400 { return "\(Int(s / 60)) min" }
        if s < 172_800 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86_400)) days"
    }
}
