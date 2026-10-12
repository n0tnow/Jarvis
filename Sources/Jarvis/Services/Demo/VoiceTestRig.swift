import AVFoundation
import Foundation

/// DEVELOPER / LIVE-TEST ONLY (lives in Services/Demo: production code never depends on it).
///
/// A closed acoustic loop WITHOUT hardware: a scripted "microphone" that plays synthetic speech at real time, and a simulated "speaker" that plays JARVIS'
/// real synthesised audio at real time — and leaks an attenuated, delayed copy of it into the scripted microphone, exactly like a laptop speaker does.
/// Everything else in the test is the real product: the sentinel helper (wake word + VAD), the turn manager, the recognisers, the conversation pipeline,
/// the speech chunker/renderer and the (Apple / neural) synthesisers. The coupling default (−27 dB, 120 ms) comes from a real built-in speaker→microphone
/// measurement on this Mac (docs/NATURAL_VOICE.md); the optional `--natural-acoustic` check measures the real loop again.
@MainActor
final class VoiceTestRig {
    let microphone = ScriptedMicrophone()
    private(set) var playbacks: [SimulatedPlayback] = []
    /// speaker → microphone coupling in dB (mic amplitude / speaker amplitude) and its delay.
    var echoCouplingDB: Float = -27
    var echoDelay: TimeInterval = 0.12
    var roomNoiseDB: Float = -62

    init() { microphone.rig = self }

    func makePlayback() -> SimulatedPlayback {
        let p = SimulatedPlayback()
        playbacks.append(p)
        return p
    }

    /// 16 kHz samples of everything JARVIS output during [from, to), mixed over all simulated speakers (silence when nothing played).
    func output(from: TimeInterval, count: Int) -> [Float] {
        var mix = [Float](repeating: 0, count: count)
        for p in playbacks { p.accumulate(from: from, into: &mix) }
        return mix
    }
}

/// Plays prepared 16 kHz clips at real time and mixes in room noise and the speaker echo. Frames are 40 ms. Nothing here touches hardware.
@MainActor
final class ScriptedMicrophone: AudioInput {
    weak var rig: VoiceTestRig?
    private(set) var isCapturing = false
    private(set) var startCount = 0, stopCount = 0
    private struct Script { let start: TimeInterval; let samples: [Float] }
    private var scripts: [Script] = []
    private var ticker: Task<Void, Never>?
    private var startedAt: TimeInterval = 0
    private var produced = 0
    private var rng = SystemRandomNumberGenerator()
    static let frameSamples = 640           // 40 ms @ 16 kHz

    /// Schedules `samples` (16 kHz mono) to be "spoken" `delay` seconds from now; returns the absolute start time (`systemUptime`).
    @discardableResult
    func say(_ samples: [Float], after delay: TimeInterval = 0.05, gainDB: Float = 0) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime + delay
        let g = pow(10, gainDB / 20)
        scripts.append(Script(start: start, samples: gainDB == 0 ? samples : samples.map { $0 * g }))
        return start
    }

    /// Clears everything that has not been delivered yet.
    func clearScript() { scripts.removeAll() }

    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void, onInterruption: @escaping @Sendable (String) -> Void) throws {
        guard !isCapturing else { throw VoiceError.microphoneUnavailable("already capturing") }
        isCapturing = true; startCount += 1
        startedAt = ProcessInfo.processInfo.systemUptime
        produced = 0
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isCapturing else { return }
                // frame k covers [startedAt + k·40 ms, +40 ms): produce it when its END time has arrived (a real microphone delivers after capture)
                let frameStart = self.startedAt + Double(self.produced) * 0.04
                let wait = frameStart + 0.04 - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, self.isCapturing else { return }
                onFrame(AudioFrame(samples: self.render(from: frameStart)))
                self.produced += 1
            }
        }
    }

    func stop() { ticker?.cancel(); ticker = nil; isCapturing = false; stopCount += 1 }

    private func render(from t0: TimeInterval) -> [Float] {
        let n = Self.frameSamples
        var frame = [Float](repeating: 0, count: n)
        // room noise
        let noiseAmp = pow(10, (rig?.roomNoiseDB ?? -62) / 20)
        for i in 0..<n { frame[i] = Float.random(in: -1...1, using: &rng) * noiseAmp * 1.7 }
        // the user
        for s in scripts {
            let offset = Int((t0 - s.start) * AudioFrame.sampleRate)
            if offset + n <= 0 || offset >= s.samples.count { continue }
            for i in 0..<n {
                let k = offset + i
                if k >= 0 && k < s.samples.count { frame[i] += s.samples[k] }
            }
        }
        scripts.removeAll { $0.start + Double($0.samples.count) / AudioFrame.sampleRate < t0 - 1 }
        // the speaker echo (JARVIS' own voice, attenuated and delayed)
        if let rig {
            let echo = rig.output(from: t0 - rig.echoDelay, count: n)
            let g = pow(10, rig.echoCouplingDB / 20)
            for i in 0..<n { frame[i] += echo[i] * g }
        }
        return frame
    }
}

