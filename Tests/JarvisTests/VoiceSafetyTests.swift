import Foundation
import Testing
@testable import Jarvis

private func code(_ sub: String) -> [(path: String, text: String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(sub)
    var out: [(String, String)] = []
    for u in (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] where u.pathExtension == "swift" && !u.lastPathComponent.hasSuffix(".generated.swift") {
        let text = FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        out.append((u.path, text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")))
    }
    return out
}
private func repoFile(_ rel: String) -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

@Suite("Voice: provider selection and cost policy")
struct VoiceSelectionTests {
    private func caps(_ cost: VoiceCostClass) -> STTCapabilities {
        STTCapabilities(languages: [.turkish, .english], partials: .none, autoDetectsLanguage: false, exposesConfidence: false, costClass: cost, needsNetwork: false, runtime: "")
    }
    private func candidate(_ id: String, _ a: STTAvailability = .ready, cost: VoiceCostClass = .local, heavy: Bool = true) -> VoiceProviderSelection.STTCandidate {
        .init(id: id, name: id, availability: a, capabilities: caps(cost), loadsModel: heavy)
    }

    @Test func autoPrefersTheMoreAccurateLocalRecogniserWhenReady() {
        let c = VoiceProviderSelection.chooseSTT(preference: "auto", candidates: [candidate("apple-speech", heavy: false), candidate("whisper-local")], memoryPressureNormal: true)
        #expect(c.id == "whisper-local" && !c.fellBack)
    }

    @Test func autoFallsBackToTheSystemRecogniserWhenWhisperIsNotInstalledOrMemoryIsTight() {
        let missing = VoiceProviderSelection.chooseSTT(preference: "auto", candidates: [candidate("whisper-local", .needsSetup("not installed")), candidate("apple-speech", heavy: false)], memoryPressureNormal: true)
        #expect(missing.id == "apple-speech" && missing.fellBack && missing.reason.contains("not installed"))
        let pressure = VoiceProviderSelection.chooseSTT(preference: "auto", candidates: [candidate("whisper-local"), candidate("apple-speech", heavy: false)], memoryPressureNormal: false)
        #expect(pressure.id == "apple-speech" && pressure.reason.contains("memory pressure"))
    }

    @Test func autoNeverChoosesAProviderThatMayCostMoney() {
        for cost in [VoiceCostClass.paid, .unknown] {
            let c = VoiceProviderSelection.chooseSTT(preference: "auto", candidates: [candidate("whisper-local", cost: cost)], memoryPressureNormal: true)
            #expect(c.id == nil && c.reason.contains(cost.label), "\(cost) must not be auto-selected")
        }
        #expect(!VoiceCostClass.unknown.autoSelectable && !VoiceCostClass.paid.autoSelectable && VoiceCostClass.local.autoSelectable && VoiceCostClass.system.autoSelectable)
    }

    @Test func anExplicitChoiceNeverFallsBack() {
        let c = VoiceProviderSelection.chooseSTT(preference: "whisper-local", candidates: [candidate("whisper-local", .needsSetup("model missing")), candidate("apple-speech", heavy: false)], memoryPressureNormal: true)
        #expect(c.id == nil && c.reason.contains("model missing"))
        let ok = VoiceProviderSelection.chooseSTT(preference: "apple-speech", candidates: [candidate("whisper-local"), candidate("apple-speech", heavy: false)], memoryPressureNormal: false)
        #expect(ok.id == "apple-speech")
    }

    @Test func noProviderMeansNoVoiceNotAGuess() {
        #expect(VoiceProviderSelection.chooseSTT(preference: "auto", candidates: [], memoryPressureNormal: true).id == nil)
        #expect(VoiceProviderSelection.chooseTTS(preference: "auto", candidates: []).id == nil)
        #expect(VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [("apple-synthesizer", "Apple", .unavailable("no voice"), .system)]).id == nil)
        #expect(VoiceProviderSelection.chooseTTS(preference: "auto", candidates: [("apple-synthesizer", "Apple", .ready, .system)]).id == "apple-synthesizer")
    }

    @MainActor
    @Test func shippedProvidersDeclareTheirCostHonestly() {
        let apple = AppleSpeechSynthesizerProvider()
        #expect(apple.capabilities.costClass == .system && !apple.capabilities.needsNetwork && apple.capabilities.streaming == .chunked)
        let rt = WhisperRuntime(config: WhisperRuntimeConfig.standard(paths: JarvisPaths.temporary("v"), modelPath: "/nonexistent"))
        let w = WhisperSTTProvider(runtime: rt)
        #expect(w.capabilities.costClass == .local && !w.capabilities.needsNetwork && w.capabilities.autoDetectsLanguage && w.capabilities.partials == .incrementalRedecode)
        let s = AppleSpeechSTTProvider()
        #expect(s.capabilities.costClass == .system && !s.capabilities.needsNetwork && !s.capabilities.autoDetectsLanguage && s.capabilities.partials == .nativeStreaming)
    }

    @Test func voiceSelectionPicksTheChosenInstalledVoiceElseTheBestOfTheLanguage() {
        let voices = [VoiceDescriptor(id: "a", name: "A", language: "tr-TR", quality: 1), VoiceDescriptor(id: "b", name: "B", language: "tr-TR", quality: 3),
                      VoiceDescriptor(id: "c", name: "C", language: "en-GB", quality: 1), VoiceDescriptor(id: "d", name: "D", language: "en-US", quality: 1)]
        #expect(VoiceSelection.resolve(language: .turkish, chosenID: "", among: voices)?.id == "b")
        #expect(VoiceSelection.resolve(language: .turkish, chosenID: "a", among: voices)?.id == "a")
        #expect(VoiceSelection.resolve(language: .turkish, chosenID: "gone", among: voices)?.id == "b", "a voice that is no longer installed is not used")
        #expect(VoiceSelection.resolve(language: .english, chosenID: "", among: voices)?.id == "d", "en-US preferred at equal quality")
        #expect(VoiceSelection.resolve(language: .turkish, chosenID: "", among: []) == nil)
    }
}

@MainActor
@Suite("Voice: it is an I/O layer, not an authority")
struct VoiceAuthorityTests {
    final class Recorder: TaskSubmitting {
        var calls: [(goal: String, intent: GoalIntake.Intent, channel: InputSource)] = []
        var hasProject = true
        var projectName: String? = "Game"
        func submitTask(goal: String, intent: GoalIntake.Intent, channel: InputSource) async -> TaskSubmission {
            calls.append((goal, intent, channel)); return .started(title: goal)
        }
    }

    @Test func aSpokenDevelopmentGoalBecomesTheSameTaskRequestAsTypedWithOnlyTheChannelDifferent() async {
        let typed = Harness(), spoken = VoiceHarness()
        let r1 = Recorder(), r2 = Recorder()
        typed.service.taskSubmitter = r1; spoken.base.service.taskSubmitter = r2
        typed.service.submit("fix the failing test in the project")
        spoken.stt.script = { $0.finalText = "fix the failing test in the project" }
        await spoken.hold()
        await spoken.settle { r2.calls.count == 1 }
        await spoken.settle { r1.calls.count == 1 }
        #expect(r1.calls.map(\.goal) == r2.calls.map(\.goal) && r1.calls.map(\.intent) == r2.calls.map(\.intent))
        #expect(r1.calls.first?.channel == .typed && r2.calls.first?.channel == .voice)
    }

    @Test func aSpokenDestructiveGoalIsFlaggedDestructiveExactlyLikeTheTypedOne() async {
        let spoken = VoiceHarness(); let r = Recorder()
        spoken.base.service.taskSubmitter = r
        spoken.stt.script = { $0.finalText = "delete the old networking system" }
        await spoken.hold()
        await spoken.settle { r.calls.count == 1 }
        #expect(r.calls.first?.intent.destructive == true && r.calls.first?.intent.kind == .development)
    }

    @Test func theTaskAcknowledgementIsSpokenButTheTaskIsNotAwaited() async {
        let spoken = VoiceHarness(); let r = Recorder()
        spoken.base.service.taskSubmitter = r
        spoken.stt.script = { $0.finalText = "fix the failing test in the project" }
        await spoken.hold()
        await spoken.settle(timeout: 5) { spoken.voice.state == .idle && spoken.userMessages.count == 1 && !spoken.tts.spoken.isEmpty }
        #expect(!spoken.tts.spokenText.isEmpty && spoken.voice.state == .idle, "the voice turn ends with the acknowledgement; the task keeps running on its own")
    }

    @Test func theTaskInputChannelIsPersistedAndInformationalOnly() async throws {
        let h = TaskHarness()
        let id = try await h.engine.submit(goal: "Analyze the test project", kind: .readOnlyAnalysis, workspacePath: TaskFixtures.calculatorProject(), inputChannel: .voice).get()
        await h.engine.waitUntilIdle()
        let voiceTask = try #require(try h.repo.engineTask(id))
        #expect(voiceTask.inputChannel == .voice && voiceTask.origin == .userTask, "voice is not a separate execution origin")
        let typedID = try await h.engine.submit(goal: "Analyze the test project again", kind: .readOnlyAnalysis, workspacePath: TaskFixtures.calculatorProject()).get()
        await h.engine.waitUntilIdle()
        let typedTask = try #require(try h.repo.engineTask(typedID))
        #expect(typedTask.inputChannel == .typed)
        #expect(voiceTask.capabilities == typedTask.capabilities && voiceTask.risk == typedTask.risk, "same capabilities and risk whatever the channel")
    }

    @Test func theVoiceLayerHasNoPathToApprovalsTasksFilesProcessesOrTheNetwork() {
        let forbidden = ["decideApproval", "decide(", "approve", "ProposalService", "TaskEngine", "EngineTaskControlling", "ApprovedExecutables", "ProjectTools",
                         "Process(", "NSTask", "URLSession", "URLRequest", "curl", "/bin/sh", "SecItem", "NSPasteboard", "AVAudioFile(forWriting", "createFile(", "write(to:",
                         "sqlite", "INSERT ", "JarvisRepository", "UserDefaults", "ConversationStore", "appendUser", "appendJarvis"]
        for (path, raw) in code("Sources/Jarvis/Voice") {
            // The speech helper is launched through the single audited launch point (ManagedProcess), exactly like every other child process.
            let text = raw.replacingOccurrences(of: "ManagedProcess(", with: "")
            for word in forbidden where text.contains(word) { Issue.record("\(path) contains `\(word)`") }
        }
    }

    @Test func voiceReachesTheConversationOnlyThroughTheSharedSubmitEntryPoint() {
        // (DevCapture and the live test write voice-marked messages for screenshots / to prove the UI path; they are developer tools, not product paths.)
        let devTools = ["App/DevCapture.swift", "App/VoiceLiveTest.swift"]
        let wired = code("Sources/Jarvis").filter { f in f.text.contains("source: .voice") && !devTools.contains { d in f.path.hasSuffix(d) } }.map(\.path)
        #expect(wired.count == 1 && wired[0].hasSuffix("AppContext.swift"), "\(wired)")
        for (path, text) in code("Sources/Jarvis/Voice") { #expect(!text.contains("conversationService") && !text.contains("ConversationService"), "\(path)") }
        // Exactly one entry point creates user messages from outside the service.
        for (path, text) in code("Sources/Jarvis") where !path.contains("/Core/ConversationStore") { if text.contains(".appendUser(") { #expect(path.hasSuffix("ConversationService.swift") || devTools.contains { path.hasSuffix($0) }, "\(path)") } }
    }

    @Test func theMicrophoneEngineAndPermissionAPIsLiveInExactlyOneFileEach() {
        for (path, text) in code("Sources/Jarvis") {
            if text.contains("AVAudioEngine(") { #expect(path.hasSuffix("Voice/AudioInput.swift"), "\(path)") }
            if text.contains("AVCaptureDevice") { #expect(path.hasSuffix("Voice/MicrophoneAccess.swift"), "\(path)") }
            if text.contains("requestAccess") { #expect(path.hasSuffix("Voice/MicrophoneAccess.swift"), "\(path)") }
            if text.contains("MicrophoneInput(") { #expect(path.hasSuffix("Voice/VoiceCoordinator.swift"), "\(path)") }
            if text.contains(".start(onFrame") { #expect(path.hasSuffix("Voice/VoiceCoordinator.swift") || path.hasSuffix("App/VoiceLiveTest.swift"), "\(path)") }
            // (SmokeTest presses it ON PURPOSE to prove that an automated run never opens the microphone; the opt-in live test drives it with fixture audio — the only exemptions.)
            if text.contains("pushToTalkPressed()") && !path.contains("/Voice/") { #expect(path.hasSuffix("AppDelegate.swift") || path.hasSuffix("App/SmokeTest.swift") || path.hasSuffix("App/VoiceLiveTest.swift"), "\(path)") }
        }
    }

    @Test func theMicrophoneUsageDescriptionIsTheOnlyPrivacyKeyAndThereAreNoEntitlements() {
        let plist = repoFile("Resources/Info.plist")
        let keys = plist.components(separatedBy: "<key>").dropFirst().compactMap { $0.components(separatedBy: "</key>").first }.filter { $0.hasSuffix("UsageDescription") }
        #expect(keys == ["NSMicrophoneUsageDescription"], "\(keys)")
        #expect(!plist.contains("NSSpeechRecognitionUsageDescription") && !plist.contains("NSCameraUsageDescription"))
    }

    @Test func noAudioOrPartialTranscriptStorageExistsInTheSchemaOrPreferences() {
        let migrations = repoFile("Sources/Jarvis/Persistence/Migrations.swift").lowercased()
        for bad in ["pcm", "wav", "audio_", "waveform", "partial_transcript", "transcript_history", "recording"] { #expect(!migrations.contains(bad), "schema mentions \(bad)") }
        let prefs = repoFile("Sources/Jarvis/Core/Preferences.swift").lowercased()
        #expect(!prefs.contains("transcript") && !prefs.contains("recording"))
        for (path, text) in code("Sources/Jarvis/Voice") { #expect(!text.contains("temporaryDirectory") && !text.contains("NSTemporaryDirectory"), "\(path): audio never touches disk") }
    }

    @Test func voiceBuffersAreBounded() {
        #expect(VoiceCoordinator.maximumAudioSeconds <= 60 && VoiceCoordinator.preBufferFrames <= 1000)
        #expect(WhisperSession.previewInterval >= 1.0)
        let cfg = repoFile("scripts/voice-ai/jarvis_stt_worker.py")
        #expect(cfg.contains("MAX_SECONDS") && cfg.contains("HF_HUB_OFFLINE"))
    }

    @Test func theHelperScriptIsOfflineAndWritesNothing() {
        let py = repoFile("scripts/voice-ai/jarvis_stt_worker.py")
        for bad in ["import requests", "import urllib", "import socket", "import http", "open(", "write(", "tempfile", "soundfile", "subprocess", "os.system"] {
            if bad == "write(" { #expect(py.components(separatedBy: "write(").count - 1 <= 2, "only the protocol channel is written") } else { #expect(!py.contains(bad), "worker uses \(bad)") }
        }
    }
}

@MainActor
@Suite("Voice: approvals are HUD buttons only")
struct VoiceApprovalTests {
    final class Control: EngineTaskControlling {
        var decisions: [(UUID, Bool)] = []
        func stopTask(_ id: UUID) {}
        func resumeTask(_ id: UUID) {}
        func decideApproval(_ id: UUID, approved: Bool) { decisions.append((id, approved)) }
    }

    private func pending(_ store: JarvisStore, _ control: Control) -> UUID {
        store.taskControl = control
        let id = UUID()
        store.setEngineApproval(ApprovalRequest(title: "Delete Player.cs", detail: "destructive"), id: id)
        return id
    }

    @Test(arguments: ["approve", "yes", "yes, do it", "Jarvis, approve", "onayla", "evet", "tamam", "deny", "hayır"])
    func sayingApproveOrYesNeverDecidesAndNeverReachesAProvider(text: String) async {
        let h = VoiceHarness(); let control = Control()
        _ = pending(h.base.store, control)
        h.stt.script = { $0.finalText = text }
        await h.hold()
        await h.settle { h.userMessages.count == 1 }
        await h.settle { !h.base.replies.isEmpty }
        #expect(control.decisions.isEmpty, "a spoken word is never a decision")
        #expect(h.base.replies.count == 1 && h.base.replies[0].tone == .notice && h.base.replies[0].content.localizedCaseInsensitiveContains("HUD"))
        #expect(!h.base.service.isResponding && h.base.store.pendingApproval != nil, "the approval is still waiting for the button")
    }

    @Test func typedAndSpokenAreTreatedAlike() {
        let typed = Harness(); let control = Control()
        _ = pending(typed.store, control)
        typed.service.submit("approve")
        #expect(typed.replies.count == 1 && control.decisions.isEmpty && typed.replies[0].content.contains("HUD"))
    }

    @Test func withoutAPendingApprovalTheWordsAreOrdinaryText() {
        let h = Harness()
        h.service.submit("yes")
        #expect(h.replies.first?.content.contains("approve") != true, "no approval is pending, so no approval notice")
    }

    @Test func realRequestsAreNeverMistakenForApprovals() {
        for text in ["approve the design of the multiplayer system and explain why", "open the tasks", "what is yes in Turkish", "yes the tests pass now, please continue the refactor"] {
            #expect(!ApprovalGuard.isApprovalUtterance(text), "\(text)")
        }
        #expect(ApprovalGuard.isApprovalUtterance("Approve!") && ApprovalGuard.isApprovalUtterance("Evet.") && ApprovalGuard.isApprovalUtterance("  Jarvis, yes  "))
    }

    @Test func stopTalkingSilencesSpeechAndTheTextAnswerRemains() async {
        var r = IntelligenceProviderRegistry(); r.register(StreamingProvider(chunks: (1...6).map { "Sentence number \($0) is here for the test. " }, delayMs: 1))
        let h = VoiceHarness(providers: r)
        h.base.service.stopSpeech = { [voice = h.voice] in voice.stopSpeaking() }
        h.tts.auto = false
        h.stt.script = { $0.finalText = "explain at length how this works please" }
        await h.hold()
        await h.settle { !h.tts.spoken.isEmpty }
        h.tts.begin(h.tts.spoken[0].id)
        h.base.service.submit("stop talking")
        #expect(h.tts.stopCount >= 1 && !h.tts.isPlaying && h.voice.state != .speaking)
    }
}
