import Foundation
import CryptoKit

struct PlannedImportFile: Equatable, Sendable { var relative: String; var size: Int; var sourcePath: String; var sha256: String }
struct SkippedImportFile: Equatable, Sendable { var relative: String; var reason: String }

struct ImportPlan: Equatable, Sendable {
    var destination: String                 // project-relative folder, e.g. Assets/ThirdParty/Kitchen-1a2b3c
    var files: [PlannedImportFile]
    var skipped: [SkippedImportFile]
    var totalBytes: Int
    var includesCode: Bool
    var flagged: [String]
}

struct ImportReport: Equatable, Sendable {
    var destination: String
    var copied: Int
    var bytes: Int
    var skipped: Int
    var provenancePath: String
    var hashesMatch: Bool
}

enum ImportError: Error, Equatable, CustomStringConvertible {
    case notReady(String), destinationExists(String), limit(String), workspace(String), hashMismatch(String), io(String)
    var description: String {
        switch self {
        case .notReady(let w): "not ready to import: \(w)"; case .destinationExists(let p): "the destination already exists (\(p)); JARVIS never overwrites"
        case .limit(let w): "import limit: \(w)"; case .workspace(let w): w; case .hashMismatch(let p): "a copied file does not match its source (\(p))"; case .io(let w): "disk error: \(w)"
        }
    }
}

/// Copies the files of a quarantined, inspected artifact into a project — the ONLY write path for third-party assets. It is a typed tool of a V0.4
/// development task: workspace-guarded, bounded, never overwrites, never imports executables, native libraries or scripts unless the user approved
/// code, verifies every copied file by hash and leaves a provenance file next to the result.
enum AssetImporter {
    static let maxFiles = 3_000
    static let maxBytes = 500_000_000

