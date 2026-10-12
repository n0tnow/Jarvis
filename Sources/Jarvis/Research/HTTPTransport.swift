import Foundation
import CryptoKit

// MARK: - Wire types

struct HTTPRequestSpec: Sendable {
    var url: URL
    var method = "GET"
    var headers: [String: String] = [:]
    var timeout: TimeInterval = 20                // idle timeout
    var overallTimeout: TimeInterval = 60
    var acceptEncoding = true
}

struct HTTPHead: Sendable, Equatable {
    var status: Int
    var headers: [String: String]                // lower-cased names
    var url: URL
    var mime: String?
    var contentLength: Int64?
    var suggestedFilename: String?
    var location: URL?                           // resolved Location of a 3xx
    var isRedirect: Bool { (301...308).contains(status) && status != 304 && location != nil }
}

enum TransferEnd: Sendable, Equatable {
    case finished
    case stoppedBySink                           // the caller decided to stop (too large, not wanted)
    case failed(ResearchFailure)
    case cancelled
}

struct TransferReport: Sendable {
    var head: HTTPHead?
    var end: TransferEnd
    var remoteAddress: String?
    var bytesReceived: Int
    var metricsProtocol: String?
}

/// One HTTP exchange WITHOUT following redirects (the caller revalidates every hop). `onHead` decides whether the body is read;
/// `onData` receives chunks and may stop the transfer. Cookies, caches and credential storage are never used.
protocol HTTPTransport: Sendable {
    func transfer(_ spec: HTTPRequestSpec, onHead: @escaping @Sendable (HTTPHead) -> Bool, onData: @escaping @Sendable (Data) -> Bool) async -> TransferReport
}

// MARK: - URLSession implementation

/// Ephemeral URLSession per exchange: no cookie jar, no URL cache, no credential storage, TLS ≥ 1.2, auth challenges are CANCELLED (JARVIS never
/// supplies credentials), redirects are surfaced instead of followed, and the remote address of the real connection is reported.
struct URLSessionTransport: HTTPTransport {
    func transfer(_ spec: HTTPRequestSpec, onHead: @escaping @Sendable (HTTPHead) -> Bool, onData: @escaping @Sendable (Data) -> Bool) async -> TransferReport {
        let handler = TransferHandler(onHead: onHead, onData: onData)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.waitsForConnectivity = false
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.timeoutIntervalForRequest = spec.timeout
        cfg.timeoutIntervalForResource = spec.overallTimeout
        cfg.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.name = "jarvis.research.transport"
        let session = URLSession(configuration: cfg, delegate: handler, delegateQueue: queue)
        var request = URLRequest(url: spec.url)
        request.httpMethod = spec.method
        request.httpShouldHandleCookies = false
        request.timeoutInterval = spec.timeout
        for (k, v) in spec.headers { request.setValue(v, forHTTPHeaderField: k) }
        if !spec.acceptEncoding { request.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
        let task = session.dataTask(with: request)
        let report = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<TransferReport, Never>) in
                handler.start(task, continuation: cont)
            }
        } onCancel: {
            handler.cancel()
        }
        session.finishTasksAndInvalidate()
        return report
    }
}

