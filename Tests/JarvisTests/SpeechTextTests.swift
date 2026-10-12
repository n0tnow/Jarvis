import Foundation
import Testing
@testable import Jarvis

// MARK: - Chunker

private func chunks(_ text: String, split: (String) -> [String] = { [$0] }) -> [SpeechPiece] {
    var c = SpeechChunker()
    var out: [SpeechPiece] = []
    for part in split(text) { out += c.push(part) }
    return out + c.finish()
}
private func texts(_ pieces: [SpeechPiece]) -> [String] { pieces.compactMap { if case .text(let t) = $0 { t } else { nil } } }
private func chars(_ s: String) -> [String] { s.map(String.init) }

@Suite("Speech chunker")
struct SpeechChunkerTests {
    @Test func splitsCompleteSentences() {
        #expect(texts(chunks("Unity is connected. The EditMode tests passed and nothing else changed! Do you want the report?")) ==
                ["Unity is connected.", "The EditMode tests passed and nothing else changed!", "Do you want the report?"])
    }

    @Test func aTerminatorAtTheEndOfTheBufferWaitsForMoreText() {
        var c = SpeechChunker()
        #expect(c.push("The value is 3.").isEmpty)                       // "3." might become "3.14": not stable yet
        #expect(texts(c.push("14 and that is final. Next")) == ["The value is 3.14 and that is final."])
    }

    @Test func decimalsVersionsAndFileNamesAreNotSentenceEnds() {
        #expect(texts(chunks("Version 0.7 is ready. Open Program.swift now.")) == ["Version 0.7 is ready.", "Open Program.swift now."])
    }

    @Test func englishAndTurkishAbbreviationsDoNotSplit() {
        #expect(texts(chunks("Use a shortcut, e.g. the right Option key, to talk. Dr. Smith agrees.")) == ["Use a shortcut, e.g. the right Option key, to talk.", "Dr. Smith agrees."])
        #expect(texts(chunks("Testler, vb. işlemler bitti. Örn. bu iyi bir sonuç.")) == ["Testler, vb. işlemler bitti.", "Örn. bu iyi bir sonuç."])
    }

    @Test func shortSentencesMergeExceptTheVeryFirst() {
        let out = texts(chunks("Yes. OK. Fine. The PlayMode tests also passed without any new console errors."))
        #expect(out.first == "Yes.")                                    // speech may start early with a short first phrase
        #expect(out.dropFirst().first == "OK. Fine. The PlayMode tests also passed without any new console errors.")
    }

    @Test func questionExclamationAndEllipsisRunsStayTogether() {
        #expect(texts(chunks("Really?! That is surprising... Anyway, it works.")) == ["Really?!", "That is surprising... Anyway, it works."])
    }

    @Test func aVeryLongSentenceIsSplitAtAClauseAndIsBounded() {
        let long = (0..<60).map { "word\($0)" }.joined(separator: " ") + ", and then some more words follow here " + (0..<40).map { "tail\($0)" }.joined(separator: " ") + "."
        let out = texts(chunks(long))
        #expect(out.count >= 2)
        #expect(out.allSatisfy { $0.count <= SpeechChunker().hardMaxCharacters })
        #expect(out.joined(separator: " ").replacingOccurrences(of: " ", with: "") == long.replacingOccurrences(of: " ", with: ""))      // nothing lost
    }

    @Test func textWithoutAnySpaceIsStillBounded() {
        let out = texts(chunks(String(repeating: "x", count: 1000)))
        #expect(out.count >= 3 && out.allSatisfy { $0.count <= 320 })
    }

    @Test func fencedCodeIsNeverSpokenAndSurfacesOnce() {
        let out = chunks("Here is the fix.\n```swift\nlet x = 1\nprint(x)\n```\nThat should compile now.")
        #expect(out.contains(.codeOmitted))
        #expect(!texts(out).joined().contains("print"))
        #expect(texts(out).contains("Here is the fix.") && texts(out).contains("That should compile now."))
        #expect(out.filter { $0 == .codeOmitted }.count == 1)
    }

    @Test func anUnterminatedFenceAtTheEndSpeaksNoCode() {
        let out = chunks("Look:\n```\nlet secret = 1\nmore code")
        #expect(!texts(out).joined().contains("secret"))
        #expect(out.contains(.codeOmitted))
    }

    @Test func tablesAreOmittedNotRead() {
        let out = chunks("Results:\n| a | b |\n|---|---|\n| 1 | 2 |\nAll done here, thanks.")
        #expect(out.contains(.tableOmitted) && !texts(out).joined().contains("|"))
        #expect(texts(out).last == "All done here, thanks.")
    }

    @Test func headingsAndListItemsAreSeparatePhrases() {
        let out = texts(chunks("## Summary\n- Compile passed\n- Tests passed\n1. Review the report\nDone."))
        #expect(out == ["Summary", "Compile passed", "Tests passed", "Review the report", "Done."])
    }

    @Test func inlineCodeIsNotSplit() {
        #expect(texts(chunks("Call `a.b.c()` now. Then wait for the answer to arrive.")) == ["Call `a.b.c()` now.", "Then wait for the answer to arrive."])
    }

    @Test func turkishTextAndPunctuationSurvive() {
        let out = texts(chunks("Unity testleri tamamlandı. Tüm EditMode ve PlayMode testleri geçti. İşte şöyle: çğıöşü."))
        #expect(out.joined(separator: " ").contains("tamamlandı") && out.joined().contains("çğıöşü") && out.contains { $0.contains("İşte") })
    }

    @Test func finishFlushesTheUnterminatedRemainder() {
        var c = SpeechChunker()
        #expect(c.push("The task is still running").isEmpty)
        #expect(texts(c.finish()) == ["The task is still running"])
    }

    @Test func emptyAndWhitespaceProduceNothing() {
        #expect(chunks("").isEmpty && chunks("   \n \n").isEmpty)
    }

    /// The property that matters for streaming: HOW the text is cut into deltas must never change what is spoken.
    @Test(arguments: [
        "Unity is connected. The EditMode tests passed.\n\nHere is the code:\n```swift\nlet a = 1.5\n```\nAfter that, e.g. Dr. Smith said 3.14 is fine. Done!",
        "## Report\n- Compile passed.\n- 12 tests passed (v0.7 build).\n\n| a | b |\n|--|--|\n| 1 | 2 |\nTamam. Testler geçti, şimdi ne yapalım? Hepsi hazır...",
        "A very short one.",
        "First paragraph line one\nline two continues. Second sentence here.\n\nNew paragraph starts. And ends",
    ])
    func chunkingIsIndependentOfTheDeltaBoundaries(sample: String) {
        let whole = chunks(sample)
        #expect(chunks(sample, split: chars) == whole)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<25 {
            let cut = chunks(sample) { s in
                var parts: [String] = [], rest = Substring(s)
                while !rest.isEmpty { let n = Int.random(in: 1...9, using: &rng); parts.append(String(rest.prefix(n))); rest = rest.dropFirst(n) }
                return parts
            }
            #expect(cut == whole)
        }
    }
}

