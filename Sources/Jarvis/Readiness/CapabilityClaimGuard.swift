import Foundation

/// Provider identity firewall, output side (V1.0 stabilisation fix 2).
///
/// A capability, settings or storage question is answered by JARVIS from its own state (`ReadinessAssistant`, `StorageTruth`) and never reaches a language model. The engine can still volunteer
/// a claim about JARVIS in an ordinary answer — “I can’t see your screen”, “I have no memory”, “I can delete any file”. Those sentences describe the ENGINE’s sandbox, not JARVIS, and are
/// either false or dangerous, so a finished reply that contains one is replaced by JARVIS’ own statement of what it can do. Nothing here grants or removes a capability: it only refuses to show a claim.
enum CapabilityClaimGuard {
    enum Kind: Equatable, Sendable { case deniesAbility, overclaims }
    struct Finding: Equatable, Sendable { var kind: Kind; var sentence: String }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
    }

    private static let negators = ["i can't", "i cant", "i cannot", "i can not", "i am unable", "i'm unable", "i am not able", "i'm not able", "i don't have", "i do not have", "i have no ", "i lack",
                                   "unable to", "no ability", "not able to", "doesn't have the ability",
                                   "goremiyorum", "gorem", "okuyamam", "okuyamiyorum", "erisemem", "erisemiyorum", "erisimim yok", "ozelligim yok", "yetenegim yok", "saklayamam", "saklayamiyorum",
                                   "hatirlayamam", "hatirlayamiyorum", "kaydedemem", "kaydedemiyorum", "yapamam", "yapamiyorum", "imkanim yok", "hafizam yok", "bellegim yok"]
    private static let topics = ["your screen", "the screen", "see your", "see the screen", "your files", "read files", "access files", "access to files", "file system", "files on your", "your computer",
                                 "my memory", "any memory", "remember", "persist", "store information", "save information", "long-term memory", "across conversations", "between conversations",
                                 "ekran", "dosya", "hafiza", "bellek", "hatirla", "kalici", "bilgisayar"]
    private static let overclaims = ["i can delete any", "i can delete all", "i can delete your", "i can delete files", "i have full access to your", "i have full control of your", "i can control your entire",
                                     "i can access any file", "i can read any file", "i can run any command", "i can execute any command", "i can install anything", "i can see everything on your",
                                     "herhangi bir dosyayi silebilirim", "tum dosyalarinizi silebilirim", "tum dosyalariniza erisebilirim", "her dosyaya erisebilirim", "bilgisayarinizi tamamen kontrol",
                                     "her komutu calistirabilirim", "tum bilgisayarinizi kontrol", "ekraninizdaki her seyi gorebilirim"]

    /// Sentences that claim what the product can or cannot do about the screen, files, memory or the computer.
    static func findings(in reply: String) -> [Finding] {
        let sentences = reply.split(whereSeparator: { ".!?\n;".contains($0) }).map(String.init)
        var out: [Finding] = []
        for s in sentences {
            let f = fold(s)
            if overclaims.contains(where: { f.contains($0) }) { out.append(Finding(kind: .overclaims, sentence: s.trimmingCharacters(in: .whitespaces))); continue }
            if negators.contains(where: { f.contains($0) }), topics.contains(where: { f.contains($0) }) { out.append(Finding(kind: .deniesAbility, sentence: s.trimmingCharacters(in: .whitespaces))) }
        }
        return out
    }

    /// The text shown instead: a one-line notice plus JARVIS' own, state-based statement.
    static func replacement(for findings: [Finding], grounded: String, language l: ReplyLanguage) -> String {
        let overclaim = findings.contains { $0.kind == .overclaims }
        let note = l == .tr
            ? (overclaim ? "Dil modelinin söylediği, JARVIS'in gerçek yetkileriyle uyuşmuyordu (fazla geniş bir iddia); o cümleyi göstermiyorum." : "Dil modelinin JARVIS'in yetenekleri hakkında söylediği şey doğru değildi; onu göstermiyorum.")
            : (overclaim ? "The language model claimed more than JARVIS is allowed to do, so I am not showing that sentence." : "The language model said something about what JARVIS can do that was not true, so I am not showing it.")
        return note + " " + grounded
    }
}