/// Real-time playback simulation: same chunk bookkeeping and events as `SpeechPlayer`, but the audio goes to a timeline (for the echo) instead of the speaker.
@MainActor
final class SimulatedPlayback: PCMPlayback {
    private struct Chunk { let id: Int; var outstanding = 0; var closed = false; var scheduled = false }
    private struct Played { let start: TimeInterval; var samples: [Float] }       // 16 kHz

    var onChunkStarted: ((Int) -> Void)?
    var onChunkFinished: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReferenceLevel: (@Sendable (Float, TimeInterval) -> Void)?
    private(set) var isPlaying = false
    private var chunks: [Chunk] = []
    private var timeline: [Played] = []
    private var queueEnd: TimeInterval = 0
    private var generation = 0
    private var meter: Task<Void, Never>?
    /// Everything the speaker started/finished, with absolute times (for inter-chunk gap and latency measurements).
    private(set) var startedAt: [Int: TimeInterval] = [:]
    private(set) var finishedAt: [Int: TimeInterval] = [:]
    private(set) var stopRequests: [TimeInterval] = []
    private(set) var firstAudioAt: TimeInterval?

    func enqueue(_ block: PCMBlock, chunkID: Int) {
        guard !block.samples.isEmpty, block.sampleRate == PCMResampler.outputRate else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wasIdle = chunks.isEmpty
        let start = max(now, queueEnd)
        timeline.append(Played(start: start, samples: Self.decimate(block.samples)))
        queueEnd = start + block.seconds
        if timeline.count > 400 { timeline.removeFirst(timeline.count - 400) }
        let idx = chunks.firstIndex { $0.id == chunkID } ?? { chunks.append(Chunk(id: chunkID)); return chunks.count - 1 }()
        chunks[idx].outstanding += 1; chunks[idx].scheduled = true
        let gen = generation, end = queueEnd
        Task { @MainActor [weak self] in
            let wait = end - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self?.bufferPlayed(chunkID, generation: gen)
        }
        isPlaying = true
        startMeter()
        if wasIdle {
            if firstAudioAt == nil || chunkID >= 0 { firstAudioAt = start }
            startedAt[chunkID] = start
            onChunkStarted?(chunkID)
        }
    }

    func closeChunk(_ chunkID: Int) {
        if let idx = chunks.firstIndex(where: { $0.id == chunkID }) { chunks[idx].closed = true } else { chunks.append(Chunk(id: chunkID, closed: true)) }
        advance()
    }

    private func bufferPlayed(_ chunkID: Int, generation gen: Int) {
        guard gen == generation, let idx = chunks.firstIndex(where: { $0.id == chunkID }) else { return }
        chunks[idx].outstanding = max(0, chunks[idx].outstanding - 1)
        advance()
    }

    private func advance() {
        while let head = chunks.first, head.closed, head.outstanding == 0 {
            chunks.removeFirst()
            let now = ProcessInfo.processInfo.systemUptime
            finishedAt[head.id] = now
            onChunkFinished?(head.id)
            if let next = chunks.first, next.scheduled { startedAt[next.id] = now; onChunkStarted?(next.id) }
        }
        if chunks.isEmpty { isPlaying = false }
    }

    func stop() {
        generation += 1
        let now = ProcessInfo.processInfo.systemUptime
        stopRequests.append(now)
        // the sound ends NOW: cut the timeline
        timeline = timeline.compactMap { p in
            if p.start >= now { return nil }
            let keep = Int((now - p.start) * AudioFrame.sampleRate)
            return keep >= p.samples.count ? p : Played(start: p.start, samples: Array(p.samples.prefix(max(0, keep))))
        }
        queueEnd = now
        chunks.removeAll()
        isPlaying = false
    }

    func shutdown() { stop(); meter?.cancel(); meter = nil; onChunkStarted = nil; onChunkFinished = nil; onFailure = nil; onReferenceLevel = nil }

    // MARK: Timeline

