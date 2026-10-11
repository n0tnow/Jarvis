import Testing
import Foundation
@testable import Jarvis

/// ALL secrets in these tests are synthetic fixtures — never a real credential.
enum FakeSecrets {
    static let skKey = "sk-test-FAKE0123456789abcdefghijklmnopqrstuvwx"
    static let bearer = "FAKEbearerTOKEN0123456789abcdef"
    static let ghToken = "ghp_FAKE0123456789abcdefghijklmnopqrstu"
    static let awsKey = "AKIAFAKE0123456789AB"
    static let password = "Hunter2-FAKE-passw0rd"
    static let jwt = "eyJFAKEheader123.eyJFAKEpayload456.FAKEsignature789"
    static let pem = "-----BEGIN PRIVATE KEY-----\nFAKEKEYMATERIALAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nBBBBBBBBBBBBBBBBBBBB\n-----END PRIVATE KEY-----"
    static let all = [skKey, bearer, ghToken, awsKey, password, jwt, "FAKEKEYMATERIALAAAA"]
    static func leaks(_ text: String) -> [String] { all.filter { text.contains($0) } }
}

@Suite("Output sanitizer (central security boundary)", .serialized)
struct OutputSanitizerTests {
    @Test func providerStyleSecretsAreMasked() {
        let samples = [
            "key is \(FakeSecrets.skKey) ok", "Authorization: Bearer \(FakeSecrets.bearer)", "Bearer \(FakeSecrets.bearer)",
            "token \(FakeSecrets.ghToken)", FakeSecrets.awsKey, "jwt=\(FakeSecrets.jwt)", "password = \(FakeSecrets.password)",
            "MY_API_KEY=\(FakeSecrets.skKey)", "export SECRET_TOKEN: \(FakeSecrets.bearer)", FakeSecrets.pem,
            "https://user:\(FakeSecrets.password)@example.com/x", "GET /x?api_key=\(FakeSecrets.skKey)&a=1",
            "Cookie: session=\(FakeSecrets.bearer); other=1", "Set-Cookie: sid=\(FakeSecrets.bearer)",
        ]
        for s in samples {
            let out = OutputSanitizer.sanitize(s)
            #expect(FakeSecrets.leaks(out).isEmpty, "leak in: \(s) → \(out)")
            #expect(out.contains(OutputSanitizer.mask), "not masked: \(s)")
            #expect(OutputSanitizer.containsSecret(s))
        }
        #expect(OutputSanitizer.sanitize("https://user:\(FakeSecrets.password)@example.com/x").contains("example.com"))   // host stays readable
    }

    @Test func credentialFieldsInPlainTextJSONAreMaskedByTheTextEngineToo() {
        for t in ["{\"password\": \"\(FakeSecrets.password)\", \"note\": \"ok\"}", "{'api_key':'\(FakeSecrets.password)'}", "\"client_secret\" : \"\(FakeSecrets.password)\""] {
            let out = OutputSanitizer.sanitize(t)
            #expect(!out.contains(FakeSecrets.password), Comment(rawValue: out))
        }
        #expect(OutputSanitizer.sanitize("{\"password\": \"x1y2z3\", \"note\": \"ok\"}").contains("\"note\": \"ok\""))
    }

