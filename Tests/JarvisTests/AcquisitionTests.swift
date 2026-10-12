import Testing
import Foundation
@testable import Jarvis

private func tmp(_ tag: String = "acq") -> URL {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func write(_ d: Data, _ name: String, in dir: URL) -> URL { let u = dir.appendingPathComponent(name); try! d.write(to: u); return u }
private func run(_ exe: String, _ args: [String], cwd: URL) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.currentDirectoryURL = cwd
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
}

@Suite("Acquisition · file identification")
struct SnifferTests {
    @Test func contentDecidesNotTheName() {
        #expect(ArtifactSniffer.sniff(ResearchFixtureSite.goodZip()).kind == "zip" && ArtifactSniffer.sniff(ResearchFixtureSite.goodZip()).isArchive)
        #expect(ArtifactSniffer.sniff(ResearchFixtureSite.png).kind == "png")
        #expect(ArtifactSniffer.sniff(Data("<!DOCTYPE html><html><body>Please log in</body></html>".utf8)).isHTML)
        #expect(ArtifactSniffer.sniff(Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])).isExecutable)
        #expect(ArtifactSniffer.sniff(Data("#!/bin/sh\nls".utf8)).isExecutable)
        #expect(ArtifactSniffer.sniff(Data("Kaydara FBX Binary  \0".utf8)).kind == "fbx-binary")
        #expect(ArtifactSniffer.sniff(Data("RIFF....WAVEfmt ".utf8)).kind == "wav")
    }

    @Test func mismatchesBetweenNameMimeAndContentAreCaught() {
        let html = ArtifactSniffer.sniff(Data("<html><body>login</body></html>".utf8))
        #expect(ArtifactSniffer.mismatch(declaredMIME: "application/zip", filename: "pack.zip", sniffed: html)?.contains("web page") == true)
        let zip = ArtifactSniffer.sniff(ResearchFixtureSite.goodZip())
        #expect(ArtifactSniffer.mismatch(declaredMIME: "image/png", filename: "tex.png", sniffed: zip) != nil)
        #expect(ArtifactSniffer.mismatch(declaredMIME: "application/zip", filename: "pack.zip", sniffed: zip) == nil)
        let exe = ArtifactSniffer.sniff(Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]))
        #expect(ArtifactSniffer.mismatch(declaredMIME: "application/octet-stream", filename: "model.fbx", sniffed: exe)?.contains("executable") == true)
        #expect(ArtifactSniffer.mismatch(declaredMIME: "application/octet-stream", filename: "a.zip", sniffed: ArtifactSniffer.sniff(Data("hello".utf8))) != nil)
    }
}

@Suite("Acquisition · archives")
struct ArchiveTests {
    private func list(_ data: Data) throws -> (ArtifactInspection, [ArchiveEntry]) {
        let dir = tmp(); let f = write(data, "a.zip", in: dir)
        return try ArchiveInspector.inspect(fileURL: f, kind: "zip")
    }

    @Test func aNormalArchiveIsListedAndAccepted() throws {
        let (insp, entries) = try list(ResearchFixtureSite.goodZip())
        #expect(entries.count == 3 && insp.rejectedReason == nil && insp.kind == "zip" && insp.codeBearing == .none && !insp.hasScripts && !insp.hasExecutables)
        #expect(insp.sampleEntries.contains("Throw/throw_a.fbx"))
    }

    @Test func traversalAbsolutePathsAndSymlinksAreRejected() throws {
        #expect(try list(ResearchFixtureSite.traversalZip()).0.rejectedReason?.contains("traversal") == true)
        #expect(try list(ResearchFixtureSite.absoluteZip()).0.rejectedReason?.contains("absolute") == true)
        #expect(try list(ResearchFixtureSite.symlinkZip()).0.rejectedReason?.contains("symbolic link") == true)
        #expect(try list(ResearchFixtureSite.bombZip()).0.rejectedReason?.contains("bomb") == true || (try list(ResearchFixtureSite.bombZip()).0.rejectedReason?.contains("MB") == true))
        let enc = ZipBuilder.build([ZipBuilder.Entry(name: "secret.bin", data: Data(repeating: 1, count: 10), encrypted: true)])
        #expect(try list(enc).0.rejectedReason?.contains("password-protected") == true)
    }

