import Testing
import Foundation
@testable import Jarvis

// V0.15 — presentation only: response depth, shortening that never hides a failure, and the “efendim” address policy.

@Suite("Daily · response depth")
struct DailyDepthTests {
    func d(_ s: String) -> ResponseDepthDetector.Detection? { ResponseDepthDetector.detect(s) }

    @Test("Turkish and English requests for more are detected; a bare request refers to the previous answer")
    func expand() {
        #expect(d("Detaylı anlat.") == .init(depth: .detailed, bare: true))
        #expect(d("Ayrıntılı anlat") == .init(depth: .detailed, bare: true))
        #expect(d("explain in detail") == .init(depth: .detailed, bare: true))
        #expect(d("show details")?.depth == .detailed)
        #expect(d("Adım adım anlat")?.depth == .instructional)
        #expect(d("step by step please")?.depth == .instructional)
        #expect(d("Bana öğret")?.depth == .instructional)
        #expect(d("Rapor ver.") == .init(depth: .report, bare: true))
        #expect(d("give me a full report")?.depth == .report)
        #expect(d("Neden?")?.depth == .detailed)
        #expect(d("Why did it fail?")?.depth == .detailed)
    }

    @Test("requests for less")
    func shorten() {
        #expect(d("Kısa söyle.") == .init(depth: .terse, bare: true))
        #expect(d("kısaca")?.depth == .terse)
        #expect(d("be brief")?.depth == .terse)
        #expect(d("tl;dr")?.depth == .terse)
    }

    @Test("a depth word inside a real request is not bare, and ordinary requests have no depth")
    func notBare() {
        #expect(d("Hamam ne durumda, detaylı anlat")?.bare == false)
        #expect(d("Testler geçti mi?") == nil)
        #expect(d("Hamam ne durumda?") == nil)
        #expect(d("raporu aç") == nil)                       // that is a navigation command, not a request for a report
        #expect(d("open the settings") == nil)
    }
}

@Suite("Daily · shaping never hides a failure")
struct DailyShapeTests {
    let long = "Son doğrulamalar başarılı. Sıradaki iş müşteri davranışları. Ayrıca bütün sahneler kontrol edildi. Çok sayıda ek ayrıntı burada yer alıyor ve sayfalarca devam ediyor. " +
               "Bir test başarısız oldu: PlayerTests.jump. Bir ayrıntı daha ve bir tane daha, ve bir tane daha, ve bir tane daha, uzun bir cümle bu."

    @Test("a normal turn is shortened but keeps the failing sentence; the full text stays available")
    func keepsFailures() {
        let s = ReplyShaper.shape(full: long, depth: .normal, style: .concise, language: .tr)
        #expect(s.wasShortened && s.shown.count < s.full.count + 60)
        #expect(s.shown.contains("başarısız oldu: PlayerTests.jump"))
        #expect(s.shown.contains("detaylı anlat"))
        #expect(s.full.contains("Çok sayıda ek ayrıntı"))
    }

    @Test("detailed turns show everything; short answers are untouched")
    func expandsAndLeavesShort() {
        #expect(ReplyShaper.shape(full: long, depth: .detailed, style: .concise, language: .tr).shown == long.trimmingCharacters(in: .whitespaces))
        #expect(ReplyShaper.shape(full: long, depth: .report, style: .concise, language: .tr).wasShortened == false)
        let short = "Evet. Tüm testler geçti."
        #expect(ReplyShaper.shape(full: short, depth: .normal, style: .concise, language: .tr).shown == short)
    }

    @Test("a purpose-built short form still carries every critical sentence of the full text")
    func shortFormKeepsCritical() {
        let full = "Claude Code kurulu ve hazır. Codex kurulu ama giriş gerekiyor. OpenCode hazır. Ayrıntılı sürüm bilgisi: 1.2.3."
        let s = ReplyShaper.shape(full: full, short: "Claude hazır.", depth: .normal, style: .concise, language: .tr)
        #expect(s.shown.contains("giriş gerekiyor") || s.shown.contains("Codex"))
    }

    @Test("decimals and file names do not end a sentence")
    func pieces() {
        #expect(ReplyShaper.pieces("Sürüm 0.15 hazır. Tamam.").count == 2)
        #expect(ReplyShaper.pieces("scripts/verify.sh geçti. Bitti.").count == 2)
    }

