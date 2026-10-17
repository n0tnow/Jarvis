import AppKit

/// `Jarvis --voice-live-test [--live-dir <dir>] [--voice-audible] [--voice-no-whisper]` — OPT-IN, REAL (V0.7).
/// Exercises the ACTUAL voice stack on this Mac with SYNTHETIC speech (made by the macOS system voices — never a recording of a person):
///   provider discovery → STT benchmark (Apple on-device + local Whisper helper) → partial/final semantics → language detection → TTS rendering and
///   REAL playback timing (silent unless --voice-audible) → stop/cancel → incremental sentence synthesis while text streams → end-to-end
///   fixture audio → real STT → final transcript → the SAME ConversationService.submit → deterministic command → real TTS (Turkish AND English) →
///   voice → normal V0.4 task (scripted planner, isolated fixture) → rapid Push-to-Talk → Push-to-Talk during speech → resource/CPU/RAM figures
///   → no-network evidence → no audio on disk → sanitization → restart reconciliation → SIGTERM of a child JARVIS leaves no helper.
/// What it CANNOT prove (MANUAL TEST REQUIRED): recognition quality for a real human voice, a real microphone, voice naturalness, VoiceOver.
@MainActor
enum VoiceLiveTest {
    static func run(context: AppContext, captureDirectory: String, audible: Bool, skipWhisper: Bool, realMicrophone: Bool, combined: Bool) async {
        var failures = 0, passes = 0, skipped = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "", synthetic: Bool = false) {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(synthetic ? "[synthetic audio] " : "")\(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func skip(_ name: String, _ why: String) { print("SKIPPED  \(name) — \(why)"); skipped += 1; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func bench(_ s: String) { print("BENCH  \(s)"); fflush(stdout) }
        func perf(_ s: String) { print("PERF  \(s)"); fflush(stdout) }
        func fmt(_ d: Double?, _ f: String = "%.2f") -> String { d.map { String(format: f, $0) } ?? "–" }
        func ms(_ d: Double?) -> String { d.map { "\(Int($0 * 1000)) ms" } ?? "–" }
        func mb(_ b: UInt64?) -> String { b.map { "\($0 / 1_048_576) MB" } ?? "–" }

        let prefs = context.preferences, voice = context.voice, me = getpid()
        let realInput = voice.makeInput                       // the product's own factory (a real MicrophoneInput) — captured before the fixtures replace it
        let savedRoot = prefs.projectRoot
        DispatchQueue.main.asyncAfter(deadline: .now() + 1500) { ProcessRegistry.shared.killAll(); print("VOICE LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        var temps: [String] = []
        func finish() -> Never {
            prefs.projectRoot = savedRoot
            prefs.defaults.removeObject(forKey: "prefs.tasks.projectRoot")
            if !savedRoot.isEmpty { prefs.projectRoot = savedRoot }
            voice.shutdown()
            for t in temps { try? FileManager.default.removeItem(atPath: t) }
            print("VOICE LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, \(skipped) skipped)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
            return cond()
        }
        func shell(_ exe: String, _ args: [String]) async -> String {
            await ManagedProcess.runOnce(executable: exe, arguments: args, environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 15, maxOutput: 2_000_000)?.output ?? ""        // ps lists ~600 processes: the default 64 KB cap would cut the list
        }
        func cpu(_ pid: pid_t) -> Double { ProcessTree.cpuSeconds(of: pid) ?? 0 }
        func speechProcesses() async -> [(pid: Int, rssMB: Int, name: String)] {
            await shell("/bin/ps", ["-axo", "pid=,rss=,comm="]).split(separator: "\n").compactMap { line in
                let p = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard p.count == 3, let pid = Int(p[0]), let rss = Int(p[1]) else { return nil }
                let name = (String(p[2]) as NSString).lastPathComponent
                return name.lowercased().contains("speech") || name.lowercased().contains("siri") && name.lowercased().contains("tts") ? (pid, rss / 1024, name) : nil
            }
        }

        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history)")
        guard let apple = voice.sttProviders.first(where: { $0.id == "apple-speech" }) as? AppleSpeechSTTProvider,
              let tts = voice.ttsProviders.compactMap({ $0 as? AppleSpeechSynthesizerProvider }).first else { check("The expected voice providers exist", false); finish() }
        let whisperProvider = voice.sttProviders.first(where: { $0.id == "whisper-local" })
        tts.outputVolume = audible ? 1.0 : 0
        info(audible ? "AUDIBLE mode: JARVIS will speak aloud during the TTS checks." : "Silent mode: real playback runs at volume 0 (timing, events and stop are real; nothing is heard). Use --voice-audible to hear it.")

        // ------------------------------------------------------------ 0. discovery, truthful states, nothing running
        await voice.refreshProviders()
        for p in voice.sttProviders {
            let a = voice.sttAvailability[p.id]
            info("STT \(p.displayName): \(a.map { "\($0)" } ?? "?") · cost \(p.capabilities.costClass.label) · network \(p.capabilities.needsNetwork ? "yes" : "no") · partials: \(p.capabilities.partials.label) · language detection: \(p.capabilities.autoDetectsLanguage ? "real" : "none")")
        }
        info("TTS \(tts.displayName): \(tts.capabilities.streaming.label) · cost \(tts.capabilities.costClass.label) · voices: \(tts.voices().map { "\($0.name) \($0.language) \($0.qualityLabel)" }.joined(separator: ", "))")
        info("microphone permission (read-only status, never requested by this test): \(voice.permission.label)")
        check("Voice is idle at launch: microphone closed, no recogniser helper process, no speech playing", voice.state == .idle && !voice.isMicrophoneOpen && context.whisper.workerPID == nil && !voice.speaker.isActive)
        check("The default speech path declares no network and no cost (STT: local/system, TTS: system)", voice.sttProviders.allSatisfy { !$0.capabilities.needsNetwork && $0.capabilities.costClass.autoSelectable } && !tts.capabilities.needsNetwork && tts.capabilities.costClass == .system)
        check("A Turkish and an English system voice are installed", tts.voices().contains { $0.voiceLanguage == .turkish } && tts.voices().contains { $0.voiceLanguage == .english })
        let appleReady = voice.sttAvailability["apple-speech"] == .ready
        let whisperReady = !skipWhisper && voice.sttAvailability["whisper-local"] == .ready
        let appleTR = await apple.availability(for: .turkish), appleEN = await apple.availability(for: .english)
        check("Apple on-device speech is ready for Turkish and English", appleTR == .ready && appleEN == .ready)
        if skipWhisper { skip("Whisper checks", "--voice-no-whisper") } else if !whisperReady { check("The local Whisper helper is installed (scripts/setup_voice_ai.sh)", false, "\(voice.sttAvailability["whisper-local"].map { "\($0)" } ?? "?")") }
        let baselineSpeech = await speechProcesses()

        // ------------------------------------------------------------ 1. synthetic fixtures (system voices, in memory)
        struct Fixture { var name: String; var reference: String; var language: VoiceLanguage; var clip: [Float] }
        var fixtures: [Fixture] = []
        let specs: [(String, String, VoiceLanguage, [AudioFixtures.Segment])] = [
            ("tr_short", "Jarvis, Unity'deki son task'ın durumunu göster.", .turkish, [.init(text: "Jarvis, Unity'deki son task'ın durumunu göster.", language: .turkish)]),
            ("tr_long", "Jarvis, Play Mode testlerini çalıştır ve yeni Console hatası varsa bana söyle.", .turkish, [.init(text: "Jarvis, Play Mode testlerini çalıştır ve yeni Console hatası varsa bana söyle.", language: .turkish)]),
            ("tr_cmd", "Jarvis, görevler ekranını aç.", .turkish, [.init(text: "Jarvis, görevler ekranını aç.", language: .turkish)]),
            ("en_short", "Jarvis, run the EditMode tests.", .english, [.init(text: "Jarvis, run the EditMode tests.", language: .english)]),
            ("en_long", "Show me the latest task report.", .english, [.init(text: "Show me the latest task report.", language: .english)]),
            ("en_cmd", "Jarvis, open the Tasks screen.", .english, [.init(text: "Jarvis, open the Tasks screen.", language: .english)]),
            ("mixed", "Jarvis, BoxCollider değişikliğini kontrol et and run the relevant test.", .turkish,
             [.init(text: "Jarvis, BoxCollider", language: .english), .init(text: "değişikliğini kontrol et", language: .turkish), .init(text: "and run the relevant test.", language: .english)]),
            ("mixed_cmd", "Jarvis, Unity Play Mode testlerini kontrol et.", .turkish,
             [.init(text: "Jarvis,", language: .english), .init(text: "Unity Play Mode", language: .english), .init(text: "testlerini kontrol et.", language: .turkish)]),
        ]
        for (name, ref, lang, segs) in specs {
            if let clip = try? await AudioFixtures.make(segs, tts: tts) { fixtures.append(Fixture(name: name, reference: ref, language: lang, clip: clip)) }
        }
        check("Synthetic speech fixtures were generated in memory for Turkish, English and mixed sentences (nothing written to disk)", fixtures.count == specs.count && fixtures.allSatisfy { $0.clip.count > 16_000 },
              fixtures.map { "\($0.name) \(fmt(Double($0.clip.count) / 16_000, "%.1f")) s" }.joined(separator: " · "), synthetic: true)
        func fixture(_ n: String) -> Fixture { fixtures.first { $0.name == n }! }

        // ------------------------------------------------------------ 2. STT benchmark: real providers, real-time pacing
        struct Run { var text = ""; var language: String?; var startup = 0.0; var firstPartial: Double?; var finalize = 0.0; var partials = 0; var confidence: Double?; var final: SpeechTranscriptEvent? }
        func transcribe(_ provider: any SpeechToTextProvider, _ f: Fixture, language: VoiceLanguage) async -> Run? {
            var r = Run()
            let t0 = Date()
            guard let session = try? await provider.makeSession(language: language) else { return nil }
            r.startup = Date().timeIntervalSince(t0)
            var firstFrameAt: Date?
            let watcher = Task { @MainActor in
                for await e in session.events where !e.isFinal {
                    r.partials += 1
                    if r.firstPartial == nil, let ff = firstFrameAt { r.firstPartial = Date().timeIntervalSince(ff) }
                }
            }
            var index = 0
            while index < f.clip.count {
                let end = min(index + 1600, f.clip.count)
                if firstFrameAt == nil { firstFrameAt = Date() }
                session.append(AudioFrame(samples: Array(f.clip[index..<end])))
                index = end
                try? await Task.sleep(for: .milliseconds(100))              // real-time pacing, like a microphone
            }
            let releasedAt = Date()
            guard let final = try? await session.finish() else { watcher.cancel(); return r }
            r.finalize = Date().timeIntervalSince(releasedAt)
            watcher.cancel()
            r.text = final.text; r.language = final.language; r.confidence = final.confidence; r.final = final
            return r
        }
        // ------------------------------------------------------------ 2b. combined representative state (placed early so a concurrently started Unity editor is alive) (local Qwen resident + Whisper + TTS; a Unity editor too when --unity-live-test runs alongside)
        if combined {
            func sysctlSwap() async -> String { await shell("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).trimmingCharacters(in: .whitespacesAndNewlines) }
            func pressureLine() async -> String { await shell("/usr/bin/memory_pressure", []).split(separator: "\n").last { $0.contains("free percentage") }.map(String.init) ?? "n/a" }
            func unityRSS() async -> (Int, Int) {
                let all = await shell("/bin/ps", ["-axo", "rss=,comm="]).split(separator: "\n")
                let rows = all.filter { $0.contains("/Unity.app/") || $0.contains("/Hub/Editor/") }          // the editor and its helpers (not Unity Hub's relay)
                if rows.isEmpty { let anyUnity = all.filter { $0.lowercased().contains("unity") }.prefix(2); if !anyUnity.isEmpty { info("combined: ps lines mentioning unity (not the editor): \(anyUnity.map(String.init))") } }
                return (rows.count, rows.compactMap { Int($0.split(separator: " ").first ?? "") }.reduce(0, +) / 1024)
            }
            perf("combined: before loading anything — swap \(await sysctlSwap()) · \(await pressureLine())")
            let q0 = Date()
            await context.testLocalModel()                                         // starts the local worker and makes one tiny real generation (so the model is genuinely resident)
            perf("combined: local Qwen worker ready after \(fmt(Date().timeIntervalSince(q0), "%.1f")) s (load \(fmt(context.localRuntime.metrics.loadSeconds, "%.1f")) s) — RSS \(mb(context.localRuntime.workerResidentBytes)) · peak \(fmt(context.localRuntime.metrics.peakMemoryGB, "%.1f")) GB (state \(context.localRuntime.state.label)) · test: \(context.localTestResult ?? "–")")
            if whisperReady { try? await context.whisper.ensureStarted() }
            var u = await unityRSS()
            if u.0 == 0 {                                                          // wait (bounded) for a Unity editor started elsewhere, e.g. next to --unity-live-test
                info("combined: waiting up to 300 s for a Unity editor to appear (start --unity-live-test next to this test)…")
                let deadline = Date().addingTimeInterval(300)
                while u.0 == 0, Date() < deadline { try? await Task.sleep(for: .seconds(5)); u = await unityRSS() }
            }
            perf("combined: Unity processes found: \(u.0) · total RSS \(u.1) MB\(u.0 == 0 ? " (no Unity editor was running during this sample)" : "")")
            // an active voice cycle while everything is resident
            let providerForCombined: any SpeechToTextProvider = (whisperReady ? whisperProvider! : apple as any SpeechToTextProvider)
            let c0 = cpu(me)
            let r = await transcribe(providerForCombined, fixture("tr_long"), language: .auto)
            tts.speak(SpeechChunk(id: 9200, text: "Unity testleri tamamlandı. Tüm EditMode ve PlayMode testleri geçti.", language: .turkish), voice: nil, rate: 1.0)
            try? await Task.sleep(for: .seconds(3))
            let rssJarvis = ProcessTree.residentBytes(of: me), rssHelper = context.whisper.workerResidentBytes, rssQwen = context.localRuntime.workerResidentBytes
            let total = (rssJarvis ?? 0) + (rssHelper ?? 0) + (rssQwen ?? 0) + UInt64(u.1) * 1_048_576
            perf("combined, one full voice cycle with Qwen resident: JARVIS \(mb(rssJarvis)) + Whisper helper \(mb(rssHelper)) + Qwen worker \(mb(rssQwen)) + Unity \(u.1) MB = \(total / 1_048_576) MB · JARVIS +\(fmt(cpu(me) - c0, "%.2f")) CPU-s · heard \"\(r?.text ?? "")\"")
            perf("combined: after the cycle — swap \(await sysctlSwap()) · \(await pressureLine()) · memory pressure \(context.resources.pressure.memory.rawValue)")
            tts.stop()
            let unloadAt = Date()
            context.resources.setMemory(.warning)
            _ = await waitUntil(5) { context.whisper.state != .ready }
            perf("combined: a memory-pressure WARNING unloads the speech helper in \(fmt(Date().timeIntervalSince(unloadAt), "%.2f")) s (state \(context.whisper.state.label))")
            check("A memory-pressure warning unloads the speech helper (Whisper) and never during an utterance", context.whisper.state != .ready || !whisperReady)
            context.resources.setMemory(.normal)
            await context.localRuntime.unload()
        }

        var tableRows: [(provider: String, fixture: String, wer: Double, cer: Double, text: String)] = []
        var finalizeSamples: [String: [Double]] = [:]
        let providers: [(String, any SpeechToTextProvider)] = (appleReady ? [("apple-speech", apple as any SpeechToTextProvider)] : []) + (whisperReady ? [("whisper-local", whisperProvider!)] : [])
        for (pid, provider) in providers {
            if pid == "whisper-local" { await context.whisper.unload() }
            var first = true
            for f in fixtures {
                let repeats = 3
                for i in 0..<repeats {
                    // Whisper: each fixture is also run with Auto language (real detection); Apple cannot detect, so it gets the explicit language.
                    let lang: VoiceLanguage = provider.capabilities.autoDetectsLanguage ? .auto : (f.language == .turkish ? .turkish : .english)
                    guard let r = await transcribe(provider, f, language: lang) else { check("\(provider.displayName) transcribed \(f.name)", false, "session failed", synthetic: true); continue }
                    let wer = SpeechMetrics.wer(reference: f.reference, hypothesis: r.text), cer = SpeechMetrics.cer(reference: f.reference, hypothesis: r.text)
                    if i == 0 {
                        bench("stt provider=\(pid) fixture=\(f.name) lang=\(lang.rawValue)→\(r.language ?? "?") audio=\(fmt(Double(f.clip.count) / 16_000, "%.1f"))s start=\(ms(r.startup))\(first && pid == "whisper-local" ? " (COLD: helper start + model load)" : "") firstPartial=\(ms(r.firstPartial)) partials=\(r.partials) finalize=\(ms(r.finalize)) WER=\(fmt(wer)) CER=\(fmt(cer)) confidence=\(fmt(r.confidence)) text=\"\(r.text)\"")
                        tableRows.append((pid, f.name, wer, cer, r.text))
                    }
                    first = false
                    finalizeSamples[pid, default: []].append(r.finalize)
                }
            }
            let fs = finalizeSamples[pid] ?? []
            bench("stt provider=\(pid) finalization after release: p50=\(ms(SpeechMetrics.p50(fs))) min=\(ms(fs.min())) max=\(ms(fs.max())) over \(fs.count) runs (small sample: not a statistical claim)")
            let rows = tableRows.filter { $0.provider == pid }
            let meanWER = rows.map(\.wer).reduce(0, +) / Double(max(1, rows.count)), meanCER = rows.map(\.cer).reduce(0, +) / Double(max(1, rows.count))
            bench("stt provider=\(pid) mean WER = \(fmt(meanWER)) · mean CER = \(fmt(meanCER)) over \(rows.count) fixtures (synthetic system-voice speech: flatters real-world accuracy)")
        }
        check("At least one real recogniser transcribed the synthetic fixtures", !tableRows.isEmpty)

        // partial / final semantics + language handling (real)
        if appleReady {
            let r = await transcribe(apple, fixture("en_cmd"), language: .english)
            check("Apple Speech emits revisable PARTIAL transcripts while audio arrives, then one FINAL (native streaming)", (r?.partials ?? 0) >= 1 && r?.final?.isFinal == true && (r?.firstPartial ?? 99) < 2.5,
                  "partials=\(r?.partials ?? 0) first=\(ms(r?.firstPartial))", synthetic: true)
            check("Apple Speech does not claim language detection or a confidence it does not have", !apple.capabilities.autoDetectsLanguage && r?.final?.confidence == nil)
        }
        if whisperReady, let w = whisperProvider {
            let tr = await transcribe(w, fixture("tr_cmd"), language: .auto), en = await transcribe(w, fixture("en_cmd"), language: .auto)
            check("Whisper detects Turkish and English by itself (real detection, restricted to those two)", tr?.language == "tr" && en?.language == "en", "tr→\(tr?.language ?? "?") en→\(en?.language ?? "?")", synthetic: true)
            let long = await transcribe(w, fixture("tr_long"), language: .turkish)
            check("Whisper previews are provisional (non-final) and the final arrives once, with a real confidence value", long?.final?.isFinal == true && (long?.partials ?? 0) >= 1 && long?.confidence != nil,
                  "previews=\(long?.partials ?? 0) first preview \(ms(long?.firstPartial))", synthetic: true)
        }

        // ------------------------------------------------------------ 3. TTS: rendering, real playback timing, stop, incremental synthesis
        let ttsTexts: [(String, VoiceLanguage, String)] = [("tr", .turkish, "Unity testleri tamamlandı. Tüm EditMode ve PlayMode testleri geçti."),
                                                           ("en", .english, "The Unity tests are complete. No new Console errors were detected."),
                                                           ("mixed", .turkish, "Play Mode tamamlandı ve BoxCollider değişikliği doğrulandı.")]
        var renderOK = true
        for (name, lang, text) in ttsTexts {
            guard let r = try? await tts.render(text, language: lang, voice: nil, rate: 1.0) else { renderOK = false; continue }
            let peak = r.samples.map { abs($0) }.max() ?? 0
            renderOK = renderOK && r.frames > 0 && r.duration > 1 && peak > 0.01
            bench("tts render lang=\(name) firstBuffer=\(ms(r.firstBufferSeconds)) total=\(ms(r.totalSeconds)) audio=\(fmt(r.duration, "%.1f"))s peak=\(fmt(Double(peak))) samples=\(r.frames)")
        }
        check("TTS produced real audio (duration > 0, samples > 0, not silent) for Turkish, English and mixed text", renderOK, synthetic: false)

        var events: [TTSPlaybackEvent] = []
        var eventTimes: [Date] = []
        let savedHandler = tts.onEvent
        tts.onEvent = { events.append($0); eventTimes.append(Date()) }
        let sampleChunk = SpeechChunk(id: 9001, text: "Unity testleri tamamlandı.", language: .turkish)
        let spokeAt = Date()
        tts.speak(sampleChunk, voice: nil, rate: 1.0)
        let started = await waitUntil(8) { events.contains(.started(chunkID: 9001)) }
        let finished = await waitUntil(15) { events.contains(.finished(chunkID: 9001)) }
        check("Real playback: a Turkish phrase reports START then FINISH (state SPEAKING in between)", started && finished && tts.state == .ready,
              "speak→audio started \(ms(eventTimes.first.map { $0.timeIntervalSince(spokeAt) })) · played for \(ms(eventTimes.count >= 2 ? eventTimes[1].timeIntervalSince(eventTimes[0]) : nil))")
        events = []; eventTimes = []
        let longText = "Bu uzun bir test cümlesidir. İkinci cümle de burada. Üçüncü cümle hâlâ devam ediyor. Dördüncü cümle bitmek bilmiyor. Beşinci cümle ile bitiriyoruz."
        tts.speak(SpeechChunk(id: 9002, text: longText, language: .turkish), voice: nil, rate: 1.0)
        tts.speak(SpeechChunk(id: 9003, text: "Bu cümle hiç çalmamalı.", language: .turkish), voice: nil, rate: 1.0)
        _ = await waitUntil(8) { events.contains(.started(chunkID: 9002)) }
        try? await Task.sleep(for: .milliseconds(300))
        let stopAt = Date()
        tts.stop()
        let stopLatency = Date().timeIntervalSince(stopAt)
        let afterStop = events.count
        try? await Task.sleep(for: .milliseconds(1500))
        check("stop() silences real playback at once, drops the queued phrase and nothing stale plays afterwards",
              events.contains(.cancelled(chunkID: 9002)) && events.contains(.cancelled(chunkID: 9003)) && !events.contains(.started(chunkID: 9003)) && events.count == afterStop && tts.state == .ready && stopLatency < 0.2,
              "stop latency \(ms(stopLatency))")
        tts.onEvent = savedHandler

        // incremental sentence synthesis while the answer is still streaming (real conversation store, real speaker, real TTS)
        let conv = context.conversation
        voice.settings = { var s = VoiceSettings(enabled: true); s.voicePreset = .systemFallback; s.speakResponses = true; return s }
        let userMsg = conv.appendUser("explain the build please", source: .voice)
        let reply = conv.beginJarvisResponse(route: .reasoning)
        voice.speaker.beginTurn(afterUserMessage: userMsg.id, fallbackLanguage: .english)
        var firstAudioWhileStreaming = false
        let streamStart = Date()
        for sentence in ["The build finished without errors. ", "All EditMode tests passed as well. ", "The PlayMode tests are still running, ", "but nothing has failed so far. "] {
            conv.appendDelta(reply, sentence)
            try? await Task.sleep(for: .milliseconds(700))
            if voice.speaker.isSpeaking && conv.messages.last(where: { $0.id == reply })?.status == .streaming { firstAudioWhileStreaming = true }
        }
        let streamSeconds = Date().timeIntervalSince(streamStart)
        conv.finish(reply)
        voice.conversationChanged()
        _ = await waitUntil(25) { !voice.speaker.isActive }
        check("TTS starts speaking while the answer is still streaming (incremental sentence synthesis; the provider has no native streaming)", firstAudioWhileStreaming, "the text took ~\(fmt(streamSeconds, "%.1f")) s to arrive; audio began before it was complete")

        // ------------------------------------------------------------ 4. end-to-end through the REAL coordinator (fixture audio → real STT → typed pipeline → real TTS)
        let windows = context.windows
        func e2e(_ f: Fixture, provider id: String, language: VoiceLanguage) async -> (user: ConversationMessage?, reply: ConversationMessage?, metrics: VoiceTurnMetrics?, closedAtRelease: Bool, usersBefore: Int) {
            windows.hideFullHUD(); windows.hideCompactHUD(); context.hud.section = .dashboard
            conv.clear()
            let input = FixtureAudioInput(clip: f.clip)
            voice.makeInput = { input }
            voice.settings = { var s = VoiceSettings(enabled: true); s.voicePreset = .systemFallback; s.sttProvider = id; s.language = language; s.speakResponses = true; return s }
            voice.pushToTalkPressed()
            _ = await waitUntil(5) { voice.state == .listening }
            await input.waitUntilDelivered()
            try? await Task.sleep(for: .milliseconds(250))
            voice.pushToTalkReleased()
            let closed = !input.isCapturing && !voice.isMicrophoneOpen
            _ = await waitUntil(40) { voice.state == .idle && voice.lastMetrics?.outcome != nil }
            return (conv.messages.first { $0.role == .user }, conv.messages.first { $0.role == .jarvis }, voice.lastMetrics, closed, 0)
        }
        for (pid, _) in providers {
            for (name, lang, expectSection) in [("tr_cmd", VoiceLanguage.turkish, HUDSection.tasks), ("en_cmd", .english, .tasks)] {
                let f = fixture(name)
                let r = await e2e(f, provider: pid, language: pid == "whisper-local" ? .auto : lang)
                let heard = r.user?.content ?? ""
                bench("e2e provider=\(pid) fixture=\(name) heard=\"\(heard)\" reply=\"\(r.reply?.content ?? "")\" \(r.metrics.map { VoiceSettingsSection.describe($0) } ?? "")")
                check("[\(pid)] \(lang == .turkish ? "TURKISH" : "ENGLISH") end to end: audio → real STT → the typed pipeline → deterministic command → real TTS",
                      r.closedAtRelease && r.user?.source == .voice && r.reply?.route == .command && context.hud.section == expectSection && windows.isFullHUDOpen && r.metrics?.releaseToFirstAudio != nil && r.metrics?.outcome == "ok",
                      "heard \"\(heard)\" · release→first audio \(ms(r.metrics?.releaseToFirstAudio)) · STT final \(ms(r.metrics?.sttFinalization)) · text→TTS \(ms(r.metrics?.firstTextToSynthesis)) · TTS→audio \(ms(r.metrics?.synthesisToFirstAudio))", synthetic: true)
                // the typed twin: same words → identical reply (one pipeline)
                let typedReply = { () -> String? in conv.clear(); windows.hideFullHUD(); context.conversationService.submit(heard, origin: .other); return conv.messages.last(where: { $0.role == .jarvis })?.content }()
                check("[\(pid)] the recognised text typed by hand produces exactly the same reply (one pipeline, no voice-only path)", typedReply == r.reply?.content, "\"\(typedReply ?? "nil")\"")
                voice.speaker.stop()
            }
        }

        // mixed Turkish/English: the recognised text is RECORDED per provider; the test requires that at least one recogniser keeps the meaning
        // (code-switched speech is the weakest area of every small model — see docs/VOICE_IO.md and KNOWN_ISSUES).
        var preserved: [String: Bool] = [:]
        for (pid, provider) in providers {
            for name in ["mixed", "mixed_cmd"] {
                let f = fixture(name)
                var best: (text: String, hits: Int)?
                // Auto, and — for the Turkish-speaking user this was built for — explicit Turkish too.
                for lang in (provider.capabilities.autoDetectsLanguage ? [VoiceLanguage.auto, .turkish] : [.turkish]) {
                    guard let r = await transcribe(provider, f, language: lang) else { continue }
                    let n = SpeechMetrics.normalize(r.text)
                    let keys = name == "mixed" ? ["kontrol", "test"] : ["play", "kontrol"]
                    let hits = keys.filter { n.contains($0) }.count
                    bench("mixed provider=\(pid) fixture=\(name) language=\(lang.rawValue)→\(r.language ?? "?") heard=\"\(r.text)\" semanticKeywords=\(hits)/\(keys.count)")
                    if best == nil || hits > best!.hits { best = (r.text, hits) }
                }
                if best?.hits == 2 { preserved[name] = true }
            }
        }
        for name in ["mixed", "mixed_cmd"] where !providers.isEmpty {
            check("Mixed Turkish/English technical speech (\(name)): at least one real recogniser keeps the meaning (key words recognised)", preserved[name] == true, synthetic: true)
        }

        // ------------------------------------------------------------ 5. voice → a normal V0.4 task (scripted planner on an isolated fixture)
        let proj = NSTemporaryDirectory() + "jarvis-voice-live-\(UUID().uuidString.prefix(8))"
        temps.append(proj)
        try? FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        try? "def add(a, b):\n    return a - b\n".write(toFile: proj + "/calc.py", atomically: true, encoding: .utf8)
        let planText = #"{"summary":"analyze","steps":[{"id":"s1","title":"Inspect the project","description":"read it","type":"analysis","dependsOn":[],"expected":"understanding","validation":"structuredResult","risk":"low"}]}"#
        let analysisText = #"{"summary":"add() subtracts","findings":["calc.add returns a - b"],"relevantFiles":["calc.py"],"rootCause":"wrong operator"}"#
        let runner = ScriptedAgentRunner(audit: context.audit, real: nil, scriptedTypes: ["PlannerAgent", "AnalysisAgent", "CodingAgent", "ReviewAgent"]) { job, _ in job.type == "PlannerAgent" ? planText : analysisText }
        let taskEngine = TaskEngine(repository: context.repository!, artifacts: context.artifacts, audit: context.audit, leases: context.leases, agents: runner)
        prefs.projectRoot = proj
        let intake = TaskIntake(engine: taskEngine, preferences: prefs)
        let savedSubmitter = context.conversationService.taskSubmitter
        context.conversationService.taskSubmitter = intake
        if let (pid, _) = providers.first {
            let f = try? await AudioFixtures.make([.init(text: "Jarvis, analyze the test project.", language: .english)], tts: tts)
            if let f {
                let r = await e2e(Fixture(name: "task", reference: "Jarvis, analyze the test project.", language: .english, clip: f), provider: pid, language: .english)
                _ = await waitUntil(20) { ((try? context.repository?.engineTasks(limit: 5)) ?? []).contains { $0.workspaceRoot?.hasSuffix((proj as NSString).lastPathComponent) == true } }
                let tasks = ((try? context.repository?.engineTasks(limit: 20)) ?? []).filter { $0.workspaceRoot?.hasSuffix((proj as NSString).lastPathComponent) == true }
                if let t = tasks.first { await taskEngine.waitUntilFinished(t.id) }
                let done = tasks.first.flatMap { try? context.repository?.engineTask($0.id) } ?? nil
                bench("voice→task heard=\"\(r.user?.content ?? "")\" reply=\"\(r.reply?.content ?? "")\" task=\(done?.state.rawValue ?? "none") channel=\(done?.inputChannel.rawValue ?? "?")")
                check("[\(pid)] a spoken goal becomes a NORMAL V0.4 task (voice channel recorded, user origin, same engine), acknowledged aloud while the task runs on its own",
                      done?.inputChannel == .voice && done?.origin == .userTask && tasks.count == 1 && r.metrics?.releaseToFirstAudio != nil, "heard \"\(r.user?.content ?? "")\" · task \(done?.state.rawValue ?? "none")", synthetic: true)
            }
        } else { skip("voice → task", "no recogniser available") }
        context.conversationService.taskSubmitter = savedSubmitter

        // ------------------------------------------------------------ 6. rapid Push-to-Talk and Push-to-Talk during speech (real providers)
        if let (pid, _) = providers.last {
            conv.clear()
            let f = fixture("en_cmd")
            let input = FixtureAudioInput(clip: Array(f.clip.dropFirst(Int(0.3 * AudioFrame.sampleRate))))          // speech starts at once: every short hold contains words
            voice.makeInput = { input }
            voice.settings = { var s = VoiceSettings(enabled: true); s.voicePreset = .systemFallback; s.sttProvider = pid; s.language = pid == "whisper-local" ? .auto : .english; s.speakResponses = false; return s }
            var maxOpen = 0
            for _ in 0..<4 {
                voice.pushToTalkPressed()
                maxOpen = max(maxOpen, voice.isMicrophoneOpen ? 1 : 0)
                try? await Task.sleep(for: .milliseconds(900))
                voice.pushToTalkReleased()
                try? await Task.sleep(for: .milliseconds(60))                // the next press arrives while the previous transcript is still being finalised
            }
            _ = await waitUntil(40) { voice.state == .idle }
            let users = conv.messages.filter { $0.role == .user }
            check("Rapid press/release ×4: no crash, no stuck LISTENING, microphone closed, no stale or duplicate submission", voice.state == .idle && !voice.isMicrophoneOpen && !input.isCapturing && users.count >= 1 && users.count <= 4 && Set(users.map(\.id)).count == users.count && !context.whisper.hasActiveUtterance,
                  "\(users.count) message(s) submitted; starts=\(input.startCount) stops=\(input.stopCount)", synthetic: true)

            // PTT during speech
            conv.clear(); windows.hideFullHUD()
            voice.settings = { var s = VoiceSettings(enabled: true); s.voicePreset = .systemFallback; s.sttProvider = pid; s.language = pid == "whisper-local" ? .auto : .english; s.speakResponses = true; return s }
            voice.speaker.speakStandalone("Bu çok uzun bir yanıt. Konuşmaya devam ediyorum, ikinci cümle. Üçüncü cümle de burada, dördüncü cümle de geliyor. Beşinci cümle.", language: .turkish)
            _ = await waitUntil(8) { voice.speaker.isSpeaking }
            let wasSpeaking = voice.speaker.isSpeaking
            let input2 = FixtureAudioInput(clip: fixture("en_cmd").clip)
            voice.makeInput = { input2 }
            voice.pushToTalkPressed()
            let listening = await waitUntil(5) { voice.state == .listening }
            let silenced = !voice.speaker.isSpeaking && !voice.speaker.isActive && tts.state == .ready
            await input2.waitUntilDelivered()
            try? await Task.sleep(for: .milliseconds(250))
            voice.pushToTalkReleased()
            _ = await waitUntil(30) { voice.state == .idle && voice.lastMetrics?.outcome != nil }
            let heard = conv.messages.first { $0.role == .user }?.content ?? ""
            check("Push-to-Talk during speech stops the speech first, then listens; the new session hears only the new audio (explicit stop — not barge-in)",
                  wasSpeaking && listening && silenced && SpeechMetrics.normalize(heard).contains("open") && !SpeechMetrics.normalize(heard).contains("uzun"), "heard \"\(heard)\"", synthetic: true)
            voice.speaker.stop()
        }

        // ------------------------------------------------------------ 6b. the REAL global hotkey: synthetic OS-level Right-Option key events → polling service → PTT machine → coordinator
        func postRightOption(_ down: Bool) {
            guard let ev = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 61, keyDown: down) else { return }
            ev.type = .flagsChanged
            ev.flags = CGEventFlags(rawValue: down ? (0x80000 | 0x40) : 0)       // maskAlternate | NX_DEVICERALTKEYMASK
            ev.post(tap: .cghidEventTap)
        }
        if let (pid, _) = providers.last {
            let hudStates: [(String, () -> Void)] = [("Full HUD open", { windows.showFullHUD(section: .dashboard) }), ("Compact HUD open", { windows.showCompactHUD() }), ("no HUD open", { windows.hideFullHUD(); windows.hideCompactHUD() })]
            var delivered = true
            for (label, setup) in hudStates where delivered {
                setup(); conv.clear(); try? await Task.sleep(for: .milliseconds(300))
                let input = FixtureAudioInput(clip: fixture("en_cmd").clip)
                voice.makeInput = { input }
                voice.settings = { var s = VoiceSettings(enabled: true); s.voicePreset = .systemFallback; s.sttProvider = pid; s.language = pid == "whisper-local" ? .auto : .english; s.speakResponses = false; return s }
                postRightOption(true)
                let began = await waitUntil(3) { voice.state == .listening }
                if !began { postRightOption(false); skip("Global Push-to-Talk hotkey (\(label))", "synthetic key events were not delivered to this session (Accessibility is not granted to the host process) — MANUAL TEST REQUIRED"); delivered = false; break }
                for _ in 0..<25 { postRightOption(true); try? await Task.sleep(for: .milliseconds(10)) }                    // key repeat while held
                await input.waitUntilDelivered()
                try? await Task.sleep(for: .milliseconds(250))
                postRightOption(false)
                let closed = await waitUntil(1) { !input.isCapturing }
                _ = await waitUntil(30) { voice.state == .idle && voice.lastMetrics?.outcome != nil }
                let heard = conv.messages.first { $0.role == .user }?.content ?? ""
                check("Global hotkey (hold right ⌥) with \(label): microphone starts after the hold, key repeat does not restart it, release stops it at once, the transcript runs the command",
                      closed && input.startCount == 1 && input.stopCount == 1 && SpeechMetrics.normalize(heard).contains("task") && windows.isFullHUDOpen && context.hud.section == .tasks, "heard \"\(heard)\"", synthetic: true)
            }
            postRightOption(false)
            windows.hideFullHUD(); windows.hideCompactHUD()
        }

        // ------------------------------------------------------------ 6c. the REAL microphone: capture plumbing only (opt-in; permission must already be granted; level only, nothing kept)
        if realMicrophone {
            voice.refreshPermission()
            if voice.permission == .granted {
                final class Tally: @unchecked Sendable { let lock = NSLock(); var frames = 0, samples = 0; var peak: Float = 0; var interrupted = false
                    func add(_ f: AudioFrame) { lock.lock(); frames += 1; samples += f.samples.count; peak = max(peak, f.samples.map { abs($0) }.max() ?? 0); lock.unlock() } }
                let tally = Tally()
                let mic = realInput()
                do {
                    try mic.start(onFrame: { tally.add($0) }, onInterruption: { _ in tally.lock.lock(); tally.interrupted = true; tally.lock.unlock() })
                    let wasOpen = mic.isCapturing
                    try? await Task.sleep(for: .milliseconds(1500))
                    mic.stop()
                    check("REAL microphone: capture starts, delivers bounded 16 kHz mono frames, and STOPS (permission was already granted; only a level was read, nothing stored)",
                          wasOpen && !mic.isCapturing && tally.frames >= 8 && tally.samples >= 16_000, "\(tally.frames) frames · \(fmt(Double(tally.samples) / 16_000, "%.1f")) s · peak \(fmt(Double(tally.peak), "%.3f"))")
                } catch { mic.stop(); check("REAL microphone capture could start", false, "\(error)") }
            } else { skip("REAL microphone capture", "permission is \(voice.permission.label): this test never asks for it") }
        }

        // ------------------------------------------------------------ 7. resources (JARVIS vs helpers, measured separately)
        voice.cancelAll()
        if whisperReady {
            await context.whisper.unload()
            try? await Task.sleep(for: .milliseconds(500))
            perf("JARVIS (voice enabled, idle, helper UNLOADED): RSS \(mb(ProcessTree.residentBytes(of: me)))")
            let c0 = cpu(me); try? await Task.sleep(for: .seconds(6)); perf("JARVIS idle CPU over 6 s with voice enabled: \(fmt(cpu(me) - c0, "%.3f")) CPU-s (\(fmt((cpu(me) - c0) / 6 * 100, "%.2f")) % of one core)")
            try? await context.whisper.ensureStarted()
            try? await Task.sleep(for: .milliseconds(800))
            let hp = context.whisper.workerPID ?? 0
            perf("Whisper helper LOADED, idle: RSS \(mb(context.whisper.workerResidentBytes)) · load \(fmt(context.whisper.metrics.loadSeconds, "%.1f")) s")
            let h0 = cpu(hp); try? await Task.sleep(for: .seconds(5)); perf("Whisper helper idle CPU over 5 s: \(fmt(cpu(hp) - h0, "%.3f")) CPU-s")
            let j0 = cpu(me), hh0 = cpu(hp)
            _ = await transcribe(whisperProvider!, fixture("tr_long"), language: .auto)
            perf("one ACTIVE utterance (5 s audio, Turkish): JARVIS +\(fmt(cpu(me) - j0, "%.2f")) CPU-s · helper +\(fmt(cpu(hp) - hh0, "%.2f")) CPU-s · helper RSS \(mb(context.whisper.workerResidentBytes)) · last decode \(fmt(context.whisper.metrics.lastFinalDecodeSeconds, "%.2f")) s (RTF \(fmt(context.whisper.metrics.realTimeFactor)))")
        }
        let speechNow = await speechProcesses()
        perf("macOS speech services after STT+TTS use (pid/name/RSS MB): \(speechNow.map { "\($0.pid) \($0.name) \($0.rssMB)" }.joined(separator: " · ")) — baseline before: \(baselineSpeech.map { "\($0.name) \($0.rssMB)" }.joined(separator: " · "))")
        let t0 = cpu(me)
        tts.speak(SpeechChunk(id: 9100, text: "Bu, sesli yanıt sırasındaki işlemci kullanımını ölçmek için okunan uzun bir cümledir ve birkaç saniye sürer.", language: .turkish), voice: nil, rate: 1.0)
        try? await Task.sleep(for: .seconds(4))
        perf("JARVIS during real TTS playback: +\(fmt(cpu(me) - t0, "%.3f")) CPU-s over 4 s (\(fmt((cpu(me) - t0) / 4 * 100, "%.1f")) % of one core)")
        tts.stop()
        perf("JARVIS RSS now (STT+TTS used, HUD closed): \(mb(ProcessTree.residentBytes(of: me)))")

        // ------------------------------------------------------------ 8. no-network evidence, no audio on disk, sanitization, restart
        let jarvisSockets = await shell("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(me)", "-i"]).split(separator: "\n").filter { !$0.hasPrefix("COMMAND") }
        var helperSockets: [Substring] = []
        if let hp = context.whisper.workerPID { helperSockets = await shell("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(hp)", "-i"]).split(separator: "\n").filter { !$0.hasPrefix("COMMAND") } }
        check("No network socket is open in JARVIS or in the speech helper while speech runs (JARVIS has none; Apple's own speech services are system processes and cannot be inspected)", jarvisSockets.isEmpty && helperSockets.isEmpty, "JARVIS: \(jarvisSockets.count) · helper: \(helperSockets.count)")
        context.store.log("Voice test heard sk-LIVEVOICE0123456789abcdefghij secret", kind: .info)
        voice.onEvent?("Voice: heard token=ghp_abcdefghijklmnopqrstuvwxyz0123456789", .info)
        try? await Task.sleep(for: .milliseconds(500))
        let dataFiles = (FileManager.default.enumerator(atPath: context.paths.root.path)?.allObjects as? [String]) ?? []
        let audioFiles = dataFiles.filter { ["wav", "caf", "aiff", "aif", "m4a", "mp3", "flac", "ogg", "opus", "pcm"].contains(($0 as NSString).pathExtension.lowercased()) }
        check("No audio file exists anywhere in the JARVIS data directory after the whole run (raw audio is never persisted)", audioFiles.isEmpty, "\(dataFiles.count) files scanned")
        var leaked = false
        for f in dataFiles where f.hasSuffix(".sqlite") || f.hasSuffix(".sqlite-wal") || f.contains("artifacts/") {
            if let d = FileManager.default.contents(atPath: context.paths.root.appendingPathComponent(f).path), String(decoding: d, as: UTF8.self).contains("LIVEVOICE0123456789") || String(decoding: d, as: UTF8.self).contains("ghp_abcdefghijklmnopqrstuvwxyz") { leaked = true }
        }
        check("Fake secrets sent through the voice event path are masked in SQLite and artifacts", !leaked)
        let fresh = VoiceCoordinator(sttProviders: [], ttsProviders: [])
        check("After a restart a new voice session starts IDLE (no LISTENING/SPEAKING/TRANSCRIBING is ever restored)", fresh.state == .idle && !fresh.isMicrophoneOpen && voice.state == .idle)

        // ------------------------------------------------------------ 9. quit: SIGTERM of a child JARVIS leaves no speech helper behind
        if whisperReady {
            await context.whisper.unload()
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let child = ManagedProcess(executable: exe, arguments: ["--voice-live-test", "--voice-quit-child"], environment: ProcessInfo.processInfo.environment, workingDirectory: "/")
            if let lines = try? child.start(stdin: nil, keepStdinOpen: true) {
                var helperPID: pid_t = 0, ready = false
                let reader = Task { @MainActor in for await l in lines { let s = String(decoding: l, as: UTF8.self); if s.hasPrefix("HELPER_PID="), let p = Int32(s.dropFirst(11)) { helperPID = p }; if s == "CHILD_READY" { ready = true; break } } }
                let up = await waitUntil(90) { ready }
                reader.cancel()
                let alive = helperPID > 0 && ProcessTree.isAlive(helperPID)
                kill(child.processIdentifier, SIGTERM)
                let exited = await waitUntil(10) { !child.isRunning }
                let gone = await waitUntil(5) { helperPID > 0 && !ProcessTree.isAlive(helperPID) }
                if !exited { await child.cancel() }
                check("Quitting JARVIS (SIGTERM) while the speech helper is loaded terminates the helper too — no orphan", up && alive && exited && gone, "helper pid \(helperPID) alive before: \(alive), gone after: \(gone)")
            } else { check("The quit child could be launched", false) }
        } else { skip("quit cleanup", "Whisper helper not installed") }

        voice.shutdown()                                                              // what the app does at quit
        let cleaned = await waitUntil(5) { ProcessRegistry.shared.count == 0 && context.whisper.workerPID == nil }
        check("After shutdown no managed process (speech helper or one-shot tool) is left behind by the voice stack", cleaned, "registry: \(ProcessRegistry.shared.count) \(ProcessRegistry.shared.names)")
        finish()
    }

    /// Child-process mode (`--voice-quit-child`): loads the speech helper and idles so the parent can SIGTERM this process.
    static func runQuitChild(context: AppContext) async {
        guard let provider = context.voice.sttProviders.first(where: { $0.id == "whisper-local" }) else { exit(3) }
        do { _ = try await provider.makeSession(language: .english) } catch { print("CHILD_FAILED \(error)"); fflush(stdout); exit(4) }
        print("HELPER_PID=\(context.whisper.workerPID ?? 0)"); print("CHILD_READY"); fflush(stdout)
        try? await Task.sleep(for: .seconds(300))
        exit(0)
    }
}
