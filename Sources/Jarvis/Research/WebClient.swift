import Foundation

// MARK: - Documents

struct FetchedDocument: Sendable {
    var requestedURL: URL
    var finalURL: URL
    var hops: [String]                        // sanitized redirect chain (storable)
    var status: Int
    var headers: [String: String]             // allow-listed response headers only
    var contentType: String?
    var body: Data
    var truncated: Bool
    var retrievedAt: Date
    var remoteAddress: String?
    var method: RetrievalMethod = .http

    var text: String {
        let declared = headers["content-type"]?.lowercased().components(separatedBy: "charset=").dropFirst().first?.trimmingCharacters(in: CharacterSet(charactersIn: " \";'")).lowercased()
        if declared == "iso-8859-1" || declared == "latin1" { return String(data: body, encoding: .isoLatin1) ?? "" }
        if declared == "windows-1252" || declared == "cp1252" { return String(data: body, encoding: .windowsCP1252) ?? "" }
        return String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }
}

struct FetchConfig: Sendable {
    var maxBytes = 1_500_000
    var timeout: TimeInterval = 20
    var overallTimeout: TimeInterval = 45
    var accept = "text/html,application/xhtml+xml,application/json;q=0.9,text/plain;q=0.8,application/xml;q=0.7"
    var textOnly = true
    var maxHops = 5
    var retries = 1
    var extraHeaders: [String: String] = [:]
}

enum ReadDecision: Sendable { case read, stop }

struct Exchange: Sendable {
    var head: HTTPHead
    var hops: [URL]
    var final: ValidatedURL
    var remoteAddress: String?
    var bytes: Int
    var end: TransferEnd
}

/// The ONLY way research code reaches the network: URL policy + DNS check before every hop, per-host politeness, manual redirect following
/// (each hop revalidated, https→http refused), post-connection check of the real remote address, allow-listed headers only.
final class WebClient: @unchecked Sendable {
    static let defaultUserAgent = "JARVIS-Research/0.9 (local assistant on macOS; polite, rate-limited; +https://github.com/n0tnow/Jarvis)"

    let gate: URLGate
    let transport: any HTTPTransport
    let limiter: HostRateLimiter
    let userAgent: String

    init(gate: URLGate = URLGate(), transport: any HTTPTransport = URLSessionTransport(), limiter: HostRateLimiter = HostRateLimiter(), userAgent: String = WebClient.defaultUserAgent) {
        self.gate = gate; self.transport = transport; self.limiter = limiter; self.userAgent = userAgent
    }

    // MARK: Generic exchange (used by page fetches and by downloads)

    func exchange(_ start: String, headers: [String: String] = [:], timeout: TimeInterval = 20, overallTimeout: TimeInterval = 45, maxHops: Int = 5,
                  shouldRead: @escaping @Sendable (HTTPHead) -> ReadDecision, onData: @escaping @Sendable (Data) -> Bool) async -> Result<Exchange, ResearchFailure> {
        var current: ValidatedURL
        switch await gate.authorize(start) { case .failure(let e): return .failure(.blockedByURLPolicy(e.description)); case .success(let v): current = v }
        var hops: [URL] = []
        var hop = 0
        while true {
            if Task.isCancelled { return .failure(.cancelled) }
            do { try await limiter.wait(host: current.host) } catch { return .failure(.cancelled) }
            var h = headers
            h["User-Agent"] = h["User-Agent"] ?? userAgent
            h["Accept-Language"] = h["Accept-Language"] ?? "en,tr;q=0.8"
            let spec = HTTPRequestSpec(url: current.url, headers: h, timeout: timeout, overallTimeout: overallTimeout)
            let report = await transport.transfer(spec, onHead: { head in head.isRedirect ? true : shouldRead(head) == .read }, onData: onData)
            if case .cancelled = report.end { return .failure(.cancelled) }
            if case .failed(let f) = report.end { return .failure(f) }
            guard let head = report.head else { return .failure(.providerFailed("no response")) }
            // The connection really went where the policy allowed? (defence in depth against DNS tricks)
            if let remote = report.remoteAddress, let addr = AddressClassifier.parseLiteral(remote), let why = AddressClassifier.nonPublicReason(addr) {
                return .failure(.ssrfPostCheck("\(current.host) → \(remote): \(why)"))
            }
            if head.isRedirect, let location = head.location {
                hop += 1
                hops.append(current.url)
                switch await gate.authorizeRedirect(from: current, to: location, hop: hop) {
                case .failure(let e): return .failure(.blockedByURLPolicy(e.description))
                case .success(let next): if hop > maxHops { return .failure(.blockedByURLPolicy(URLRejection.tooManyRedirects.description)) }; current = next; continue
                }
            }
            return .success(Exchange(head: head, hops: hops, final: current, remoteAddress: report.remoteAddress, bytes: report.bytesReceived, end: report.end))
        }
    }