    @Test("a negative state is never turned into a positive one by shortening")
    func negativeSurvives() {
        for text in ["Unity bağlantısı yok. Ayrıntı: Editor çalışmıyor. " + String(repeating: "Dolgu cümlesi. ", count: 30),
                     "Başlangıç. " + String(repeating: "Dolgu cümlesi. ", count: 30) + "Bu işlem reddedildi.",
                     "Önce iyi haber. " + String(repeating: "Dolgu cümlesi. ", count: 30) + "Mikrofon izni verilmedi."] {
            let s = ReplyShaper.shape(full: text, depth: .terse, style: .concise, language: .tr)
            #expect(s.shown.contains("yok") || s.shown.contains("reddedildi") || s.shown.contains("verilmedi"))
        }
    }
}

@Suite("Daily · address policy")
@MainActor
struct DailyAddressTests {
    @Test("“Başlıyorum.” becomes “Başlıyorum efendim.” and insertion is idempotent")
    func insertion() {
        #expect(AddressPolicy.insert(into: "Başlıyorum.") == "Başlıyorum efendim.")
        #expect(AddressPolicy.insert(into: "Başlıyorum efendim.") == "Başlıyorum efendim.")
        #expect(AddressPolicy.insert(into: "Testler tamamlandı. Her şey başarılı.") == "Testler tamamlandı efendim. Her şey başarılı.")
        #expect(AddressPolicy.insert(into: "Hazırım") == "Hazırım efendim")
    }

    @Test("not repeated within a short exchange; ordinary answers and English never carry it")
    func spacing() {
        let p = ResponsePresenter()
        _ = p.beginTurn("Hamam'a devam et")
        let first = p.addressed("Başlıyorum.", moment: .taskAccepted, language: .tr)
        #expect(first == "Başlıyorum efendim.")
        _ = p.beginTurn("Durum?")
        #expect(p.addressed("Testler tamamlandı.", moment: .taskCompleted, language: .tr) == "Testler tamamlandı.")
        #expect(p.addressed("Hazır.", moment: .answer, language: .tr) == "Hazır.")
        #expect(p.addressed("On it.", moment: .taskAccepted, language: .en) == "On it.")
        for _ in 0..<AddressPolicy.spacing { _ = p.beginTurn("devam") }
        #expect(p.addressed("Testler tamamlandı.", moment: .taskCompleted, language: .tr) == "Testler tamamlandı efendim.")
    }

    @Test("decisions and the wake word are always addressed; Minimal limits it to those; Off never uses it")
    func styles() {
        let p = ResponsePresenter()
        p.addressStyle = { .minimal }
        _ = p.beginTurn("x")
        #expect(p.addressed("Başlıyorum.", moment: .taskAccepted, language: .tr) == "Başlıyorum.")
        #expect(p.addressed("Bir karar gerekiyor.", moment: .decisionNeeded, language: .tr).contains("efendim"))
        #expect(p.addressed("Evet?", moment: .wake, language: .tr).contains("efendim") || p.addressed("Evet?", moment: .wake, language: .tr).contains("Efendim"))
        p.addressStyle = { .off }
        _ = p.beginTurn("y")
        #expect(!p.addressed("Bir karar gerekiyor.", moment: .decisionNeeded, language: .tr).contains("efendim"))
    }

    @Test("a detailed turn can be shortened again and a shortened one expanded")
    func rerender() {
        let p = ResponsePresenter()
        _ = p.beginTurn("Hamam ne durumda?")
        let full = String(repeating: "Uzun bir durum cümlesi. ", count: 40) + "Bir test başarısız oldu."
        let shown = p.present(full: full, language: .tr)
        #expect(shown.count < full.count)
        let more = p.rerender(depth: .detailed, language: .tr)
        #expect(more?.contains("Uzun bir durum cümlesi") == true && (more?.count ?? 0) > shown.count)
        let less = p.rerender(depth: .terse, language: .tr)
        #expect(less?.contains("başarısız oldu") == true)
    }

    @Test("task acceptance wording claims only that the task was created")
    func evidenceSafeAck() {
        for l in [ReplyLanguage.tr, .en] {
            for text in [DailyPhrasebook.taskAccepted(readOnly: false, l), DailyPhrasebook.taskAccepted(readOnly: true, l), DailyPhrasebook.orchestratedAccepted(l), DailyPhrasebook.researchAccepted(l)] {
                let f = text.lowercased()
                #expect(!f.contains("fixed") && !f.contains("düzelt") && !f.contains("tamamlandı") && !f.contains("done") && !f.contains("passed"))
            }
        }
    }
}
