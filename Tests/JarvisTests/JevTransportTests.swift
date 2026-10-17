import Testing
import Foundation
@testable import Jarvis

/// V1.0 Phase B — the real TypeSafe transport against a URLProtocol stub (no network, no credential), and the pure pieces around it.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            req.httpBody = data
        }
        Self.seen.append(req)
        let (status, body) = Self.handler?(req) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("V1.0 Phase B · TypeSafe Jev transport", .serialized)
struct JevTransportTests {
    private func transport(key: String? = "test-key-not-a-secret") -> TypeSafeJevTransport {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return TypeSafeJevTransport(credential: { key }, session: { session })
    }
    private func request() -> JevClassifyRequest {
        let c = JevContextBuilder.build(utterance: "Sistem durumunu söyle", language: "tr", source: .typed, previousInterpretation: "conversation", projectNames: [])!
        return JevRequestBuilder.request(for: c)
    }
    private let ok = #"{"model":"jev-1.13.0","answers":{"intent":{"type":"choice","choice":"system_status","confidence":0.93,"probabilities":{"system_status":0.93,"conversation":0.07}},"page":{"type":"choice","choice":"none","confidence":0.99,"probabilities":{"none":0.99}}},"usage":{"input_tokens":412,"output_tokens":20}}"#

    @Test("the body follows the documented contract: state + model + choice questions with criteria; no key in it")
    func body() throws {
        let b = TypeSafeJevTransport.body(for: request(), model: "")
        #expect(b["model"] as? String == "jev-latest")
        let q = try #require(b["questions"] as? [String: Any])
        let intent = try #require(q["intent"] as? [String: Any])
        #expect(intent["type"] as? String == "choice" && (intent["criteria"] as? [String: Any])?.count == DecisionIntent.allCases.count)
        #expect((q["page"] as? [String: Any])?["type"] as? String == "choice")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: b), as: UTF8.self)
        #expect(text.contains("Sistem durumunu söyle") && !text.lowercased().contains("bearer") && !text.contains("test-key"))
    }

    @Test("a good answer becomes a classification with usage; the request carries the key only in the Authorization header")
    func success() async throws {
        StubURLProtocol.seen = []
        StubURLProtocol.handler = { _ in (200, Data(self.ok.utf8)) }
        let c = try await transport().complete(request(), modelAlias: "jev-latest", timeout: 5)
        #expect(c.intent == "system_status" && c.confidence == 0.93 && c.model == "jev-1.13.0" && c.inputTokens == 412 && c.outputTokens == 20 && c.page == nil)
        let sent = try #require(StubURLProtocol.seen.last)
        #expect(sent.url?.absoluteString == "https://api.typesafe.ai/v1/systemone" && sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-a-secret")
        #expect(!(sent.url?.absoluteString.contains("test-key") ?? true) && !(String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains("test-key")))
        let d = try #require(JevClassificationMapper.decision(from: c))
        #expect(d.intent == .systemStatus && d.provider == .jev && d.provenance == .jevShadow && !d.requiresExecution)
    }

    @Test("HTTP errors map to failure classes; out-of-balance is told apart from a plain rate limit; nothing is retried")
    func errors() async {
        func status(_ code: Int, _ body: String = "{}") async -> JevFailure? {
            StubURLProtocol.seen = []
            StubURLProtocol.handler = { _ in (code, Data(body.utf8)) }
            do { _ = try await transport().complete(request(), modelAlias: "", timeout: 5); return nil } catch let f as JevFailure { return f } catch { return .unavailable }
        }
        #expect(await status(401) == .credentialMissing)
        #expect(await status(429) == .rateLimited)
        #expect(await status(429, #"{"error":"insufficient balance"}"#) == .outOfBalance)
        #expect(await status(402) == .outOfBalance)
        #expect(await status(422) == .apiChanged)
        #expect(await status(529) == .unavailable)
        #expect(await status(200, "not json") == .malformedResponse)
        StubURLProtocol.seen = []
        _ = await status(529)
        #expect(StubURLProtocol.seen.count == 1, "a failed request is not retried by the transport")
    }

    @Test("no credential → no request at all")
    func noCredential() async {
        StubURLProtocol.seen = []
        do { _ = try await transport(key: nil).complete(request(), modelAlias: "", timeout: 5); #expect(Bool(false)) } catch let f as JevFailure { #expect(f == .credentialMissing) } catch { #expect(Bool(false)) }
        #expect(StubURLProtocol.seen.isEmpty)
    }

    @Test("model discovery reads names only, from the shapes the service may use")
    func models() {
        #expect(TypeSafeJevTransport.modelNames(from: Data(#"[{"name":"jev-latest","description":"x","release_date":"2026"},{"name":"jev-preview"}]"#.utf8)) == ["jev-latest", "jev-preview"])
        #expect(TypeSafeJevTransport.modelNames(from: Data(#"{"data":[{"id":"jev-latest"}]}"#.utf8)) == ["jev-latest"])
        #expect(TypeSafeJevTransport.modelNames(from: Data("nope".utf8)).isEmpty)
    }

    @Test("an intent that is not one of ours is a malformed answer, never a guess; a navigation page must be one of JARVIS' pages")
    func mapping() {
        #expect(JevClassificationMapper.decision(from: JevClassification(intent: "make_coffee", confidence: 0.9)) == nil)
        var nav = JevClassification(intent: "jarvis_navigation", confidence: 0.95); nav.page = "system"
        #expect(JevClassificationMapper.decision(from: nav)?.target == "system")
        nav.page = "hamam"
        #expect(JevClassificationMapper.decision(from: nav)?.target == nil)
    }

    @Test("credential validation: plausible keys only; the store file is the one reader; presence needs no secret")
    func credential() {
        #expect(JevCredentialStore.validate("  abcdefgh12345678  ") == "abcdefgh12345678")
        #expect(JevCredentialStore.validate("short") == nil && JevCredentialStore.validate("has space inside key") == nil && JevCredentialStore.validate("ünïcödé-key-123456") == nil)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Jarvis")
        var readers: [String] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "swift" {
                if let t = try? String(contentsOf: u, encoding: .utf8), t.contains("JevCredentialStore.read(") { readers.append(u.lastPathComponent) }
            }
        }
        #expect(Set(readers).isSubset(of: ["TypeSafeJevTransport.swift"]), "only the transport reads the key: \(readers)")
    }
}