    @Test func nameRulesAreStrict() {
        for bad in ["../x", "a/../../x", "/abs", "C:\\win", "a\\..\\..\\b", "~/x", "a/\u{0}b", ""] { #expect(ArchiveInspector.unsafeReason(bad) != nil, "\(bad.debugDescription)") }
        for good in ["a/b.txt", "Throw/preview.png", "dir/", "a b/c d.fbx", "..hidden/file", "a/.../b"] { #expect(ArchiveInspector.unsafeReason(good) == nil, "\(good)") }
        #expect(ArchiveInspector.unsafeReason(String(repeating: "a/", count: 60)) != nil)
        #expect(ArchiveInspector.unsafeReason(String(repeating: "x", count: 600)) != nil)
    }

    @Test func scriptsEditorCodeNativeLibrariesAndExecutablesAreClassified() throws {
        let (insp, _) = try list(ResearchFixtureSite.scriptsZip())
        #expect(insp.hasScripts && insp.hasEditorScripts && insp.hasNativeLibraries && insp.hasExecutables && insp.codeBearing == .nativeLibraries && insp.rejectedReason == nil)
        #expect(insp.findings.contains { $0.contains("EDITOR scripts") } && insp.findings.contains { $0.contains("never run by JARVIS") })
    }

    @Test func tooManyEntriesIsRejected() throws {
        let many = ZipBuilder.build((0..<60).map { ZipBuilder.file("f\($0).txt", "x") })
        let dir = tmp(); let f = write(many, "m.zip", in: dir)
        var lim = ArchiveLimits(); lim.maxEntries = 50
        let (insp, _) = try ArchiveInspector.inspect(fileURL: f, kind: "zip", limits: lim)
        #expect(insp.rejectedReason?.contains("entries") == true)
    }

    @Test func extractionStaysInsideTheDestinationAndStripsExecutableBits() throws {
        let dir = tmp(); let f = write(ResearchFixtureSite.goodZip(), "a.zip", in: dir)
        let entries = try ArchiveInspector.listZIP(f, limits: ArchiveLimits())
        let dest = dir.appendingPathComponent("out")
        let report = try ArchiveInspector.extractZIP(f, entries: entries, to: dest)
        #expect(report.files == 3)
        let read = try String(contentsOf: dest.appendingPathComponent("Throw/readme.txt"), encoding: .utf8)
        #expect(read == "Throwing animations. CC0.")
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("Throw/throw_a.fbx").path)
        #expect(((attrs[.posixPermissions] as? Int) ?? 0) & 0o111 == 0)
    }

    @Test func extractingATraversalArchiveThrowsAndWritesNothingOutside() throws {
        let dir = tmp(); let f = write(ResearchFixtureSite.traversalZip(), "evil.zip", in: dir)
        let entries = try ArchiveInspector.listZIP(f, limits: ArchiveLimits())
        let dest = dir.appendingPathComponent("out")
        #expect(throws: ArchiveError.self) { try ArchiveInspector.extractZIP(f, entries: entries, to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape.txt").path))
    }

    @Test func aHeaderThatLiesAboutTheSizeCannotInflateBeyondWhatItDeclared() throws {
        let dir = tmp(); let f = write(ResearchFixtureSite.lyingHeaderZip(), "liar.zip", in: dir)
        let entries = try ArchiveInspector.listZIP(f, limits: ArchiveLimits())
        #expect(throws: ArchiveError.self) { try ArchiveInspector.extractZIP(f, entries: entries, to: dir.appendingPathComponent("out")) }
        let written = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("out/liar.bin").path)[.size] as? Int) ?? 0
        #expect(written < 1_000)                                         // it stopped almost immediately, it did not write 2 MB
    }

    @Test func corruptDataFailsTheCRCCheck() throws {
        let bad = ZipBuilder.build([ZipBuilder.Entry(name: "a.bin", data: Data(repeating: 5, count: 100), crcOverride: 0xDEADBEEF)])
        let dir = tmp(); let f = write(bad, "bad.zip", in: dir)
        let entries = try ArchiveInspector.listZIP(f, limits: ArchiveLimits())
        #expect(throws: ArchiveError.self) { try ArchiveInspector.extractZIP(f, entries: entries, to: dir.appendingPathComponent("out")) }
    }

    @Test func tarGzAndUnityPackagesAreListedWithoutWritingAnything() throws {
        let dir = tmp(); let pkg = dir.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("abc123"), withIntermediateDirectories: true)
        try Data("Assets/Models/prop.fbx".utf8).write(to: pkg.appendingPathComponent("abc123/pathname"))
        try Data(repeating: 3, count: 600).write(to: pkg.appendingPathComponent("abc123/asset"))
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("def456"), withIntermediateDirectories: true)
        try Data("Assets/Scripts/Thrower.cs".utf8).write(to: pkg.appendingPathComponent("def456/pathname"))
        try Data("class Thrower {}".utf8).write(to: pkg.appendingPathComponent("def456/asset"))
        run("/usr/bin/tar", ["-czf", "../test.unitypackage", "."], cwd: pkg)
        let (insp, entries) = try ArchiveInspector.inspect(fileURL: dir.appendingPathComponent("test.unitypackage"), kind: "gzip")
        #expect(entries.count >= 4 && insp.rejectedReason == nil)
        #expect(insp.sampleEntries.contains("Assets/Models/prop.fbx") && insp.sampleEntries.contains("Assets/Scripts/Thrower.cs"))
        #expect(throws: ArchiveError.self) { try ArchiveInspector.inspect(fileURL: write(Data("x".utf8), "x.gz", in: dir), kind: "gzip") }
    }
}

