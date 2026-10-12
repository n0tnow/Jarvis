import AppKit

/// `Jarvis --natural-voice-live-test [--natural-audible] [--natural-acoustic] [--natural-idle <min>]` — OPT-IN, REAL (V0.8).
///
/// Exercises the ACTUAL natural-voice stack on this Mac with SYNTHETIC speech (system voices — never a recording of a person) in a CLOSED ACOUSTIC LOOP
/// without hardware: a scripted microphone plays the speech at real time and a simulated speaker plays JARVIS' real synthesised audio at real time while
/// leaking an attenuated, delayed copy of it back into the microphone. Everything else is the product, unchanged:
///   the local wake-word/VAD sentinel helper → turn manager → endpoint policy → real recognisers (Whisper / Apple) → the SAME ConversationService.submit
///   → deterministic command → real speech synthesis (local neural voice, Apple fallback) → chunker → player queue → barge-in detector → stop.
/// Scenarios: provider discovery, neural voice (tr/en/mixed, latency, RTF, cancel, unload, fallback), wake positives/negatives, self-wake, attentive timeout,
/// natural turns (Turkish, English, one-breath, hesitation), follow-up and its end, barge-in at beginning/middle/end, false barge-in, approvals, Push-to-Talk
/// compatibility, resources, no sockets, no audio on disk, quit cleanup.
/// What it CANNOT prove (MANUAL TEST REQUIRED): wake/recognition quality for a real human voice, a real room, voice naturalness, VoiceOver, the real speaker echo
/// of another machine. `--natural-acoustic` additionally measures the REAL speaker→microphone loop of this Mac (audible; levels only, nothing kept).
@MainActor
enum NaturalVoiceLiveTest {
    // swiftlint:disable:next function_body_length
    static func run(context: AppContext, rig: VoiceTestRig, audible: Bool, acoustic: Bool, idleMinutes: Double, combined: Bool) async {
        var failures = 0, passes = 0, skipped = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "", synthetic: Bool = false) {
            print("\(ok ? "REAL TESTED PASS" : "REAL TESTED FAIL")  \(synthetic ? "[synthetic audio] " : "")\(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if ok { passes += 1 } else { failures += 1 }
            fflush(stdout)
        }
        func skip(_ name: String, _ why: String) { print("SKIPPED  \(name) — \(why)"); skipped += 1; fflush(stdout) }
        func info(_ s: String) { print("INFO  \(s)"); fflush(stdout) }
        func perf(_ s: String) { print("PERF  \(s)"); fflush(stdout) }
        func fmt(_ d: Double?, _ f: String = "%.2f") -> String { d.map { String(format: f, $0) } ?? "–" }
        func ms(_ d: Double?) -> String { d.map { "\(Int($0 * 1000)) ms" } ?? "–" }
        func mb(_ b: UInt64?) -> String { b.map { "\($0 / 1_048_576) MB" } ?? "–" }

        let voice = context.voice, hf = context.handsFree, sentinel = context.sentinel, neural = context.neuralVoice, hub = context.micHub, me = getpid()
        let conversation = context.conversation, store = context.store
        DispatchQueue.main.asyncAfter(deadline: .now() + 2400 + idleMinutes * 60) { ProcessRegistry.shared.killAll(); print("NATURAL VOICE LIVE TEST TIMEOUT"); fflush(stdout); exit(2) }
        let startedWall = Date()
        func finish() -> Never {
            hf.shutdown(); voice.shutdown()
            print("NATURAL VOICE LIVE TEST \(failures == 0 ? "PASSED" : "FAILED") (\(passes) passed, \(failures) failed, \(skipped) skipped)"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
        func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return cond()
        }
        func shell(_ exe: String, _ args: [String]) async -> String {
            await ManagedProcess.runOnce(executable: exe, arguments: args, environment: ProviderEnvironment.make(), workingDirectory: "/", timeout: 20, maxOutput: 2_000_000)?.output ?? ""
        }
        func cpu(_ pid: pid_t?) -> Double { pid.flatMap { ProcessTree.cpuSeconds(of: $0) } ?? 0 }
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        func messages(since count: Int) -> [ConversationMessage] { Array(conversation.messages.dropFirst(count)) }
        func userMessages(since count: Int) -> [ConversationMessage] { messages(since: count).filter { $0.role == .user } }
        func jarvisMessages(since count: Int) -> [ConversationMessage] { messages(since: count).filter { $0.role == .jarvis } }

        // ---- test settings: the real preferences are never touched
        var ts = VoiceSettings(enabled: true, pushToTalkEnabled: true, speakResponses: true, language: .auto, sttProvider: "auto", ttsProvider: "auto", speechRate: 1.0,
                               wakeEnabled: true, wakeAcknowledgement: .sound, bargeInEnabled: true, voicePreset: .jarvisDefault)
        voice.settings = { ts }
        hf.settings = { ts }
        var cfg = hf.config
        cfg.attentiveSeconds = 4; cfg.followUpSeconds = 5                    // shortened for the test (defaults: 7 s / 8 s)
        hf.config = cfg
        let neuralProvider = voice.ttsProviders.first { $0.id == "neural-supertonic" } as? NeuralSpeechProvider
        let appleProvider = voice.ttsProviders.first { $0.id == "apple-synthesizer" } as? AppleSpeechSynthesizerProvider
        guard let neuralProvider, let appleProvider else { check("The expected voice providers exist", false); finish() }
        info("data directory: \(context.paths.root.path) (isolated from your real JARVIS history) · closed acoustic loop: scripted microphone + simulated speaker (echo \(Int(rig.echoCouplingDB)) dB, \(Int(rig.echoDelay * 1000)) ms)")
        info(audible ? "AUDIBLE neural/Apple rendering checks: the Mac will speak." : "Silent: speech is synthesised for real but played into the simulated speaker only.")

        // ------------------------------------------------------------ 0. discovery
        await voice.refreshProviders()
        sentinel.inspect(); neural.inspect()
        info("wake sentinel: \(sentinel.state.label) · neural voice: \(neural.state.label) · STT choice: \(voice.sttChoice.reason) · TTS choice: \(voice.ttsChoice.reason)")
        check("Voice and wake mode are idle at launch: no microphone engine, no helper process, nothing speaking, turn manager dormant",
              !hub.isCapturing && hub.subscriberCount == 0 && sentinel.host.pid == nil && neural.host.pid == nil && hf.state == .dormant && !voice.speaker.isActive && context.whisper.workerPID == nil)
        check("The wake-word helper is installed (scripts/setup_voice_ai.sh --natural; head: scripts/train_wake_head.sh)", sentinel.isAvailable, "\(sentinel.state.label)")
        check("The local neural voice is installed (scripts/setup_voice_ai.sh --natural)", { if case .notInstalled = neural.state { return false }; return true }(), "\(neural.state.label)")
        guard sentinel.isAvailable else { finish() }
        check("Every speech component declares LOCAL/SYSTEM cost, no network and no API key",
              voice.ttsProviders.allSatisfy { !$0.capabilities.needsNetwork && $0.capabilities.costClass.autoSelectable } && voice.sttProviders.allSatisfy { !$0.capabilities.needsNetwork },
              "neural \(neuralProvider.capabilities.costClass.label) · apple \(appleProvider.capabilities.costClass.label)")
        check("Auto chooses the local neural JARVIS voice when installed (Apple system voice is the fallback)", voice.ttsChoice.id == "neural-supertonic" || { if case .notInstalled = neural.state { return true }; return false }(), voice.ttsChoice.reason)
        let neuralInstalled: Bool = { if case .notInstalled = neural.state { return false }; return true }()

        // ------------------------------------------------------------ 1. fixtures (system voices, in memory)
        func clip(_ text: String, _ lang: VoiceLanguage, lead: Double = 0.2, tail: Double = 0.25) async -> [Float] {
            (try? await AudioFixtures.make([.init(text: text, language: lang)], tts: appleProvider, lead: lead, tail: tail)) ?? []
        }
        func wordEnd(_ c: [Float], tail: Double = 0.25) -> Double { Double(c.count) / AudioFrame.sampleRate - tail }
        let jarvisEN = await clip("Jarvis", .english), jarvisTR = await clip("Jarvis", .turkish), jarvisDaniel = (try? await AudioFixtures.make([.init(text: "Jarvis", language: .english)], tts: appleProvider)) ?? []
        let cmdTR = await clip("görevler ekranını aç.", .turkish), cmdEN = await clip("open the system screen.", .english)
        let breathTR = await clip("Jarvis, görevler ekranını aç.", .turkish), breathEN = await clip("Jarvis, open the Tasks screen.", .english)
        let hesA = await clip("Jarvis, Unity'deki", .turkish, tail: 0.0), hesB = await clip("son testlerin durumunu söyle.", .turkish, lead: 0.0)
        let longAskTR = await clip("projeyi anlat.", .turkish), followTR = await clip("sistem ekranını aç.", .turkish), followEN = await clip("show me the tasks.", .english)
        let interruptTR = await clip("Dur, görevler ekranını aç.", .turkish), interruptEN = await clip("Stop. Open the system screen.", .english)
        let chatterTR = await clip("Bugün hava çok güzel, akşam biraz yürüyüşe çıkalım mı?", .turkish)
        let chatterEN = await clip("The meeting starts at nine tomorrow morning, please be on time.", .english)
        let approveEN = await clip("approve", .english), approveTR = await clip("evet, onayla, tamam yap", .turkish)
        let selfTR = await clip("Merhaba, ben Jarvis. Sesim böyle.", .turkish)
        check("Synthetic speech fixtures were generated in memory (nothing written to disk)",
              [jarvisEN, jarvisTR, jarvisDaniel, cmdTR, cmdEN, breathTR, breathEN, hesA, hesB, longAskTR, followTR, followEN, interruptTR, interruptEN, chatterTR, chatterEN, approveEN, approveTR, selfTR].allSatisfy { $0.count > 3000 }, synthetic: true)
        // Developer aid: JARVIS_DUMP_FIXTURES=<dir> writes the (synthetic, non-sensitive) fixtures as 16-bit WAVs for the Python wake benchmark and exits.
        if let dir = ProcessInfo.processInfo.environment["JARVIS_DUMP_FIXTURES"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let named: [(String, [Float])] = [("jarvisEN", jarvisEN), ("jarvisTR", jarvisTR), ("jarvisDaniel", jarvisDaniel), ("breathTR", breathTR), ("breathEN", breathEN), ("cmdTR", cmdTR), ("cmdEN", cmdEN)]
            for (n, c) in named {
                var data = Data()
                func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
                data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + c.count * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(16000)); le(UInt32(32000)); le(UInt16(2)); le(UInt16(16))
                data.append(contentsOf: Array("data".utf8)); le(UInt32(c.count * 2)); for v in c { le(Int16(max(-1, min(1, v)) * 32767)) }
                try? data.write(to: URL(fileURLWithPath: dir + "/\(n).wav"))
            }
            info("fixtures written to \(dir)"); finish()
        }
        func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * AudioFrame.sampleRate)) }
        func concat(_ parts: [[Float]]) -> [Float] { parts.reduce(into: []) { $0 += $1 } }

        // ------------------------------------------------------------ 2. neural voice, in isolation (before the loops)
        if neuralInstalled {
            neuralProvider.outputVolume = audible ? 1.0 : 0
            let phrases: [(String, String, VoiceLanguage)] = [("tr", "Unity testleri tamamlandı. Tüm EditMode ve PlayMode testleri geçti.", .turkish), ("tr2", "Efendim? Son görevin sonuçlarını kontrol ediyorum.", .turkish),
                                                              ("en", "The Unity tests are complete. No new Console errors were detected.", .english), ("en2", "Of course. I'm checking the latest task now.", .english),
                                                              ("mixed", "Play Mode tamamlandı ve BoxCollider değişikliği doğrulandı.", .turkish), ("mixed2", "Unity projesinde iki GameObject güncellendi.", .turkish)]
            let t0 = Date()
            let cold = try? await neuralProvider.render(phrases[0].1, language: .turkish, voice: nil, rate: 1.0)
            let coldTotal = Date().timeIntervalSince(t0)
            perf("neural voice cold start (helper launch + model load + first phrase): \(ms(coldTotal)) (helper load \(fmt(neural.host.lastLoadSeconds, "%.1f")) s) · first block \(ms(neural.metrics.lastFirstBlockSeconds))")
            var firsts: [Double] = [], rtfs: [Double] = []
            var audioOK = cold != nil && (cold?.duration ?? 0) > 1
            for (_, text, lang) in phrases {
                guard let r = try? await neuralProvider.render(text, language: lang, voice: nil, rate: 1.0) else { audioOK = false; continue }
                firsts.append(r.firstBufferSeconds ?? 0); rtfs.append(r.totalSeconds / max(r.duration, 0.1))
                audioOK = audioOK && r.duration > 0.8 && r.samples.contains { abs($0) > 0.02 }
            }
            check("Neural synthesis works for Turkish, English and mixed Turkish/English technical phrases (real audio, tr/en/mixed)", audioOK, "warm first block p50 \(ms(SpeechMetrics.p50(firsts))) · RTF p50 \(fmt(SpeechMetrics.p50(rtfs))) · \(neural.metrics.phrases) phrases", synthetic: false)
            perf("neural voice: RSS \(mb(neural.host.residentBytes)) · CPU \(fmt(neural.host.cpuSeconds, "%.1f")) s total · load \(fmt(neural.host.lastLoadSeconds, "%.1f")) s")
            // cancellation: start a long phrase, stop after the first block
            let longText = "Bu uzun bir cümle, çünkü iptal edilebildiğini görmek istiyorum ve birkaç saniye sürmesi gerekiyor."
            let cancelStart = Date()
            var gotBlock = false
            let stream = neural.synthesize(id: 9001, text: longText, language: .turkish, parameters: VoiceIdentityMapper.neural(preset: .jarvisDefault, rate: 1.0)!, tailMilliseconds: 160)
            let consumer = Task { @MainActor in do { for try await _ in stream { gotBlock = true; break } } catch {} }
            _ = await waitUntil(8) { gotBlock }
            consumer.cancel()
            neural.cancelAll()
            check("A neural synthesis in progress can be cancelled; the helper stays healthy and answers the next request", { if case .running = neural.state { return true }; return false }() , "cancelled \(ms(Date().timeIntervalSince(cancelStart))) after the request")
            let after = try? await neuralProvider.render("Tamam.", language: .turkish, voice: nil, rate: 1.0)
            check("The next phrase after a cancellation is not polluted by the cancelled one", (after?.duration ?? 0) > 0.2 && (after?.duration ?? 9) < 2, "duration \(fmt(after?.duration))")
            // memory-pressure fallback + unload
            voice.memoryPressureNormal = { false }
            await voice.refreshProviders()
            check("Under memory pressure Auto falls back to the Apple system voice (the neural voice is not selected)", voice.ttsChoice.id == "apple-synthesizer", voice.ttsChoice.reason)
            let unloadStart = Date()
            await neural.unload()
            check("Memory pressure unloads the neural helper (process gone)", neural.host.pid == nil && neural.state == .idle, "\(ms(Date().timeIntervalSince(unloadStart)))")
            voice.memoryPressureNormal = { true }
            ts.voicePreset = .systemFallback
            await voice.refreshProviders()
            check("The System Fallback preset selects the Apple voice and leaves the neural helper unloaded", voice.ttsChoice.id == "apple-synthesizer" && neural.host.pid == nil, voice.ttsChoice.reason)
            ts.voicePreset = .jarvisDefault
            await voice.refreshProviders()
            check("An explicit choice never falls back: choosing the neural voice with it unavailable explains instead of switching",
                  VoiceProviderSelection.chooseTTS(preference: "neural-supertonic", candidates: [("neural-supertonic", "JARVIS Voice", .unavailable("x"), .local), ("apple-synthesizer", "Apple", .ready, .system)]).id == nil)
        } else {
            skip("neural voice checks", "not installed — scripts/setup_voice_ai.sh --natural")
        }

        // ------------------------------------------------------------ 3. wake mode on: nothing but the sentinel listens
        appleProvider.outputVolume = audible ? 1.0 : 0
        neuralProvider.outputVolume = audible ? 1.0 : 0
        let hubStarts0 = hub.startCount
        await hf.applySettings()
        check("Wake mode starts: sentinel helper running, ONE microphone engine, status LISTENING", hf.wakeStatus == .listening && sentinel.isRunning && hub.isCapturing && hub.startCount == hubStarts0 + 1 && hf.state == .wakeListening,
              "status \(hf.wakeStatus.label) · helper pid \(sentinel.host.pid.map(String.init) ?? "–") · load \(fmt(sentinel.host.lastLoadSeconds, "%.2f")) s · subscribers \(hub.subscriberLabels)")
        check("Before the wake word NO speech recognition runs: no recogniser helper, no STT session, voice session idle, no transcript",
              context.whisper.workerPID == nil && voice.state == .idle && !voice.isMicrophoneOpen && voice.partialTranscript.isEmpty && voice.turns == 0)
        let sentinelPID = sentinel.host.pid
        perf("sentinel RSS \(mb(sentinel.host.residentBytes)) · JARVIS RSS \(mb(ProcessTree.residentBytes(of: me)))")

        var turnsBaseline = 0, wakesBaseline = 0                                              // turns already run by the optional combined sample
        // ---- 3-combined. the representative heavy state: local Qwen resident + Whisper + neural voice + wake sentinel (+ a Unity editor when --unity-live-test runs next to this test)
        if combined {
            func sysctlSwap() async -> String { await shell("/usr/sbin/sysctl", ["-n", "vm.swapusage"]).trimmingCharacters(in: .whitespacesAndNewlines) }
            func pressureLine() async -> String { await shell("/usr/bin/memory_pressure", []).split(separator: "\n").last { $0.contains("free percentage") }.map(String.init) ?? "n/a" }
            func unityRSS() async -> (Int, Int) {
                let all = await shell("/bin/ps", ["-axo", "rss=,comm="]).split(separator: "\n")
                let rows = all.filter { $0.contains("/Unity.app/") || $0.contains("/Hub/Editor/") }
                return (rows.count, rows.compactMap { Int($0.split(separator: " ").first ?? "") }.reduce(0, +) / 1024)
            }
            perf("combined: before loading anything — swap \(await sysctlSwap()) · \(await pressureLine())")
            let q0 = Date()
            await context.testLocalModel()
            perf("combined: local Qwen worker ready after \(fmt(Date().timeIntervalSince(q0), "%.1f")) s — RSS \(mb(context.localRuntime.workerResidentBytes)) · peak \(fmt(context.localRuntime.metrics.peakMemoryGB, "%.1f")) GB (state \(context.localRuntime.state.label))")
            try? await context.whisper.ensureStarted()
            _ = try? await neuralProvider.render("Tamam.", language: .turkish, voice: nil, rate: 1.0)
            var u = await unityRSS()
            if u.0 == 0 {
                info("combined: waiting up to 300 s for a Unity editor to appear (start --unity-live-test next to this test)…")
                let deadline = Date().addingTimeInterval(300)
                while u.0 == 0, Date() < deadline { try? await Task.sleep(for: .seconds(5)); u = await unityRSS() }
            }
            perf("combined: Unity processes found: \(u.0) · total RSS \(u.1) MB\(u.0 == 0 ? " (no Unity editor was running during this sample)" : "")")
            let c0 = cpu(me), s0 = cpu(sentinelPIDForCombined(sentinel)), w0 = cpu(context.whisper.workerPID), n0 = cpu(neural.host.pid), tA = now()
            let mark = conversation.messages.count
            rig.microphone.say(concat([silence(0.5), jarvisTR, silence(0.9), cmdTR, silence(1.5)]))
            _ = await waitUntil(60) { !jarvisMessages(since: mark).isEmpty }
            _ = await waitUntil(30) { hf.state == .attentive || hf.state == .wakeListening }
            let span = now() - tA
            turnsBaseline = voice.turns; wakesBaseline = hf.wakeCount
            let rssJ = ProcessTree.residentBytes(of: me), rssS = sentinel.host.residentBytes, rssW = context.whisper.workerResidentBytes, rssN = neural.host.residentBytes, rssQ = context.localRuntime.workerResidentBytes
            let total = (rssJ ?? 0) + (rssS ?? 0) + (rssW ?? 0) + (rssN ?? 0) + (rssQ ?? 0) + UInt64(u.1) * 1_048_576
            perf("combined, one natural turn with everything resident: JARVIS \(mb(rssJ)) + wake \(mb(rssS)) + Whisper \(mb(rssW)) + neural voice \(mb(rssN)) + Qwen worker \(mb(rssQ)) + Unity \(u.1) MB = \(total / 1_048_576) MB over \(fmt(span, "%.0f")) s · CPU-s: JARVIS +\(fmt(cpu(me) - c0, "%.2f")), wake +\(fmt(cpu(sentinel.host.pid) - s0, "%.2f")), Whisper +\(fmt(cpu(context.whisper.workerPID) - w0, "%.2f")), neural +\(fmt(cpu(neural.host.pid) - n0, "%.2f"))")
            perf("combined: after the turn — swap \(await sysctlSwap()) · \(await pressureLine()) · memory pressure \(context.resources.pressure.memory.rawValue)")
            check("The natural turn completed with Qwen, Whisper, the neural voice, the wake sentinel (and Unity, if running) all resident; memory pressure stayed NORMAL", !jarvisMessages(since: mark).isEmpty && context.resources.pressure.memory == .normal, "pressure \(context.resources.pressure.memory.rawValue)")
            await context.localRuntime.unload()
            _ = await waitUntil(hf.config.followUpSeconds + 6) { hf.state == .wakeListening }          // the follow-up window of that turn ends before the quiet-room measurements
            try? await Task.sleep(for: .seconds(3))
        }

        // ---- 3a. idle in a quiet room: the energy gate keeps the sentinel fed with NOTHING
        let cpu0 = cpu(sentinelPID), me0 = cpu(me), sent0 = sentinel.metrics.secondsSent
        try? await Task.sleep(for: .seconds(8))
        let idleSent = sentinel.metrics.secondsSent - sent0
        perf("wake mode idle (quiet room, 8 s): audio sent to the helper \(fmt(idleSent, "%.1f")) s · helper CPU \(fmt(cpu(sentinelPID) - cpu0, "%.2f")) CPU-s · JARVIS CPU \(fmt(cpu(me) - me0, "%.2f")) CPU-s · helper RSS \(mb(sentinel.host.residentBytes))")
        check("Wake mode in a quiet room costs almost nothing: the helper receives (almost) no audio and no phantom turn appears", idleSent < 2.5 && hf.wakeCount == wakesBaseline && voice.turns == turnsBaseline && hf.state == .wakeListening, "sent \(fmt(idleSent, "%.1f")) s of 8 s")

        // ---- 3b. negatives: look-alike words, ordinary Turkish/English speech, noise events (SYNTHETIC WAKE TESTED)
        func clicks(_ n: Int, seconds: Double) -> [Float] {
            var x = [Float](repeating: 0, count: Int(seconds * 16000))
            for k in 0..<n {
                let i = Int(Double(k + 1) / Double(n + 1) * Double(x.count)); if i + 400 < x.count { for j in 0..<400 { x[i + j] += Float.random(in: -1...1) * exp(-Float(j) / 60) * 0.25 } }
            }
            return x
        }
        // (a) ordinary speech and noise: strictly NO wake; (b) acoustic look-alikes: reported, a minority may wake (documented limit)
        let wakes0 = hf.wakeCount, turns0 = voice.turns
        var negativeAudio = 0.0
        for c in [chatterTR, chatterEN, clicks(30, seconds: 4), chatterTR, chatterEN] {
            let padded = concat([c, silence(0.8)])
            rig.microphone.say(padded); negativeAudio += Double(padded.count) / 16000
            try? await Task.sleep(for: .seconds(Double(padded.count) / 16000 + 0.2))
        }
        let ordinaryWakes = hf.wakeCount - wakes0
        info("ordinary-speech stream: \(fmt(negativeAudio, "%.0f")) s of Turkish/English sentences and keyboard clicks · wake events \(ordinaryWakes) · detector hits rejected as not utterance-initial \(hf.rejectedWakes)")
        check("No false wake on ordinary Turkish/English speech and keyboard noise (live stream)", ordinaryWakes == 0 && hf.state == .wakeListening && voice.turns == turns0, "\(ordinaryWakes) false wake(s) in \(fmt(negativeAudio, "%.0f")) s", synthetic: true)
        var lookalikeWakes = 0
        let lookalikes: [(String, VoiceLanguage)] = [("Service", .english), ("Harvest", .english), ("Marvin", .english), ("Hey Travis", .english), ("Çarşı", .turkish), ("Hey service", .english)]
        for (text, lang) in lookalikes {
            let w = hf.wakeCount
            let c = concat([await clip(text, lang), silence(1.0)])
            rig.microphone.say(c)
            try? await Task.sleep(for: .seconds(Double(c.count) / 16000 + 0.4))
            if hf.wakeCount > w { lookalikeWakes += 1; info("look-alike «\(text)» woke JARVIS (documented limit: near-homophones can)"); _ = await waitUntil(hf.config.attentiveSeconds + 3) { hf.state == .wakeListening } }
        }
        check("Acoustic look-alike words («Service», «Marvin», «Hey Travis» …) wake JARVIS only exceptionally", lookalikeWakes <= 2, "\(lookalikeWakes) of \(lookalikes.count)", synthetic: true)
        try? await Task.sleep(for: .seconds(1))

        // ---- 3c. positives and latency, then the attentive timeout back to wake mode
        var wakeLatencies: [Double] = [], detected = 0
        let positives: [(String, [Float], Float)] = [("Samantha 'Jarvis'", jarvisEN, 0), ("Yelda 'Jarvis' (Turkish reader)", jarvisTR, 0), ("Daniel 'Jarvis'", jarvisDaniel, 0), ("Samantha 'Jarvis' quiet (−18 dB)", jarvisEN, -18)]
        for (name, c, gain) in positives {
            let w0 = hf.wakeCount
            let start = rig.microphone.say(concat([silence(0.6), c, silence(0.2)]), gainDB: gain)
            let endOfWord = start + 0.6 + wordEnd(c)
            let ok = await waitUntil(5) { hf.wakeCount > w0 }
            let detectedAt = now()
            if ok { detected += 1; wakeLatencies.append(detectedAt - endOfWord) }
            let st = await sentinel.requestStats()
            info("wake «\(name)»: \(ok ? "detected" : "MISSED") \(ok ? "\(Int((detectedAt - endOfWord) * 1000)) ms after the end of the word" : "") · helper max score \(fmt(st.helperMaxScore)) · rejected as not utterance-initial so far \(hf.rejectedWakes)")
            let back = await waitUntil(hf.config.attentiveSeconds + 3) { hf.state == .wakeListening }                 // attentive timeout → wake-only listening
            if !back { info("did not return to wake mode in time: \(hf.state.label)") }
            try? await Task.sleep(for: .milliseconds(600))
        }
        check("The wake word is detected for most positive variants (synthetic Apple voices unseen in training)", detected >= 3, "\(detected) of \(positives.count) · latency after the word ends: p50 \(ms(SpeechMetrics.p50(wakeLatencies))) min \(ms(wakeLatencies.min())) max \(ms(wakeLatencies.max()))", synthetic: true)
        check("After a wake with nothing said, JARVIS returns to wake-only listening after the attentive window — and no speech recogniser ever ran", hf.state == .wakeListening && (combined || context.whisper.workerPID == nil) && voice.turns == turnsBaseline, "state \(hf.state.label) · recogniser helper \(context.whisper.workerPID.map(String.init) ?? "never started") · turns \(voice.turns)")

        // ------------------------------------------------------------ 4. natural turns through the REAL pipeline
        func hudSection() -> HUDSection { context.hud.section }
        var turnReports: [String] = []
        func naturalTurn(_ label: String, _ script: [Float], expectSection: HUDSection?, expectTexts: [String] = [], waitSpeech: Bool = true) async -> (ok: Bool, userCount: Int, mark: Int) {
            let mark = conversation.messages.count
            let w0 = hf.wakeCount
            let start = rig.microphone.say(script)
            let spokenEnd = start + Double(script.count) / 16000
            let submitted = await waitUntil(25) { userMessages(since: mark).count >= 1 }
            let text = userMessages(since: mark).first?.content ?? ""
            let answered = await waitUntil(15) { !jarvisMessages(since: mark).isEmpty }
            let spoke = waitSpeech ? await waitUntil(15) { voice.lastMetrics?.releaseToFirstAudio != nil || hf.state == .jarvisSpeaking || hf.state == .attentive } : true
            _ = await waitUntil(20) { hf.state == .attentive || hf.state == .wakeListening }
            let m = hf.metrics
            let report = "\(label): wake→ack \(ms(m.wakeToAttentive)) · speech end→endpoint \(ms(m.speechEndToEndpoint)) · endpoint→final \(ms(m.endpointToFinal)) · endpoint→first audio \(ms(m.endpointToFirstAudio)) · user speech end→first audio \(ms(m.speechEndToEndpoint.flatMap { a in m.endpointToFirstAudio.map { a + $0 } }))"
            turnReports.append(report)
            info("\(report) · transcript «\(text)» · STT \(voice.lastMetrics?.sttProvider ?? "–") · TTS \(voice.lastMetrics?.ttsProvider ?? "–")")
            let ok0 = submitted && answered && spoke && hf.wakeCount > w0
            if !ok0 {
                info("DIAG turn «\(label)» did not complete: state \(hf.state.label) · voice \(voice.state.label) · wake events +\(hf.wakeCount - w0) · rejected \(hf.rejectedWakes) · sentinel \(sentinel.state.label) pid \(sentinel.host.pid.map(String.init) ?? "–") sent \(sentinel.metrics.framesSent) wakeEvents \(sentinel.metrics.wakeEvents) vad \(sentinel.metrics.vadTransitions) · transitions \(hf.transitions.suffix(8).map(\.state))")
                info("DIAG activity: \(store.activity.suffix(8).map(\.message))")
            }
            let sectionOK = expectSection.map { hudSection() == $0 } ?? true
            let textsOK = expectTexts.allSatisfy { text.lowercased(with: Locale(identifier: "tr_TR")).contains($0) }
            return (submitted && answered && spoke && hf.wakeCount > w0 && sectionOK && textsOK, userMessages(since: mark).count, mark)
        }

        context.windows.hideFullHUD(); context.hud.section = .dashboard
        var r = await naturalTurn("TR two-step", concat([silence(0.5), jarvisTR, silence(0.9), cmdTR, silence(1.5)]), expectSection: .tasks)
        check("Turkish natural turn: wake word → attentive → user speaks → natural endpoint → real STT → the SAME ConversationService.submit → command executed (Tasks screen) → JARVIS answers aloud → follow-up window", r.ok && r.userCount == 1, "user messages in this turn: \(r.userCount)", synthetic: true)
        let ttsUsed = voice.lastMetrics?.ttsProvider
        check("The spoken answer used the preferred local voice when installed (Apple otherwise)", neuralInstalled ? ttsUsed == "neural-supertonic" : ttsUsed == "apple-synthesizer", "\(ttsUsed ?? "–")")
        check("A spoken request is a normal voice message (source .voice) in the conversation", conversation.messages.last(where: { $0.role == .user })?.source == .voice)
        _ = await waitUntil(12) { hf.state == .wakeListening }                       // let any follow-up window expire
        context.windows.hideFullHUD(); context.hud.section = .dashboard
        r = await naturalTurn("EN two-step", concat([silence(0.5), jarvisEN, silence(0.9), cmdEN, silence(1.5)]), expectSection: .system)
        check("English natural turn through the same path (System screen opened, answer spoken)", r.ok && r.userCount == 1, synthetic: true)
        _ = await waitUntil(12) { hf.state == .wakeListening }
        context.windows.hideFullHUD(); context.hud.section = .dashboard
        r = await naturalTurn("TR one breath", concat([silence(0.5), breathTR, silence(1.5)]), expectSection: .tasks, expectTexts: ["görevler"])
        check("One breath — «Jarvis, görevler ekranını aç.» — the word is part of the utterance (pre-roll) and the command runs", r.ok && r.userCount == 1, synthetic: true)
        _ = await waitUntil(12) { hf.state == .wakeListening }
        context.windows.hideFullHUD(); context.hud.section = .dashboard
        r = await naturalTurn("EN one breath", concat([silence(0.5), breathEN, silence(1.5)]), expectSection: .tasks)
        check("One breath in English («Jarvis, open the Tasks screen.»)", r.ok && r.userCount == 1, synthetic: true)
        _ = await waitUntil(12) { hf.state == .wakeListening }

        // ---- hesitation: a natural mid-sentence pause must not split the turn
        let hesMark = conversation.messages.count, hesT0 = now()
        rig.microphone.say(concat([silence(0.5), hesA, silence(0.9), hesB, silence(2.0)]))
        _ = await waitUntil(25) { !userMessages(since: hesMark).isEmpty }
        _ = await waitUntil(15) { !jarvisMessages(since: hesMark).isEmpty }
        _ = await waitUntil(25) { hf.state == .wakeListening || hf.state == .attentive }
        try? await Task.sleep(for: .seconds(2.5))
        let hesUsers = userMessages(since: hesMark)
        info("hesitation turn: \(hesUsers.count) user message(s): \(hesUsers.map { "«\($0.content)»" }.joined(separator: " "))")
        if hesUsers.count != 1 || (hesUsers.first?.content.count ?? 0) <= 25 {
            info("DIAG hesitation trace: " + hf.eventTrace.filter { $0.at >= hesT0 }.map { "+\(fmt($0.at - hesT0, "%.2f")) \($0.event)" }.joined(separator: " | "))
        }
        check("A 0.9 s mid-sentence pause («Jarvis, Unity'deki … son testlerin durumunu söyle.») stays ONE turn — not two", hesUsers.count == 1 && (hesUsers.first?.content.count ?? 0) > 25, "\(hesUsers.count) turn(s)", synthetic: true)
        _ = await waitUntil(12) { hf.state == .wakeListening }

        // ---- follow-up without the wake word, then its end
        let fMark = conversation.messages.count
        rig.microphone.say(concat([silence(0.4), jarvisTR, silence(0.8), cmdTR, silence(1.5)]))
        _ = await waitUntil(25) { userMessages(since: fMark).count >= 1 }
        _ = await waitUntil(25) { hf.state == .attentive }                                           // JARVIS finished speaking: follow-up window open
        check("After the answer a bounded follow-up window opens (ATTENTIVE) without the wake word", hf.state == .attentive, "state \(hf.state.label)")
        let f2 = conversation.messages.count
        context.windows.hideFullHUD(); context.hud.section = .dashboard
        rig.microphone.say(concat([silence(0.3), followTR, silence(1.5)]))
        let accepted = await waitUntil(20) { userMessages(since: f2).count >= 1 }
        check("A follow-up question WITHOUT «Jarvis» is accepted inside the follow-up window (second turn, same conversation)", accepted && userMessages(since: f2).count == 1, "«\(userMessages(since: f2).first?.content ?? "")»", synthetic: true)
        _ = await waitUntil(25) { hf.state == .attentive || hf.state == .wakeListening }
        _ = await waitUntil(hf.config.followUpSeconds + 4) { hf.state == .wakeListening }
        check("After the follow-up window ends JARVIS is back to wake-only listening", hf.state == .wakeListening)
        let f3 = conversation.messages.count, turnsBefore = voice.turns
        rig.microphone.say(concat([silence(0.3), chatterTR, silence(1.0)]))
        try? await Task.sleep(for: .seconds(Double(chatterTR.count) / 16000 + 3))
        check("Ordinary speech WITHOUT the wake word after the window is ignored: no message, no recogniser session, no answer", conversation.messages.count == f3 && voice.turns == turnsBefore && hf.state == .wakeListening, "conversation unchanged: \(conversation.messages.count == f3)", synthetic: true)

        // ------------------------------------------------------------ 5. self-speech: JARVIS saying its own name must not wake it
        let wSelf = hf.wakeCount, selfMark = conversation.messages.count
        voice.speaker.speakStandalone("Merhaba, ben Jarvis. Sesim böyle.", language: .turkish)
        let selfStarted = await waitUntil(8) { voice.speaker.isSpeaking }
        _ = await waitUntil(20) { !voice.speaker.isActive }
        try? await Task.sleep(for: .seconds(2.5))
        check("JARVIS' own voice saying «Jarvis» (echoing into the microphone) never wakes it and never becomes a turn", selfStarted && hf.wakeCount == wSelf && conversation.messages.count == selfMark && hf.state == .wakeListening,
              "spoke: \(selfStarted) · wake events during/after: \(hf.wakeCount - wSelf) · echo reference peak \(fmt(Double(hf.level)))", synthetic: true)
        let wUser = hf.wakeCount
        rig.microphone.say(concat([silence(0.3), jarvisEN, silence(0.3)]))
        let userWoke = await waitUntil(5) { hf.wakeCount > wUser }
        check("A legitimate user «Jarvis» right after JARVIS spoke still wakes it", userWoke, synthetic: true)
        _ = await waitUntil(hf.config.attentiveSeconds + 3) { hf.state == .wakeListening }

        // ------------------------------------------------------------ 6. barge-in (real audio loop): beginning, middle, near the end
        var bargeReports: [String] = []
        for (label, offset) in [("beginning", 0), ("middle", 2), ("near the end", 3)] {
            let mark = conversation.messages.count
            let barges0 = hf.bargeInCount
            let startedBefore = Set(rig.playbacks.flatMap { $0.startedAt.keys })
            rig.microphone.say(concat([silence(0.4), jarvisEN, silence(0.8), longAskTR, silence(1.0)]))
            let speaking = await waitUntil(30) { hf.state == .jarvisSpeaking }
            guard speaking else { check("Barge-in «\(label)»: JARVIS started a long answer", false, "state \(hf.state.label) after the request"); continue }
            let speakStart = now()
            // The spoken answer is bounded (≈ 4–5 s, three phrases): beginning = 0.8 s in, middle = shortly after the 2nd phrase began, near the end = shortly after the LAST phrase began.
            var delay = 0.8
            if offset == 0 { try? await Task.sleep(for: .seconds(0.8)) }
            else {
                let started = { rig.playbacks.reduce(0) { n, p in n + p.startedAt.keys.filter { !startedBefore.contains($0) && $0 >= 0 }.count } }
                _ = await waitUntil(40) { started() >= offset }
                try? await Task.sleep(for: .seconds(0.3)); delay = now() - speakStart
            }
            let stillSpeaking = hf.state == .jarvisSpeaking
            info("DIAG barge-in \(label): waited \(fmt(delay, "%.1f")) s · state \(hf.state.label) · speaker active \(voice.speaker.isActive) · last barge-in \(hf.lastBargeIn ?? "none")")
            let userStart = rig.microphone.say(concat([interruptTR]), after: 0.02)
            let userSpeechEnd = userStart + Double(interruptTR.count) / 16000
            let decided = await waitUntil(6) { hf.bargeInCount > barges0 }
            let stopMoment = now()
            let silent = !voice.speaker.isSpeaking && !voice.speaker.isActive
            let newUser = await waitUntil(25) { userMessages(since: mark).count >= 2 }
            let newAnswer = await waitUntil(20) { jarvisMessages(since: mark).count >= 2 }
            let newAudio = await waitUntil(20) { hf.state == .jarvisSpeaking || hf.state == .attentive || hf.state == .wakeListening }
            let m = hf.metrics
            let line = "barge-in \(label): speaking at interruption \(stillSpeaking) · onset→decision \(ms(m.bargeInOnsetToDecision)) · decision→silence \(ms(m.bargeInDecisionToSilence)) · silent after \(silent) · new transcript «\(userMessages(since: mark).dropFirst().first?.content ?? "")» · user speech end→new first audio \(ms(m.speechEndToEndpoint.flatMap { a in m.endpointToFirstAudio.map { a + $0 } }))"
            bargeReports.append(line); info(line)
            _ = stopMoment
            check("Real barge-in at the \(label) of a long answer: the user's voice is detected over JARVIS' own echo, speech stops at once, a NEW turn is captured, transcribed and answered through the same pipeline",
                  stillSpeaking && decided && silent && newUser && newAnswer && newAudio, "decision→silence \(ms(m.bargeInDecisionToSilence)), onset→decision \(ms(m.bargeInOnsetToDecision))", synthetic: true)
            // nothing from the interrupted answer may start after the stop request (stale phrases)
            let staleStarts = rig.playbacks.reduce(0) { n, p in n + (p.stopRequests.last.map { stop in p.startedAt.filter { $0.key >= 0 && $0.value > stop + 0.05 && $0.value < stop + 0.6 }.count } ?? 0) }
            check("Barge-in «\(label)»: no stale phrase of the interrupted answer plays after the stop", staleStarts == 0, "\(staleStarts) phrase start(s) within 0.6 s after the stop")
            _ = await waitUntil(25) { hf.state == .attentive || hf.state == .wakeListening }
            _ = await waitUntil(hf.config.followUpSeconds + 4) { hf.state == .wakeListening }
        }

        // ---- no user at all: the whole long answer (it mentions «Jarvis») plays over its own echo → no false barge-in, no self-wake, no extra turn; and the gaps between its phrases are measured
        func gaps(_ playback: SimulatedPlayback) -> [Double] {
            let ids = playback.startedAt.keys.filter { $0 >= 0 }.sorted()
            var out: [Double] = []
            for (a, b) in zip(ids, ids.dropFirst()) { if let end = playback.finishedAt[a], let start = playback.startedAt[b] { out.append(max(0, start - end)) } }
            return out
        }
        for (label, preset) in [("neural JARVIS voice", JarvisVoicePreset.jarvisDefault), ("Apple system fallback", .systemFallback)] {
            if preset == .jarvisDefault && !neuralInstalled { continue }
            ts.voicePreset = preset
            await voice.refreshProviders()
            for p in rig.playbacks { _ = p }
            let quietMark = conversation.messages.count, quietBarges = hf.bargeInCount, quietWakes = hf.wakeCount
            let used = voice.ttsChoice.id
            let playback = rig.playbacks[used == "neural-supertonic" ? 0 : 1]
            let before = Set(playback.startedAt.keys)
            rig.microphone.say(concat([silence(0.4), jarvisEN, silence(0.8), longAskTR, silence(1.0)]))
            _ = await waitUntil(30) { hf.state == .jarvisSpeaking }
            _ = await waitUntil(60) { hf.state != .jarvisSpeaking && hf.state != .thinking }
            try? await Task.sleep(for: .seconds(1.5))
            let newStarts = playback.startedAt.filter { !before.contains($0.key) && $0.key >= 0 }
            let g = zip(newStarts.keys.sorted(), newStarts.keys.sorted().dropFirst()).compactMap { a, b -> Double? in
                guard let end = playback.finishedAt[a], let start = playback.startedAt[b] else { return nil }; return max(0, start - end)
            }
            perf("\(label) (\(used ?? "–")): \(newStarts.count) phrases · inter-phrase gap p50 \(ms(SpeechMetrics.p50(g))) max \(ms(g.max())) (the voice's own tail silence + synthesis wait; measured from the player queue)")
            check("A complete long answer in the \(label) over its own echo causes no false barge-in, no self-wake and no extra turn", hf.bargeInCount == quietBarges && hf.wakeCount == quietWakes + 1 && userMessages(since: quietMark).count == 1 && used == (preset == .jarvisDefault ? "neural-supertonic" : "apple-synthesizer"),
                  "barge-ins \(hf.bargeInCount - quietBarges) · wakes \(hf.wakeCount - quietWakes) (1 expected: the user's) · user messages \(userMessages(since: quietMark).count) · voice \(used ?? "–") · last barge-in: \(hf.lastBargeIn ?? "none")", synthetic: true)
            check("The phrases of the \(label) answer follow each other without long gaps (p50 < 450 ms, max < 1.5 s)", (SpeechMetrics.p50(g) ?? 0) < 0.45 && (g.max() ?? 0) < 1.5, "p50 \(ms(SpeechMetrics.p50(g))) · max \(ms(g.max()))")
            _ = await waitUntil(hf.config.followUpSeconds + 4) { hf.state == .wakeListening }
        }
        ts.voicePreset = .jarvisDefault
        await voice.refreshProviders()

        // ---- non-speech noise while JARVIS speaks: clicks, a thud, a short blip → no barge-in
        let nMark = conversation.messages.count, nB = hf.bargeInCount
        rig.microphone.say(concat([silence(0.4), jarvisEN, silence(0.8), longAskTR, silence(1.0)]))
        _ = await waitUntil(30) { hf.state == .jarvisSpeaking }
        let vad0 = sentinel.metrics.vadTransitions
        // the bounded answer lasts ≈ 4–5 s: the whole noise sequence (clicks, then the thud) has to happen inside it
        try? await Task.sleep(for: .seconds(0.3))
        rig.microphone.say(clicks(16, seconds: 1.8), after: 0.0, gainDB: 6)
        let clicksTriggered = await waitUntil(1.9) { hf.bargeInCount > nB }
        let vadClicks = sentinel.metrics.vadTransitions - vad0
        var thud = [Float](repeating: 0, count: 8000); for i in 0..<4800 { thud[i] = sin(2 * .pi * 90 * Float(i) / 16000) * exp(-Float(i) / 1500) * 0.5 }
        rig.microphone.say(thud, after: 0.0)
        let thudTriggered = await waitUntil(1.2) { hf.bargeInCount > nB }
        let vadThud = sentinel.metrics.vadTransitions - vad0 - vadClicks
        let stillSpeaking = hf.state == .jarvisSpeaking
        info("DIAG noise: clicks triggered \(clicksTriggered) (VAD transitions +\(vadClicks)) · thud triggered \(thudTriggered) (VAD transitions +\(vadThud)) · still speaking \(stillSpeaking) · last barge-in \(hf.lastBargeIn ?? "none")")
        check("Keyboard clicks and a door thud while JARVIS speaks do not interrupt it", !clicksTriggered && !thudTriggered && stillSpeaking && userMessages(since: nMark).count == 1, "state \(hf.state.label) · barge-in by clicks \(clicksTriggered) · by thud \(thudTriggered)", synthetic: true)
        voice.stopSpeaking()
        _ = await waitUntil(hf.config.followUpSeconds + 4) { hf.state == .wakeListening }

        // ------------------------------------------------------------ 7. approvals stay HUD-only
        store.setEngineApproval(ApprovalRequest(title: "Delete build folder (test fixture)", detail: "isolated fixture approval — nothing exists behind it"), id: UUID())
        let aMark = conversation.messages.count
        rig.microphone.say(concat([silence(0.4), jarvisEN, silence(0.8), approveEN, silence(1.4)]))
        _ = await waitUntil(25) { jarvisMessages(since: aMark).count >= 1 }
        let enNotice = jarvisMessages(since: aMark).first?.content ?? ""
        _ = await waitUntil(hf.config.followUpSeconds + 12) { hf.state == .wakeListening }
        let aMark2 = conversation.messages.count
        rig.microphone.say(concat([silence(0.4), jarvisTR, silence(0.8), approveTR, silence(1.4)]))
        _ = await waitUntil(25) { jarvisMessages(since: aMark2).count >= 1 }
        let trNotice = jarvisMessages(since: aMark2).first?.content ?? ""
        if enNotice.isEmpty || trNotice.isEmpty {
            info("DIAG approvals: TR transcript «\(userMessages(since: aMark2).first?.content ?? "")» · EN transcript «\(userMessages(since: aMark).first?.content ?? "")» · state \(hf.state.label) · voice \(voice.state.label) · trace tail: " + hf.eventTrace.suffix(16).map { "\($0.event)" }.joined(separator: " | "))
            info("DIAG approvals activity: \(store.activity.suffix(8).map(\.message))")
        }
        check("Waking JARVIS and saying «approve» / «evet onayla» does NOT approve: the approval stays pending and JARVIS says approvals are HUD-only",
              store.pendingApproval != nil && enNotice.lowercased().contains("hud") && trNotice.lowercased().contains("hud"), "EN «\(enNotice.prefix(60))» · TR «\(trNotice.prefix(60))»", synthetic: true)
        store.setEngineApproval(nil, id: nil)
        _ = await waitUntil(hf.config.followUpSeconds + 12) { hf.state == .wakeListening }

        // ------------------------------------------------------------ 8. Push-to-Talk keeps working (own turn, same single microphone engine)
        let startsBeforePTT = hub.startCount
        let pMark = conversation.messages.count
        voice.pushToTalkPressed()
        let labelsHeld = hub.subscriberLabels
        rig.microphone.say(concat([silence(0.2), breathEN, silence(0.3)]))
        try? await Task.sleep(for: .seconds(Double(breathEN.count) / 16000 + 0.6))
        voice.pushToTalkReleased()
        let pttDone = await waitUntil(25) { userMessages(since: pMark).count >= 1 && !jarvisMessages(since: pMark).isEmpty }
        check("Push-to-Talk during wake mode runs its own turn on the SAME single microphone engine (no second engine)", pttDone && labelsHeld.contains("push-to-talk") && labelsHeld.contains("wake") && hub.startCount == startsBeforePTT, "subscribers while held: \(labelsHeld) · engine starts +\(hub.startCount - startsBeforePTT)", synthetic: true)
        _ = await waitUntil(15) { !voice.speaker.isActive }
        // PTT while JARVIS speaks: explicit stop first, then listen
        rig.microphone.say(concat([silence(0.4), jarvisEN, silence(0.8), longAskTR, silence(1.0)]))
        _ = await waitUntil(30) { hf.state == .jarvisSpeaking }
        try? await Task.sleep(for: .seconds(1.0))
        voice.pushToTalkPressed()
        let stoppedByPTT = !voice.speaker.isSpeaking && voice.state == .listening
        voice.pushToTalkReleased(interrupted: true)
        check("Push-to-Talk pressed while JARVIS speaks stops the speech first (explicit stop) and takes the microphone", stoppedByPTT)
        _ = await waitUntil(hf.config.followUpSeconds + 12) { hf.state == .wakeListening }

        // ------------------------------------------------------------ 9. resources while wake mode runs (representative)
        let c0 = cpu(sentinelPID), j0 = cpu(me), t0 = now()
        rig.microphone.say(concat([silence(0.2), chatterEN, silence(0.5), chatterTR, silence(0.5), chatterEN]))
        try? await Task.sleep(for: .seconds(Double(chatterEN.count * 2 + chatterTR.count) / 16000 + 1.5))
        let span = now() - t0
        perf("wake mode with continuous speech in the room (\(fmt(span, "%.0f")) s): helper CPU \(fmt((cpu(sentinelPID) - c0) / span * 100, "%.1f")) % of one core · JARVIS \(fmt((cpu(me) - j0) / span * 100, "%.1f")) % · helper RSS \(mb(sentinel.host.residentBytes)) · JARVIS RSS \(mb(ProcessTree.residentBytes(of: me)))")
        let stats = await sentinel.requestStats()
        perf("helper counters: \(fmt(stats.helperAudioSeconds, "%.0f")) s of audio processed · \(fmt(stats.helperCPUSeconds, "%.1f")) CPU-s · audio sent \(fmt(stats.secondsSent, "%.0f")) s · wake events \(stats.wakeEvents) · VAD transitions \(stats.vadTransitions)")
        // ---- the cost of wake mode next to each HUD state (silent room): JARVIS' own CPU and memory, helper CPU
        for (label, open) in [("no HUD open", { context.windows.hideFullHUD(); context.windows.hideCompactHUD() }), ("Compact HUD open", { context.windows.hideFullHUD(); context.windows.showCompactHUD() }),
                              ("Full HUD open (Dashboard)", { context.windows.hideCompactHUD(); context.windows.showFullHUD(section: .dashboard) })] {
            open()
            try? await Task.sleep(for: .seconds(2))
            let j0 = cpu(me), h0 = cpu(sentinel.host.pid), t0 = now()
            try? await Task.sleep(for: .seconds(10))
            let span = now() - t0
            perf("wake mode, \(label), quiet room (\(fmt(span, "%.0f")) s): JARVIS \(fmt((cpu(me) - j0) / span * 100, "%.2f")) % of one core · wake helper \(fmt((cpu(sentinel.host.pid) - h0) / span * 100, "%.2f")) % · JARVIS RSS \(mb(ProcessTree.residentBytes(of: me)))")
        }
        context.windows.hideFullHUD(); context.windows.hideCompactHUD(); context.hud.section = .dashboard
        let neuralPID = neural.host.pid
        perf("neural voice (loaded): RSS \(mb(neural.host.residentBytes)) · whisper helper RSS \(mb(context.whisper.workerResidentBytes))")
        let voiceHelpers = [sentinel.host.pid, neural.host.pid, context.whisper.workerPID].compactMap { $0 }
        var sockets = ""
        for pid in voiceHelpers + [me] { sockets += await shell("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-i"]) }          // -a: only THIS process' sockets
        check("No network socket is open in JARVIS or in any voice helper (wake, neural, recogniser)", sockets.split(separator: "\n").filter { !$0.hasPrefix("COMMAND") }.isEmpty, sockets.isEmpty ? "lsof -i empty" : String(sockets.prefix(300)))

        // ---- raw audio never touches disk
        let audioExt: Set<String> = ["wav", "caf", "m4a", "aiff", "aif", "pcm", "mp3", "flac", "ogg", "opus"]
        var audioFiles: [String] = []
        for root in [context.paths.root, JarvisPaths.standard().root] {
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for case let url as URL in e where audioExt.contains(url.pathExtension.lowercased()) && !url.path.contains("-venv/") { audioFiles.append(url.path) }          // (python packages ship test wavs of their own)
            }
        }
        check("No audio file (wav/caf/m4a/pcm/…) exists in the JARVIS data or runtime directories — wake buffer, utterances and synthesised speech are memory-only", audioFiles.isEmpty, audioFiles.prefix(3).joined(separator: ", "))
        let db = context.paths.database
        let dbBytes = FileManager.default.contents(atPath: db.path) ?? Data()
        check("The SQLite database holds no audio blob and no partial transcript (no such column or table exists)", !String(decoding: dbBytes.prefix(2_000_000), as: UTF8.self).lowercased().contains("pcm"), "database \(dbBytes.count / 1024) KB")

        // ------------------------------------------------------------ 10. disable wake mode: everything stops; PTT still works with wake off
        ts.wakeEnabled = false
        await hf.applySettings()
        check("Turning wake mode off stops listening: no microphone engine, sentinel stopped, turn manager dormant", !hub.isCapturing && hub.subscriberCount == 0 && sentinel.host.pid == nil && hf.state == .dormant && hf.wakeStatus == .off,
              "helper pid \(sentinel.host.pid.map(String.init) ?? "gone") · hub \(hub.subscriberLabels) · turn manager \(hf.state.label) · wake \(hf.wakeStatus.label) · transitions \(hf.transitions.suffix(6).map(\.state))")
        if let pid = sentinelPID { check("The sentinel process is really gone", !ProcessTree.isAlive(pid)) }
        let pm = conversation.messages.count
        voice.pushToTalkPressed()
        let openedByPTT = hub.isCapturing
        rig.microphone.say(concat([silence(0.2), breathEN, silence(0.3)]))
        try? await Task.sleep(for: .seconds(Double(breathEN.count) / 16000 + 0.6))
        voice.pushToTalkReleased()
        let pttOnly = await waitUntil(25) { userMessages(since: pm).count >= 1 && !jarvisMessages(since: pm).isEmpty }
        _ = await waitUntil(15) { !voice.speaker.isActive }
        check("With wake mode OFF, Push-to-Talk works exactly as in V0.7 (engine opens on press, closes on release)", pttOnly && openedByPTT && !hub.isCapturing, synthetic: true)

        // ------------------------------------------------------------ 11. optional: the REAL speaker→microphone loop of this Mac, and the long idle test
        if acoustic { await acousticCheck(context: context, report: { check($0, $1, $2) }, info: info, fmt: fmt) } else { skip("real acoustic loop", "--natural-acoustic not given") }
        if idleMinutes > 0 {
            ts.wakeEnabled = true
            await hf.applySettings()
            let pid = sentinel.host.pid
            let rss0 = sentinel.host.residentBytes ?? 0, jr0 = ProcessTree.residentBytes(of: me) ?? 0
            let ca = cpu(pid), ja = cpu(me), tA = now(), sentA = sentinel.metrics.secondsSent, w0 = hf.wakeCount, turns0 = voice.turns, starts0 = sentinel.host.startCount
            info("long idle test: wake mode on a silent room for \(fmt(idleMinutes, "%.1f")) min …")
            try? await Task.sleep(for: .seconds(idleMinutes * 60))
            let span = now() - tA
            perf("long idle (\(fmt(span / 60, "%.1f")) min): helper CPU \(fmt((cpu(pid) - ca) / span * 100, "%.3f")) % of one core (\(fmt(cpu(pid) - ca, "%.2f")) CPU-s) · JARVIS CPU \(fmt((cpu(me) - ja) / span * 100, "%.3f")) % · audio sent to the helper \(fmt(sentinel.metrics.secondsSent - sentA, "%.1f")) s · helper RSS \(mb(rss0)) → \(mb(sentinel.host.residentBytes)) · JARVIS RSS \(mb(jr0)) → \(mb(ProcessTree.residentBytes(of: me)))")
            check("Long idle: no phantom wake or turn, no helper restart, no growing memory, wake mode still listening",
                  hf.wakeCount == w0 && voice.turns == turns0 && sentinel.host.startCount == starts0 && hf.state == .wakeListening && (sentinel.host.residentBytes ?? 0) < rss0 + 60 * 1_048_576 && (ProcessTree.residentBytes(of: me) ?? 0) < jr0 + 60 * 1_048_576,
                  "\(fmt(span / 60, "%.1f")) min")
            ts.wakeEnabled = false
            await hf.applySettings()
        }

        // ------------------------------------------------------------ 12. quit: SIGTERM of a child JARVIS in wake mode with the neural voice loaded leaves no helper
        if neuralInstalled {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let child = ManagedProcess(executable: exe, arguments: ["--natural-voice-live-test", "--natural-child"], environment: ProcessInfo.processInfo.environment, workingDirectory: "/")
            if let lines = try? child.start(stdin: nil, keepStdinOpen: true) {
                var pids: [pid_t] = [], ready = false
                let reader = Task { @MainActor in
                    for await l in lines {
                        let s = String(decoding: l, as: UTF8.self)
                        if s.hasPrefix("HELPER_PIDS=") { pids = s.dropFirst(12).split(separator: ",").compactMap { Int32($0) } }
                        if s == "CHILD_READY" { ready = true; break }
                    }
                }
                let up = await waitUntil(120) { ready }
                reader.cancel()
                let alive = !pids.isEmpty && pids.allSatisfy { ProcessTree.isAlive($0) }
                kill(child.processIdentifier, SIGTERM)
                let exited = await waitUntil(10) { !child.isRunning }
                let gone = await waitUntil(6) { pids.allSatisfy { !ProcessTree.isAlive($0) } }
                if !exited { await child.cancel() }
                check("Quitting JARVIS (SIGTERM) in wake mode with the neural voice loaded terminates every helper — no orphan", up && alive && exited && gone, "helper pids \(pids) alive before: \(alive), gone after: \(gone)")
            } else { check("The quit child could be launched", false) }
        } else { skip("quit cleanup", "neural voice not installed") }
        hf.shutdown(); voice.shutdown()
        let cleaned = await waitUntil(6) { ProcessRegistry.shared.count == 0 && sentinel.host.pid == nil && neural.host.pid == nil && context.whisper.workerPID == nil }
        check("After shutdown no managed process (wake, neural or recogniser helper) is left behind by the voice stack", cleaned, "registry: \(ProcessRegistry.shared.count)")
        info("test took \(Int(Date().timeIntervalSince(startedWall))) s")
        for line in turnReports + bargeReports { print("LATENCY  \(line)") }
        finish()
    }

    @MainActor private static func sentinelPIDForCombined(_ s: SentinelRuntime) -> pid_t? { s.host.pid }

    // MARK: Child mode and the optional real acoustic loop

    /// Child-process mode (`--natural-child`): wake mode on, neural voice loaded; prints the helper pids and idles so the parent can SIGTERM this process.
    static func runQuitChild(context: AppContext) async {
        let ts = VoiceSettings(enabled: true, wakeEnabled: true)
        context.voice.settings = { ts }; context.handsFree.settings = { ts }
        await context.handsFree.applySettings()
        let phrase = try? await (context.voice.ttsProviders.first { $0.id == "neural-supertonic" } as? NeuralSpeechProvider)?.render("Tamam.", language: .turkish, voice: nil, rate: 1.0)
        let pids = [context.sentinel.host.pid, context.neuralVoice.host.pid].compactMap { $0 }
        guard pids.count == 2, phrase != nil else { print("CHILD_FAILED \(pids)"); fflush(stdout); exit(4) }
        print("HELPER_PIDS=\(pids.map(String.init).joined(separator: ","))"); print("CHILD_READY"); fflush(stdout)
        try? await Task.sleep(for: .seconds(300))
        exit(0)
    }

    /// REAL speaker→microphone loop: JARVIS speaks a phrase through the real output engine while the real microphone listens; the real `BargeInDetector` must not
    /// fire on JARVIS' own voice, and a synthetic user mixed into the real microphone frames must be detected. Levels only; nothing is stored.
    static func acousticCheck(context: AppContext, report: (String, Bool, String) -> Void, info: (String) -> Void, fmt: (Double?, String) -> String) async {
        guard context.voice.permission == .granted else { info("real acoustic loop skipped: microphone permission is not already granted (never requested by this test)"); return }
        let player = SpeechPlayer()
        player.volume = 1.0
        let provider = AppleSpeechSynthesizerProvider(player: player)
        let mic = MicrophoneInput()
        final class Box: @unchecked Sendable { var frames: [(Double, Float, Double)] = []; var refs: [(Double, Float)] = []; let lock = NSLock() }
        let box = Box()
        player.onReferenceLevel = { db, t in box.lock.lock(); box.refs.append((t, db)); box.lock.unlock() }
        do {
            try mic.start(onFrame: { f in let t = ProcessInfo.processInfo.systemUptime; box.lock.lock(); box.frames.append((t, AudioLevel.db(f.samples), f.seconds)); box.lock.unlock() }, onInterruption: { _ in })
        } catch { report("Real microphone opened for the acoustic loop", false, "\(error)"); return }
        try? await Task.sleep(for: .seconds(1.5))
        let quietEnd = ProcessInfo.processInfo.systemUptime
        let speakStart = ProcessInfo.processInfo.systemUptime
        var done = false
        provider.onEvent = { if case .finished = $0 { done = true } }
        provider.speak(SpeechChunk(id: 1, text: "The Unity tests are complete. No new console errors were detected. Every edit mode and play mode test passed, and the build is clean.", language: .english), voice: nil, rate: 1.0)
        let end = Date().addingTimeInterval(14)
        while !done && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .seconds(0.6))
        mic.stop(); provider.shutdownNow()
        box.lock.lock(); let frames = box.frames, refs = box.refs; box.lock.unlock()
        let quiet = frames.filter { $0.0 < quietEnd }.map { Double($0.1) }
        let during = frames.filter { $0.0 > speakStart + 0.4 }
        let quietDB = quiet.isEmpty ? -120 : quiet.reduce(0, +) / Double(quiet.count)
        let echoDB = during.isEmpty ? -120 : during.map { Double($0.1) }.reduce(0, +) / Double(during.count)
        let refDB = refs.filter { $0.1 > -80 }.map { Double($0.1) }
        // the real detector over the recorded streams: once with the echo alone, once with a synthetic user louder than the echo mixed in digitally
        func replay(userDB: Float?) -> (fired: Bool, at: Double?, coupling: Float) {
            var d = BargeInDetector()
            d.beginPlayback(at: speakStart)
            var events: [(Double, String, Float, Double)] = refs.map { ($0.0, "r", $0.1, 0) } + frames.map { ($0.0, "m", $0.1, $0.2) }
            events.sort { $0.0 < $1.0 }
            for e in events where e.0 >= speakStart {
                if e.1 == "r" { d.pushReference(db: e.2, at: e.0); continue }
                var db = e.2
                if let u = userDB, e.0 > speakStart + 3.0 { db = 10 * log10(pow(10, db / 10) + pow(10, u / 10)) }
                d.pushVAD(isSpeech: true)                                // worst case: the VAD says "speech" for JARVIS' own voice as well
                if d.pushMic(db: db, duration: e.3, at: e.0) != nil { return (true, e.0 - speakStart, d.coupling) }
            }
            return (false, nil, d.coupling)
        }
        let echoOnly = replay(userDB: nil), withUser = replay(userDB: Float(echoDB) + 14)
        info("REAL acoustic loop: room floor \(fmt(quietDB, "%.1f")) dBFS · JARVIS' own voice at the microphone \(fmt(echoDB, "%.1f")) dBFS · reference level mean \(fmt(refDB.reduce(0, +) / Double(max(refDB.count, 1)), "%.1f")) dBFS · learned coupling \(fmt(Double(echoOnly.coupling), "%.1f")) dB")
        report("REAL acoustic loop: JARVIS' own voice through the real speaker into the real microphone never triggers a barge-in", !echoOnly.fired, "echo \(fmt(echoDB - quietDB, "%.1f")) dB above the room floor")
        report("REAL acoustic loop: a synthetic user 14 dB above the real echo, mixed into the real microphone frames, IS detected", withUser.fired, "decision \(withUser.at.map { String(format: "%.2f s", $0 - 3.0) } ?? "–") after the user began")
    }
}

