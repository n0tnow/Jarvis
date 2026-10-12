import Foundation
import Testing
@testable import Jarvis

// MARK: - Doubles (MOCK: no microphone, no recogniser, no speaker is ever touched)

@MainActor
final class FakeAudioInput: AudioInput {
    private(set) var isCapturing = false
    private(set) var startCount = 0, stopCount = 0
    var startError: Error?
    private var onFrame: (@Sendable (AudioFrame) -> Void)?
    private var onInterruption: (@Sendable (String) -> Void)?

    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void, onInterruption: @escaping @Sendable (String) -> Void) throws {
        if let startError { throw startError }
        isCapturing = true; startCount += 1
        self.onFrame = onFrame; self.onInterruption = onInterruption
    }
    func stop() { isCapturing = false; stopCount += 1; onFrame = nil; onInterruption = nil }
    /// Delivers `seconds` of audio as 100 ms frames (the real microphone's cadence).
    func feed(seconds: Double, amplitude: Float = 0.1) {
        for _ in 0..<Int((seconds * 10).rounded()) { onFrame?(AudioFrame(samples: [Float](repeating: amplitude, count: 1600))) }
    }
    func interrupt(_ why: String = "the audio device changed") { onInterruption?(why) }
    /// Delivers one prepared frame immediately.
    func feedFrame(_ frame: AudioFrame) { onFrame?(frame) }
}

@MainActor
final class FakeMicPermission: MicrophonePermissionProviding {
    var status: MicrophonePermission
    var answer: MicrophonePermission
    private(set) var requests = 0
    var delay: Duration = .zero
    init(status: MicrophonePermission = .granted, answer: MicrophonePermission = .granted) { self.status = status; self.answer = answer }
    func request() async -> MicrophonePermission {
        requests += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        status = answer
        return answer
    }
}

@MainActor
final class FakeSTTSession: STTSession {
    let events: AsyncStream<SpeechTranscriptEvent>
    let continuation: AsyncStream<SpeechTranscriptEvent>.Continuation
    private(set) var frames: [AudioFrame] = []
    private(set) var cancelled = false, finished = false
    var finalText: String? = "open the tasks screen"
    var finalLanguage: String? = "en"
    var finishDelay: Duration = .zero
    var finishError: Error?
    var seconds: Double { frames.reduce(0) { $0 + $1.seconds } }
    init() { (events, continuation) = AsyncStream<SpeechTranscriptEvent>.makeStream() }
    func append(_ frame: AudioFrame) { frames.append(frame) }
    func finish() async throws -> SpeechTranscriptEvent? {
        finished = true
        if finishDelay > .zero { try? await Task.sleep(for: finishDelay) }
        continuation.finish()
        if let finishError { throw finishError }
        return finalText.map { SpeechTranscriptEvent(text: $0, isFinal: true, language: finalLanguage, confidence: nil) }
    }
    func cancel() { cancelled = true; continuation.finish() }
    func emitPartial(_ text: String) { continuation.yield(SpeechTranscriptEvent(text: text, isFinal: false, language: "en", confidence: nil)) }
}

@MainActor
final class FakeSTT: SpeechToTextProvider {
    let id: String
    let displayName: String
    var capabilities = STTCapabilities(languages: [.turkish, .english], partials: .nativeStreaming, autoDetectsLanguage: false, exposesConfidence: false,
                                       costClass: .local, needsNetwork: false, runtime: "fake")
    var state: STTState = .ready
    var available: STTAvailability = .ready
    var startDelay: Duration = .zero
    var startError: Error?
    private(set) var sessions: [FakeSTTSession] = []
    private(set) var shutdowns = 0
    var script: ((FakeSTTSession) -> Void)?
    init(id: String = "fake-stt", name: String = "Fake STT") { self.id = id; displayName = name }
    func availability(for language: VoiceLanguage) async -> STTAvailability { available }
    func makeSession(language: VoiceLanguage) async throws -> STTSession {
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        if let startError { throw startError }
        let s = FakeSTTSession(); sessions.append(s); script?(s); return s
    }
    func unload() async {}
    func shutdownNow() { shutdowns += 1 }
}

