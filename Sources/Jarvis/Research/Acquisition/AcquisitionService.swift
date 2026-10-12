import Foundation

protocol AcquisitionPersisting: Sendable {
    func save(_ record: AcquisitionRecord)
}

/// Who may be downloaded without a human decision, who needs one, and who is refused outright. Pure.
enum AcquisitionPolicy {
    enum Decision: Equatable, Sendable {
        case eligible([String])
        case approvalRequired([String])
        case rejected([String])
        var reasons: [String] { switch self { case .eligible(let r), .approvalRequired(let r), .rejected(let r): r } }
    }

    static let priceFreshness: TimeInterval = 24 * 3_600

    static func evaluate(_ c: CandidateRecord, now: Date = Date(), maxAutoBytes: Int = 100_000_000, knownSize: Int? = nil, requireHTTPS: Bool = true) -> Decision {
        // Hard refusals: other authority levels, or nothing to download.
        switch c.acquisition {
        case .paidPurchase: return .rejected(["PURCHASE REQUIRED — JARVIS never purchases anything; open the listing yourself"])
        case .accountRequiredFree, .marketplaceClaim: return .rejected(["ACCOUNT ACTION REQUIRED — JARVIS does not sign in, accept terms or claim assets; open the listing in your own browser"])
        case .unknown: return .rejected(["no verified download route (acquisition class UNKNOWN)"])
        case .publicDirectDownload: break
        }
        guard let u = c.downloadURL, u.lowercased().hasPrefix("https://") || (!requireHTTPS && u.lowercased().hasPrefix("http://")) else { return .rejected(["there is no https download link"]) }
        if c.price.state == .paidVerified { return .rejected(["the price is not free (PAID_VERIFIED)"]) }
        var approval: [String] = []
        var ok: [String] = []
        // Price: UNKNOWN is never free.
        if c.price.state == .freeVerified {
            if let at = c.price.verifiedAt, now.timeIntervalSince(at) <= priceFreshness { ok.append("price FREE_VERIFIED \(Int(now.timeIntervalSince(at) / 60)) min ago") }
            else { approval.append("the free price was verified more than 24 h ago — re-verify or approve") }
        } else { approval.append("price is \(c.price.state.rawValue), not FREE_VERIFIED") }
        // Licence: only a recognised, commercially usable, modifiable licence goes without a human reading it.
        if c.license.allowsAutomaticAcquisition { ok.append("licence \(c.license.identifier ?? c.license.state.rawValue) allows commercial use and modification") }
        else { approval.append("licence needs review (\(c.license.identifier ?? c.license.state.rawValue)\(c.license.note.map { ": \($0)" } ?? ""))") }
        // Source trust: a mirror is not the origin.
        if c.sourceTrust < 3 { approval.append("the source is not an official / trusted origin (trust \(c.sourceTrust)/5)") }
        if let n = knownSize, n > maxAutoBytes { approval.append("large download (\(n / 1_000_000) MB)") }
        if c.accountRequired == .yes { return .rejected(["a login is required to download"]) }
        return approval.isEmpty ? .eligible(ok) : .approvalRequired(approval + ok)
    }
}

/// Runs one acquisition through its state machine: verify → (approval) → download → quarantine → inspect. Never imports, never executes,
/// never touches a project, never performs an account or payment action. Every transition is validated and persisted.
final class AcquisitionService: @unchecked Sendable {
    let downloader: Downloader
    let paths: JarvisPaths
    let store: (any AcquisitionPersisting)?
    var limits = DownloadLimits()
    var archiveLimits = ArchiveLimits()
    private let lock = NSLock()
    private var sessionBytes = 0

    init(downloader: Downloader, paths: JarvisPaths, store: (any AcquisitionPersisting)? = nil) { self.downloader = downloader; self.paths = paths; self.store = store }

    func quarantineDirectory(_ id: UUID) -> URL { paths.acquisitions.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }

    @discardableResult
    func move(_ r: inout AcquisitionRecord, to s: AcquisitionState, failure: String? = nil) -> Bool {
        let from = r.state.rawValue
        guard AcquisitionState.canMove(r.state, to: s) else { Log.app.error("rejected acquisition transition \(from, privacy: .public) → \(s.rawValue, privacy: .public)"); return false }
        r.state = s; r.updatedAt = Date()
        if let failure { r.failure = OutputSanitizer.sanitize(String(failure.prefix(400))) }
        store?.save(r)
        return true
    }

