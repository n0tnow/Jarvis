import Foundation

/// A human answer to a direct memory question, composed ONLY from retrieved records (no model, no invention). Provenance goes on a final "Sources:" line, which the speech
/// renderer drops: citations are shown, never read aloud.
struct MemoryAnswer: Sendable {
    var text: String
    var citations: [String]
    var usedIDs: [UUID]
    var found: Bool
    var milliseconds: Double
}

enum MemoryAnswerer {
    private static func tr(_ l: ReplyLanguage, _ en: String, _ trk: String) -> String { l == .tr ? trk : en }

    /// "DEC-092 — Title: body" → "body" (the id/title are shown as the source, not repeated in the sentence).
    private static func body(_ m: MemoryItem) -> String {
        var s = m.summary
        if let r = s.range(of: "^(DEC|JARVIS)-[A-Z0-9-]+ — [^:]{0,120}: ", options: .regularExpression) { s = String(s[r.upperBound...]) }
        return s.trimmingCharacters(in: .whitespaces)
    }
    private static func label(_ m: MemoryItem) -> String? {
        guard let s = m.sources.first else { return nil }
        return s.label.isEmpty ? s.ref : s.label + (s.locator.map { " · " + $0 } ?? "")
    }
    private static func rationale(_ m: MemoryItem) -> String? {
        guard let d = m.details else { return nil }
        for key in ["Why: ", "Reason: ", "Consequences: "] { if let r = d.range(of: key) { let rest = String(d[r.upperBound...]); return MemoryText.clip(rest.components(separatedBy: " Reason: ").first ?? rest, 260) } }
        return nil
    }
    /// The sentence of the record that carries the question's subject words (a long decision is quoted where it actually answers), else its summary.
    static func excerpt(_ m: MemoryItem, topicWords: [String]) -> String {
        let terms = topicWords.map(MemoryText.stem)
        guard !terms.isEmpty else { return body(m) }
        var pool = [body(m)]
        if let d = m.details { pool.append(d.replacingOccurrences(of: "Decision: ", with: "")) }
        let sentences = pool.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ".;")).map { $0.trimmingCharacters(in: .whitespaces) } }.filter { $0.count > 12 }
        let scored = sentences.map { s -> (String, Int) in let t = Set(MemoryText.tokens(s)); return (s, terms.filter { t.contains($0) }.count) }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return body(m)
    }

    private static func line(_ r: RankedMemory, withWhy: Bool, topicWords: [String] = []) -> String {
        let m = r.item
        let main = body(m)
        var t = "• " + MemoryText.clip(main, 200)
        // a long record is also quoted where it mentions the question's subject
        if !topicWords.isEmpty { let e = excerpt(m, topicWords: topicWords); if !main.contains(e) { t += " … " + MemoryText.clip(e, 220) } }
        if withWhy, let why = rationale(m) { t += " — " + MemoryText.clip(why, 200) }
        if let c = r.caveat { t += " (\(c))" }
        return t
    }

    static func compose(question q: MemoryQuestion, result: RetrievalResult, language l: ReplyLanguage, projectName: String?, truth: [TruthLine] = []) -> MemoryAnswer {
        let ranked = result.ranked
        let topic = q.topic.isEmpty ? tr(l, "that", "bu konu") : q.topic
        let onlyGood = ranked.filter { $0.item.status != .unverified }
        func finish(_ text: String, _ used: [RankedMemory], found: Bool) -> MemoryAnswer {
            var cites: [String] = []
            for r in used { if let c = label(r.item), !cites.contains(c) { cites.append(c) } }
            var out = text
            if !cites.isEmpty { out += "\n" + tr(l, "Sources: ", "Kaynaklar: ") + cites.prefix(5).joined(separator: "; ") }
            return MemoryAnswer(text: out, citations: cites, usedIDs: used.map(\.item.id), found: found, milliseconds: result.milliseconds)
        }
        guard !onlyGood.isEmpty, result.answerable else {
            let unverified = ranked.first
            if let u = unverified, u.item.status == .unverified, !result.lowConfidence {
                return finish(tr(l, "I only have an unconfirmed note about \(topic): “\(MemoryText.clip(body(u.item), 200))”. It is a guess, not a verified record.", "\(topic) hakkında yalnızca doğrulanmamış bir notum var: “\(MemoryText.clip(body(u.item), 200))”. Bu bir tahmin, doğrulanmış kayıt değil."), [u], found: true)
            }
            return MemoryAnswer(text: tr(l, "I have nothing recorded about \(topic) in this project's memory. I won't guess.", "Bu projenin hafızasında \(topic) ile ilgili bir kayıt yok. Tahmin yürütmeyeceğim."), citations: [], usedIDs: [], found: false, milliseconds: result.milliseconds)
        }
        let top = Array(onlyGood.prefix(q.kind == .constraints || q.kind == .known || q.kind == .assets ? 6 : 3))
        var intro: String
        var withWhy = true
        switch q.kind {
        case .decision, .general:
            intro = tr(l, "Here is what the records say about \(topic):", "\(topic) hakkında kayıtlar şunu söylüyor:")
        case .why:
            let hasReason = top.contains { rationale($0.item) != nil }
            intro = hasReason ? tr(l, "This is the recorded reasoning:", "Kayıtlı gerekçe şu:") : tr(l, "The records show what was decided, but not a verified reason:", "Kayıtlar neyin kararlaştırıldığını gösteriyor, ancak doğrulanmış bir gerekçe yok:")
            if !hasReason { withWhy = false }
        case .tried, .failure:
            intro = q.kind == .tried ? tr(l, "This is what the records show was tried or went wrong:", "Kayıtlara göre denenen ya da ters giden şeyler:") : tr(l, "These failures are on record:", "Kayıtlı başarısızlıklar:")
            withWhy = false
        case .constraints: intro = tr(l, "These constraints are on record for this project:", "Bu proje için kayıtlı kısıtlar:"); withWhy = false
        case .assets: intro = tr(l, "These asset decisions are on record:", "Kayıtlı varlık kararları:"); withWhy = false
        case .issues: intro = tr(l, "These issues are on record:", "Kayıtlı sorunlar:"); withWhy = false
        case .changed: intro = tr(l, "These changes were recorded (for exact code changes use Git or the task history):", "Kaydedilen değişiklikler (kesin kod değişiklikleri için Git veya görev geçmişine bakın):"); withWhy = false
        case .current: intro = tr(l, "As far as the records go, currently:", "Kayıtlara göre şu anda:")
        case .known: intro = tr(l, "Here is what I know about \(topic):", "\(topic) hakkında bildiklerim:"); withWhy = false
        }
        var parts = [intro]
        if q.kind == .current, !truth.isEmpty { parts.append(truth.prefix(4).map { "• \($0.label): \($0.value) (" + tr(l, "read from the project now", "projeden şimdi okundu") + ")" }.joined(separator: "\n")) }
        parts.append(contentsOf: top.map { line($0, withWhy: withWhy, topicWords: result.topicWords) })
        let historicalNote = top.contains { $0.item.status == .superseded }
        if historicalNote { parts.append(tr(l, "Note: at least one of these records is superseded by newer information.", "Not: bu kayıtlardan en az biri daha yeni bilgiyle değiştirilmiş.")) }
        if top.contains(where: { $0.item.status == .disputed }) { parts.append(tr(l, "Note: some records conflict with each other; I am not choosing between them.", "Not: bazı kayıtlar birbiriyle çelişiyor; aralarında seçim yapmıyorum.")) }
        return finish(parts.joined(separator: "\n"), top, found: true)
    }
}