// MARK: - Renderer

@Suite("Speech rendering")
struct SpeechRendererTests {
    private func en(_ s: String) -> String { SpeechRenderer.render(s, language: .english) }
    private func tr(_ s: String) -> String { SpeechRenderer.render(s, language: .turkish) }

    @Test func markdownSyntaxIsNotSpokenLiterally() {
        #expect(en("**Done** and *really* ~~not~~ _fine_.") == "Done and really not fine.")
        #expect(en("## Heading") == "Heading")
        #expect(en("- item one") == "item one")
        #expect(en("3. third item") == "third item")
        #expect(en("> quoted words") == "quoted words")
    }

    @Test func linksBecomeTheirTextAndBareUrlsBecomeTheHost() {
        #expect(en("See [the docs](https://example.com/very/long/path) now.") == "See the docs now.")
        #expect(en("Open https://www.github.com/n0tnow/Jarvis/pull/1 please") == "Open github.com please")
    }

    @Test func pathsKeepOnlyTheirLastComponent() {
        #expect(en("Edited /Users/me/Projects/Game/Assets/Player.cs today") == "Edited Player.cs today")
        #expect(en("and/or either/or") == "and/or either/or")
    }

    @Test func shortInlineCodeIsKeptLongCodeBecomesANote() {
        #expect(en("Add a `BoxCollider` to it") == "Add a BoxCollider to it")
        #expect(en("Run `for (int i = 0; i < n; i++) { total += values[i]; }` first") == "Run code first")
        #expect(tr("Şunu çalıştır `for (int i = 0; i < n; i++) { total += values[i]; }`") == "Şunu çalıştır kod")
    }

