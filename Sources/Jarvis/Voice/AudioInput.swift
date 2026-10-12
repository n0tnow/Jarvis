import AVFoundation
import Foundation

/// A source of microphone audio that exists only while Push-to-Talk is held. Frames are bounded (≤ ~100 ms), in order, mono 16 kHz Float32.
/// Implementations: `MicrophoneInput` (real hardware) and — in `Services/Demo` — `FileAudioInput` (fixture audio for tests and live tests).
@MainActor
protocol AudioInput: AnyObject {
    var isCapturing: Bool { get }
    /// Starts capture. `onFrame` may be called from any thread. `onInterruption` reports the device going away / changing (capture has stopped).
    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void, onInterruption: @escaping @Sendable (String) -> Void) throws
    /// Stops capture and releases the audio engine. Idempotent; after it returns no more frames are delivered.
    func stop()
}

/// Converts hardware buffers to the shared 16 kHz mono Float32 format. Used from the real-time tap thread only.
final class FrameConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let ratio: Double

    init?(from source: AVAudioFormat) {
        guard let t = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFrame.sampleRate, channels: 1, interleaved: false),
              let c = AVAudioConverter(from: source, to: t) else { return nil }
        target = t; converter = c; ratio = t.sampleRate / source.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AudioFrame? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return nil }
        return AudioFrame(samples: Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength))))
    }
}

/// The real microphone through AVAudioEngine. The engine is created on `start` and destroyed on `stop`: nothing exists while idle.
@MainActor
final class MicrophoneInput: AudioInput {
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var interruption: (@Sendable (String) -> Void)?
    private(set) var isCapturing = false

    func start(onFrame: @escaping @Sendable (AudioFrame) -> Void, onInterruption: @escaping @Sendable (String) -> Void) throws {
        guard !isCapturing else { throw VoiceError.microphoneUnavailable("a capture is already running") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.microphoneUnavailable("no input device") }
        guard let converter = FrameConverter(from: format) else { throw VoiceError.microphoneUnavailable("unsupported input format") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            if let frame = converter.convert(buffer) { onFrame(frame) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw VoiceError.microphoneUnavailable(error.localizedDescription)
        }
        self.engine = engine
        isCapturing = true
        interruption = onInterruption
        // A default-device change / unplugged headset stops the engine: report it so the session can end cleanly (never a stuck LISTENING).
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                let report = self.interruption
                self.stop()
                report?("the audio device changed")
            }
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        interruption = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isCapturing = false
    }
}
