import Foundation

/// A synthesiser that PRODUCES audio (it never plays it): Apple's `AVSpeechSynthesizer.write`, the neural helper, a test fake.
@MainActor
protocol PCMSynthesizing: AnyObject {
    func availability() -> TTSAvailability
    func voices() -> [VoiceDescriptor]
    /// Audio for ONE complete phrase, as it is produced (blocks arrive incrementally; the stream ends when the phrase is complete).
    func synthesize(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double) -> AsyncThrowingStream<PCMBlock, Error>
    /// Aborts every synthesis in progress (their streams finish).
    func cancelAll()
    func shutdownNow()
}

/// A `TextToSpeechProvider` assembled from a synthesiser and JARVIS' own player: phrases are synthesised (up to the speaker's in-flight limit at once),
/// their audio is scheduled strictly IN ORDER on the player (a later phrase can never overtake an earlier one), and playback events are reported when
/// the sound really starts / ends. `stop()` silences the player first and drops everything — nothing stale can play afterwards.
@MainActor
class PlayerBackedTTSProvider: TextToSpeechProvider {
    let id: String
    let displayName: String
    let capabilities: TTSCapabilities
    private(set) var state: TTSState = .ready
    var onEvent: ((TTSPlaybackEvent) -> Void)?
    let engine: any PCMSynthesizing
    let player: any PCMPlayback

    private final class Job {
        let chunk: SpeechChunk
        var task: Task<Void, Never>?
        var pending: [PCMBlock] = []
        var streamDone = false
        var failed = false
        init(_ chunk: SpeechChunk) { self.chunk = chunk }
    }
    private var jobs: [Int: Job] = [:]
    private var streamingOrder: [Int] = []          // chunks whose synthesis has not finished, in speaking order; the first one owns the player
    private var generation = 0
    private var started: Set<Int> = []

    init(id: String, displayName: String, capabilities: TTSCapabilities, engine: any PCMSynthesizing, player: any PCMPlayback) {
        self.id = id; self.displayName = displayName; self.capabilities = capabilities; self.engine = engine; self.player = player
        player.onChunkStarted = { [weak self] cid in self?.chunkStarted(cid) }
        player.onChunkFinished = { [weak self] cid in self?.chunkFinished(cid) }
        player.onFailure = { [weak self] why in self?.playerFailed(why) }
    }

    func availability() -> TTSAvailability { engine.availability() }
    func voices() -> [VoiceDescriptor] { engine.voices() }

    // MARK: Speaking

    func speak(_ chunk: SpeechChunk, voice: VoiceDescriptor?, rate: Double) {
        let job = Job(chunk)
        jobs[chunk.id] = job
        streamingOrder.append(chunk.id)
        if state == .ready || state == .stopping { state = .synthesizing }
        let gen = generation
        let stream = engine.synthesize(chunk, voice: voice, rate: rate)
        job.task = Task { [weak self] in
            let resampler = PCMResampler()
            do {
                for try await block in stream {
                    guard !Task.isCancelled, let self, self.generation == gen else { return }
                    let samples = resampler.convert(block)
                    if !samples.isEmpty { self.deliver(PCMBlock(samples: samples, sampleRate: PCMResampler.outputRate), chunkID: chunk.id) }
                }
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.streamFinished(chunk.id)
            } catch {
                guard !Task.isCancelled, let self, self.generation == gen else { return }
                self.streamFailed(chunk.id, "\(error)")
            }
        }
    }

    private func deliver(_ block: PCMBlock, chunkID: Int) {
        guard let job = jobs[chunkID] else { return }
        if streamingOrder.first == chunkID { player.enqueue(block, chunkID: chunkID) } else { job.pending.append(block) }
    }

    private func streamFinished(_ chunkID: Int) {
        guard let job = jobs[chunkID] else { return }
        job.streamDone = true
        guard streamingOrder.first == chunkID else { return }          // closed when it becomes the head
        advanceOrder()
    }

    private func streamFailed(_ chunkID: Int, _ message: String) {
        guard let job = jobs[chunkID] else { return }
        job.failed = true; job.streamDone = true
        onEvent?(.failed(chunkID: chunkID, message))
        if streamingOrder.first == chunkID { advanceOrder() }
    }

    /// The head chunk's audio is fully scheduled: close it on the player and let the next chunk in.
    private func advanceOrder() {
        while let headID = streamingOrder.first, let head = jobs[headID] {
            for b in head.pending { player.enqueue(b, chunkID: headID) }
            head.pending.removeAll()
            guard head.streamDone else { return }
            streamingOrder.removeFirst()
            if head.failed { jobs[headID] = nil }             // no `finished` for a failed phrase; the player is still told to move on
            player.closeChunk(headID)
        }
    }

    // MARK: Player events

    private func chunkStarted(_ cid: Int) {
        guard jobs[cid] != nil, !started.contains(cid) else { return }
        started.insert(cid)
        state = .speaking
        onEvent?(.started(chunkID: cid))
    }

    private func chunkFinished(_ cid: Int) {
        guard jobs.removeValue(forKey: cid) != nil else { return }
        started.remove(cid)
        if jobs.isEmpty { state = .ready }
        onEvent?(.finished(chunkID: cid))
    }

    private func playerFailed(_ why: String) {
        let ids = jobs.keys.sorted()
        stop()
        onEvent?(.failed(chunkID: ids.first, why))
    }

    // MARK: Stop

    func stop() {
        guard !jobs.isEmpty || player.isPlaying else { return }
        state = .stopping
        generation += 1
        let dropped = jobs.keys.sorted()
        for (_, job) in jobs { job.task?.cancel() }
        jobs.removeAll(); streamingOrder.removeAll(); started.removeAll()
        player.stop()
        engine.cancelAll()
        for cid in dropped { onEvent?(.cancelled(chunkID: cid)) }
        state = .ready
    }

    func shutdownNow() {
        stop()
        engine.shutdownNow()
        player.shutdown()
        onEvent = nil
    }

    // MARK: Cues

    private var cueSequence = 0
    /// Plays a short non-speech cue (the wake acknowledgement) through the same player. It never touches the speech jobs or their events.
    func playCue(_ block: PCMBlock) {
        cueSequence -= 1
        player.enqueue(block, chunkID: cueSequence)
        player.closeChunk(cueSequence)
    }

    // MARK: Rendering without playback (tests, benchmarks)

    func render(_ text: String, language: VoiceLanguage, voice: VoiceDescriptor?, rate: Double) async throws -> RenderedSpeech {
        let t0 = Date()
        var first: Double?
        var samples: [Float] = []
        var sampleRate = 0.0
        for try await block in engine.synthesize(SpeechChunk(id: -1, text: text, language: language), voice: voice, rate: rate) {
            if first == nil { first = Date().timeIntervalSince(t0) }
            sampleRate = block.sampleRate
            samples.append(contentsOf: block.samples)
        }
        guard !samples.isEmpty else { throw VoiceError.ttsUnavailable("the synthesizer produced no audio") }
        return RenderedSpeech(sampleRate: sampleRate, frames: samples.count, firstBufferSeconds: first, totalSeconds: Date().timeIntervalSince(t0), samples: samples)
    }
}
