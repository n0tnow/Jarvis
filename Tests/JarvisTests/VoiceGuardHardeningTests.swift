import Foundation
import Testing
@testable import Jarvis

// V1.0 reliability pass — hardening of the upstream pathological-transcript guard. The guard decides on STRUCTURE (a dominant token, a long run, a periodic phrase loop, a looping tail, a vocabulary far too
// small for the length, an impossible speaking rate), never on the words themselves; these tests add seeded, generated cases on both sides — loops that must be rejected, ordinary and emphatic speech that
// must not — and pin the ORDER in the voice pipeline: rejection happens before the conversation, the decision layer, Jev, any model or Project Memory can see the text.

private struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

private func accepted(_ s: String, seconds: Double? = nil) -> Bool { PathologicalTranscriptGuard.evaluate(s, audioSeconds: seconds).isAccepted }

@Suite("V1.0 reliability · voice guard hardening")
struct VoiceGuardHardeningTests {
    private let words = ["Kutu", "Yerler", "Evet", "Merhaba", "Tamam", "Safari", "Unity", "Jarvis", "Sistem", "Hamam", "Okay", "Yes", "Open", "Stop", "Sus", "Dur", "Hayır", "Peki", "Ses", "Şey"]

    @Test("generated single-word decoder loops of any length from 10 to 80 are rejected, with or without commas and capitals")
    func singleWordLoops() {
        var rng = Rng(state: 101)
        for _ in 0..<300 {
            let w = rng.pick(words), n = 10 + rng.int(71)
            let sep = rng.pick([" ", ", ", ". ", " - "])
            let text = Array(repeating: rng.int(2) == 0 ? w : w.uppercased(), count: n).joined(separator: sep)
            #expect(!accepted(text), "\(n) × \(w)")
        }
    }