    static func slug(_ name: String) -> String {
        let s = name.unicodeScalars.map { ($0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil)) ? Character($0) : "-" }
        let joined = String(s).replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return joined.isEmpty ? "Asset" : String(joined.prefix(40))
    }

    static func prepare(record: AcquisitionRecord, extractedRoot: URL, files: [String], workspace: WorkspaceGuard, unityProject: Bool, includeCode: Bool) throws -> ImportPlan {
        guard record.state == .readyForImport, record.trust != .rejected else { throw ImportError.notReady("the artifact is \(record.state.rawValue.uppercased()) / \(record.trust.rawValue)") }
        let base = unityProject ? "Assets/ThirdParty" : "ThirdParty"
        let destination = "\(base)/\(slug(record.name))-\(record.id.uuidString.prefix(6).lowercased())"
        let destURL: URL
        do { destURL = try workspace.resolve(destination) } catch { throw ImportError.workspace("\(error)") }
        if FileManager.default.fileExists(atPath: destURL.path) { throw ImportError.destinationExists(destination) }
        var planned: [PlannedImportFile] = [], skipped: [SkippedImportFile] = [], flagged: [String] = []
        var total = 0, code = false
        for rel in files {
            let lower = rel.lowercased()
            let comps = rel.split(separator: "/").map(String.init)
            let ext = URL(fileURLWithPath: rel).pathExtension.lowercased()
            if comps.contains("__MACOSX") || comps.last == ".DS_Store" || comps.last?.hasPrefix("._") == true { skipped.append(SkippedImportFile(relative: rel, reason: "macOS metadata")); continue }
            if WorkspaceGuard.isProtected(comps) { skipped.append(SkippedImportFile(relative: rel, reason: "protected file name")); continue }
            if ArtifactSniffer.executableExtensions.contains(ext) && !ArtifactSniffer.nativeLibraryExtensions.contains(ext) { skipped.append(SkippedImportFile(relative: rel, reason: "executable / installer content is never imported")); continue }
            if ArtifactSniffer.nativeLibraryExtensions.contains(ext) { if !includeCode { skipped.append(SkippedImportFile(relative: rel, reason: "native library — needs explicit approval of code")); continue }; code = true; flagged.append("native: \(rel)") }
            if ext == "meta" { skipped.append(SkippedImportFile(relative: rel, reason: "foreign .meta files can carry conflicting GUIDs; Unity creates its own")); continue }
            if ["cs", "js", "asmdef", "asmref", "py", "lua", "sh", "rb", "pl"].contains(ext) {
                if !includeCode { skipped.append(SkippedImportFile(relative: rel, reason: "script / source code — needs explicit approval of code")); continue }
                code = true; flagged.append((lower.contains("/editor/") || lower.hasPrefix("editor/") ? "editor script: " : "script: ") + rel)
            }
            let src = extractedRoot.appendingPathComponent(rel)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: src.path), (attrs[.type] as? FileAttributeType) == .typeRegular, let size = attrs[.size] as? Int else { skipped.append(SkippedImportFile(relative: rel, reason: "not a regular file")); continue }
            total += size
            if planned.count + 1 > maxFiles { throw ImportError.limit("more than \(maxFiles) files") }
            if total > maxBytes { throw ImportError.limit("more than \(maxBytes / 1_000_000) MB") }
            planned.append(PlannedImportFile(relative: rel, size: size, sourcePath: src.path, sha256: try sha256(of: src)))
        }
        guard !planned.isEmpty else { throw ImportError.notReady("nothing importable remains after the safety rules (\(skipped.count) file(s) skipped)") }
        return ImportPlan(destination: destination, files: planned, skipped: skipped, totalBytes: total, includesCode: code, flagged: flagged)
    }

    static func apply(_ plan: ImportPlan, record: AcquisitionRecord, taskID: UUID, workspace: WorkspaceGuard, shouldContinue: () -> Bool = { true }) throws -> ImportReport {
        let fm = FileManager.default
        let destURL: URL
        do { destURL = try workspace.resolve(plan.destination) } catch { throw ImportError.workspace("\(error)") }
        if fm.fileExists(atPath: destURL.path) { throw ImportError.destinationExists(plan.destination) }
        var matched = true
        do {
            try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            for f in plan.files {
                guard shouldContinue() else { throw CancellationError() }
                let target: URL
                do { target = try workspace.resolve(plan.destination + "/" + f.relative) } catch { throw ImportError.workspace("\(error)") }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(atPath: f.sourcePath, toPath: target.path)
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)           // no exec bit, ever
                if try sha256(of: target) != f.sha256 { matched = false; throw ImportError.hashMismatch(f.relative) }
            }
            struct Provenance: Codable {
                var importedBy = "JARVIS V0.9"; var acquisitionID: String; var taskID: String; var name: String; var sourceURL: String; var downloadURL: String?; var publisher: String?; var license: String?; var licenseSourceURL: String?
                var priceStateAtAcquisition: String?; var artifactSHA256: String?; var originalFilename: String?; var importedAt: Date; var fileCount: Int; var skipped: [String]; var includesCode: Bool; var note: String
            }
            let prov = Provenance(acquisitionID: record.id.uuidString, taskID: taskID.uuidString, name: record.name, sourceURL: record.sourceURL, downloadURL: record.downloadURL, publisher: record.publisher, license: record.licenseID,
                                  licenseSourceURL: record.licenseSourceURL, priceStateAtAcquisition: record.priceState?.rawValue, artifactSHA256: record.sha256, originalFilename: record.originalFilename, importedAt: Date(), fileCount: plan.files.count,
                                  skipped: plan.skipped.map { "\($0.relative): \($0.reason)" }, includesCode: plan.includesCode,
                                  note: "Third-party asset. Keep its licence terms. Imported by JARVIS from a quarantined, hash-verified download; nothing in it was executed.")
            let provURL = destURL.appendingPathComponent("JARVIS-PROVENANCE.json")
            try JSONEncoder.pretty.encode(prov).write(to: provURL, options: .atomic)
            return ImportReport(destination: plan.destination, copied: plan.files.count, bytes: plan.totalBytes, skipped: plan.skipped.count, provenancePath: plan.destination + "/JARVIS-PROVENANCE.json", hashesMatch: matched)
        } catch {
            try? fm.removeItem(at: destURL)                    // a half-copied import is removed (the destination did not exist before)
            if let e = error as? ImportError { throw e }
            if error is CancellationError { throw error }
            throw ImportError.io("\(error)")
        }
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
