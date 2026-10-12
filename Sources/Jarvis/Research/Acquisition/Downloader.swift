import Foundation
import CryptoKit
import Darwin

struct DownloadLimits: Sendable, Equatable {
    var maxBytes = 250_000_000
    var sessionBudget = 600_000_000
    var idleTimeout: TimeInterval = 30
    var overallTimeout: TimeInterval = 900
    var requireHTTPS = true
    var maxRedirects = 5
    var freeSpaceFactor = 2.0
}

struct DownloadRequest: Sendable {
    var id: UUID
    var url: String
    var expectedSHA256: String?
    var expectedMD5: String?                  // vendors such as Poly Haven publish MD5: compared when given, never invented
    var expectedSize: Int?
    var suggestedName: String?
}

struct DownloadResult: Sendable {
    var fileURL: URL
    var sha256: String
    var md5: String
    var size: Int
    var finalURL: String                      // sanitized (no tokens)
    var finalHost: String
    var hops: [String]
    var declaredMIME: String?
    var originalFilename: String
    var sniff: ArtifactSniffer.Result
    var hashMatchesPublished: Tri
}

enum DownloadFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case policy(String), network(ResearchFailure), tooLarge(Int), incomplete(received: Int, expected: Int), notAFile(String), executable(String), hashMismatch(String)
    case insufficientDisk, cancelled, io(String), mismatch(String)

    var description: String {
        switch self {
        case .policy(let w): "blocked by policy: \(w)"
        case .network(let f): f.description
        case .tooLarge(let n): "the file is larger than the \(n / 1_000_000) MB limit"
        case .incomplete(let r, let e): "incomplete download (\(r) of \(e) bytes) — a partial file is never valid"
        case .notAFile(let w): w
        case .executable(let w): "refused: \(w)"
        case .hashMismatch(let w): "the downloaded file does not match the published checksum (\(w))"
        case .insufficientDisk: "not enough free disk space"
        case .cancelled: "cancelled"
        case .io(let w): "disk error: \(w)"
        case .mismatch(let w): w
        }
    }
}

/// Streams a public artifact into the QUARANTINE folder: https only, every redirect hop revalidated, size/time/disk limits, incremental SHA-256 (+ MD5 when
/// the publisher gives one), a `.part` file that is deleted unless the transfer completed AND was verified, content sniffing (a web page is not a
/// file), the macOS download-quarantine flag, and no execution of anything. A cancelled, short or mismatching transfer never becomes an artifact.
final class Downloader: @unchecked Sendable {
    let client: WebClient
    init(client: WebClient) { self.client = client }

    static func sanitizedFilename(_ raw: String?, fallback: String = "artifact.bin") -> String {
        var name = ((raw ?? "") as NSString).lastPathComponent.removingPercentEncoding ?? fallback
        name = String(name.unicodeScalars.map { ($0.properties.isAlphabetic || $0.properties.numericType != nil || "._- ()".unicodeScalars.contains($0)) && $0.isASCII ? Character($0) : "_" })
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
        if name.isEmpty { return fallback }
        return String(name.prefix(100))
    }

    func download(_ req: DownloadRequest, into dir: URL, limits: DownloadLimits = DownloadLimits(), progress: @escaping @Sendable (Int, Int?) -> Void = { _, _ in }) async -> Result<DownloadResult, DownloadFailure> {
        let fm = FileManager.default
        if limits.requireHTTPS, !req.url.lowercased().hasPrefix("https://") { return .failure(.policy("downloads require https")) }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return .failure(.io("cannot create the quarantine folder")) }
        if let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage, Double(free) < Double(limits.maxBytes) * limits.freeSpaceFactor { return .failure(.insufficientDisk) }
        let part = dir.appendingPathComponent("download.part")
        fm.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let handle = try? FileHandle(forWritingTo: part) else { return .failure(.io("cannot open the partial file")) }
        let sink = FileSink(handle: handle, limit: limits.maxBytes, expected: nil, progress: progress)
        func discardPart() { try? handle.close(); try? fm.removeItem(at: part) }

        let result = await client.exchange(req.url, headers: ["Accept": "*/*"], timeout: limits.idleTimeout, overallTimeout: limits.overallTimeout, maxHops: limits.maxRedirects, shouldRead: { head in
            guard (200...299).contains(head.status) else { return .stop }
            if let len = head.contentLength { sink.setExpected(Int(len)); if Int(len) > limits.maxBytes { sink.markTooLarge(); return .stop } }
            if limits.requireHTTPS, head.url.scheme?.lowercased() != "https" { return .stop }
            return .read
        }, onData: { sink.write($0) })

