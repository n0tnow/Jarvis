import AppKit
import Foundation

// MARK: - V0.15 wiring (DEC-234…245): the daily experience around the existing systems
//
// Everything here is presentation, references, readiness or app lifecycle. Nothing starts a provider, a model, an MCP server or Unity; nothing here approves, grants or decides.

extension AppContext {
    func installDailyJarvis() {
        let prefs = preferences, stub = intelligenceIsStubbed
        continuity.presenter = { [weak self] text, lang in self?.conversationService.presenter.present(full: text, language: lang) ?? text }
        voice.onAddressed = { [weak self] in self?.conversationService.presenter.noteWakeAddressed() }

        // Which signature is this build? (macOS permissions belong to it — see CodeIdentity.) Compared with the one JARVIS last ran with; stored by this isolated/production defaults only.
        if !stub, let id = CodeIdentity.current() {
            let key = "prefs.identity.lastCdhash"
            let last = prefs.defaults.string(forKey: key)
            buildIsNewSinceLastLaunch = last != nil && last != id.cdhash
            prefs.defaults.set(id.cdhash, forKey: key)
        }

        // Readiness (read-only), setup (typed, allowlisted), notifications (opt-in)
        let notifier = JarvisNotifier()
        notifier.enabled = { prefs.notifyOnTaskEvents && !stub }
        self.notifier = notifier
        let runner = SetupRunner()
        runner.stubbed = stub
        runner.onEvent = { [weak self] message, kind in self?.store.log(message, kind: kind, persist: false) }
        runner.onFinished = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.localRuntime.inspect(); self.whisper.inspect(); self.neuralVoice.inspect()
                await self.voice.refreshProviders()
                self.readiness.refresh()
            }
        }
        setupRunner = runner
        let readiness = ReadinessService(probes: makeReadinessProbes())
        readiness.onEvent = { [weak self] message, kind in self?.store.log(message, kind: kind, persist: false) }
        self.readiness = readiness
        readinessAssistant = ReadinessAssistant(service: readiness)
        readinessAssistant.projectRoot = { [weak self] in self?.preferences.projectRoot }
        readinessAssistant.statusProvider = { [unowned self] in self.systemStatusSnapshot() }
        settingsAssistant = SettingsAssistant(preferences: preferences, ledger: storageLedger)
        // Typed actions: the real launcher only in the installed / developer app; an automated (stubbed) run can never open a real application.
        let hud = self.hud
        actionService = ActionService(launcher: stub ? StubbedApplicationLauncher() : SystemApplicationLauncher(), windows: windows,
                                      selfState: { [weak self] in SelfUIState(section: hud.section, fullOpen: self?.windows.isFullHUDOpen ?? false, compactOpen: self?.windows.isCompactHUDOpen ?? false, renderedSection: hud.renderedSection, requiresRenderAck: !stub) })
        actionService.log = { [weak self] message, kind in self?.store.log(message, kind: kind) }
        if !stub { actionService.unityOpener = SystemUnityProjectOpener() }          // automated runs never start an editor
        if stub { actionService.candidateApps = { AppCatalog.known.map { AppTarget(display: $0.display, bundleID: $0.bundleID) } } }
        // Recogniser biasing (Fix 4): names that exist on this Mac now, from structured sources only, read once when an utterance starts (nothing runs while idle).
        let service = actionService!
        voice.vocabularyProvider = { [weak self] in
            VoiceVocabulary.build(foreground: stub ? nil : NSWorkspace.shared.frontmostApplication?.localizedName,
                                  project: self.flatMap { $0.preferences.projectRoot }.map { URL(fileURLWithPath: $0).lastPathComponent },
                                  destinations: HUDSection.allCases.map { $0.rawValue.capitalized },
                                  providers: ProviderID.allCases.map(\.displayName),
                                  apps: service.candidateAppNames())
        }
        let hf = handsFree
        settingsAssistant.wakeIsActive = { hf.wakeStatus == .listening || hf.wakeStatus == .starting }
        settingsAssistant.endListening = { hf.endHandsFreeSession() }
        settingsAssistant.enterSleep = {
            guard hf.wakeStatus == .listening || hf.wakeStatus == .starting else { return false }
            Task { @MainActor in await hf.enterSleepMode() }
            return true
        }
        settingsAssistant.isSleeping = { hf.isSleepingByUser }
        settingsAssistant.resumeFromSleep = { Task { @MainActor in await hf.resumeFromSleepMode() } }
        configureDailyConversation(on: conversationService)

        // Coming back from System Settings (JARVIS becomes the active app again) re-reads every permission and the wake detector — event-driven, no polling, no restart needed.
        if !stub {
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.voice.refreshPermission()
                    _ = self.computer.refreshPermissions()
                    self.readiness.refresh()
                }
            }
        }

        // What can be known cheaply is evaluated once after launch (provider availability lists; starts nothing, asks for nothing).
        if !stub { Task { @MainActor [weak self] in await self?.voice.refreshProviders(); await self?.notifier.refreshStatus(); self?.readiness.refresh() } }

        // A decision is waiting: say so once, briefly, without its content (it can be seen on a locked screen). Never an approval.
        observeContinuously(track: { [weak self] in _ = self?.store.pendingApproval?.id }, onChange: { [weak self] in
            guard let self, !stub, self.store.pendingApproval != nil else { return }
            Task { @MainActor in await self.notifier.post(completed: nil, language: self.dailyLanguage()) }
        })
    }

    /// Wires the presentation policy, the follow-up context and the "any pending decision" guard onto a ConversationService. The app's service gets it from `installDailyJarvis`; a live test's own
    /// service (scripted answerer) gets the same configuration, so the test exercises the real thing.
    func configureDailyConversation(on service: ConversationService) {
        let prefs = preferences
        service.presenter.style = { prefs.responseStyle }
        service.presenter.addressStyle = { prefs.addressStyle }
        service.workingContext.enabled = prefs.conversationFollowUps
        observeContinuously(track: { _ = prefs.conversationFollowUps }, onChange: { [weak service] in
            service?.workingContext.enabled = prefs.conversationFollowUps
            if !prefs.conversationFollowUps { service?.workingContext.clear() }
        })
        service.speakTaskAcknowledgements = { prefs.voiceSpeakTaskAcks }
        // A bare "yes" never decides ANY pending decision, whichever system created it.
        service.hasPendingDecision = { [weak self] in
            guard let self else { return false }
            if !self.adaptiveDecisions.pending().isEmpty { return true }
            return ((try? self.repository?.proposals(statuses: [.pending], limit: 1)) ?? nil)?.isEmpty == false
        }
        service.focusProject = { [weak self] name in
            guard let self else { return .unknown(name, known: []) }
            return await self.continuity.focus(projectNamed: name)
        }
        service.readinessHandler = readinessAssistant
        service.settingsHandler = settingsAssistant
        service.actionService = actionService
        service.storageLedger = storageLedger
        configureDecisionIntelligence(on: service)
    }

    /// V1.0 decision milestone: the typed Decision layer in front of the existing pipeline. The deterministic grammar needs nothing; the optional remote classifier (Jev) stays DISABLED unless the user sets a
    /// mode, and in this build it has no transport and no credential (Phase B), so even "shadow" or "gated" simply finds it unavailable and JARVIS carries on exactly as before.
    func configureDecisionIntelligence(on service: ConversationService) {
        let prefs = preferences
        let engine = DecisionEngine()
        var parsers = DecisionParsers()
        parsers.action = { [weak self] text in MainActor.assumeIsolated { self?.actionService.recognizes(text) } }
        parsers.isKnownProjectName = { [weak self] spoken in
            guard let self else { return false }
            let rows = (try? self.repository?.memoryProjects()) ?? []
            var names = rows.flatMap { [$0.name] + $0.aliases }
            if !self.preferences.projectRoot.isEmpty { names.append((self.preferences.projectRoot as NSString).lastPathComponent) }
            return names.contains { ProjectOpenResolver.nameMatches(spoken: spoken, name: $0) }
        }
        engine.recognizer = DeterministicCommandRecognizer(parsers: parsers)
        engine.jev = JevDecisionProvider()
        engine.config = { JevConfig(mode: JevMode(rawValue: prefs.decisionJevMode) ?? .disabled, gatedMinimumConfidence: prefs.decisionJevMinConfidence, modelAlias: prefs.decisionJevModel) }
        engine.projectNames = { [weak self] in (try? self?.repository?.memoryProjects())?.map(\.name) ?? [] }
        // V1.0 final integration (JARVIS-V1JV-6): a project-bound remote answer is accepted only when the sentence names exactly ONE project of the registry the app already has.
        engine.projectResolver = { [weak self] raw in
            guard let self else { return .unresolved }
            let rows = ((try? self.repository?.memoryProjects()) ?? []).map { KnownProject(key: $0.key, name: $0.name, rootPath: $0.rootPath, kind: $0.identityKind, lastSeen: $0.lastSeen, aliases: $0.aliases) }
            return JevTargetResolver.resolve(raw: raw, projects: rows)
        }
        engine.onActivity = { [weak self] message in self?.store.log(message, kind: .info, persist: false) }
        service.decisionEngine = engine
        service.voiceFacts = { [weak self] heard in
            guard let self else { return VoiceStatusFacts(voiceOn: false, pushToTalkOn: false, wakeEnabled: false, wakeRunning: false, microphone: .unknown, recogniserReady: nil, heardViaVoice: heard) }
            return self.voiceStatusFacts(heardViaVoice: heard)
        }
        service.observedApps = { [weak self] in self?.computer.observedApps ?? [] }
        service.isAppRunning = { [weak self] name in
            guard let self, !self.intelligenceIsStubbed, let app = AppCatalog.match(tokens: ComputerText.tokens(name))?.app else { return nil }
            return self.actionService.launcher.isRunning(bundleID: app.bundleID)
        }
        service.currentProjectRoot = { prefs.projectRoot.isEmpty ? nil : prefs.projectRoot }
        service.knownProjects = { [weak self] in
            guard let self else { return [] }
            var rows = ((try? self.repository?.memoryProjects()) ?? []).map { KnownProject(key: $0.key, name: $0.name, rootPath: $0.rootPath, kind: $0.identityKind, lastSeen: $0.lastSeen, aliases: $0.aliases) }
            let root = self.preferences.projectRoot
            if !root.isEmpty, !rows.contains(where: { $0.rootPath == root }) { rows.append(KnownProject(key: "path:" + root, name: (root as NSString).lastPathComponent, rootPath: root, kind: "path", lastSeen: .distantPast)) }
            return rows
        }
        service.openProject = { [weak self] project in
            guard let self else { var r = ActionReceipt(kind: .openProject, target: project.name, executor: "none"); r.fail("JARVIS is shutting down"); return r }
            _ = await self.continuity.focus(projectNamed: project.name)         // the conversation's project (no permission change, nothing selected for writing)
            return await self.actionService.perform(.openProject(name: project.name, path: project.rootPath ?? ""))
        }
    }

    /// Facts about the voice pipeline for "Sesim geliyor mu?" — read from the same preferences, permission and readiness records the Settings and System pages show.
    func voiceStatusFacts(heardViaVoice heard: Bool) -> VoiceStatusFacts {
        let mic: MicrophoneFact
        switch voice.permission { case .granted: mic = .granted; case .denied, .restricted: mic = .denied; case .notDetermined: mic = .notAsked }
        let stt: Bool? = {
            switch readiness.snapshot.item("voice.stt")?.state { case .ready?: return true; case nil, .unknown?: return nil; default: return false }
        }()
        return VoiceStatusFacts(voiceOn: preferences.voiceEnabled, pushToTalkOn: preferences.voicePushToTalk, wakeEnabled: preferences.voiceWakeEnabled, wakeRunning: handsFree.wakeStatus == .listening,
                                microphone: mic, recogniserReady: stt, heardViaVoice: heard)
    }

    /// ONE structured system state — the same sources the Dashboard, System and Settings read (readiness records, preferences, the hands-free detector, the task engine, the agent hub).
    /// The conversation answers "sistem durumu" from this; it never asks a model.
    func systemStatusSnapshot() -> SystemStatusSnapshot {
        let detector: WakeDetectorProbe
        switch handsFree.wakeStatus {
        case .listening: detector = .running
        case .starting: detector = .starting
        case .paused: detector = .paused
        case .unavailable(let why): detector = .error(why)
        case .off: detector = .stopped
        }
        let root = preferences.projectRoot
        return SystemStatusSnapshot(state: store.state, versionLine: AppInfo.versionLine, readiness: readiness.refresh(), project: root.isEmpty ? nil : (root as NSString).lastPathComponent,
                                    activeTasks: taskEngine.activeCount, activeAgents: hub.activeRuns.count, voiceOn: preferences.voiceEnabled, pushToTalkOn: preferences.voicePushToTalk,
                                    wakeEnabled: preferences.voiceWakeEnabled, wakeDetector: detector, providerPreference: preferences.providerPreference.displayName)
    }

    /// The right ⌥ key was held while Voice is OFF: say so, visibly, once in a while — instead of ignoring the hold in silence. Nothing is switched on and the microphone stays closed; the
    /// person decides (Settings → Voice, or System & Readiness → Turn On Voice).
    func pushToTalkWhileVoiceIsOff() {
        guard !intelligenceIsStubbed, PushToTalkHint.shouldShow(lastShown: lastPushToTalkHint, now: Date()) else { return }
        lastPushToTalkHint = Date()
        let lang = dailyLanguage()
        conversation.appendJarvis(PushToTalkHint.message(lang), tone: .notice, route: .local, silent: true)
        store.log("Push-to-Talk key held while Voice is off — nothing was recorded", kind: .warning)
        if !windowManager.isFullHUDOpen { windows.showCompactHUD() }
    }

    /// The language of the current conversation (the last thing the user wrote), defaulting to the system language.
    func dailyLanguage() -> ReplyLanguage {
        if let last = conversation.messages.last(where: { $0.role == .user }) { return InputNormalizer.normalize(last.content).language }
        return (Locale.current.language.languageCode?.identifier == "tr") ? .tr : .en
    }

    /// Called by the task-finished hook with the text already chosen for the conversation.
    func dailyTaskFinished(_ v: TaskView, text: String) {
        let lang = InputNormalizer.normalize(v.task.goal).language
        let ok = v.task.state == .completed
        let shown = conversationService.presenter.present(full: text, moment: .taskCompleted, language: lang)
        conversation.appendJarvis(shown, tone: ok ? .normal : .notice, route: .worker)
        Announcer.announce(shown, high: !ok)
        if !intelligenceIsStubbed {
            if preferences.voiceEnabled, preferences.voiceSpeakCompletions { voice.speakCompletion(shown, language: lang) }
            Task { @MainActor in await notifier.post(completed: ok, language: lang) }
        }
    }

    // MARK: Probes (reads only)

    func makeReadinessProbes() -> ReadinessProbes {
        var p = ReadinessProbes()
        p.stubbed = { [weak self] in self?.intelligenceIsStubbed ?? true }
        p.schemaVersion = { [weak self] in self?.database?.schemaVersion }
        p.persistenceError = { [weak self] in self?.persistenceError }
        p.activeTasks = { [weak self] in self?.taskEngine.activeCount ?? 0 }
        p.providers = { [weak self] in
            guard let self else { return [] }
            return ProviderID.subscription.map { id in
                let s = self.providers.status(id)
                return ProviderProbeResult(id: id == .claudeCode ? "claude" : "codex", name: id.displayName, state: s.state, version: s.version, path: s.executablePath, loginHint: id.loginCommand)
            }
        }
        p.openCode = { [weak self] in
            guard let self else { return (.unknown, 0, false) }
            return (self.openCode.state, self.openCode.freePool.count, self.openCode.executableFoundOnDisk)
        }
        p.localQwen = { [weak self] in
            guard let self else { return LocalModelProbe(kind: .notConfigured, modelPath: "") }
            self.localRuntime.inspect()
            let path = self.localRuntime.config.modelPath
            switch self.localRuntime.state {
            case .notConfigured: return LocalModelProbe(kind: .notConfigured, modelPath: path)
            case .runtimeMissing: return LocalModelProbe(kind: .runtimeMissing, modelPath: path)
            case .modelMissing: return LocalModelProbe(kind: .modelMissing, modelPath: path)
            case .failed(let w), .unavailable(let w): return LocalModelProbe(kind: .failed(w), modelPath: path)
            case .ready, .running: return LocalModelProbe(kind: .ready(loaded: true), modelPath: path)
            default: return LocalModelProbe(kind: .ready(loaded: false), modelPath: path)
            }
        }
        p.vision = { [weak self] in (self?.visionRuntime.isInstalled ?? false, self?.visionRuntime.installProblem) }
        p.memoryEmbedding = { [weak self] in (self?.memory.embedding?.isInstalled ?? false, self?.memory.embedding?.installProblem) }
        p.whisper = { [weak self] in
            guard let self else { return .unavailable("not available") }
            self.whisper.inspect()
            switch self.whisper.state {
            case .runtimeMissing: return .needsSetup("The Whisper runtime is not installed. Apple's on-device recogniser works without it.")
            case .modelMissing: return .needsSetup("The Whisper model is missing at \(self.whisper.config.modelPath).")
            case .failed(let w): return .unavailable(w)
            default: return .ready
            }
        }
        p.wakeDetector = { [weak self] in
            guard let self else { return .stopped }
            switch self.handsFree.wakeStatus {
            case .listening: return .running
            case .starting: return .starting
            case .paused: return .paused
            case .unavailable(let why): return .error(why)
            case .off: return .stopped
            }
        }
        p.identity = { CodeIdentity.current() }
        p.identityChanged = { [weak self] in self?.buildIsNewSinceLastLaunch ?? false }
        p.appleSTT = { [weak self] in self?.voice.sttAvailability.first(where: { $0.key.contains("apple") })?.value }
        p.naturalVoice = { [weak self] in
            guard let self else { return (false, "") }
            if case .notInstalled = self.neuralVoice.state { return (false, "") }
            return (true, "local neural voice · loads on demand, unloads when idle")
        }
        p.wakeWord = { [weak self] in
            guard let self else { return (false, false, "") }
            var installed = true
            if case .notInstalled = self.sentinel.state { installed = false }
            return (installed, self.preferences.voiceWakeEnabled, self.handsFree.wakeStatus.label)
        }
        p.tts = { [weak self] in (self?.voice.ttsProviders ?? []).map { ($0.displayName, $0.availability()) } }
        p.voiceEnabled = { [weak self] in self?.preferences.voiceEnabled ?? false }
        p.pushToTalk = { [weak self] in
            guard let self else { return (false, true, false, false) }
            let d = self.hotkeyDiagnostics?()
            return (self.preferences.voiceEnabled, self.preferences.voicePushToTalk, d?.monitorRunning ?? false, d?.handlerAttached ?? false)
        }
        p.microphone = { [weak self] in
            switch self?.voice.permission ?? .notDetermined { case .granted: .granted; case .notDetermined: .notDetermined; case .denied: .denied; case .restricted: .restricted }
        }
        p.accessibility = { [weak self] in
            guard let self else { return .unsupported }
            self.computer.refreshPermissions()
            return self.computer.permissions.accessibility == .granted ? .granted : .notDetermined
        }
        p.screenRecording = { [weak self] in self?.computer.permissions.screenRecording == .granted ? .granted : .notDetermined }
        p.notifications = { [weak self] in self?.notifier.status ?? .notDetermined }
        p.computerUseEnabled = { [weak self] in self?.preferences.computerUseEnabled ?? true }
        p.unity = { [weak self] in
            guard let self else { return UnityProbe(editorVersions: [], hubInstalled: false, connectedProject: nil, bridge: nil, editorRunning: false) }
            let connected = self.unity.connections.values.first { $0.state == .connected }
            return UnityProbe(editorVersions: self.unity.editors.map { $0.version.description }, hubInstalled: self.unity.hubInstalled,
                              connectedProject: connected.map { ($0.root as NSString).lastPathComponent }, bridge: connected == nil ? "not connected" : "connected", editorRunning: connected != nil)
        }
        p.mcp = { [weak self] in
            guard let self else { return MCPProbe(installed: 0, active: 0, degraded: 0, recommended: 0, newestHealthCheck: nil) }
            let all = self.mcp.servers().filter { $0.status != .removed && $0.status != .rejected }
            let live = all.filter { [.installed, .active, .degraded, .disabled].contains($0.status) }
            return MCPProbe(installed: live.count, active: live.filter { $0.status == .active }.count, degraded: live.filter { $0.status == .degraded }.count,
                            recommended: all.filter { $0.status == .recommended }.count, newestHealthCheck: live.compactMap(\.lastSuccessAt).max())
        }
        p.launchAtLogin = { LaunchAtLogin.status }
        return p
    }
}

