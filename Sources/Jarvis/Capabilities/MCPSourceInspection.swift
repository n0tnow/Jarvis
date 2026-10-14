import Foundation

// MARK: - Source inspection of a candidate (V0.14, DEC-227): download the repository snapshot, list it, extract it, scan it, delete it. Nothing is executed.

extension MCPDiscovery {
    /// Downloads the repository's source snapshot (zip, ≤ 12 MB, https only, through the V0.9 downloader), checks the archive listing, extracts with `ditto`, scans, and removes the folder.
    /// Returns nil when the snapshot could not be fetched or its listing is unsafe.
    func inspectSource(of r: MCPDiscoveryRecord, workRoot: URL) async -> MCPInspection? {
        guard let snapshot = Self.sourceSnapshotURL(of: r) else { return nil }
        let dir = workRoot.appendingPathComponent("inspect-" + UUID().uuidString.prefix(8), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dl = Downloader(client: client)
        var limits = DownloadLimits(); limits.maxBytes = 12_000_000; limits.sessionBudget = 12_000_000; limits.overallTimeout = 120
        let req = DownloadRequest(id: UUID(), url: snapshot.url, expectedSHA256: nil, expectedMD5: nil, expectedSize: nil, suggestedName: "\(snapshot.name).zip")
        guard case .success(let result) = await dl.download(req, into: dir, limits: limits) else { return nil }
        guard let listing = try? ArchiveInspector.listZIP(result.fileURL, limits: ArchiveLimits()), listing.count <= 6000, !listing.contains(where: { ArchiveInspector.unsafeReason($0.name) != nil }) else { return nil }
        let out = dir.appendingPathComponent("src", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let ex = await ManagedProcess.runOnce(executable: "/usr/bin/ditto", arguments: ["-x", "-k", result.fileURL.path, out.path], environment: ["PATH": "/usr/bin:/bin"], timeout: 60), ex.exitCode == 0 else { return nil }
        return MCPInspector.scan(directory: out)
    }
}