@Suite("Acquisition · policy and downloads", .serialized)
struct DownloadTests {
    private func candidate(price: PriceState = .freeVerified, verifiedAgo: TimeInterval = 60, licence: LicenseAssessment? = nil, acq: AcquisitionClass = .publicDirectDownload, url: String? = "https://kenney.nl/files/good.zip", trust: Int = 5, account: Tri = .no) -> CandidateRecord {
        var c = CandidateRecord(researchID: UUID(), name: "Throw Pack", url: "https://kenney.nl/asset/free-throw")
        c.price = PriceAssessment(state: price, amount: 0, currency: "USD", evidence: [], verifiedAt: Date().addingTimeInterval(-verifiedAgo), note: nil)
        c.license = licence ?? LicenseAssessment(state: .permissive, identifier: "CC0-1.0", commercialUse: .yes, modification: .yes, redistribution: .yes, attribution: .no, evidence: [], needsReview: false, note: nil)
        c.acquisition = acq; c.downloadURL = url; c.sourceTrust = trust; c.accountRequired = account
        return c
    }

    @Test func thePolicyMatrix() {
        if case .eligible = AcquisitionPolicy.evaluate(candidate()) {} else { Issue.record("a fresh FREE_VERIFIED permissive official download is eligible") }
        if case .rejected(let r) = AcquisitionPolicy.evaluate(candidate(acq: .paidPurchase)) { #expect(r.joined().contains("PURCHASE")) } else { Issue.record("paid") }
        if case .rejected(let r) = AcquisitionPolicy.evaluate(candidate(acq: .accountRequiredFree)) { #expect(r.joined().contains("ACCOUNT ACTION")) } else { Issue.record("account") }
        if case .rejected = AcquisitionPolicy.evaluate(candidate(acq: .marketplaceClaim)) {} else { Issue.record("claim") }
        if case .rejected = AcquisitionPolicy.evaluate(candidate(acq: .unknown)) {} else { Issue.record("unknown class") }
        if case .rejected = AcquisitionPolicy.evaluate(candidate(url: nil)) {} else { Issue.record("no link") }
        if case .rejected = AcquisitionPolicy.evaluate(candidate(url: "http://kenney.nl/files/good.zip")) {} else { Issue.record("plain http") }
        if case .approvalRequired = AcquisitionPolicy.evaluate(candidate(price: .unknown)) {} else { Issue.record("unknown price needs a human, and is never 'free'") }
        if case .approvalRequired = AcquisitionPolicy.evaluate(candidate(verifiedAgo: 3 * 86_400)) {} else { Issue.record("stale price") }
        if case .approvalRequired = AcquisitionPolicy.evaluate(candidate(licence: .unknown)) {} else { Issue.record("unknown licence") }
        if case .approvalRequired = AcquisitionPolicy.evaluate(candidate(trust: 1)) {} else { Issue.record("mirror") }
        if case .rejected = AcquisitionPolicy.evaluate(candidate(account: .yes)) {} else { Issue.record("login to download") }
        if case .rejected = AcquisitionPolicy.evaluate(candidate(price: .paidVerified)) {} else { Issue.record("paid verified") }
    }

    private func service(_ env: ResearchFixtureEnv, _ paths: JarvisPaths = .temporary("acqsvc")) -> AcquisitionService {
        try? paths.ensureDirectories()
        return AcquisitionService(downloader: Downloader(client: env.client), paths: paths)
    }

    private func dl(_ env: ResearchFixtureEnv, _ path: String, host: String = "kenney.nl", limits: DownloadLimits = DownloadLimits(), md5: String? = nil, sha: String? = nil) async -> Result<DownloadResult, DownloadFailure> {
        await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "https://\(host)\(path)", expectedSHA256: sha, expectedMD5: md5, expectedSize: nil, suggestedName: nil), into: tmp("dl"), limits: limits)
    }