    private static func decimate(_ s48: [Float]) -> [Float] {
        let n = s48.count / 3
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = (s48[3 * i] + s48[3 * i + 1] + s48[3 * i + 2]) / 3 }
        return out
    }

    /// Adds the 16 kHz audio that was OUTPUT during [from, from + count/16000) into `mix`.
    func accumulate(from: TimeInterval, into mix: inout [Float]) {
        let to = from + Double(mix.count) / AudioFrame.sampleRate
        for p in timeline {
            let pEnd = p.start + Double(p.samples.count) / AudioFrame.sampleRate
            if pEnd <= from || p.start >= to { continue }
            for i in 0..<mix.count {
                let t = from + Double(i) / AudioFrame.sampleRate
                let k = Int((t - p.start) * AudioFrame.sampleRate)
                if k >= 0 && k < p.samples.count { mix[i] += p.samples[k] }
            }
        }
    }

    /// Level of the audio playing right now, every 20 ms, only while something is queued (like the real player's mixer tap).
    private func startMeter() {
        guard meter == nil else { return }
        meter = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                var window = [Float](repeating: 0, count: 320)
                self.accumulate(from: now - 0.02, into: &window)
                self.onReferenceLevel?(AudioLevel.db(window), now)
                if !self.isPlaying && now > self.queueEnd + 0.5 { self.meter = nil; return }
            }
        }
    }
}

// MARK: - Test doubles for the closed-loop natural voice test

/// In the rig the "microphone" is a script, so the system permission is not involved (and the test never asks macOS for anything).
@MainActor
final class RigMicrophonePermission: MicrophonePermissionProviding {
    var status: MicrophonePermission { .granted }
    func request() async -> MicrophonePermission { .granted }
}

/// A provider that answers with canned text (streamed in small deltas), so a hands-free turn that is NOT a deterministic command never reaches a real model
/// and never spends quota. Short answers by default, a long one (≈ 9 sentences, mentions "Jarvis") when the request asks for an explanation.
struct ScriptedAnswerProvider: IntelligenceProvider {
    let id = "scripted-answers"
    let displayName = "Scripted answers (test)"
    func supports(_ kind: IntelligenceRequestKind) -> Bool { true }

    static func answer(for prompt: String, language: ReplyLanguage) -> String {
        let p = prompt.lowercased(with: Locale(identifier: "tr_TR"))
        let long = ["anlat", "uzun", "explain", "tell me about", "project"].contains { p.contains($0) }
        switch (language, long) {
        case (.tr, true):
            return "Projenin durumu şöyle. Ben Jarvis, EditMode ve PlayMode testlerini ayrı ayrı kontrol ettim. Tüm EditMode testleri geçti ve yeni bir Console hatası görünmüyor. PlayMode tarafında altı test çalıştı ve hepsi temiz bitti. Multiplayer testleri henüz bir fikstür bekliyor. Son görevin raporu ekranda hazır. İsterseniz bir sonraki adımı birlikte planlayabiliriz. Şimdilik onay bekleyen bir işlem yok."
        case (.tr, false):
            return "Hepsi geçti. EditMode ve PlayMode temiz. Yeni bir Console hatası da görünmüyor."
        case (.en, true):
            return "Here is where the project stands. I am Jarvis, and I checked the EditMode and PlayMode tests separately. Every EditMode test passed and no new Console error is visible. Six PlayMode tests ran and all of them finished clean. The multiplayer suite still waits for a fixture. The report of the latest task is ready on screen. We can plan the next step together if you like. Nothing is waiting for your approval right now."
        case (.en, false):
            return "All tests passed. EditMode and PlayMode are clean. There is no new Console error."
        }
    }

    func respond(to request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceEvent, Error> {
        let text = Self.answer(for: request.prompt, language: request.language)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)[...]
                while !words.isEmpty {
                    if Task.isCancelled { break }
                    let take = Array(words.prefix(5)); words = words.dropFirst(5)
                    continuation.yield(.textDelta(take.joined(separator: " ") + (words.isEmpty ? "" : " ")))
                    try? await Task.sleep(for: .milliseconds(140))
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
final class ScriptedAnswerResolver: IntelligenceProviderResolving {
    private(set) var prompts: [String] = []
    var hasProviders: Bool { true }
    func resolve(_ kind: IntelligenceRequestKind) async -> ProviderResolution { .ready(ResolvedProvider(provider: ScriptedAnswerProvider(), id: nil)) }
    func resolve(_ kind: IntelligenceRequestKind, prompt: String) async -> ProviderResolution { prompts.append(prompt); return await resolve(kind) }
    func sessionID(for id: ProviderID?) -> String? { nil }
    func recordSession(_ session: String, for id: ProviderID?) {}
    func providerStarted(_ id: ProviderID?) {}
    func providerFinished(_ id: ProviderID?, outcome: ProviderOutcome) {}
    func resetSessions() {}
}
