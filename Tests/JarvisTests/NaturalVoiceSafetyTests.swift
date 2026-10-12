import Foundation
import Testing
@testable import Jarvis

private func code(_ sub: String, ext: String = "swift") -> [(path: String, text: String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(sub)
    var out: [(String, String)] = []
    for u in (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] where u.pathExtension == ext && !u.lastPathComponent.hasSuffix(".generated.swift") {
        if ext == "py" && u.path.contains("/bench/") { continue }                                    // benchmark/training tooling (developer-only) is not the runtime
        let text = FileManager.default.contents(atPath: u.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let comment = ext == "py" ? "#" : "//"
        out.append((u.path, text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(comment) }.joined(separator: "\n")))
    }
    return out
}
private func repoFile(_ rel: String) -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

@Suite("Natural voice: privacy, authority and cost guards (structural)")
struct NaturalVoiceSafetyTests {
    @Test func wakeModeIsOptInAndOffByDefault() {
        #expect(VoiceSettings().wakeEnabled == false && VoiceSettings().enabled == false)
        let prefs = repoFile("Sources/Jarvis/Core/Preferences.swift")
        #expect(prefs.contains("Key.wakeEnabled) as? Bool ?? false"), "the stored default of wake mode is OFF")
        // Nothing enables wake listening directly: it only ever starts through `applySettings()` (which checks the saved preference).
        for (path, text) in code("Sources/Jarvis") where text.contains("handsFree.enable()") || text.contains("hf.enable()") { Issue.record("\(path) enables wake mode directly") }
        let ctx = repoFile("Sources/Jarvis/App/AppContext.swift")
        #expect(ctx.contains("handsFree.applySettings()") && !ctx.contains("handsFree.enable()"), "launch only APPLIES the saved preference")
    }

    @Test func theMicrophoneHubIsTheOnlyPathToTheMicrophoneEngine() {
        for (path, text) in code("Sources/Jarvis") {
            if text.contains("hub.subscribe(") || text.contains("microphoneHub.subscribe(") { #expect(path.hasSuffix("Voice/Natural/AudioHub.swift") || path.hasSuffix("Voice/Natural/HandsFreeCoordinator.swift"), "\(path)") }
            if text.contains("MicrophoneHub(") { #expect(path.hasSuffix("App/AppContext.swift") || path.hasSuffix("Voice/Natural/AudioHub.swift"), "\(path)") }
        }
    }

    @Test func theNaturalLayerHasNoAuthorityAndNoPathToTasksApprovalsFilesOrTheNetwork() {
        let forbidden = ["decideApproval", "decide(", "approve", "ProposalService", "TaskEngine", "GoalIntake", "TaskIntake", "OpportunityEngine", "EngineTaskControlling", "taskSubmitter",
                         "ApprovedExecutables", "ProjectTools", "ConversationService", "ConversationStore", "appendUser", "appendJarvis", "JarvisRepository", "UserDefaults",
                         "Process(", "NSTask", "URLSession", "URLRequest", "curl", "/bin/sh", "osascript", "SecItem", "kSecClass", "Keychain", "NSPasteboard", "sqlite", "INSERT "]
        for (path, raw) in code("Sources/Jarvis/Voice") {
            let text = raw.replacingOccurrences(of: "ManagedProcess(", with: "")
            for word in forbidden where text.contains(word) { Issue.record("\(path) contains `\(word)`") }
        }
    }

    @Test func helperOutputIsReadOnlyAsNumbersFlagsAndAudio() {
        for file in ["SentinelRuntime.swift", "NeuralVoice.swift"] {
            let text = code("Sources/Jarvis/Voice/Natural").first { $0.path.hasSuffix(file) }?.text ?? ""
            #expect(!text.isEmpty)
            // every `as? String` read of helper output is the protocol discriminator, the request id or the base64 audio — never free text
            for line in text.split(separator: "\n") where line.contains("as? String") {
                #expect(line.contains("\"type\"") || line.contains("\"id\"") || line.contains("\"pcm\""), "helper text read in \(file): \(line)")
            }
        }
    }

    @Test func everyAudioBufferAndQueueIsBounded() {
        let hf = repoFile("Sources/Jarvis/Voice/Natural/HandsFreeCoordinator.swift")
        #expect(hf.contains("AudioRing(maxSeconds: 3.0)") && hf.contains("bufferingNewest(120)"), "wake ring ≤ 3 s, frame stream bounded")
        #expect(repoFile("Sources/Jarvis/Voice/Natural/SentinelRuntime.swift").contains("messageSamples = 1600"), "the sentinel queue flushes every 100 ms of audio")
        let speaker = repoFile("Sources/Jarvis/Voice/VoiceResponseSpeaker.swift")
        #expect(speaker.contains("maxInFlight = 2") && speaker.contains("maxQueued = 12"), "the speech queue is bounded")
        #expect(repoFile("Sources/Jarvis/Voice/Natural/BargeInDetector.swift").contains("cutoff = t - 2.0"), "the reference history keeps 2 s at most")
        #expect(repoFile("Sources/Jarvis/Voice/Natural/AudioHub.swift").contains("while seconds > maxSeconds"), "AudioRing drops the oldest audio")
        #expect(repoFile("scripts/voice-ai/jarvis_sentinel_worker.py").contains("MAX_LINE") && repoFile("scripts/voice-ai/jarvis_tts_worker.py").contains("MAX_TEXT"))
    }

    @Test func noRawAudioOrBufferCanBeWritten() {
        let writers = ["forWriting", "AVAudioRecorder", "AVAssetWriter", "ExtAudioFileCreate", "FileHandle(forWriting", "createFile(", "write(to:", ".wav\"", ".caf\"", ".m4a\"", ".pcm\"", ".raw\""]
        for (path, text) in code("Sources/Jarvis/Voice") { for w in writers where text.contains(w) { Issue.record("\(path) can write audio: `\(w)`") } }
        // the runtime helpers keep audio in memory: no file is ever opened for writing, no audio library, no temp file (they only READ their models)
        for (path, text) in code("scripts/voice-ai", ext: "py") {
            for w in ["open(", "np.save", ".tofile(", "wavfile", "soundfile", "wave.open", "tempfile", "savez"] where text.contains(w) { Issue.record("\(path) contains `\(w)`") }
        }
    }

    @Test func noPollingNoTimersInTheNaturalLayerOnlySingleShotWaits() {
        for (path, text) in code("Sources/Jarvis/Voice/Natural") {
            for w in ["Timer.", "scheduledTimer", "CADisplayLink", "DispatchSource", "while true", "repeat {"] where text.contains(w) { Issue.record("\(path) contains `\(w)`") }
        }
    }

    @Test func noCloudWakeNoPaidSpeechNoApiKeyNoVoiceCloning() {
        let banned = ["porcupine", "picovoice", "snowboy", "elevenlabs", "play.ht", "fish.audio", "fishaudio", "resemble.ai/api", "polly.", "cognitiveservices", "speech.googleapis", "texttospeech.googleapis",
                      "deepgram", "assemblyai", "ACCESS_KEY", "accessKey", "api_key", "apiKey", "API_KEY", "ref_audio", "speaker_wav", "audio_prompt", "reference_audio", "voice_clone", "clone_voice", "cloneVoice"]
        var files = code("Sources/Jarvis/Voice") + code("scripts/voice-ai", ext: "py")
        files += [("setup_voice_ai.sh", repoFile("scripts/setup_voice_ai.sh")), ("train_wake_head.sh", repoFile("scripts/train_wake_head.sh"))]
        for (path, text) in files {
            let lower = text.lowercased()
            for w in banned where lower.contains(w.lowercased()) { Issue.record("\(path) mentions `\(w)`") }
        }
    }

    @Test func pythonRuntimeHelpersHaveNoNetworkProcessOrDownloadCode() {
        let forbidden = ["import requests", "import urllib", "import socket", "import http", "import httpx", "import aiohttp", "import subprocess", "import tempfile", "snapshot_download", "hf_hub_download",
                         "urlretrieve", "os.system", "eval(", "exec(", "__import__"]
        for (path, text) in code("scripts/voice-ai", ext: "py") { for w in forbidden where text.contains(w) { Issue.record("\(path) contains `\(w)`") } }
        #expect(repoFile("scripts/voice-ai/jarvis_tts_worker.py").contains("HF_HUB_OFFLINE") && repoFile("scripts/voice-ai/jarvis_sentinel_worker.py").contains("HF_HUB_OFFLINE"))
        #expect(repoFile("scripts/voice-ai/jarvis_tts_worker.py").contains("auto_download=False"), "the neural voice never downloads at runtime")
    }

    @Test func nothingDownloadsAModelAtLaunchOrOutsideTheExplicitSetupScripts() {
        for (path, text) in code("Sources/Jarvis/Voice") + code("Sources/Jarvis/App").filter({ $0.path.hasSuffix("AppContext.swift") || $0.path.hasSuffix("AppDelegate.swift") }) {
            for w in ["snapshot_download", "hf_hub_download", "huggingface.co", "github.com/dscripka", "curl "] where text.contains(w) { Issue.record("\(path) contains `\(w)`") }
        }
        for script in ["scripts/build_app.sh", "scripts/test.sh"] { #expect(!repoFile(script).contains("snapshot_download"), Comment(rawValue: script)) }
    }

    @Test func noVoiceModelAudioOrCredentialArtefactSitsInTheSourceTree() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bad: Set<String> = ["wav", "caf", "aiff", "aif", "m4a", "mp3", "flac", "ogg", "opus", "pcm", "onnx", "npz", "safetensors", "gguf"]
        for sub in ["Sources", "scripts", "Resources", "Tests", "docs", "UnityBridge"] {
            let urls = (FileManager.default.enumerator(at: root.appendingPathComponent(sub), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            for u in urls where bad.contains(u.pathExtension.lowercased()) { Issue.record("artefact in the repository tree: \(u.path)") }
        }
    }

    @Test func theVoiceIdentityDoesNotCloneAnyoneAndIsDeclaredAsOriginal() {
        let id = repoFile("Sources/Jarvis/Voice/Natural/VoiceIdentity.swift")
        #expect(id.contains("original character") && id.contains("does not copy, clone or"))
        #expect(!id.lowercased().contains("bettany") && !id.lowercased().contains("stark"))
    }
}