    @Test func aGoodArtifactIsHashedTypedAndQuarantined() async throws {
        let env = try ResearchFixtureEnv()
        guard case .success(let r) = await dl(env, "/files/good.zip") else { Issue.record("download"); return }
        #expect(r.size == ResearchFixtureSite.goodZip().count && r.sniff.kind == "zip" && r.originalFilename == "throw-pack.zip" && r.finalHost == "kenney.nl")
        #expect(r.sha256 == (try AssetImporter.sha256(of: r.fileURL)) && r.sha256.count == 64 && Quarantine.hasFlag(r.fileURL))
        let perms = (try FileManager.default.attributesOfItem(atPath: r.fileURL.path)[.posixPermissions] as? Int) ?? 0
        #expect(perms & 0o077 == 0)
        #expect(!FileManager.default.fileExists(atPath: r.fileURL.deletingLastPathComponent().appendingPathComponent("download.part").path))
    }

    @Test func downloadsRequireHTTPSAndRefuseBlockedTargets() async throws {
        let env = try ResearchFixtureEnv()
        let plain = await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "http://kenney.nl/files/good.zip", expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: tmp("dl"))
        if case .failure(let f) = plain { #expect(f.description.contains("https")) } else { Issue.record("plain http download") }
        for u in ["https://kenney.nl/redirect/private", "https://kenney.nl/redirect/file"] { if case .success = await dl(env, u.replacingOccurrences(of: "https://kenney.nl", with: "")) { Issue.record("\(u)") } }
        if case .success = await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "https://127.0.0.1/files/good.zip", expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: tmp("dl")) { Issue.record("loopback download") }
    }

    @Test func aWebPageMasqueradingAsAFileIsRefused() async throws {
        let env = try ResearchFixtureEnv()
        if case .failure(let f) = await dl(env, "/files/notzip.zip") { #expect(f.description.contains("web page")) } else { Issue.record("html as zip") }
        if case .failure(let f) = await dl(env, "/files/wrongmime.png") { _ = f } else { Issue.record("zip content named png") }
    }

    @Test func executablesAreRefusedAndNeverStored() async throws {
        let env = try ResearchFixtureEnv()
        let dir = tmp("dl")
        for p in ["/files/exe", "/files/script.sh"] {
            let r = await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "https://kenney.nl\(p)", expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: dir)
            if case .failure(let f) = r { #expect(f.description.contains("refused") || f.description.contains("executable"), "\(f)") } else { Issue.record("\(p) must be refused") }
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func publishedChecksumsAreComparedNotInvented() async throws {
        let env = try ResearchFixtureEnv()
        guard case .success(let ok) = await dl(env, "/files/good.zip") else { Issue.record("baseline"); return }
        if case .success(let r) = await dl(env, "/files/good.zip", sha: ok.sha256) { #expect(r.hashMatchesPublished == .yes) } else { Issue.record("matching sha256") }
        if case .success(let r) = await dl(env, "/files/good.zip", md5: ok.md5) { #expect(r.hashMatchesPublished == .yes) } else { Issue.record("matching md5") }
        let dir = tmp("dl")
        let bad = await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "https://kenney.nl/files/good.zip", expectedSHA256: String(repeating: "0", count: 64), expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: dir)
        if case .failure(let f) = bad { #expect(f.description.contains("checksum")) } else { Issue.record("a wrong published checksum must fail") }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
        if case .success(let r) = await dl(env, "/files/good.zip") { #expect(r.hashMatchesPublished == .unknown) }
    }

    @Test func partialAndOversizedDownloadsAreNeverValid() async throws {
        let env = try ResearchFixtureEnv()
        let shortDir = tmp("dl")
        let short = await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "https://kenney.nl/files/short.zip", expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: shortDir)
        if case .failure = short {} else { Issue.record("a short body must not become an artifact") }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: shortDir.path)) ?? []).isEmpty)
        var small = DownloadLimits(); small.maxBytes = 100_000
        let hugeDir = tmp("dl")
        let huge = await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "https://kenney.nl/files/huge.bin", expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: hugeDir, limits: small)
        if case .failure(let f) = huge { if case .tooLarge = f {} else { Issue.record("expected tooLarge, got \(f)") } } else { Issue.record("oversized") }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: hugeDir.path)) ?? []).isEmpty)
        var tiny = DownloadLimits(); tiny.maxBytes = 50_000
        let big = await Downloader(client: env.client).download(DownloadRequest(id: UUID(), url: "https://kenney.nl/files/slow.bin", expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: tmp("dl"), limits: tiny)
        if case .failure(let f) = big, case .tooLarge = f {} else { Issue.record("a body past the limit is stopped") }
    }

    @Test func cancellingADownloadLeavesNoFile() async throws {
        let env = try ResearchFixtureEnv()
        let dir = tmp("dl"); let client = env.client
        let task = Task { await Downloader(client: client).download(DownloadRequest(id: UUID(), url: "https://kenney.nl/files/slow.bin", expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: nil), into: dir) }
        try await Task.sleep(for: .milliseconds(600))
        let t0 = Date(); task.cancel()
        let r = await task.value
        if case .failure(let f) = r { #expect(f == .cancelled) } else { Issue.record("cancelled download must fail") }
        #expect(Date().timeIntervalSince(t0) < 2)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
    }

    @Test func theServiceRunsTheStateMachineAndWritesProvenance() async throws {
        let env = try ResearchFixtureEnv()
        let svc = service(env)
        var states: [AcquisitionState] = []
        let store = RecordingStore { states.append($0.state) }
        let s2 = AcquisitionService(downloader: Downloader(client: env.client), paths: svc.paths, store: store)
        let rec = await s2.acquire(candidate(), researchID: UUID(), taskID: UUID(), approved: false)
        #expect(rec.state == .readyForImport && rec.trust == .validatedForImport && rec.sha256?.count == 64 && rec.finalHost == "kenney.nl" && rec.detectedType == "zip")
        #expect(rec.inspection?.entryCount == 3 && rec.inspection?.codeBearing == CodeBearing.none)
        #expect(Array(states.prefix(4)) == [.discovered, .verifying, .eligible, .downloading])
        #expect(states.last == .readyForImport && !states.contains(.failed))
        let dir = s2.quarantineDirectory(rec.id)
        let prov = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("provenance.json"))) as? [String: Any]
        #expect(prov?["sha256"] as? String == rec.sha256 && prov?["license"] as? String == "CC0-1.0" && prov?["priceStateAtAcquisition"] as? String == "FREE_VERIFIED" && (prov?["sourceURL"] as? String)?.hasPrefix("https://kenney.nl") == true)
        #expect(s2.verifyStored(rec))
        // tampering is noticed
        try Data("tampered".utf8).write(to: s2.paths.acquisitions.appendingPathComponent(rec.quarantinePath!))
        #expect(!s2.verifyStored(rec))
    }

    @Test func hostileArtifactsAreRejectedAfterInspectionAndRemovedFromDisk() async throws {
        let env = try ResearchFixtureEnv()
        for (path, expect) in [("/files/traversal.zip", "traversal"), ("/files/symlink.zip", "symbolic"), ("/files/bomb.zip", "bomb")] {
            let svc = service(env)
            var c = candidate(url: "https://kenney.nl\(path)")
            c.name = "Hostile"
            let rec = await svc.acquire(c, researchID: UUID(), taskID: nil, approved: false)
            #expect(rec.state == .rejected && rec.trust == .rejected && (rec.failure ?? "").contains(expect) || (rec.failure ?? "").contains("MB"), "\(path): \(rec.failure ?? "-")")
            let dir = svc.quarantineDirectory(rec.id)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "provenance.json" }
            #expect(files.isEmpty, "the rejected artifact must be deleted: \(files)")
        }
    }

    @Test func approvalIsRequiredForUncertainCandidatesAndAccountBoundOnesAreNeverFetched() async throws {
        let env = try ResearchFixtureEnv()
        let svc = service(env)
        let uncertain = await svc.acquire(candidate(licence: .unknown), researchID: UUID(), taskID: nil, approved: false)
        #expect(uncertain.state == .approvalRequired && uncertain.sha256 == nil)
        let approved = await svc.acquire(candidate(licence: .unknown), researchID: UUID(), taskID: nil, approved: true)
        #expect(approved.state == .readyForImport)
        let acct = await svc.acquire(candidate(acq: .accountRequiredFree), researchID: UUID(), taskID: nil, approved: true)
        #expect(acct.state == .rejected && acct.sha256 == nil)                    // even an approval cannot make JARVIS act on an account
        let paid = await svc.acquire(candidate(acq: .paidPurchase), researchID: UUID(), taskID: nil, approved: true)
        #expect(paid.state == .rejected)
    }

    @Test func interruptedAcquisitionsAreMarkedAndTheirPartialFilesDeleted() throws {
        let paths = JarvisPaths.temporary("acqrec"); try paths.ensureDirectories()
        let svc = AcquisitionService(downloader: Downloader(client: WebClient()), paths: paths)
        var r = svc.newRecord(for: candidate(), researchID: nil, taskID: nil, licenseSourceURL: nil)
        svc.move(&r, to: .verifying); svc.move(&r, to: .eligible); svc.move(&r, to: .downloading)
        let dir = svc.quarantineDirectory(r.id); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: dir.appendingPathComponent("download.part"))
        let fixed = svc.reconcile([r])
        #expect(fixed.count == 1 && fixed[0].state == .interrupted && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("download.part").path))
        // an interrupted acquisition can only be resumed explicitly: no direct jump to "ready"
        #expect(!AcquisitionState.canMove(.interrupted, to: .readyForImport) && AcquisitionState.canMove(.interrupted, to: .verifying))
    }

    @Test func theStateMachineRejectsShortcuts() {
        #expect(!AcquisitionState.canMove(.discovered, to: .downloading) && !AcquisitionState.canMove(.downloading, to: .readyForImport) && !AcquisitionState.canMove(.rejected, to: .downloading))
        #expect(AcquisitionState.canMove(.downloaded, to: .inspecting) && AcquisitionState.canMove(.inspecting, to: .readyForImport))
    }
}