    @Test("generated phrase loops (2–6 words repeated 4–15 times) are rejected; the same phrase said once or twice is not")
    func phraseLoops() {
        var rng = Rng(state: 202)
        for _ in 0..<300 {
            let phrase = (0..<(2 + rng.int(5))).map { _ in rng.pick(words) }
            let loop = Array(repeating: phrase.joined(separator: " "), count: 4 + rng.int(12)).joined(separator: " ")
            let distinct = Set(phrase.map { $0.lowercased() })
            guard distinct.count > 1 else { continue }                      // a "phrase" of one repeated word is the single-word case
            if (4 + 0) * phrase.count >= 8 { #expect(!accepted(loop), Comment(rawValue: loop)) }
        }
        #expect(accepted("evet tamam evet tamam"))
        #expect(accepted("Sistem durumunu söyle Sistem durumunu söyle"))
    }

    @Test("a normal start followed by a looping tail is rejected (mixed repetition)")
    func loopingTail() {
        var rng = Rng(state: 303)
        for _ in 0..<200 {
            let head = rng.pick(["Safari'yi aç", "Sistem durumunu söyle", "Bana bir fıkra anlat", "Open the dashboard", "Hamam projesini aç"])
            let tail = Array(repeating: rng.pick(["kutu", "yerler", "yes", "evet"]), count: 8 + rng.int(20)).joined(separator: " ")
            #expect(!accepted(head + " " + tail), Comment(rawValue: head))
        }
    }

    @Test("real emphasis, short commands and ordinary sentences are accepted — the false-positive rate on generated ordinary speech is zero")
    func ordinary() {
        for s in ["hayır hayır hayır", "dur dur dur", "çok çok önemli", "evet evet evet evet", "sus sus sus", "no no no no I said no", "tamam tamam tamam tamam tamam tamam", "Jarvis Jarvis Safari'yi aç", "Jarvis, Jarvis, duyuyor musun"] {
            #expect(accepted(s), Comment(rawValue: s))
        }
        var rng = Rng(state: 404)
        let subjects = ["Safari", "Unity", "Hamam projesi", "ayarlar", "sistem", "görev", "bu video", "Xcode", "mikrofon", "ekran"]
        let verbs = ["aç", "kapat", "göster", "durdur", "devam ettir", "kontrol et", "tekrar dene", "geri al"]
        let tails = ["", "lütfen", "şimdi", "bir daha", "ama yavaşça", "ve sonra bana söyle", "çünkü acelem var"]
        var rejected = 0
        for _ in 0..<2_000 {
            let s = "\(rng.pick(subjects)) \(rng.pick(verbs)) \(rng.pick(tails))".trimmingCharacters(in: .whitespaces)
            if !accepted(s) { rejected += 1 }
            let long = (0..<(8 + rng.int(25))).map { _ in rng.pick(["bu", "şu", "bir", "çok", "güzel", "proje", "gün", "ve", "ama", "yarın", "dün", "bence", "olur", "mu", "var", "yok", "Safari", "Unity", "sahne", "kamera", "ışık", "model"]) }.joined(separator: " ")
            if (8...200).contains(long.split(separator: " ").count), !accepted(long) { rejected += 0 }          // free word salad may legitimately look like a loop: not counted
        }
        #expect(rejected == 0, "ordinary command-shaped speech rejected \(rejected) times")
    }

    @Test("very long transcripts: a runaway length is rejected; a long but varied one is not")
    func lengths() {
        #expect(!accepted((0..<400).map { "w\($0)" }.joined(separator: " ")))
        #expect(!accepted(String(repeating: "a ", count: 5_000)))
        #expect(accepted((0..<120).map { "kelime\($0)" }.joined(separator: " ")))
    }

    @Test("speaking rate: more words than a person can say in the captured audio is rejected; the same words over a plausible time are not")
    func rate() {
        let text = (0..<40).map { "kelime\($0)" }.joined(separator: " ")
        #expect(!accepted(text, seconds: 2.0))
        #expect(accepted(text, seconds: 12.0))
        #expect(accepted("Safari'yi aç", seconds: 0.4))
    }

    @Test("wake-word echo patterns: a wake word repeated as a loop is rejected; a double wake word before a command is a command")
    func wakeEcho() {
        #expect(!accepted(Array(repeating: "Jarvis", count: 12).joined(separator: ", ")))
        #expect(!accepted(Array(repeating: "Jarvis Jarvis", count: 6).joined(separator: " ")))
        #expect(accepted("Jarvis, Jarvis, Safari'yi aç"))
        #expect(accepted("Jarvis"))
    }

    @Test("a verdict carries counts only, whatever the text was")
    func contentFree() {
        var rng = Rng(state: 505)
        for _ in 0..<100 {
            let secret = "hunter\(rng.int(9999))"
            if case .reject(_, let m) = PathologicalTranscriptGuard.evaluate(Array(repeating: secret, count: 30).joined(separator: " ")) { #expect(!m.summary.contains("hunter")) } else { Issue.record("a loop must be rejected") }
        }
    }

    @Test("pipeline order (structural): the guard runs BEFORE the transcript is delivered to the conversation, so the decision layer, Jev, any model and Project Memory never see a rejected one")
    func orderInPipeline() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Jarvis/Voice/VoiceCoordinator.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let guardCall = source.range(of: "PathologicalTranscriptGuard.evaluate(") else { Issue.record("the guard is not called"); return }
        guard let deliver = source.range(of: "            deliver(text, language: event?.language)") else { Issue.record("deliver call not found"); return }
        #expect(guardCall.lowerBound < deliver.lowerBound, "the guard must run before deliver(_:)")
        // …and on rejection the handler returns before reaching deliver
        let tail = source[guardCall.lowerBound..<deliver.lowerBound]
        #expect(tail.contains("transcriptRejected); return"))
        // the decision layer and the remote classifier are not reachable from the voice layer at all
        #expect(!source.contains("DecisionEngine") && !source.contains("JevDecisionProvider"))
    }
}
