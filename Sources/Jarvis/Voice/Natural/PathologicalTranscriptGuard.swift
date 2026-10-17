import Foundation

// MARK: - Pathological transcript guard (V1.0 decision milestone)
//
// A speech recogniser can fall into a decoder loop and emit "Kutu, Kutu, Kutu, Kutu, …" or "Yerler, Yerler, Yerler, …" for what was noise, a cough or JARVIS' own voice. Such output is not something a
// person said, and no language model can make it one: a smarter model would only invent a request out of it. So it is rejected UPSTREAM — here, on the final transcript, before the conversation, the
// decision layer, any model (local or remote), the task engine or Project Memory can see it — and the capture recovers for the next utterance.
//
// Deliberately NOT a blacklist of the two observed words and NOT a rule against repetition as such: people say "hayır hayır hayır", "dur dur dur" and "çok çok önemli". The signals are structural —
// a dominant token over a long utterance, a long run of one token, a periodic n-gram loop, a looping tail after a normal start, a vocabulary far too small for the length, an impossible speaking rate —
// each with bounded thresholds. On rejection only a reason code and counts are kept (never the text, never audio).

enum TranscriptRejection: String, Codable, Sendable, CaseIterable {
    /// One token dominates a long utterance (or the same token runs on and on).
    case excessiveTokenRepetition
    /// A short phrase (2–6 words) repeats back to back many times.
    case repeatedNGramLoop
    /// A normal start followed by a looping tail, a vocabulary far too small for the length, or a runaway length.
    case decoderLoopSuspected
    /// More words than anyone speaks in the audio that was captured.
    case implausibleSpeechRate
}

/// Content-free measurements behind a verdict (safe for diagnostics and audit).
struct TranscriptMetrics: Equatable, Sendable {
    var tokens: Int
    var distinct: Int
    /// Share of the most frequent token, 0…1.
    var topShare: Double
    var longestRun: Int
    /// Period (in words) of a detected back-to-back loop, 0 = none.
    var loopPeriod: Int
    var loopRepeats: Int
    /// Share of the transcript covered by a looping tail, 0…1.
    var tailShare: Double
    var summary: String {
        "tokens=\(tokens) distinct=\(distinct) top=\(Int(topShare * 100))% run=\(longestRun) loop=\(loopPeriod)x\(loopRepeats) tail=\(Int(tailShare * 100))%"
    }
}

enum TranscriptVerdict: Equatable, Sendable {
    case accept
    case reject(TranscriptRejection, TranscriptMetrics)
    var isAccepted: Bool { if case .accept = self { return true }; return false }
}

enum PathologicalTranscriptGuard {
    /// Bounded thresholds (documented in docs/VOICE_IO.md; each has a "legitimate repetition" test next to it).
    struct Config: Equatable, Sendable {
        /// A single token over at least this share of an utterance of at least `dominantMinTokens` words.
        var dominantShare = 0.6
        var dominantMinTokens = 8
        /// The same token this many times in a row (and at least half of the utterance).
        var runLimit = 7
        /// A 2…6-word phrase repeated back to back this many times, covering at least `loopCoverage` of the utterance, in at least `loopMinTokens` words.
        var loopRepeatLimit = 4
        var loopCoverage = 0.6
        var loopMinTokens = 8
        /// A looping tail (same token ≥ `tailRun` times or a phrase ≥ `tailRepeats` times at the end) that is at least this share of the utterance.
        var tailRun = 6
        var tailRepeats = 4
        var tailShare = 0.5
        /// Vocabulary: this many words, no more than this share distinct.
        var diversityMinTokens = 14
        var diversityMaxShare = 0.2
        /// Runaway length (words) and speaking rate (words per second of captured audio; people speak ≤ ~5, fast speech ~6).
        var maxTokens = 150
        var maxWordsPerSecond = 9.0
        var rateMinTokens = 20
    }

