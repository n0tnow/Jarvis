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
        configureDailyConversation(on: conversationService)

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