    @Test func symbolsAreNormalisedPerLanguage() {
        #expect(en("Coverage is 42% now") == "Coverage is 42 percent now")
        #expect(tr("Kapsam 42% oldu") == "Kapsam yüzde 42 oldu")
        #expect(en("Compile -> test → report").contains("to"))
        #expect(en("Fast & safe") == "Fast and safe")
        #expect(en("Use e.g. this").contains("for example"))
    }

    @Test func turkishLettersAreNeverFolded() {
        let s = "İstanbul'da çalışıyor; öğrenci ğ ş ı İ Ü Ç."
        #expect(tr(s).contains("İstanbul") && tr(s).contains("çalışıyor") && tr(s).contains("öğrenci") && tr(s).contains("ğ ş ı İ Ü Ç"))
    }

    @Test func emojiAndControlCharactersAreDropped() {
        #expect(en("All good ✅🎉 done\u{0007}\u{200B}.") == "All good done.")
    }

    @Test func tableRowsBecomeCellLists() {
        #expect(en("| Name | State |\n|---|---|\n| Unity | connected |") == "Name, State. Unity, connected")
    }

    @Test func renderingIsDeterministicAndNeverAddsContent() {
        let s = "**Unity** is connected; `EditMode` passed (100%)."
        #expect(en(s) == en(s))
        let out = en(s)
        for word in ["Unity", "connected", "EditMode", "passed", "100"] { #expect(out.contains(word)) }
    }
}

@Suite("Language guess and long answers")
struct SpeechLanguageTests {
    @Test func turkishLettersWin() { #expect(LanguageGuess.guess("Testler geçti") == .turkish) }
    @Test func englishFunctionWords() { #expect(LanguageGuess.guess("The tests have passed and nothing is wrong") == .english) }
    @Test func turkishFunctionWordsWithoutDiacritics() { #expect(LanguageGuess.guess("bu gorev icin ve bir test") == .turkish) }
    @Test func tiesUseTheFallback() {
        #expect(LanguageGuess.guess("Play Mode", fallback: .turkish) == .turkish)
        #expect(LanguageGuess.guess("Play Mode", fallback: .english) == .english)
        #expect(LanguageGuess.guess("BoxCollider", fallback: .auto) == .english)
    }

    @Test func policyAlwaysAllowsTheFirstChunkThenBoundsTheRest() {
        let p = LongAnswerPolicy()
        #expect(!p.wouldExceed(spokenCharacters: 0, spokenChunks: 0, next: 5000))
        #expect(p.wouldExceed(spokenCharacters: 500, spokenChunks: 3, next: 100))
        #expect(p.wouldExceed(spokenCharacters: 50, spokenChunks: p.maxSpokenChunks, next: 10))
        #expect(!p.wouldExceed(spokenCharacters: 100, spokenChunks: 2, next: 100))
    }

    @Test func notesExistInBothLanguages() {
        #expect(LongAnswerPolicy.screenNote(.turkish).contains("ekranda") && LongAnswerPolicy.screenNote(.english).contains("screen"))
        #expect(LongAnswerPolicy.codeNote(.turkish).contains("Kod") && LongAnswerPolicy.tableNote(.english).contains("table"))
    }
}