/// The ActionReceipt invariant, enforced on the model side too (V1.0 stabilisation fix 4).
///
/// The conversation engine is text-in/text-out: it has NO execution path, so it never performed anything. A first-person claim of action in its text — “Safari'yi açıyorum”, “videoyu başlatıyorum”,
/// “I've opened it”, “I'm playing it now” — can therefore never be backed by an `ActionReceipt`. Such sentences are removed from what the user sees and hears, and a short, true notice takes their place.
/// Detection is structural (action-verb stem + first-person ending, in Turkish and English), not a list of phrases; real actions go through `ActionService` and are worded from their receipt.
enum ActionClaimGuard {
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased().replacingOccurrences(of: "ı", with: "i")
    }

    /// Folded stems of verbs that CHANGE something (open, start, play, stop, save, delete, move, create, finish, click, send, install …).
    private static let stems = ["ac", "baslat", "oynat", "durdur", "degistir", "kaydet", "sil", "tasi", "olustur", "tamamla", "calistir", "kapat", "gonder", "indir", "kur", "yukle", "ekle", "duzelt", "guncelle",
                                "ilerlet", "devam ed", "tikla", "yaz", "yap", "uygula", "cevir", "bagla", "kopyala", "yapistir"]
    private static let firstPerson = ["iyorum", "uyorum", "yorum", "dim", "tim", "dum", "tum", "mistim", "eyim"]
    private static let english = try! NSRegularExpression(pattern: #"\bi(?:'m| am|'ve| have| just| now| will now|'ll now)?\s+(?:now\s+|just\s+|already\s+)?(opening|opened|launching|launched|starting|started|playing|played|pausing|paused|stopping|stopped|saving|saved|deleting|deleted|moving|moved|creating|created|completing|completed|clicking|clicked|typing|typed|running|ran|installing|installed|sending|sent|closing|closed|changing|changed|resuming|resumed|writing|wrote|updated|updating)\b"#, options: [.caseInsensitive])

    /// The sentences of `reply` that claim the engine performed (or is performing) an action.
    static func claims(in reply: String) -> [String] {
        let sentences = reply.split(whereSeparator: { ".!?\n;".contains($0) }).map(String.init)
        return sentences.filter { sentence in
            let f = fold(sentence)
            if english.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) != nil { return true }
            let words = f.split(whereSeparator: { !$0.isLetter }).map(String.init)
            return words.contains { w in stems.contains { stem in w.hasPrefix(stem.replacingOccurrences(of: " ", with: "")) && w.count > stem.count + 2 } && firstPerson.contains { w.hasSuffix($0) } }
                || f.contains("devam ediyorum") || f.contains("devam ettiriyorum")
        }
    }

    /// `reply` without the claim sentences, plus a true notice. Nothing was done: say so.
    static func replacement(for reply: String, claims: [String], language l: ReplyLanguage) -> String {
        var kept = reply
        for c in claims { kept = kept.replacingOccurrences(of: c, with: "") }
        let rest = kept.split(whereSeparator: { ".!?;".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 3 }.joined(separator: ". ")
        let notice = l == .tr
            ? "Bunu yapmadım: bu cevap bir dil modelinden geldi ve hiçbir eylem gerçekleştirilmedi. Bir şey yapmamı istiyorsanız doğrudan söyleyin (örneğin “Safari'yi aç”); yaptığımda yalnızca doğrulayabildiğimi söylerim."
            : "I did not do that: this answer came from a language model and nothing was executed. If you want something done, ask directly (for example “open Safari”); when I do it, I only say what I could verify."
        return rest.isEmpty ? notice : rest + ". " + notice
    }
}
