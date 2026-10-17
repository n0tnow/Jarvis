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