@MainActor
final class FakeTTS: TextToSpeechProvider {
    let id = "fake-tts", displayName = "Fake TTS"
    let capabilities = TTSCapabilities(languages: [.turkish, .english], streaming: .chunked, selectableVoices: true, costClass: .system, needsNetwork: false, runtime: "fake")
    private(set) var state: TTSState = .ready
    var available: TTSAvailability = .ready
    var onEvent: ((TTSPlaybackEvent) -> Void)?
    private(set) var spoken: [SpeechChunk] = []
    private(set) var voicesUsed: [String?] = []
    private(set) var stopCount = 0, shutdowns = 0
    private var playing: [Int] = []
    /// true: each chunk starts at once and finishes `playTime` later. false: the test drives `begin`/`end`.
    var auto = true
    var playTime: Duration = .milliseconds(15)
    func availability() -> TTSAvailability { available }
    func voices() -> [VoiceDescriptor] {
        [VoiceDescriptor(id: "tr.fake", name: "Fake TR", language: "tr-TR", quality: 1), VoiceDescriptor(id: "en.fake", name: "Fake EN", language: "en-US", quality: 1)]
    }
    func speak(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double) {
        spoken.append(chunk); voicesUsed.append(voice?.id); playing.append(chunk.id); state = .synthesizing
        guard auto else { return }
        let id = chunk.id
        Task { @MainActor [weak self] in
            self?.begin(id)
            try? await Task.sleep(for: self?.playTime ?? .milliseconds(15))
            self?.end(id)
        }
    }
    func begin(_ id: Int) { guard playing.contains(id) else { return }; state = .speaking; onEvent?(.started(chunkID: id)) }
    func end(_ id: Int) { guard playing.contains(id) else { return }; playing.removeAll { $0 == id }; if playing.isEmpty { state = .ready }; onEvent?(.finished(chunkID: id)) }
    func stop() { stopCount += 1; let dropped = playing; playing = []; state = .ready; for id in dropped { onEvent?(.cancelled(chunkID: id)) } }
    func render(_ text: String, language: VoiceLanguage, voice: VoiceDescriptor?, rate: Double) async throws -> RenderedSpeech {
        RenderedSpeech(sampleRate: 22050, frames: 22050, firstBufferSeconds: 0.01, totalSeconds: 0.02, samples: [Float](repeating: 0.1, count: 22050))
    }
    func shutdownNow() { shutdowns += 1; stop() }
    var isPlaying: Bool { !playing.isEmpty }
    var spokenText: [String] { spoken.map(\.text) }
}

/// The whole voice stack wired exactly like `AppContext`, around the real ConversationService and fake edges.
@MainActor
struct VoiceHarness {
    let base: Harness
    let input = FakeAudioInput()
    let mic: FakeMicPermission
    let stt: FakeSTT
    let tts = FakeTTS()
    let voice: VoiceCoordinator
    var settings = VoiceSettings(enabled: true)

    init(permission: MicrophonePermission = .granted, providers: IntelligenceProviderRegistry = IntelligenceProviderRegistry(), enabled: Bool = true, hub: MicrophoneHub? = nil, wake: Bool = false) {
        base = Harness(providers: providers)
        mic = FakeMicPermission(status: permission)
        stt = FakeSTT()
        let input = self.input
        voice = VoiceCoordinator(sttProviders: [stt], ttsProviders: [tts], permission: mic, store: base.store, makeInput: { hub.map { HubAudioInput(hub: $0) as any AudioInput } ?? input })
        let service = base.service, conversation = base.conversation, windows = base.windows
        _ = windows
        let enabledNow = enabled, wakeNow = wake
        voice.settings = { VoiceSettings(enabled: enabledNow, wakeEnabled: wakeNow) }
        voice.conversation = { conversation.messages }
        voice.conversationBusy = { service.isAnswering }
        voice.submit = { text, _ in
            service.submit(text, origin: .other, source: .voice)
            return conversation.messages.last(where: { $0.role == .user })?.id
        }
        service.onSubmit = { [voice] source in if source == .typed { voice.typedInputArrived() } }
        observeContinuously(track: { _ = conversation.messages; _ = service.isAnswering }, onChange: { [voice] in voice.conversationChanged() })
    }

    /// Hold, speak `seconds`, release.
    func hold(seconds: Double = 1.0) async {
        voice.pushToTalkPressed()
        await settle { voice.state == .listening }
        input.feed(seconds: seconds)
        voice.pushToTalkReleased()
    }

    func settle(timeout: Double = 3, _ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    var userMessages: [ConversationMessage] { base.conversation.messages.filter { $0.role == .user } }
}