private final class RecordingStore: AcquisitionPersisting, @unchecked Sendable {
    private let lock = NSLock(); private let body: (AcquisitionRecord) -> Void
    init(_ body: @escaping (AcquisitionRecord) -> Void) { self.body = body }
    func save(_ record: AcquisitionRecord) { lock.lock(); body(record); lock.unlock() }
}

@Suite("Acquisition · import into a project", .serialized)
struct ImportTests {
    private func readyRecord(_ svc: AcquisitionService, zip: Data, name: String = "Pack") async throws -> AcquisitionRecord {
        let env = try ResearchFixtureEnv()
        _ = env
        let dir = svc.quarantineDirectory(UUID()); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pack.zip"); try zip.write(to: file)
        var c = CandidateRecord(researchID: UUID(), name: name, url: "https://kenney.nl/asset/x")
        c.price = PriceAssessment(state: .freeVerified, amount: 0, currency: nil, evidence: [], verifiedAt: Date(), note: nil)
        var r = svc.newRecord(for: c, researchID: nil, taskID: nil, licenseSourceURL: nil, id: UUID(uuidString: dir.lastPathComponent) ?? UUID())
        r.originalFilename = "pack.zip"; r.size = zip.count; r.sha256 = try AssetImporter.sha256(of: file); r.detectedType = "zip"
        r.quarantinePath = "\(dir.lastPathComponent)/pack.zip"
        let sniff = ArtifactSniffer.sniff(Data(zip.prefix(512)))
        r.inspection = svc.inspect(file: file, sniff: sniff, name: "pack.zip")
        r.state = .readyForImport; r.trust = .validatedForImport
        return r
    }

