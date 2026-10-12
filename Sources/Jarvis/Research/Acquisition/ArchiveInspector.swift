import Foundation
import Compression

struct ArchiveLimits: Sendable, Equatable {
    var maxEntries = 5_000
    var maxUncompressedBytes = 1_500_000_000
    var maxEntryBytes = 700_000_000
    var maxRatio: Double = 150          // uncompressed ÷ compressed, per archive and per large entry
    var maxDepth = 40
    var maxNameLength = 512
    var maxDirectoryBytes = 32_000_000  // central directory / tar listing read into memory
}

struct ArchiveEntry: Sendable, Equatable {
    var name: String
    var compressed: Int
    var uncompressed: Int
    var isDirectory: Bool
    var isSymlink = false
    var isHardlink = false
    var isSpecial = false               // device, fifo, socket
    var isEncrypted = false
    var unixMode: UInt32?
    var method = 0
    var localOffset = 0
    var crc32: UInt32 = 0
    var isExecutableMode: Bool { (unixMode ?? 0) & 0o111 != 0 && !isDirectory }
}

enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    case limit(String)
    case unsafe(String)
    var description: String {
        switch self { case .malformed(let s): "malformed archive: \(s)"; case .unsupported(let s): "unsupported archive: \(s)"; case .limit(let s): "archive limit exceeded: \(s)"; case .unsafe(let s): "unsafe archive: \(s)" }
    }
}

enum ArchiveInspector {
    // MARK: Entry-name safety (pure)