    @Test func ordinaryTextPathsAndHashesAreNotDestroyed() {
        let ok = ["Explain how a neural network works.", "Changed Assets/Scripts/NetworkPlayer.cs (+17 -4)", "/Users/someone/Library/Application Support/JARVIS/artifacts/reports/20261011/file.txt",
                  "a-very-long-kebab-case-identifier-without-any-digits-in-it-at-all", "Reply with exactly: JARVIS_OK", "Step 3 of 7: running tests", "key points: speed and safety"]
        for s in ok { #expect(OutputSanitizer.sanitize(s) == s, "mangled: \(s) → \(OutputSanitizer.sanitize(s))") }
        #expect(!OutputSanitizer.containsSecret("Explain how a neural network works."))
    }

    @Test func structuredFieldsAreMaskedByFieldNameNotOnlyByPattern() throws {
        let line = #"{"type":"tool","data":{"password":"short","api_key":"x","Authorization":"y","note":"hello","nested":{"client_secret":"abc"},"list":[{"token":"t"}]}}"#
        let out = OutputSanitizer.sanitizeStructured(line)
        #expect(out.contains("hello") && !out.contains("short") && !out.contains("\"abc\"") && !out.contains("\"t\""))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(((obj["data"] as? [String: Any])?["password"] as? String) == OutputSanitizer.mask)
        // A secret-bearing string under an innocent field name is still caught by the text engine.
        let sneaky = OutputSanitizer.sanitizeStructured(#"{"note":"use \#(FakeSecrets.skKey) here"}"#)
        #expect(FakeSecrets.leaks(sneaky).isEmpty)
        // Malformed JSON falls back to the text engine, never to raw.
        #expect(FakeSecrets.leaks(OutputSanitizer.sanitizeStructured("{broken \(FakeSecrets.skKey)")).isEmpty)
    }

    private struct BrokenEngine: SanitizerEngine {
        func redact(_ text: String) throws -> String { throw SanitizerFailure() }
        func detectsSecret(_ text: String) throws -> Bool { throw SanitizerFailure() }
    }

    @Test func aFailingSanitizerFailsClosedAndNeverReturnsTheRawPayload() {
        let saved = OutputSanitizer.holder.get()
        OutputSanitizer.holder.set(BrokenEngine())
        defer { OutputSanitizer.holder.set(saved) }
        let out = OutputSanitizer.sanitize("token \(FakeSecrets.skKey)")
        #expect(out == OutputSanitizer.withheld && FakeSecrets.leaks(out).isEmpty)
        #expect(OutputSanitizer.containsSecret("anything"))                                       // unknown ⇒ treated as sensitive
        #expect(OutputSanitizer.sanitizeStructured("{\"a\":\"\(FakeSecrets.skKey)\"}") != "{\"a\":\"\(FakeSecrets.skKey)\"}")
        let stream = StreamSanitizer()
        let emitted = stream.feed("hello \(FakeSecrets.skKey) world\n") + stream.flush()
        #expect(FakeSecrets.leaks(emitted).isEmpty)
        #expect(Redactor.redact("x \(FakeSecrets.skKey)") == OutputSanitizer.withheld)             // the old API shares the same fail-closed layer
        #expect(Redactor.excerpt("x \(FakeSecrets.skKey)", max: 50).contains(FakeSecrets.skKey) == false)
    }
}

@Suite("Streaming sanitizer (secrets split across chunks)")
struct StreamSanitizerTests {
    private func run(_ text: String, chunk: Int) -> String {
        let s = StreamSanitizer()
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
            out += s.feed(String(text[i..<j])); i = j
        }
        return out + s.flush()
    }

    @Test func aSecretSplitAtEveryPossibleBoundaryNeverLeaks() {
        let texts = ["Here is the key \(FakeSecrets.skKey) and more words after it.\nNext line.",
                     "Authorization: Bearer \(FakeSecrets.bearer)\nthen text",
                     "password = \(FakeSecrets.password) done",
                     "token: \(FakeSecrets.ghToken)", "id \(FakeSecrets.awsKey) end",
                     "prefix \(FakeSecrets.pem)\nafter the block", "jwt \(FakeSecrets.jwt) tail"]
        for t in texts {
            for chunk in [1, 2, 3, 5, 7, 11, 19, 64] {
                let out = run(t, chunk: chunk)
                #expect(FakeSecrets.leaks(out).isEmpty, "leak (chunk \(chunk)): \(t) → \(out)")
                // No long fragment of the secret either (≥10 consecutive characters).
                for secret in FakeSecrets.all where secret.count >= 14 {
                    for start in 0...(secret.count - 10) {
                        let frag = String(secret.dropFirst(start).prefix(10))
                        #expect(!out.contains(frag), "fragment \(frag) leaked (chunk \(chunk)) in \(out)")
                    }
                }
            }
        }
    }

    @Test func aCredentialWordFollowedByItsValueOnTheNextLineIsStillCaught() {
        let out = run("The password:\n\(FakeSecrets.password)\nnext", chunk: 4)
        #expect(!out.contains(FakeSecrets.password))
    }

    @Test func ordinaryProseIsReleasedWordByWordWithoutWaitingForTheLineToEnd() {
        let s = StreamSanitizer()
        #expect(s.feed("Hello wor") == "Hello ")
        #expect(s.feed("ld and more") == "world and ")
        #expect(s.feed(" text") == "more ")
        #expect(s.flush() == "text")
        #expect(s.heldCharacters == 0)
    }

    @Test func creditialishLinesAreHeldBoundedAndOutputIsComplete() {
        let s = StreamSanitizer(maxHold: 300)
        var out = s.feed("the token ")
        #expect(out.isEmpty)                                                                       // held: a credential word is on this line
        out += s.feed(String(repeating: "lorem ipsum ", count: 100))
        #expect(s.heldCharacters <= 300 + 160)                                                    // bounded
        out += s.flush()
        #expect(out.contains("lorem ipsum") && out.hasPrefix("the token"))
    }

    @Test func plainTextRoundTripsExactly() {
        let t = "Line one.\nLine two with several words.\n\nAnd unicode: çğıöşü 日本語 🚀 end"
        #expect(run(t, chunk: 3) == t && run(t, chunk: 1) == t)
    }
}
