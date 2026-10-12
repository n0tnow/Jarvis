import Foundation

/// File identification by CONTENT (magic bytes), not by name or by the server's Content-Type. Used to refuse "downloads" that are really web pages,
/// to spot executables inside an asset download, and to tell archives from plain assets.
enum ArtifactSniffer {
    struct Result: Equatable, Sendable {
        var kind: String                   // zip, gzip, tar, 7z, png, jpeg, fbx, gltf-binary, wav, ogg, executable-macho, script, html, …
        var isArchive: Bool
        var isExecutable: Bool             // would run if opened (Mach-O, ELF, PE, script with a shebang, installer)
        var isHTML: Bool
        var plausibleMIME: [String]
    }

    private static func has(_ d: Data, _ bytes: [UInt8], at offset: Int = 0) -> Bool {
        guard d.count >= offset + bytes.count else { return false }
        return d.subdata(in: offset..<(offset + bytes.count)).elementsEqual(bytes)
    }

    static func sniff(_ head: Data) -> Result {
        let d = head.prefix(8_192)
        func r(_ kind: String, archive: Bool = false, exec: Bool = false, html: Bool = false, mime: [String] = []) -> Result { Result(kind: kind, isArchive: archive, isExecutable: exec, isHTML: html, plausibleMIME: mime) }
        if has(d, [0x50, 0x4B, 0x03, 0x04]) || has(d, [0x50, 0x4B, 0x05, 0x06]) { return r("zip", archive: true, mime: ["application/zip", "application/x-zip-compressed", "application/octet-stream", "application/x-zip"]) }
        if has(d, [0x1F, 0x8B]) { return r("gzip", archive: true, mime: ["application/gzip", "application/x-gzip", "application/x-tar", "application/octet-stream"]) }
        if has(d, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return r("7z", archive: true, mime: ["application/x-7z-compressed", "application/octet-stream"]) }
        if has(d, [0x52, 0x61, 0x72, 0x21]) { return r("rar", archive: true, mime: ["application/vnd.rar", "application/x-rar-compressed", "application/octet-stream"]) }
        if has(d, Array("ustar".utf8), at: 257) { return r("tar", archive: true, mime: ["application/x-tar", "application/octet-stream"]) }
        if has(d, [0x89, 0x50, 0x4E, 0x47]) { return r("png", mime: ["image/png"]) }
        if has(d, [0xFF, 0xD8, 0xFF]) { return r("jpeg", mime: ["image/jpeg"]) }
        if has(d, Array("GIF8".utf8)) { return r("gif", mime: ["image/gif"]) }
        if has(d, Array("RIFF".utf8)) && has(d, Array("WAVE".utf8), at: 8) { return r("wav", mime: ["audio/wav", "audio/x-wav", "audio/wave", "application/octet-stream"]) }
        if has(d, Array("OggS".utf8)) { return r("ogg", mime: ["audio/ogg", "application/ogg", "application/octet-stream"]) }
        if has(d, Array("fLaC".utf8)) { return r("flac", mime: ["audio/flac", "audio/x-flac", "application/octet-stream"]) }
        if has(d, Array("ID3".utf8)) || (d.count > 2 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] & 0xE0 == 0xE0) { return r("mp3", mime: ["audio/mpeg", "audio/mp3", "application/octet-stream"]) }
        if has(d, Array("Kaydara FBX Binary".utf8)) { return r("fbx-binary", mime: ["application/octet-stream", "model/fbx", "application/x-fbx"]) }
        if has(d, Array("glTF".utf8)) { return r("gltf-binary", mime: ["model/gltf-binary", "application/octet-stream"]) }
        if has(d, Array("BLENDER".utf8)) { return r("blend", mime: ["application/x-blender", "application/octet-stream"]) }
        // executables / installers
        if has(d, [0xCF, 0xFA, 0xED, 0xFE]) || has(d, [0xCE, 0xFA, 0xED, 0xFE]) || has(d, [0xFE, 0xED, 0xFA, 0xCE]) || has(d, [0xFE, 0xED, 0xFA, 0xCF]) || has(d, [0xCA, 0xFE, 0xBA, 0xBE]) { return r("executable-macho", exec: true) }
        if has(d, [0x7F, 0x45, 0x4C, 0x46]) { return r("executable-elf", exec: true) }
        if has(d, [0x4D, 0x5A]) { return r("executable-pe", exec: true) }
        if has(d, Array("xar!".utf8)) { return r("installer-pkg", archive: true, exec: true) }
        if has(d, [0x23, 0x21]) { return r("script-shebang", exec: true) }
        let text = String(decoding: d, as: UTF8.self)
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.contains("<head>") || lower.hasPrefix("<?xml") && lower.contains("<html") { return r("html", html: true, mime: ["text/html"]) }
        if has(d, Array("; FBX".utf8)) { return r("fbx-ascii", mime: ["text/plain", "application/octet-stream"]) }
        if lower.hasPrefix("{"), lower.contains("\"asset\""), lower.contains("\"version\"") { return r("gltf-json", mime: ["model/gltf+json", "application/json", "application/octet-stream"]) }
        if lower.hasPrefix("{") || lower.hasPrefix("[") { return r("json", mime: ["application/json", "text/plain"]) }
        if text.hasPrefix("# ") || text.hasPrefix("v ") || text.hasPrefix("mtllib") { return r("obj-text", mime: ["text/plain", "model/obj", "application/octet-stream"]) }
        let printable = d.prefix(512).allSatisfy { $0 == 9 || $0 == 10 || $0 == 13 || ($0 >= 32 && $0 < 127) || $0 >= 0x80 }
        return r(printable ? "text" : "binary", mime: printable ? ["text/plain", "application/octet-stream"] : ["application/octet-stream"])
    }

    /// Extensions that run code or install software when opened. An asset download containing one is flagged; one that IS one is refused.
    static let executableExtensions: Set<String> = ["app", "pkg", "dmg", "exe", "msi", "bat", "cmd", "com", "scr", "sh", "command", "bash", "zsh", "csh", "ps1", "vbs", "jar", "apk", "ipa", "deb", "rpm", "run", "bin", "workflow", "action", "scpt", "applescript", "terminal", "dylib", "so", "dll", "bundle", "kext", "plugin", "framework", "xpc", "appex"]
    static let nativeLibraryExtensions: Set<String> = ["dll", "so", "dylib", "bundle", "a", "lib", "framework", "aar", "jar", "xpc", "kext"]
    static let scriptExtensions: Set<String> = ["cs", "js", "ts", "py", "rb", "pl", "lua", "php", "sh", "command", "bat", "ps1", "cmd", "asmdef", "dll"]

    /// Does the content agree with what the server and the file name claim?
    static func mismatch(declaredMIME: String?, filename: String, sniffed: Result) -> String? {
        if sniffed.isHTML { return "the “download” is a web page, not a file (probably a login, consent or error page)" }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let archiveExt: Set<String> = ["zip", "7z", "rar", "gz", "tgz", "tar", "unitypackage"]
        if archiveExt.contains(ext), !sniffed.isArchive { return "the file name says .\(ext) but the content is \(sniffed.kind)" }
        if ["png", "jpg", "jpeg", "wav", "ogg", "mp3", "fbx", "glb", "blend"].contains(ext) {
            let expect: [String: [String]] = ["png": ["png"], "jpg": ["jpeg"], "jpeg": ["jpeg"], "wav": ["wav"], "ogg": ["ogg"], "mp3": ["mp3"], "fbx": ["fbx-binary", "fbx-ascii", "text"], "glb": ["gltf-binary"], "blend": ["blend", "gzip", "zip"]]
            if let ok = expect[ext], !ok.contains(sniffed.kind) { return "the file name says .\(ext) but the content is \(sniffed.kind)" }
        }
        if sniffed.isExecutable, !executableExtensions.contains(ext) { return "the content is an executable (\(sniffed.kind)) although the name says .\(ext.isEmpty ? "?" : ext)" }
        if let m = declaredMIME?.lowercased(), !m.isEmpty, !sniffed.plausibleMIME.isEmpty, !sniffed.plausibleMIME.contains(m), m != "binary/octet-stream", !m.hasPrefix("application/x-"), !m.contains("octet") {
            return "the server says \(m) but the content looks like \(sniffed.kind)"
        }
        return nil
    }
}