    /// nil = safe relative path; otherwise why the name is refused. Both separators are treated as separators.
    static func unsafeReason(_ rawName: String, limits: ArchiveLimits = ArchiveLimits()) -> String? {
        if rawName.isEmpty { return "empty entry name" }
        if rawName.count > limits.maxNameLength { return "entry name is too long" }
        if rawName.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7f }) { return "control characters in an entry name" }
        let n = rawName.replacingOccurrences(of: "\\", with: "/")
        if n.hasPrefix("/") { return "absolute path “\(rawName.prefix(60))”" }
        if n.range(of: "^[A-Za-z]:", options: .regularExpression) != nil { return "drive-letter path “\(rawName.prefix(60))”" }
        if n.hasPrefix("~") { return "home-relative path" }
        let parts = n.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") { return "path traversal “\(rawName.prefix(60))”" }
        if parts.count > limits.maxDepth { return "path nesting is too deep" }
        return nil
    }

    static func normalized(_ rawName: String) -> String {
        rawName.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.joined(separator: "/")
    }

    // MARK: Inspect

    /// Lists the archive WITHOUT extracting anything and judges it. The result's `rejectedReason` is non-nil when the archive must not be extracted.
    static func inspect(fileURL: URL, kind: String, limits: ArchiveLimits = ArchiveLimits()) throws -> (inspection: ArtifactInspection, entries: [ArchiveEntry]) {
        let entries: [ArchiveEntry]
        var extraPaths: [String] = []
        switch kind {
        case "zip": entries = try listZIP(fileURL, limits: limits)
        case "gzip": (entries, extraPaths) = try listTarGz(fileURL, limits: limits)
        default: throw ArchiveError.unsupported(kind)
        }
        return (judge(entries: entries, kind: kind, assetPaths: extraPaths, archiveSize: (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0, limits: limits), entries)
    }

    static func judge(entries: [ArchiveEntry], kind: String, assetPaths: [String] = [], archiveSize: Int, limits: ArchiveLimits) -> ArtifactInspection {
        var findings: [String] = []
        var rejected: String?
        func reject(_ why: String) { if rejected == nil { rejected = why }; findings.append("REJECTED: " + why) }
        var total = 0, scripts = false, editor = false, native = false, exec = false
        var maxRatio = 0.0
        var seen = Set<String>()
        if entries.count > limits.maxEntries { reject("more than \(limits.maxEntries) entries (\(entries.count))") }
        for e in entries {
            total += e.uncompressed
            if let why = unsafeReason(e.name, limits: limits) { reject(why); continue }
            if e.isSymlink { reject("symbolic link “\(e.name.prefix(60))” (could point outside the quarantine)") }
            if e.isHardlink { reject("hard link “\(e.name.prefix(60))”") }
            if e.isSpecial { reject("device / special file “\(e.name.prefix(60))”") }
            if e.isEncrypted { reject("password-protected entry “\(e.name.prefix(60))” cannot be inspected") }
            if e.uncompressed > limits.maxEntryBytes { reject("entry “\(e.name.prefix(60))” is larger than \(limits.maxEntryBytes / 1_000_000) MB") }
            let ratio = e.compressed > 0 ? Double(e.uncompressed) / Double(e.compressed) : (e.uncompressed > 0 ? .infinity : 0)
            if e.uncompressed > 1_000_000, ratio > limits.maxRatio { reject("entry “\(e.name.prefix(60))” expands \(ratio.isInfinite ? "without bound" : "\(Int(ratio))×") (decompression bomb)") }
            maxRatio = max(maxRatio, ratio.isInfinite ? 1e9 : ratio)
            if !seen.insert(normalized(e.name).lowercased()).inserted { findings.append("duplicate entry name (case-insensitive): \(e.name.prefix(60))") }
            let ext = URL(fileURLWithPath: e.name).pathExtension.lowercased()
            let lowerName = normalized(e.name).lowercased()
            if ArtifactSniffer.scriptExtensions.contains(ext) && !["dll"].contains(ext) { scripts = true }
            if ext == "cs", lowerName.contains("/editor/") || lowerName.hasPrefix("editor/") { editor = true }
            if ArtifactSniffer.nativeLibraryExtensions.contains(ext) { native = true }
            if ArtifactSniffer.executableExtensions.contains(ext) || e.isExecutableMode && !["", "meta"].contains(ext) && !ArtifactSniffer.nativeLibraryExtensions.contains(ext) { exec = true }
            if lowerName.contains(".app/") || lowerName.hasSuffix(".app") { exec = true }
        }
        if total > limits.maxUncompressedBytes { reject("expands to \(total / 1_000_000) MB (limit \(limits.maxUncompressedBytes / 1_000_000) MB)") }
        let overall = archiveSize > 0 ? Double(total) / Double(archiveSize) : 0
        if total > 50_000_000, overall > limits.maxRatio { reject("overall expansion \(Int(overall))× (decompression bomb)") }
        maxRatio = max(maxRatio, overall)
        if scripts { findings.append("contains scripts / source code — read before importing; nothing is executed by JARVIS") }
        if editor { findings.append("contains Unity EDITOR scripts — they run inside the Unity Editor when imported (higher risk)") }
        if native { findings.append("contains native libraries (dll/dylib/so/…) — platform support and trust must be checked") }
        if exec { findings.append("contains executable / installer content — never run by JARVIS; the importer skips it unless you approve it explicitly") }
        let cb: CodeBearing = native ? .nativeLibraries : editor ? .editorScripts : scripts ? .scripts : .none
        let sample = (assetPaths.isEmpty ? entries.map(\.name) : assetPaths).prefix(14).map { String($0.prefix(110)) }
        return ArtifactInspection(kind: kind, entryCount: entries.count, uncompressedBytes: total, maxCompressionRatio: maxRatio, hasScripts: scripts, hasEditorScripts: editor, hasNativeLibraries: native, hasExecutables: exec,
                                  findings: findings, rejectedReason: rejected, sampleEntries: Array(sample), codeBearing: cb)
    }

    // MARK: ZIP (central directory; ZIP64 aware)

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }
    private static func u64(_ d: Data, _ o: Int) -> Int { u32(d, o) | u32(d, o + 4) << 32 }

    static func listZIP(_ url: URL, limits: ArchiveLimits) throws -> [ArchiveEntry] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = Int(try fh.seekToEnd())
        guard size >= 22 else { throw ArchiveError.malformed("too small for a zip file") }
        let tailLen = min(size, 66_000)
        try fh.seek(toOffset: UInt64(size - tailLen))
        let tail = try fh.read(upToCount: tailLen) ?? Data()
        guard let eocdRel = (0...(max(0, tail.count - 22))).reversed().first(where: { tail.count >= $0 + 22 && u32(tail, $0) == 0x06054b50 }) else { throw ArchiveError.malformed("no end-of-central-directory record") }
        var total = u16(tail, eocdRel + 10), cdSize = u32(tail, eocdRel + 12), cdOffset = u32(tail, eocdRel + 16)
        if (total == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF), eocdRel >= 20, u32(tail, eocdRel - 20) == 0x07064b50 {
            let eocd64 = u64(tail, eocdRel - 20 + 8)
            try fh.seek(toOffset: UInt64(eocd64))
            guard let r = try fh.read(upToCount: 56), r.count >= 56, u32(r, 0) == 0x06064b50 else { throw ArchiveError.malformed("bad ZIP64 record") }
            total = u64(r, 32); cdSize = u64(r, 40); cdOffset = u64(r, 48)
        }
        guard cdSize <= limits.maxDirectoryBytes else { throw ArchiveError.limit("central directory is \(cdSize / 1_000_000) MB") }
        guard total <= limits.maxEntries * 4 else { throw ArchiveError.limit("\(total) entries declared") }
        guard cdOffset + cdSize <= size else { throw ArchiveError.malformed("central directory lies outside the file") }
        try fh.seek(toOffset: UInt64(cdOffset))
        let cd = try fh.read(upToCount: cdSize) ?? Data()
        var out: [ArchiveEntry] = []
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x02014b50 {
            if out.count > limits.maxEntries * 2 { throw ArchiveError.limit("more than \(limits.maxEntries * 2) entries") }
            let madeBy = u16(cd, p + 4), flags = u16(cd, p + 8), method = u16(cd, p + 10), crc = UInt32(truncatingIfNeeded: u32(cd, p + 16))
            var csize = u32(cd, p + 20), usize = u32(cd, p + 24)
            let nlen = u16(cd, p + 28), elen = u16(cd, p + 30), clen = u16(cd, p + 32), ext = u32(cd, p + 38)
            var lofs = u32(cd, p + 42)
            guard p + 46 + nlen + elen + clen <= cd.count else { throw ArchiveError.malformed("truncated central directory") }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nlen))
            let name = flags & 0x800 != 0 ? String(decoding: nameData, as: UTF8.self) : (String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "")
            var q = p + 46 + nlen
            let extraEnd = q + elen
            while q + 4 <= extraEnd {                                       // ZIP64 extended information
                let id = u16(cd, q), len = u16(cd, q + 2)
                if id == 0x0001 {
                    var r = q + 4
                    if usize == 0xFFFFFFFF, r + 8 <= extraEnd { usize = u64(cd, r); r += 8 }
                    if csize == 0xFFFFFFFF, r + 8 <= extraEnd { csize = u64(cd, r); r += 8 }
                    if lofs == 0xFFFFFFFF, r + 8 <= extraEnd { lofs = u64(cd, r) }
                }
                q += 4 + len
            }
            let isUnix = (madeBy >> 8) == 3
            let mode: UInt32? = isUnix ? UInt32(truncatingIfNeeded: ext >> 16) : nil
            let fmt = (mode ?? 0) & 0o170000
            var e = ArchiveEntry(name: name, compressed: csize, uncompressed: usize, isDirectory: name.hasSuffix("/") || fmt == 0o040000, isSymlink: fmt == 0o120000,
                                 isSpecial: [0o020000, 0o060000, 0o010000, 0o140000].contains(fmt), isEncrypted: flags & 1 != 0, unixMode: mode, method: method, localOffset: lofs, crc32: crc)
            if isUnix == false, ext & 0x400 != 0 { e.isSymlink = false }   // DOS reparse bit is not interpreted
            out.append(e)
            p += 46 + nlen + elen + clen
        }
        if total > 0, out.isEmpty { throw ArchiveError.malformed("no entries could be read") }
        return out
    }

    // MARK: Safe extraction (ZIP) — only into a directory JARVIS created, only after `judge` accepted the archive

    struct ExtractionReport: Equatable, Sendable { var files: Int; var bytes: Int; var skipped: [String] }

    static func extractZIP(_ url: URL, entries: [ArchiveEntry], to destination: URL, limits: ArchiveLimits = ArchiveLimits(), shouldContinue: () -> Bool = { true }) throws -> ExtractionReport {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let src = try FileHandle(forReadingFrom: url)
        defer { try? src.close() }
        var files = 0, bytes = 0
        var skipped: [String] = []
        for e in entries {
            guard shouldContinue() else { throw CancellationError() }
            if let why = unsafeReason(e.name, limits: limits) { throw ArchiveError.unsafe(why) }
            if e.isSymlink || e.isHardlink || e.isSpecial || e.isEncrypted { throw ArchiveError.unsafe("entry “\(e.name.prefix(60))” is not a plain file or directory") }
            let rel = normalized(e.name)
            if rel.isEmpty { continue }
            let target = destination.appendingPathComponent(rel)
            let resolved = target.standardizedFileURL.path
            guard resolved == root || resolved.hasPrefix(root + "/") else { throw ArchiveError.unsafe("entry “\(e.name.prefix(60))” would leave the quarantine") }
            if e.isDirectory { try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); continue }
            guard e.method == 0 || e.method == 8 else { skipped.append("\(rel) (compression method \(e.method) is not supported)"); continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: target.path) { throw ArchiveError.unsafe("duplicate entry “\(rel.prefix(60))”") }
            // local header → data offset
            try src.seek(toOffset: UInt64(e.localOffset))
            guard let lh = try src.read(upToCount: 30), lh.count == 30, u32(lh, 0) == 0x04034b50 else { throw ArchiveError.malformed("bad local header for “\(rel.prefix(60))”") }
            let dataStart = e.localOffset + 30 + u16(lh, 26) + u16(lh, 28)
            try src.seek(toOffset: UInt64(dataStart))
            guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ArchiveError.malformed("cannot create “\(rel.prefix(60))”") }
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            var written = 0
            var crc = CRC32()
            let cap = min(e.uncompressed + 1, limits.maxEntryBytes)
            func emit(_ buf: UnsafeBufferPointer<UInt8>) throws {
                guard buf.count > 0 else { return }
                written += buf.count; bytes += buf.count
                if written > cap || bytes > limits.maxUncompressedBytes { throw ArchiveError.limit("entry “\(rel.prefix(60))” produced more data than it declared") }
                crc.update(buf)
                try out.write(contentsOf: Data(buf))
            }
            var remaining = e.compressed
            if e.method == 0 {
                while remaining > 0 { guard let chunk = try src.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else { throw ArchiveError.malformed("truncated data") }; remaining -= chunk.count; try chunk.withUnsafeBytes { try emit($0.bindMemory(to: UInt8.self)) } }
            } else {
                let inflater = try RawInflater()
                while remaining > 0 {
                    guard let chunk = try src.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else { throw ArchiveError.malformed("truncated data") }
                    remaining -= chunk.count
                    try inflater.feed(chunk, last: remaining == 0, sink: emit)
                }
                if e.compressed == 0 { try inflater.feed(Data(), last: true, sink: emit) }
            }
            guard written == e.uncompressed else { throw ArchiveError.malformed("“\(rel.prefix(60))” has the wrong size") }
            if e.crc32 != 0 || written == 0, crc.value != e.crc32, !(written == 0 && e.crc32 == 0) { throw ArchiveError.malformed("“\(rel.prefix(60))” fails its CRC check") }
            files += 1
        }
        return ExtractionReport(files: files, bytes: bytes, skipped: skipped)
    }

    // MARK: gzip + tar (listing only: .tar.gz, .tgz, .unitypackage)

    static func listTarGz(_ url: URL, limits: ArchiveLimits) throws -> (entries: [ArchiveEntry], assetPaths: [String]) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let head = try fh.read(upToCount: 4_096), head.count >= 18, head[0] == 0x1F, head[1] == 0x8B, head[2] == 8 else { throw ArchiveError.malformed("not a gzip stream") }
        let flg = head[3]
        var p = 10
        if flg & 4 != 0 { p += 2 + u16(head, p) }
        if flg & 8 != 0 { while p < head.count, head[p] != 0 { p += 1 }; p += 1 }
        if flg & 16 != 0 { while p < head.count, head[p] != 0 { p += 1 }; p += 1 }
        if flg & 2 != 0 { p += 2 }
        guard p < head.count else { throw ArchiveError.malformed("bad gzip header") }
        try fh.seek(toOffset: UInt64(p))
        let parser = TarStreamParser(limits: limits)
        let inflater = try RawInflater()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var consumed = p
        while true {
            guard let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            consumed += chunk.count
            let isLast = consumed >= fileSize
            try inflater.feed(isLast ? chunk.dropLast(min(8, chunk.count)) : chunk, last: isLast) { buf in try parser.consume(buf) }
            if parser.finished { break }
        }
        return (parser.entries, parser.assetPaths)
    }
}