    func newRecord(for c: CandidateRecord, researchID: UUID?, taskID: UUID?, licenseSourceURL: String?, id: UUID = UUID()) -> AcquisitionRecord {
        AcquisitionRecord(id: id, researchID: researchID, candidateID: c.id, taskID: taskID, state: .discovered, acquisitionClass: c.acquisition, name: String(c.name.prefix(120)), sourceURL: CanonicalURL.forStorage(c.url),
                          downloadURL: c.downloadURL.map(CanonicalURL.forStorage), finalHost: nil, originalFilename: nil, publisher: c.publisher, assetVersion: c.meta.version, licenseID: c.license.identifier ?? (c.license.state == .unknown ? nil : c.license.state.rawValue),
                          licenseSourceURL: licenseSourceURL, priceState: c.price.state, priceVerifiedAt: c.price.verifiedAt, sha256: nil, expectedSHA256: nil, hashMatchesPublished: .unknown, size: nil, detectedType: nil, declaredMIME: nil,
                          quarantinePath: nil, trust: .downloaded, inspection: nil, failure: nil, bytesDownloaded: nil, bytesExpected: nil)
    }

    /// The whole flow. `approved` is the user's explicit yes for the exact reasons returned earlier as `.approvalRequired`.
    func acquire(_ c: CandidateRecord, researchID: UUID?, taskID: UUID?, approved: Bool, expectedMD5: String? = nil, expectedSHA256: String? = nil, licenseSourceURL: String? = nil,
                 record existing: AcquisitionRecord? = nil, progress: @escaping @Sendable (AcquisitionRecord) -> Void = { _ in }) async -> AcquisitionRecord {
        var r = existing ?? newRecord(for: c, researchID: researchID, taskID: taskID, licenseSourceURL: licenseSourceURL)
        store?.save(r)
        if r.state == .discovered { move(&r, to: .verifying) }
        let decision = AcquisitionPolicy.evaluate(c, knownSize: nil, requireHTTPS: limits.requireHTTPS)
        switch decision {
        case .rejected(let why): move(&r, to: .rejected, failure: why.joined(separator: "; ")); progress(r); return r
        case .approvalRequired(let why):
            if !approved { move(&r, to: .approvalRequired, failure: why.joined(separator: "; ")); progress(r); return r }
            move(&r, to: .approvalRequired); move(&r, to: .approved)
        case .eligible: move(&r, to: .eligible)
        }
        guard let url = c.downloadURL else { move(&r, to: .failed, failure: "no download link"); return r }
        let used = lock.withLock { sessionBytes }
        var lim = limits; lim.sessionBudget = limits.sessionBudget
        if used >= lim.sessionBudget { move(&r, to: .failed, failure: "the session download budget is used up"); return r }
        move(&r, to: .downloading)
        r.expectedSHA256 = expectedSHA256
        let dir = quarantineDirectory(r.id)
        let rid = r.id
        let req = DownloadRequest(id: rid, url: url, expectedSHA256: expectedSHA256, expectedMD5: expectedMD5, expectedSize: nil, suggestedName: nil)
        let box = RecordBox(r)
        let result = await downloader.download(req, into: dir, limits: lim) { got, expected in
            var snap = box.update { $0.bytesDownloaded = got; $0.bytesExpected = expected; $0.updatedAt = Date() }
            snap.state = .downloading
            progress(snap)
        }
        r = box.value
        switch result {
        case .failure(let f):
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("download.part"))
            r.bytesDownloaded = nil
            if f == .cancelled { move(&r, to: .cancelled, failure: "download cancelled — the partial file was removed") } else { move(&r, to: .failed, failure: f.description) }
            writeProvenance(r, in: dir)
            progress(r); return r
        case .success(let d):
            lock.withLock { sessionBytes += d.size }
            r.sha256 = d.sha256; r.size = d.size; r.detectedType = d.sniff.kind; r.declaredMIME = d.declaredMIME; r.originalFilename = d.originalFilename
            r.finalHost = d.finalHost; r.downloadURL = d.finalURL; r.hashMatchesPublished = d.hashMatchesPublished; r.downloadedAt = Date(); r.bytesDownloaded = d.size; r.bytesExpected = d.size
            r.quarantinePath = "\(dir.lastPathComponent)/\(d.originalFilename)"; r.trust = .downloaded
            move(&r, to: .downloaded)
            move(&r, to: .inspecting)
            let outcome = inspect(file: d.fileURL, sniff: d.sniff, name: d.originalFilename)
            r.inspection = outcome
            if let why = outcome.rejectedReason {
                try? FileManager.default.removeItem(at: d.fileURL)
                r.trust = .rejected
                move(&r, to: .rejected, failure: why)
            } else {
                r.trust = (outcome.hasExecutables || outcome.hasNativeLibraries || outcome.hasEditorScripts) ? .inspected : .validatedForImport
                move(&r, to: .readyForImport)
            }
            writeProvenance(r, in: dir)
            progress(r)
            return r
        }
    }

    /// Looks inside without executing or extracting anything.
    func inspect(file: URL, sniff: ArtifactSniffer.Result, name: String) -> ArtifactInspection {
        if sniff.isArchive, sniff.kind == "zip" || sniff.kind == "gzip" {
            do {
                var kind = sniff.kind
                if sniff.kind == "gzip", name.lowercased().hasSuffix(".unitypackage") { kind = "gzip" }
                var (insp, _) = try ArchiveInspector.inspect(fileURL: file, kind: kind, limits: archiveLimits)
                insp.kind = name.lowercased().hasSuffix(".unitypackage") ? "unitypackage" : (sniff.kind == "gzip" ? "tar.gz" : "zip")
                return insp
            } catch {
                return ArtifactInspection(kind: sniff.kind, entryCount: 0, uncompressedBytes: 0, maxCompressionRatio: 0, hasScripts: false, hasEditorScripts: false, hasNativeLibraries: false, hasExecutables: false,
                                          findings: ["REJECTED: \(error)"], rejectedReason: "\(error)", sampleEntries: [], codeBearing: .unknown)
            }
        }
        if sniff.isArchive { // rar / 7z / tar: recognised but not inspectable in V0.9 → not importable
            return ArtifactInspection(kind: sniff.kind, entryCount: 0, uncompressedBytes: 0, maxCompressionRatio: 0, hasScripts: false, hasEditorScripts: false, hasNativeLibraries: false, hasExecutables: false,
                                      findings: ["the \(sniff.kind) format cannot be inspected safely by JARVIS yet"], rejectedReason: "\(sniff.kind) archives cannot be inspected before extraction in this version", sampleEntries: [], codeBearing: .unknown)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let script = ArtifactSniffer.scriptExtensions.contains(ext)
        return ArtifactInspection(kind: sniff.kind, entryCount: 1, uncompressedBytes: size, maxCompressionRatio: 1, hasScripts: script, hasEditorScripts: false, hasNativeLibraries: false, hasExecutables: false,
                              findings: script ? ["the file is a script / source file — read before importing"] : [], rejectedReason: nil, sampleEntries: [name], codeBearing: script ? .scripts : .none)
    }

    func writeProvenance(_ r: AcquisitionRecord, in dir: URL) {
        struct Provenance: Codable {
            var jarvisAcquisitionID: String; var name: String; var sourceURL: String; var downloadURL: String?; var finalHost: String?; var publisher: String?; var assetVersion: String?
            var license: String?; var licenseSourceURL: String?; var priceStateAtAcquisition: String?; var priceVerifiedAt: Date?; var sha256: String?; var publishedChecksumMatch: String
            var originalFilename: String?; var size: Int?; var detectedType: String?; var downloadedAt: Date?; var trust: String; var state: String; var failure: String?
        }
        let p = Provenance(jarvisAcquisitionID: r.id.uuidString, name: r.name, sourceURL: r.sourceURL, downloadURL: r.downloadURL, finalHost: r.finalHost, publisher: r.publisher, assetVersion: r.assetVersion, license: r.licenseID,
                           licenseSourceURL: r.licenseSourceURL, priceStateAtAcquisition: r.priceState?.rawValue, priceVerifiedAt: r.priceVerifiedAt, sha256: r.sha256, publishedChecksumMatch: r.hashMatchesPublished.rawValue,
                           originalFilename: r.originalFilename, size: r.size, detectedType: r.detectedType, downloadedAt: r.downloadedAt, trust: r.trust.rawValue, state: r.state.rawValue, failure: r.failure)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder.pretty.encode(p) { try? data.write(to: dir.appendingPathComponent("provenance.json"), options: .atomic) }
    }

    /// Launch: anything that was in flight is INTERRUPTED (never resumed silently); half-written files are deleted.
    func reconcile(_ records: [AcquisitionRecord]) -> [AcquisitionRecord] {
        var out: [AcquisitionRecord] = []
        for var r in records where [.verifying, .approved, .downloading, .downloaded, .inspecting].contains(r.state) {
            try? FileManager.default.removeItem(at: quarantineDirectory(r.id).appendingPathComponent("download.part"))
            move(&r, to: .interrupted, failure: "JARVIS quit while this acquisition was in progress — nothing partial is kept")
            out.append(r)
        }
        return out
    }

    /// Size of everything in the quarantine (what the user sees in Settings).
    func quarantineBytes() -> Int {
        guard let e = FileManager.default.enumerator(at: paths.acquisitions, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var n = 0
        for case let u as URL in e { if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { n += v.fileSize ?? 0 } }
        return n
    }

    /// The user's "delete downloaded files": removes the quarantine folders and marks the records so nothing can be imported from a missing file.
    @discardableResult
    func purgeQuarantine(_ records: [AcquisitionRecord]) -> Int {
        let fm = FileManager.default
        var removed = 0
        for var r in records {
            let dir = quarantineDirectory(r.id)
            if fm.fileExists(atPath: dir.path) { try? fm.removeItem(at: dir); removed += 1 }
            if !r.state.isTerminal || r.state == .readyForImport { r.state = .rejected; r.trust = .rejected; r.failure = "deleted by the user"; r.quarantinePath = nil; r.updatedAt = Date(); store?.save(r) }
        }
        if let rest = try? fm.contentsOfDirectory(atPath: paths.acquisitions.path) { for name in rest { try? fm.removeItem(at: paths.acquisitions.appendingPathComponent(name)); removed += 1 } }
        return removed
    }

    /// Re-hashes the stored artifact (a partial or modified file is never reused).
    func verifyStored(_ r: AcquisitionRecord) -> Bool {
        guard let rel = r.quarantinePath, let expected = r.sha256 else { return false }
        let url = paths.acquisitions.appendingPathComponent(rel)
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var hasher = SHA256Streaming()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(chunk) }
        return hasher.hex() == expected
    }

    /// Extracts a ZIP artifact into `<id>/extracted/` (inside the quarantine only) — a prerequisite of a project import, never an import itself.
    func extractForImport(_ r: AcquisitionRecord) throws -> (root: URL, files: [String]) {
        guard let rel = r.quarantinePath else { throw ArchiveError.malformed("no stored artifact") }
        let file = paths.acquisitions.appendingPathComponent(rel)
        let dest = quarantineDirectory(r.id).appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        if r.inspection?.kind == "zip" {
            let entries = try ArchiveInspector.listZIP(file, limits: archiveLimits)
            let judged = ArchiveInspector.judge(entries: entries, kind: "zip", archiveSize: r.size ?? 0, limits: archiveLimits)
            if let why = judged.rejectedReason { throw ArchiveError.unsafe(why) }
            _ = try ArchiveInspector.extractZIP(file, entries: entries, to: dest, limits: archiveLimits)
        } else {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: file, to: dest.appendingPathComponent(file.lastPathComponent))
        }
        Quarantine.markTree(dest)
        var files: [String] = []
        let base = dest.resolvingSymlinksInPath().path               // /var vs /private/var: compare resolved paths with resolved paths
        if let e = FileManager.default.enumerator(at: dest, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let p = u.resolvingSymlinksInPath().path
                if p.hasPrefix(base + "/") { files.append(String(p.dropFirst(base.count + 1))) }
            }
        }
        return (dest, files.sorted())
    }
}

import CryptoKit
struct SHA256Streaming {
    private var h = SHA256()
    mutating func update(_ d: Data) { h.update(data: d) }
    mutating func hex() -> String { h.finalize().map { String(format: "%02x", $0) }.joined() }
}

/// Lets a `@Sendable` progress callback update a record safely.
final class RecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var record: AcquisitionRecord
    init(_ r: AcquisitionRecord) { record = r }
    @discardableResult func update(_ f: (inout AcquisitionRecord) -> Void) -> AcquisitionRecord { lock.lock(); defer { lock.unlock() }; f(&record); return record }
    var value: AcquisitionRecord { lock.lock(); defer { lock.unlock() }; return record }
}