    static func evaluate(_ text: String, audioSeconds: Double? = nil, config c: Config = Config()) -> TranscriptVerdict {
        let tokens = words(text)
        let n = tokens.count
        guard n >= 2 else { return .accept }
        var counts: [String: Int] = [:]
        for t in tokens { counts[t, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        let topShare = Double(top) / Double(n)
        let run = longestRun(tokens)
        let loop = bestLoop(tokens, c)
        let tail = tailLoopShare(tokens, c)
        let m = TranscriptMetrics(tokens: n, distinct: counts.count, topShare: topShare, longestRun: run.length, loopPeriod: loop.period, loopRepeats: loop.repeats, tailShare: tail)

        if n > c.maxTokens { return .reject(.decoderLoopSuspected, m) }
        if let s = audioSeconds, s > 0.5, n >= c.rateMinTokens, Double(n) / s > c.maxWordsPerSecond { return .reject(.implausibleSpeechRate, m) }
        if n >= c.dominantMinTokens, topShare >= c.dominantShare { return .reject(.excessiveTokenRepetition, m) }
        if run.length >= c.runLimit, Double(run.length) / Double(n) >= 0.5 { return .reject(.excessiveTokenRepetition, m) }
        if loop.period >= 2, loop.repeats >= c.loopRepeatLimit, n >= c.loopMinTokens, Double(loop.period * loop.repeats) / Double(n) >= c.loopCoverage { return .reject(.repeatedNGramLoop, m) }
        if tail >= c.tailShare, n >= c.loopMinTokens { return .reject(.decoderLoopSuspected, m) }
        if n >= c.diversityMinTokens, Double(counts.count) / Double(n) <= c.diversityMaxShare { return .reject(.decoderLoopSuspected, m) }
        return .accept
    }

    // MARK: Measurements

    /// Folded word tokens (letters and digits; Turkish letters folded so "Kutu," / "kutu" / "KUTU" are one token).
    static func words(_ text: String) -> [String] {
        let f = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
        return f.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    private static func longestRun(_ t: [String]) -> (length: Int, token: String?) {
        var best = (length: 0, token: String?.none), cur = 0
        for i in t.indices {
            cur = (i > 0 && t[i] == t[i - 1]) ? cur + 1 : 1
            if cur > best.length { best = (cur, t[i]) }
        }
        return best
    }

    /// The (period, repeats) of the periodic n-gram loop with the largest coverage anywhere in the utterance (period 2…6; a period-1 loop is the token run above).
    private static func bestLoop(_ t: [String], _ c: Config) -> (period: Int, repeats: Int) {
        var best = (period: 0, repeats: 0), bestCover = 0
        for p in 2...6 where t.count >= p * 2 {
            var i = 0
            while i + p * 2 <= t.count {
                var reps = 1
                while i + (reps + 1) * p <= t.count, Array(t[(i + reps * p)..<(i + (reps + 1) * p)]) == Array(t[i..<(i + p)]) { reps += 1 }
                if reps >= 2, reps * p > bestCover { bestCover = reps * p; best = (p, reps) }
                i += reps >= 2 ? reps * p : 1
            }
        }
        return best
    }

    /// Share of the utterance covered by a looping TAIL: the last token repeated, or the last k-gram repeated, at the very end.
    private static func tailLoopShare(_ t: [String], _ c: Config) -> Double {
        guard let last = t.last else { return 0 }
        var share = 0.0
        var runLen = 0
        for w in t.reversed() { if w == last { runLen += 1 } else { break } }
        if runLen >= c.tailRun { share = Double(runLen) / Double(t.count) }
        for p in 2...6 where t.count >= p * c.tailRepeats {
            let unit = Array(t[(t.count - p)...])
            var reps = 1
            while t.count - (reps + 1) * p >= 0, Array(t[(t.count - (reps + 1) * p)..<(t.count - reps * p)]) == unit { reps += 1 }
            if reps >= c.tailRepeats { share = max(share, Double(reps * p) / Double(t.count)) }
        }
        return share
    }
}

// MARK: - Where did this utterance come from? (instrumentation for the real Mac — metadata only)

/// The three things a bad or unexpected transcript can be, kept apart so Phase B can tell them apart from counters alone (no audio, no text is kept):
///   A. the microphone captured JARVIS' own speech (`selfEcho`)           — SelfSpeechFilter / PhantomGuard / the barge-in envelope check
///   B. the recogniser emitted a decoder loop or hallucination (`decoderHallucination`) — this guard
///   C. a person really talking, possibly over JARVIS (`userInterruption` / `userTurn`)
enum UtteranceOrigin: String, Codable, Sendable, CaseIterable {
    case selfEcho, decoderHallucination, userInterruption, userTurn
}

extension VoiceDiagnostics {
    /// Records the classification of one utterance as a counter and a bounded detail line (reason code and measurements only).
    func noteOrigin(_ origin: UtteranceOrigin, _ detail: String = "", at t: TimeInterval) {
        note("origin.\(origin.rawValue)", detail, at: t)
    }
}
