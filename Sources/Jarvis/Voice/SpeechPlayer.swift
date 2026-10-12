import AVFoundation
import Foundation

/// A mono slice of synthesised speech. Providers produce these; `SpeechPlayer` plays them. Memory only — never written anywhere.
struct PCMBlock: Sendable {
    var samples: [Float]
    var sampleRate: Double
    var seconds: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// What a speech provider needs from the output side. The real implementation is `SpeechPlayer` (AVAudioEngine, OUTPUT only); tests use a fake.
@MainActor
protocol PCMPlayback: AnyObject {
    var isPlaying: Bool { get }
    var onChunkStarted: ((Int) -> Void)? { get set }
    var onChunkFinished: ((Int) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// Level (dB FS RMS) of what is being played right now, with the time (`ProcessInfo.systemUptime`) it was measured. Called from the audio thread.
    var onReferenceLevel: (@Sendable (Float, TimeInterval) -> Void)? { get set }
    func enqueue(_ block: PCMBlock, chunkID: Int)
    /// No more blocks will arrive for this chunk.
    func closeChunk(_ chunkID: Int)
    /// Silences playback NOW and forgets everything queued. No `finished` is reported for dropped chunks.
    func stop()
    func shutdown()
}

/// Stateful sample-rate conversion to the player's fixed rate, one instance per synthesised chunk (state survives block boundaries: no clicks).
final class PCMResampler: @unchecked Sendable {
    static let outputRate = 48_000.0
    private var converter: AVAudioConverter?
    private var inputRate = 0.0
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMResampler.outputRate, channels: 1, interleaved: false)!

    func convert(_ block: PCMBlock) -> [Float] {
        guard !block.samples.isEmpty, block.sampleRate > 0 else { return [] }
        if block.sampleRate == Self.outputRate { return block.samples }
        if converter == nil || inputRate != block.sampleRate {
            guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: block.sampleRate, channels: 1, interleaved: false) else { return [] }
            converter = AVAudioConverter(from: src, to: target)
            inputRate = block.sampleRate
        }
        guard let converter, let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: block.sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(block.samples.count)) else { return [] }
        input.frameLength = AVAudioFrameCount(block.samples.count)
        block.samples.withUnsafeBufferPointer { src in input.floatChannelData![0].update(from: src.baseAddress!, count: block.samples.count) }
        let capacity = AVAudioFrameCount(Double(block.samples.count) * Self.outputRate / block.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}

/// Plays speech through JARVIS' OWN output engine (AVAudioEngine + AVAudioPlayerNode — output only, no input node). Owning the playback means JARVIS knows
/// exactly what it plays: the level of every output slice becomes the REFERENCE for self-speech suppression (`BargeInDetector`). The engine is created
/// when speech starts and torn down shortly after it ends, so an idle JARVIS has no audio engine at all.
@MainActor
final class SpeechPlayer: PCMPlayback {
    private struct Chunk { let id: Int; var outstanding = 0; var closed = false; var scheduled = false }

    var onChunkStarted: ((Int) -> Void)?
    var onChunkFinished: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReferenceLevel: (@Sendable (Float, TimeInterval) -> Void)? {
        get { meter.handler }
        set { meter.handler = newValue }
    }
    /// 1.0 normally. The live test sets 0 to exercise the REAL playback path (start/finish/stop timing, reference levels) without making the Mac speak aloud.
    var volume: Float = 1.0 { didSet { engine?.mainMixerNode.outputVolume = volume } }
    var idleTeardown: TimeInterval = 12

    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var _handler: (@Sendable (Float, TimeInterval) -> Void)?
        var handler: (@Sendable (Float, TimeInterval) -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return _handler }
            set { lock.lock(); _handler = newValue; lock.unlock() }
        }
        func report(_ buffer: AVAudioPCMBuffer) {
            guard let h = handler, let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[0][i] * ch[0][i] }
            let db = n > 0 ? max(-120, 20 * log10(max((sum / Float(n)).squareRoot(), 1e-9))) : -120
            h(db, ProcessInfo.processInfo.systemUptime)
        }
    }

    private let meter = Meter()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var chunks: [Chunk] = []
    private var generation = 0
    private var teardown: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMResampler.outputRate, channels: 1, interleaved: false)!
    private(set) var isPlaying = false

    // MARK: Engine lifecycle

    private func ensureEngine() -> Bool {
        teardown?.cancel(); teardown = nil
        if let engine, engine.isRunning { return true }
        discardEngine()
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = volume
        let m = meter
        e.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in m.report(buffer) }
        e.prepare()
        do { try e.start() } catch {
            e.mainMixerNode.removeTap(onBus: 0)
            onFailure?("the audio output could not start (\(error.localizedDescription))")
            return false
        }
        engine = e; node = p
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine != nil else { return }
                let wasBusy = !self.chunks.isEmpty
                self.stop()
                self.discardEngine()
                if wasBusy { self.onFailure?("the audio output device changed") }
            }
        }
        return true
    }

    private func discardEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        node?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil; node = nil
    }

    private func scheduleTeardown() {
        teardown?.cancel()
        let delay = idleTeardown
        teardown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.chunks.isEmpty else { return }
            self.discardEngine()
        }
    }

    // MARK: PCMPlayback

    func enqueue(_ block: PCMBlock, chunkID: Int) {
        guard !block.samples.isEmpty, block.sampleRate == PCMResampler.outputRate else { return }       // callers resample first
        guard ensureEngine(), let node else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(block.samples.count)
        block.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: block.samples.count) }
        let wasIdle = chunks.isEmpty
        let idx = chunks.firstIndex { $0.id == chunkID } ?? { chunks.append(Chunk(id: chunkID)); return chunks.count - 1 }()
        chunks[idx].outstanding += 1
        chunks[idx].scheduled = true
        let gen = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferPlayed(chunkID, generation: gen) }
        }
        if !node.isPlaying { node.play() }
        isPlaying = true
        if wasIdle { onChunkStarted?(chunkID) }
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

    /// Finishes every chunk at the head of the queue that is closed and fully played; announces the start of the next one.
    private func advance() {
        while let head = chunks.first, head.closed, head.outstanding == 0 {
            chunks.removeFirst()
            onChunkFinished?(head.id)
            if let next = chunks.first, next.scheduled { onChunkStarted?(next.id) }
        }
        if chunks.isEmpty {
            isPlaying = false
            scheduleTeardown()
        }
    }

    func stop() {
        generation += 1
        node?.stop()
        chunks.removeAll()
        isPlaying = false
        if engine != nil { scheduleTeardown() }
    }

    func shutdown() {
        generation += 1
        teardown?.cancel(); teardown = nil
        chunks.removeAll()
        isPlaying = false
        discardEngine()
        onChunkStarted = nil; onChunkFinished = nil; onFailure = nil
        meter.handler = nil
    }

    var hasEngine: Bool { engine != nil }
}