        if Task.isCancelled { discardPart(); return .failure(.cancelled) }
        switch result {
        case .failure(let f):
            discardPart()
            if f == .cancelled { return .failure(.cancelled) }
            if case .blockedByURLPolicy(let w) = f { return .failure(.policy(w)) }
            return .failure(.network(f))
        case .success(let ex):
            try? handle.close()
            if sink.tooLarge { try? fm.removeItem(at: part); return .failure(.tooLarge(limits.maxBytes)) }
            if let w = sink.writeError { try? fm.removeItem(at: part); return .failure(.io(w)) }
            guard (200...299).contains(ex.head.status) else { try? fm.removeItem(at: part); return .failure(.network(.httpStatus(ex.head.status))) }
            let received = sink.count
            if let expected = ex.head.contentLength, Int(expected) != received, ex.head.headers["content-encoding"] == nil { try? fm.removeItem(at: part); return .failure(.incomplete(received: received, expected: Int(expected))) }
            if case .stoppedBySink = ex.end { try? fm.removeItem(at: part); return .failure(.incomplete(received: received, expected: Int(ex.head.contentLength ?? 0))) }
            guard received > 0 else { try? fm.removeItem(at: part); return .failure(.notAFile("the server sent an empty file")) }
            let (sha, md5) = sink.digests()
            // published checksums are compared, never invented
            var match: Tri = .unknown
            if let want = req.expectedSHA256?.lowercased() { match = want == sha ? .yes : .no }
            else if let want = req.expectedMD5?.lowercased() { match = want == md5 ? .yes : .no }
            if match == .no { try? fm.removeItem(at: part); return .failure(.hashMismatch("published \((req.expectedSHA256 ?? req.expectedMD5 ?? "").prefix(12))…, got \(req.expectedSHA256 != nil ? sha.prefix(12) : md5.prefix(12))…")) }
            if let want = req.expectedSize, want != received, req.expectedSHA256 == nil, req.expectedMD5 == nil { try? fm.removeItem(at: part); return .failure(.mismatch("size \(received) differs from the published size \(want)")) }
            let name = Self.sanitizedFilename(ex.head.suggestedFilename ?? req.suggestedName ?? URL(string: req.url)?.lastPathComponent)
            let finalFile = dir.appendingPathComponent(name)
            try? fm.removeItem(at: finalFile)
            do { try fm.moveItem(at: part, to: finalFile); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalFile.path) } catch { try? fm.removeItem(at: part); return .failure(.io("cannot store the artifact")) }
            let head = (try? FileHandle(forReadingFrom: finalFile))?.readData(ofLength: 8_192) ?? Data()
            let sniff = ArtifactSniffer.sniff(head)
            if let why = ArtifactSniffer.mismatch(declaredMIME: ex.head.mime, filename: name, sniffed: sniff) {
                try? fm.removeItem(at: finalFile)
                return .failure(sniff.isExecutable ? .executable(why) : .notAFile(why))
            }
            if sniff.isExecutable || ArtifactSniffer.executableExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) && !ArtifactSniffer.nativeLibraryExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
                try? fm.removeItem(at: finalFile); return .failure(.executable("the artifact itself is an \(sniff.isExecutable ? sniff.kind : "installer / executable type") — JARVIS never stores or runs those"))
            }
            Quarantine.markDownloaded(finalFile)
            return .success(DownloadResult(fileURL: finalFile, sha256: sha, md5: md5, size: received, finalURL: CanonicalURL.forStorage(ex.final.url), finalHost: ex.final.host, hops: (ex.hops + [ex.final.url]).map(CanonicalURL.forStorage),
                                           declaredMIME: ex.head.mime, originalFilename: name, sniff: sniff, hashMatchesPublished: match))
        }
    }
}

/// Thread-safe sink: writes chunks, hashes them incrementally, enforces the size cap, throttles progress callbacks.
final class FileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let limit: Int
    private var sha = SHA256()
    private var md5 = Insecure.MD5()
    private var expected: Int?
    private var lastProgress = Date.distantPast
    private let progress: @Sendable (Int, Int?) -> Void
    private(set) var count = 0
    private(set) var tooLarge = false
    private(set) var writeError: String?

    init(handle: FileHandle, limit: Int, expected: Int?, progress: @escaping @Sendable (Int, Int?) -> Void) { self.handle = handle; self.limit = limit; self.expected = expected; self.progress = progress }

    func setExpected(_ n: Int) { lock.lock(); expected = n; lock.unlock() }
    func markTooLarge() { lock.lock(); tooLarge = true; lock.unlock() }

    /// false = stop the transfer.
    func write(_ data: Data) -> Bool {
        lock.lock()
        if count + data.count > limit { tooLarge = true; lock.unlock(); return false }
        do { try handle.write(contentsOf: data) } catch { writeError = "\(error)"; lock.unlock(); return false }
        sha.update(data: data); md5.update(data: data)
        count += data.count
        let c = count, e = expected
        let now = Date()
        let fire = now.timeIntervalSince(lastProgress) > 0.25
        if fire { lastProgress = now }
        lock.unlock()
        if fire { progress(c, e) }
        return true
    }

    func digests() -> (sha256: String, md5: String) {
        lock.lock(); defer { lock.unlock() }
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(), md5.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

enum Quarantine {
    /// The macOS download-quarantine flag: Gatekeeper then treats the file like a browser download (relevant to anything executable inside it).
    static func markDownloaded(_ url: URL) {
        let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));JARVIS;"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }
    static func markTree(_ root: URL) {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let u as URL in e { if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { markDownloaded(u) } }
    }
    static func hasFlag(_ url: URL) -> Bool { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }
}