    // MARK: Page fetch (in memory, bounded, text only)

    func fetch(_ urlString: String, config: FetchConfig = FetchConfig()) async -> Result<FetchedDocument, ResearchFailure> {
        var attempt = 0
        while true {
            let result = await fetchOnce(urlString, config: config)
            switch result {
            case .success: return result
            case .failure(let f):
                attempt += 1
                var retryable = false
                var delay = 0.8
                switch f {
                case .httpStatus(500...599): retryable = true
                case .rateLimited(let after): retryable = (after ?? 2) <= 8; delay = min(after ?? 2, 8)
                case .timeout: retryable = true
                default: break
                }
                if !retryable || attempt > config.retries || Task.isCancelled { return result }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func fetchOnce(_ urlString: String, config: FetchConfig) async -> Result<FetchedDocument, ResearchFailure> {
        let box = BodyBox(limit: config.maxBytes)
        var headers = config.extraHeaders
        headers["Accept"] = headers["Accept"] ?? config.accept
        let textOnly = config.textOnly
        let result = await exchange(urlString, headers: headers, timeout: config.timeout, overallTimeout: config.overallTimeout, maxHops: config.maxHops, shouldRead: { head in
            if (200...299).contains(head.status) { return textOnly && !Self.isTextual(head.mime) ? .stop : .read }
            return [403, 429, 503].contains(head.status) ? .read : .stop           // a small error body can reveal a CAPTCHA challenge
        }, onData: { box.append($0) })
        switch result {
        case .failure(let f): return .failure(f)
        case .success(let ex):
            let head = ex.head
            let body = box.data
            let safeHeaders = HeaderRedactor.keep(head.headers)
            switch head.status {
            case 200...299:
                if textOnly && !Self.isTextual(head.mime) { return .failure(.unsupportedContent(head.mime ?? "unknown")) }
                return .success(FetchedDocument(requestedURL: URL(string: urlString) ?? ex.final.url, finalURL: ex.final.url, hops: (ex.hops + [ex.final.url]).map(CanonicalURL.forStorage),
                                                status: head.status, headers: safeHeaders, contentType: head.mime, body: body, truncated: box.truncated, retrievedAt: Date(), remoteAddress: ex.remoteAddress))
            case 401: return .failure(.loginWall)
            case 403, 429, 503:
                let probe = HTMLExtractor.extract(body.prefix(60_000), maxChars: 3_000)
                if probe.isCaptchaChallenge { return .failure(.captcha) }
                if head.status == 429 { return .failure(.rateLimited(retryAfter: head.headers["retry-after"].flatMap(TimeInterval.init))) }
                if head.status == 403, probe.isLoginWall { return .failure(.loginWall) }
                return .failure(.httpStatus(head.status))
            default: return .failure(.httpStatus(head.status))
            }
        }
    }

    static func isTextual(_ mime: String?) -> Bool {
        guard let m = mime?.lowercased(), !m.isEmpty else { return true }
        return m.hasPrefix("text/") || m.contains("json") || m.contains("xml") || m.contains("html") || m == "application/javascript" || m == "application/x-ndjson"
    }
}

/// Thread-safe, size-bounded accumulator for `onData` callbacks (URLSession delivers them on its own queue).
final class BodyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var truncated = false
    let limit: Int
    init(limit: Int) { self.limit = limit }
    /// false = stop the transfer (limit reached).
    func append(_ d: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if buffer.count + d.count > limit { buffer.append(d.prefix(max(0, limit - buffer.count))); truncated = true; return false }
        buffer.append(d); return true
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}