final class TransferHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let onHead: @Sendable (HTTPHead) -> Bool
    private let onData: @Sendable (Data) -> Bool
    private var continuation: CheckedContinuation<TransferReport, Never>?
    private var task: URLSessionDataTask?
    private var head: HTTPHead?
    private var remote: String?
    private var proto: String?
    private var bytes = 0
    private var stoppedBySink = false
    private var cancelledByUs = false
    private var finished = false
    private var redirectLocation: URL?

    init(onHead: @escaping @Sendable (HTTPHead) -> Bool, onData: @escaping @Sendable (Data) -> Bool) { self.onHead = onHead; self.onData = onData }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<TransferReport, Never>) {
        lock.lock()
        self.task = task; self.continuation = continuation
        let alreadyCancelled = cancelledByUs
        lock.unlock()
        if alreadyCancelled { task.cancel() } else { task.resume() }
        if alreadyCancelled { finish(.cancelled) }
    }

    func cancel() {
        lock.lock(); cancelledByUs = true; let t = task; lock.unlock()
        t?.cancel()
    }

    private func finish(_ end: TransferEnd) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true; continuation = nil
        let report = TransferReport(head: head, end: end, remoteAddress: remote, bytesReceived: bytes, metricsProtocol: proto)
        lock.unlock()
        cont.resume(returning: report)
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirectLocation = request.url; lock.unlock()
        completionHandler(nil)                                   // deliver the 3xx itself; the caller revalidates the next hop
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url else { lock.lock(); stoppedBySink = true; lock.unlock(); completionHandler(.cancel); return }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v } }
        lock.lock(); let loc = redirectLocation; lock.unlock()
        let location = loc ?? headers["location"].flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        let mime = http.mimeType?.lowercased()
        let h = HTTPHead(status: http.statusCode, headers: headers, url: url, mime: mime, contentLength: http.expectedContentLength >= 0 ? http.expectedContentLength : nil,
                         suggestedFilename: http.suggestedFilename, location: location)
        lock.lock(); head = h; lock.unlock()
        if h.isRedirect { lock.lock(); stoppedBySink = false; lock.unlock(); _ = onHead(h); completionHandler(.cancel); return }
        if onHead(h) { completionHandler(.allow) } else { lock.lock(); stoppedBySink = true; lock.unlock(); completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); bytes += data.count; lock.unlock()
        if !onData(data) { lock.lock(); stoppedBySink = true; lock.unlock(); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        if let t = metrics.transactionMetrics.last { remote = t.remoteAddress; proto = t.networkProtocolName }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let sink = stoppedBySink, ours = cancelledByUs, h = head; lock.unlock()
        if let error {
            let ns = error as NSError
            if ours { finish(.cancelled); return }
            if sink || (ns.code == NSURLErrorCancelled && h != nil) { finish(h?.isRedirect == true ? .finished : .stoppedBySink); return }
            finish(.failed(Self.map(ns))); return
        }
        finish(.finished)
    }

    // Never answer authentication challenges with credentials; accept only default server-trust evaluation.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    static func map(_ e: NSError) -> ResearchFailure {
        guard e.domain == NSURLErrorDomain else { return .providerFailed("network error \(e.code)") }
        switch e.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorNetworkConnectionLost, NSURLErrorInternationalRoamingOff: return .offline
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorCannotLoadFromNetwork: return .tlsFailure
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .providerFailed("the host name could not be found")
        case NSURLErrorCannotConnectToHost: return .providerFailed("the server refused the connection")
        case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: return .providerFailed("redirect failure")
        case NSURLErrorUserCancelledAuthentication, NSURLErrorUserAuthenticationRequired: return .loginWall
        case NSURLErrorCancelled: return .cancelled
        default: return .providerFailed("network error \(e.code)")
        }
    }
}

// MARK: - Politeness: per-host spacing

/// A minimum interval between requests to the same host (respectful rate; also keeps search engines from blocking us).
actor HostRateLimiter {
    private var next: [String: Date] = [:]
    var defaultInterval: TimeInterval
    private var overrides: [String: TimeInterval] = [:]

    init(defaultInterval: TimeInterval = 1.0) { self.defaultInterval = defaultInterval }
    func setInterval(_ seconds: TimeInterval, for host: String) { overrides[host] = seconds }

    /// Reserves the next slot for `host` and sleeps until it (cancellable).
    func wait(host: String) async throws {
        let interval = overrides[host] ?? defaultInterval
        let now = Date()
        let slot = max(now, next[host] ?? now)
        next[host] = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0.001 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}

// MARK: - Header handling

enum HeaderRedactor {
    static let sensitive: Set<String> = ["authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token", "x-amz-security-token", "x-goog-api-key", "www-authenticate", "proxy-authenticate"]
    static let keepOnResponse: Set<String> = ["content-type", "content-length", "content-disposition", "last-modified", "etag", "date", "retry-after", "expires", "cache-control", "x-ratelimit-remaining", "x-ratelimit-reset", "link"]

    /// Safe to log/persist: sensitive names are masked, values sanitized and bounded.
    static func redact(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers {
            let name = k.lowercased()
            if sensitive.contains(name) || name.contains("token") || name.contains("secret") || name.contains("api-key") || name.contains("apikey") { out[name] = OutputSanitizer.mask }
            else { out[name] = OutputSanitizer.sanitize(String(v.prefix(200))) }
        }
        return out
    }
    /// What a retrieved document keeps of the response headers.
    static func keep(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers where keepOnResponse.contains(k.lowercased()) { out[k.lowercased()] = OutputSanitizer.sanitize(String(v.prefix(200))) }
        return out
    }
}