/// Minimal ustar / GNU-long-name / pax-path reader that never writes anything: it counts bytes and records names, types and sizes.
final class TarStreamParser {
    private(set) var entries: [ArchiveEntry] = []
    private(set) var assetPaths: [String] = []
    private(set) var finished = false
    private let limits: ArchiveLimits
    private var buffer = Data()
    private var current: (entry: ArchiveEntry, remaining: Int, padding: Int, capture: String?)?
    private var captured = Data()
    private var pendingLongName: String?
    private var pendingPaxPath: String?
    private var totalBytes = 0
    private var zeroBlocks = 0

    init(limits: ArchiveLimits) { self.limits = limits }

    func consume(_ buf: UnsafeBufferPointer<UInt8>) throws {
        guard !finished, buf.count > 0 else { return }
        totalBytes += buf.count
        if totalBytes > limits.maxUncompressedBytes + limits.maxEntries * 1024 { throw ArchiveError.limit("archive expands past \(limits.maxUncompressedBytes / 1_000_000) MB") }
        buffer.append(contentsOf: buf)
        while true {
            if var cur = current {
                let take = min(cur.remaining + cur.padding, buffer.count)
                guard take > 0 else { return }
                let dataPart = min(cur.remaining, take)
                if cur.capture != nil, captured.count < 4_096 { captured.append(buffer.prefix(min(dataPart, 4_096 - captured.count))) }
                buffer.removeFirst(take)
                let dataLeft = cur.remaining - dataPart
                let padLeft = cur.padding - (take - dataPart)
                cur.remaining = dataLeft; cur.padding = padLeft
                if dataLeft == 0 && padLeft == 0 { try finishEntry(cur); current = nil } else { current = cur; return }
                continue
            }
            guard buffer.count >= 512 else { return }
            let header = buffer.prefix(512); buffer.removeFirst(512)
            if header.allSatisfy({ $0 == 0 }) { zeroBlocks += 1; if zeroBlocks >= 2 { finished = true; return }; continue }
            zeroBlocks = 0
            try beginEntry(Data(header))
        }
    }