    private func project(unity: Bool = true) throws -> (String, WorkspaceGuard) {
        let root = tmp("proj")
        for d in unity ? ["Assets", "ProjectSettings"] : ["src"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        if unity { try Data("m_EditorVersion: 6000.0.23f1\n".utf8).write(to: root.appendingPathComponent("ProjectSettings/ProjectVersion.txt")) }
        return (root.path, try WorkspaceGuard(rootPath: root.path))
    }

    @Test func assetsAreCopiedWithMatchingHashesAndProvenance() async throws {
        let paths = JarvisPaths.temporary("imp"); try paths.ensureDirectories()
        let svc = AcquisitionService(downloader: Downloader(client: WebClient()), paths: paths)
        let rec = try await readyRecord(svc, zip: ResearchFixtureSite.goodZip(), name: "Kitchen Props")
        let (root, ws) = try project()
        let ex = try svc.extractForImport(rec)
        let plan = try AssetImporter.prepare(record: rec, extractedRoot: ex.root, files: ex.files, workspace: ws, unityProject: true, includeCode: false)
        #expect(plan.destination.hasPrefix("Assets/ThirdParty/Kitchen-Props-") && plan.files.count == 3 && !plan.includesCode)
        let report = try AssetImporter.apply(plan, record: rec, taskID: UUID(), workspace: ws)
        #expect(report.copied == 3 && report.hashesMatch)
        let prov = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/" + report.provenancePath))) as? [String: Any]
        #expect(prov?["artifactSHA256"] as? String == rec.sha256 && (prov?["note"] as? String)?.contains("nothing in it was executed") == true)
        for f in plan.files { #expect(try AssetImporter.sha256(of: URL(fileURLWithPath: root + "/" + plan.destination + "/" + f.relative)) == f.sha256) }
        // never overwrite
        #expect(throws: ImportError.self) { try AssetImporter.apply(plan, record: rec, taskID: UUID(), workspace: ws) }
    }

    @Test func scriptsNativeCodeAndExecutablesAreLeftOutUnlessCodeIsApprovedAndExecutablesNever() async throws {
        let paths = JarvisPaths.temporary("imp"); try paths.ensureDirectories()
        let svc = AcquisitionService(downloader: Downloader(client: WebClient()), paths: paths)
        let rec = try await readyRecord(svc, zip: ResearchFixtureSite.scriptsZip())
        let (_, ws) = try project()
        let ex = try svc.extractForImport(rec)
        let safe = try AssetImporter.prepare(record: rec, extractedRoot: ex.root, files: ex.files, workspace: ws, unityProject: true, includeCode: false)
        #expect(safe.files.map(\.relative) == ["Pack/Models/prop.fbx"] && safe.skipped.count == 4 && !safe.includesCode)
        let withCode = try AssetImporter.prepare(record: rec, extractedRoot: ex.root, files: ex.files, workspace: ws, unityProject: true, includeCode: true)
        #expect(withCode.includesCode && withCode.files.contains { $0.relative.hasSuffix("Thrower.cs") } && withCode.files.contains { $0.relative.hasSuffix("native.dylib") })
        #expect(!withCode.files.contains { $0.relative.hasSuffix("install.sh") })                 // an installer script is never imported, approved code or not
        #expect(withCode.flagged.contains { $0.hasPrefix("editor script") })
    }

    @Test func onlyReadyAndUntaintedArtifactsCanBeImported() async throws {
        let paths = JarvisPaths.temporary("imp"); try paths.ensureDirectories()
        let svc = AcquisitionService(downloader: Downloader(client: WebClient()), paths: paths)
        var rec = try await readyRecord(svc, zip: ResearchFixtureSite.goodZip())
        let (_, ws) = try project()
        let ex = try svc.extractForImport(rec)
        rec.state = .rejected
        #expect(throws: ImportError.self) { try AssetImporter.prepare(record: rec, extractedRoot: ex.root, files: ex.files, workspace: ws, unityProject: true, includeCode: false) }
        rec.state = .readyForImport; rec.trust = .rejected
        #expect(throws: ImportError.self) { try AssetImporter.prepare(record: rec, extractedRoot: ex.root, files: ex.files, workspace: ws, unityProject: true, includeCode: false) }
    }

    @Test func aRejectedArchiveCannotEvenBeExtractedForImport() async throws {
        let paths = JarvisPaths.temporary("imp"); try paths.ensureDirectories()
        let svc = AcquisitionService(downloader: Downloader(client: WebClient()), paths: paths)
        let rec = try await readyRecord(svc, zip: ResearchFixtureSite.traversalZip())
        #expect(throws: (any Error).self) { try svc.extractForImport(rec) }
    }

    @Test func nonUnityProjectsGetAThirdPartyFolderAtTheRoot() async throws {
        let paths = JarvisPaths.temporary("imp"); try paths.ensureDirectories()
        let svc = AcquisitionService(downloader: Downloader(client: WebClient()), paths: paths)
        let rec = try await readyRecord(svc, zip: ResearchFixtureSite.goodZip())
        let (_, ws) = try project(unity: false)
        let ex = try svc.extractForImport(rec)
        #expect(try AssetImporter.prepare(record: rec, extractedRoot: ex.root, files: ex.files, workspace: ws, unityProject: false, includeCode: false).destination.hasPrefix("ThirdParty/"))
    }
}