extension AppContext {
    /// A finished research task's ranked candidate records (validated V0.9 records, shown on the Research screen) become the “second one / that one” of the next turn. Only completed web tasks;
    /// the names are labels (sanitised, instruction-shaped names refused), the identity is the record id.
    func noteResearchResults(_ v: TaskView) {
        guard v.task.kind.isWebTask, v.task.state == .completed else { return }
        noteResearchCandidates(researchID: v.id, into: conversationService)
    }

    func noteResearchCandidates(researchID: UUID, into service: ConversationService) {
        guard preferences.conversationFollowUps, let repository else { return }
        let candidates = ((try? repository.researchCandidates(researchID)) ?? []).sorted { $0.rank == $1.rank ? $0.score > $1.score : ($0.rank == 0 ? false : ($1.rank == 0 ? true : $0.rank < $1.rank)) }
        guard !candidates.isEmpty else { return }
        service.workingContext.noteList(kind: .asset, entries: candidates.map { ($0.id.uuidString, $0.name, $0.url) }, source: .validatedResult("research-report"), evidence: "research:\(researchID.uuidString.prefix(8))")
    }
}


/// The hint shown when the right ⌥ key is held while Voice is OFF. Pure, so it is tested without a window.
enum PushToTalkHint {
    static let interval: TimeInterval = 20
    static func shouldShow(lastShown: Date, now: Date) -> Bool { now.timeIntervalSince(lastShown) > interval }
    static func message(_ l: ReplyLanguage) -> String {
        l == .tr ? "Sağ ⌥ tuşunu algıladım ama ses girişi kapalı, bu yüzden mikrofon açılmadı. Açmak için Sistem ve Hazırlık ekranında “Turn On Voice” düğmesine ya da Ayarlar → Voice bölümüne bakın."
                 : "I saw the right ⌥ key, but voice input is OFF, so the microphone stayed closed. Turn it on with “Turn On Voice” in System & Readiness, or in Settings → Voice."
    }
}