    private func field(_ h: Data, _ o: Int, _ n: Int) -> String {
        let s = h.subdata(in: (h.startIndex + o)..<(h.startIndex + o + n))
        return String(decoding: s.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    private func octal(_ h: Data, _ o: Int, _ n: Int) -> Int {
        let raw = h.subdata(in: (h.startIndex + o)..<(h.startIndex + o + n))
        if let f = raw.first, f & 0x80 != 0 { return raw.dropFirst().reduce(0) { $0 << 8 | Int($1) } }          // base-256 for huge sizes
        return Int(String(decoding: raw.prefix(while: { $0 != 0 && $0 != 0x20 }), as: UTF8.self).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
    }

    private func beginEntry(_ h: Data) throws {
        let type = h[h.startIndex + 156]
        let size = octal(h, 124, 12)
        let mode = UInt32(truncatingIfNeeded: octal(h, 100, 8))
        var name = field(h, 0, 100)
        let prefix = field(h, 345, 155)
        if !prefix.isEmpty { name = prefix + "/" + name }
        if size < 0 || size > limits.maxEntryBytes { throw ArchiveError.limit("tar entry of \(size / 1_000_000) MB") }
        let padding = (512 - size % 512) % 512
        let t = Character(UnicodeScalar(type == 0 ? 0x30 : type))
        switch t {
        case "L": current = (ArchiveEntry(name: "", compressed: size, uncompressed: size, isDirectory: false), size, padding, "gnu-long-name"); captured = Data()
        case "x": current = (ArchiveEntry(name: "", compressed: size, uncompressed: size, isDirectory: false), size, padding, "pax"); captured = Data()
        case "g", "K": current = (ArchiveEntry(name: "", compressed: size, uncompressed: size, isDirectory: false), size, padding, nil)
        default:
            var e = ArchiveEntry(name: pendingLongName ?? pendingPaxPath ?? name, compressed: size, uncompressed: size, isDirectory: t == "5", unixMode: mode)
            e.isSymlink = t == "2"; e.isHardlink = t == "1"; e.isSpecial = ["3", "4", "6"].contains(t)
            pendingLongName = nil; pendingPaxPath = nil
            let leaf = (e.name as NSString).lastPathComponent
            let capture = (!e.isDirectory && leaf == "pathname" && size <= 4_096) ? "pathname" : nil
            captured = Data()
            current = (e, size, padding, capture)
            if entries.count >= limits.maxEntries * 2 { throw ArchiveError.limit("more than \(limits.maxEntries * 2) entries") }
        }
        if size == 0 && padding == 0, let cur = current { try finishEntry(cur); current = nil }
    }

    private func finishEntry(_ cur: (entry: ArchiveEntry, remaining: Int, padding: Int, capture: String?)) throws {
        switch cur.capture {
        case "gnu-long-name": pendingLongName = String(decoding: captured.prefix(while: { $0 != 0 }), as: UTF8.self)
        case "pax":
            for line in String(decoding: captured, as: UTF8.self).split(separator: "\n") {
                if let eq = line.firstIndex(of: "="), line[..<eq].hasSuffix("path") { pendingPaxPath = String(line[line.index(after: eq)...]) }
            }
        case "pathname":
            let p = String(decoding: captured.prefix(while: { $0 != 0 && $0 != 10 }), as: UTF8.self)
            if !p.isEmpty { assetPaths.append(p) }
            entries.append(cur.entry)
        default:
            if cur.entry.name.isEmpty { return }
            entries.append(cur.entry)
        }
    }
}

// MARK: - Raw DEFLATE (zip entries, gzip body) via the system Compression framework

final class RawInflater {
    private var stream: UnsafeMutablePointer<compression_stream>
    private let outBuf: UnsafeMutablePointer<UInt8>
    private let outSize = 1 << 17
    private var done = false

    init() throws {
        stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        stream.initialize(to: compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil))
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ArchiveError.unsupported("cannot start the decompressor") }
    }
    deinit { compression_stream_destroy(stream); stream.deallocate(); outBuf.deallocate() }

    /// Feeds compressed bytes; `sink` receives decompressed chunks.
    func feed(_ data: Data, last: Bool, sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        if done { return }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            stream.pointee.src_ptr = base.map { UnsafePointer($0) } ?? UnsafePointer(outBuf)
            stream.pointee.src_size = data.count
            while true {
                stream.pointee.dst_ptr = outBuf; stream.pointee.dst_size = outSize
                let status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                let produced = outSize - stream.pointee.dst_size
                if produced > 0 { try sink(UnsafeBufferPointer(start: outBuf, count: produced)) }
                if status == COMPRESSION_STATUS_END { done = true; return }
                if status == COMPRESSION_STATUS_ERROR { throw ArchiveError.malformed("corrupt compressed data") }
                if stream.pointee.src_size == 0 && stream.pointee.dst_size != 0 { return }
            }
        }
    }
}

struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; return c }
    private var state: UInt32 = 0xFFFFFFFF
    mutating func update(_ buf: UnsafeBufferPointer<UInt8>) { for b in buf { state = Self.table[Int((state ^ UInt32(b)) & 0xFF)] ^ (state >> 8) } }
    var value: UInt32 { state ^ 0xFFFFFFFF }
}
