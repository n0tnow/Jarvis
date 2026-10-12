@preconcurrency import AVFoundation
import Foundation
import Speech

/// Apple's on-device recogniser (macOS 26 `SpeechAnalyzer` + `DictationTranscriber`): free, no API key, no JARVIS runtime, audio never leaves
/// the Mac, native streaming (revisable partials while audio arrives). It cannot detect the language, so `auto` resolves to the system language.
/// Measured on synthetic speech (docs/VOICE_IO.md) it is fast but weak on technical words; it is the zero-setup fallback.
@MainActor
final class AppleSpeechSTTProvider: SpeechToTextProvider {
    let id = "apple-speech"
    let displayName = "Apple Speech (on-device)"
    private(set) var state: STTState = .ready
    let capabilities = STTCapabilities(languages: [.turkish, .english], partials: .nativeStreaming, autoDetectsLanguage: false, exposesConfidence: false,
                                       costClass: .system, needsNetwork: false, runtime: "macOS speech service (in-process API)")
    /// A frame count of silence appended at the end of an utterance so the recogniser commits the last word (live microphones have it naturally).
    static let trailingSilence: TimeInterval = 0.5

    static func resolved(_ language: VoiceLanguage) -> VoiceLanguage { language == .auto ? .systemDefault : language }

    func availability(for language: VoiceLanguage) async -> STTAvailability {
        guard #available(macOS 26.0, *) else { return .unavailable("Apple's on-device speech analyzer needs macOS 26 or later") }
        let lang = Self.resolved(language)
        guard let tag = lang.tag else { return .unavailable("unsupported language") }
        let locale = Locale(identifier: tag)
        let supported = await DictationTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) || $0.identifier == locale.identifier }) else {
            return .unavailable("\(lang.label) is not supported by the on-device recogniser")
        }
        // The system keeps the dictation models; `installedLocales` is the truth (AssetInventory.status can say "supported" for a locale that
        // dictation already installed and that transcribes fine — measured on macOS 26.4).
        let installed = await DictationTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) || $0.identifier == locale.identifier }) { return .ready }
        let module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .ready
        case .supported, .downloading: return .needsSetup("The \(lang.label) speech model is not installed (Apple downloads it once, about a minute).")
        default: return .unavailable("\(lang.label) is not available on this Mac")
        }
    }

    /// Explicit, user-triggered model installation (Settings → Voice → Install). Apple's own asset service does the download.
    func install(language: VoiceLanguage) async throws {
        guard #available(macOS 26.0, *), let tag = Self.resolved(language).tag else { throw VoiceError.sttUnavailable("needs macOS 26") }
        let module = DictationTranscriber(locale: Locale(identifier: tag), contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await request.downloadAndInstall() }
    }

    func makeSession(language: VoiceLanguage) async throws -> STTSession {
        guard #available(macOS 26.0, *) else { throw VoiceError.sttUnavailable("needs macOS 26") }
        let lang = Self.resolved(language)
        guard await availability(for: lang) == .ready, let tag = lang.tag else { throw VoiceError.sttUnavailable("the \(lang.label) speech model is not installed") }
        state = .starting
        do {
            let s = try await AppleSTTSession(locale: Locale(identifier: tag), language: lang.rawValue)
            state = .listening
            return s
        } catch { state = .error("\(error)"); throw VoiceError.sttFailed("could not start the recogniser") }
    }

    func unload() async { state = .ready }
    func shutdownNow() { state = .ready }
}

@available(macOS 26.0, *)
@MainActor
final class AppleSTTSession: STTSession {
    let events: AsyncStream<SpeechTranscriptEvent>
    private let continuation: AsyncStream<SpeechTranscriptEvent>.Continuation
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let source: AVAudioFormat
    private let analyzerFormat: AVAudioFormat?
    private let converter: AVAudioConverter?
    private var results: Task<Void, Never>?
    private var finals: [String] = []
    private var volatile = ""
    private var failure: Error?
    private var ended = false
    private let language: String

    init(locale: Locale, language: String) async throws {
        self.language = language
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        input = builder
        let (events, cont) = AsyncStream<SpeechTranscriptEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.events = events; continuation = cont
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFrame.sampleRate, channels: 1, interleaved: false)!
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        source = src
        analyzerFormat = best
        converter = best.flatMap { AVAudioConverter(from: src, to: $0) }
        let resultStream = transcriber.results
        results = Task { [weak self] in
            do {
                for try await r in resultStream {
                    let text = String(r.text.characters)
                    await MainActor.run { self?.receive(text, isFinal: r.isFinal) }
                }
            } catch { await MainActor.run { self?.failure = error } }
        }
        try await analyzer.start(inputSequence: stream)
    }

    private func receive(_ text: String, isFinal: Bool) {
        guard !ended else { return }
        if isFinal { finals.append(text); volatile = "" } else { volatile = text }
        let combined = TranscriptText.clean((finals + (volatile.isEmpty ? [] : [volatile])).joined(separator: " "))
        if !combined.isEmpty { continuation.yield(SpeechTranscriptEvent(text: combined, isFinal: false, language: language, confidence: nil)) }
    }

    func append(_ frame: AudioFrame) { feed(frame.samples) }

    private func feed(_ samples: [Float]) {
        guard !ended, !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if let converter, let analyzerFormat {
            let capacity = AVAudioFrameCount(Double(samples.count) * analyzerFormat.sampleRate / source.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var supplied = false
            converter.convert(to: out, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return buffer
            }
            if out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
        } else {
            input.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func finish() async throws -> SpeechTranscriptEvent? {
        guard !ended else { return nil }
        feed([Float](repeating: 0, count: Int(AudioFrame.sampleRate * AppleSpeechSTTProvider.trailingSilence)))
        input.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { failure = error }
        await results?.value
        ended = true
        continuation.finish()
        if failure != nil, finals.isEmpty { throw VoiceError.sttFailed("the recogniser stopped") }
        let text = TranscriptText.clean((finals + (volatile.isEmpty ? [] : [volatile])).joined(separator: " "))
        return text.isEmpty ? nil : SpeechTranscriptEvent(text: text, isFinal: true, language: language, confidence: nil)
    }

    func cancel() {
        guard !ended else { return }
        ended = true
        input.finish()
        results?.cancel()
        continuation.finish()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}
