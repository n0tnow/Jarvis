import Foundation
import Darwin

// MARK: - Addresses

/// A resolved or literal network address (4 or 16 bytes). Security decisions use the BYTES, never the text.
enum NetworkAddress: Equatable, Sendable, CustomStringConvertible {
    case v4([UInt8])
    case v6([UInt8])

    var description: String {
        switch self {
        case .v4(let b): return b.map(String.init).joined(separator: ".")
        case .v6(let b):
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) { parts.append(String(format: "%x", Int(b[i]) << 8 | Int(b[i + 1]))) }
            return parts.joined(separator: ":")
        }
    }
}

/// "Is this a public, globally routable internet address?" — the SSRF boundary. Everything that is loopback, private, link-local, shared,
/// documentation, multicast, reserved or a transition-mechanism wrapper around such an address is refused.
enum AddressClassifier {
    /// Parses a host that is a numeric address in ANY of the legacy IPv4 spellings (`2130706433`, `0x7f.1`, `0177.0.0.1`, `127.1`) or IPv6.
    static func parseLiteral(_ rawHost: String) -> NetworkAddress? {
        var host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        guard !host.isEmpty else { return nil }
        var v6 = in6_addr()
        if host.contains(":"), inet_pton(AF_INET6, host, &v6) == 1 {
            return .v6(withUnsafeBytes(of: &v6) { Array($0) })
        }
        // inet_aton accepts the classic abbreviated/octal/hex forms that browsers (and many HTTP stacks) also accept.
        let looksNumeric = host.allSatisfy { $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" }
        guard looksNumeric else { return nil }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            let n = UInt32(bigEndian: v4.s_addr)
            return .v4([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        }
        return nil
    }

    /// nil = public; otherwise the reason it is refused.
    static func nonPublicReason(_ a: NetworkAddress) -> String? {
        switch a {
        case .v4(let b): return v4Reason(b)
        case .v6(let b): return v6Reason(b)
        }
    }
    static func isPublic(_ a: NetworkAddress) -> Bool { nonPublicReason(a) == nil }

    private static func v4Reason(_ b: [UInt8]) -> String? {
        guard b.count == 4 else { return "malformed IPv4" }
        let a0 = b[0], a1 = b[1], a2 = b[2]
        switch a0 {
        case 0: return "this-network (0.0.0.0/8)"
        case 10: return "private network (10.0.0.0/8)"
        case 127: return "loopback (127.0.0.0/8)"
        case 100 where (64...127).contains(a1): return "shared address space (100.64.0.0/10)"
        case 169 where a1 == 254: return "link-local / cloud metadata (169.254.0.0/16)"
        case 172 where (16...31).contains(a1): return "private network (172.16.0.0/12)"
        case 192 where a1 == 168: return "private network (192.168.0.0/16)"
        case 192 where a1 == 0 && (a2 == 0 || a2 == 2): return "reserved / documentation (192.0.0.0/24, 192.0.2.0/24)"
        case 192 where a1 == 88 && a2 == 99: return "6to4 relay (192.88.99.0/24)"
        case 198 where a1 == 18 || a1 == 19: return "benchmarking (198.18.0.0/15)"
        case 198 where a1 == 51 && a2 == 100: return "documentation (198.51.100.0/24)"
        case 203 where a1 == 0 && a2 == 113: return "documentation (203.0.113.0/24)"
        case 224...239: return "multicast"
        case 240...255: return "reserved / broadcast"
        default: return nil
        }
    }

    private static func v6Reason(_ b: [UInt8]) -> String? {
        guard b.count == 16 else { return "malformed IPv6" }
        let allZeroPrefix = b[0..<10].allSatisfy { $0 == 0 }
        if b.allSatisfy({ $0 == 0 }) { return "unspecified (::)" }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return "loopback (::1)" }
        if allZeroPrefix && b[10] == 0xff && b[11] == 0xff { return v4Reason(Array(b[12..<16])).map { "IPv4-mapped \($0)" } }          // ::ffff:a.b.c.d
        if b[0..<12].allSatisfy({ $0 == 0 }) { return "IPv4-compatible / reserved (::/96)" }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) { return v4Reason(Array(b[12..<16])).map { "NAT64 \($0)" } }
        if b[0] == 0x01, b[1] == 0x00, b[2..<8].allSatisfy({ $0 == 0 }) { return "discard-only (100::/64)" }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x00, b[3] == 0x00 { return "Teredo (2001::/32)" }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return "documentation (2001:db8::/32)" }
        if b[0] == 0x20, b[1] == 0x02 { return v4Reason(Array(b[2..<6])).map { "6to4 \($0)" } }                                            // 2002::/16 wraps an IPv4
        if b[0] & 0xfe == 0xfc { return "unique local (fc00::/7)" }
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return "link-local (fe80::/10)" }
        if b[0] == 0xfe, b[1] & 0xc0 == 0xc0 { return "site-local (fec0::/10)" }
        if b[0] == 0xff { return "multicast (ff00::/8)" }
        return nil
    }
}

// MARK: - URL policy

enum URLRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case scheme(String)
    case userinfo
    case host(String)
    case privateAddress(String)
    case port(Int)
    case tooLong
    case insecureDownload
    case redirectDowngrade
    case tooManyRedirects
    case resolutionFailed(String)

    var description: String {
        switch self {
        case .malformed(let w): "malformed URL (\(w))"
        case .scheme(let s): "scheme “\(s)” is not allowed (only http/https)"
        case .userinfo: "credentials inside a URL are not allowed"
        case .host(let w): "host refused (\(w))"
        case .privateAddress(let w): "address refused (\(w))"
        case .port(let p): "port \(p) is not allowed"
        case .tooLong: "URL is too long"
        case .insecureDownload: "downloads require https"
        case .redirectDowngrade: "a redirect from https to http was refused"
        case .tooManyRedirects: "too many redirects"
        case .resolutionFailed(let h): "the host could not be resolved (\(h))"
        }
    }
}

struct ValidatedURL: Equatable, Sendable {
    var url: URL
    var host: String
    var port: Int
    var isHTTPS: Bool
    var literal: NetworkAddress?
}

/// Pure URL validation. Security decisions use PARSED components (never substring checks). Public research may only reach the public
/// internet: localhost, private ranges, link-local/cloud-metadata, `file:`, `ftp:`, custom schemes and credentials-in-URL are refused.
struct URLPolicy: Sendable {
    var allowedSchemes: Set<String> = ["http", "https"]
    var allowedPorts: Set<Int> = [80, 443, 8080, 8443]
    var maxLength = 2048
    static let production = URLPolicy()

    private static let blockedSuffixes = [".localhost", ".local", ".internal", ".lan", ".home", ".corp", ".intranet", ".home.arpa", ".localdomain"]
    private static let blockedHosts: Set<String> = ["localhost", "ip6-localhost", "ip6-loopback", "metadata", "metadata.google.internal", "instance-data"]

    /// The authority exactly as written (between `//` and the first `/ ? #`), so an encoded host cannot hide behind Foundation's decoding.
    static func rawAuthority(_ s: String) -> String {
        guard let r = s.range(of: "//") else { return "" }
        let rest = s[r.upperBound...]
        return String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }

    func validate(_ raw: String) -> Result<ValidatedURL, URLRejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.malformed("empty")) }
        guard trimmed.count <= maxLength else { return .failure(.tooLong) }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == "\\" || $0 == " " }) { return .failure(.malformed("control character, space or backslash")) }
        if Self.rawAuthority(trimmed).contains("%") { return .failure(.host("percent-encoded host")) }          // Foundation would silently decode it
        guard let comps = URLComponents(string: trimmed), let url = comps.url else { return .failure(.malformed("not parseable")) }
        return validate(url: url, components: comps)
    }

    func validate(url: URL) -> Result<ValidatedURL, URLRejection> {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.malformed("not parseable")) }
        return validate(url: url, components: comps)
    }

    private func validate(url: URL, components comps: URLComponents) -> Result<ValidatedURL, URLRejection> {
        guard let scheme = comps.scheme?.lowercased(), !scheme.isEmpty else { return .failure(.malformed("no scheme")) }
        guard allowedSchemes.contains(scheme) else { return .failure(.scheme(scheme)) }
        if comps.user != nil || comps.password != nil { return .failure(.userinfo) }
        guard var host = comps.host?.lowercased(), !host.isEmpty else { return .failure(.host("no host")) }
        // IDNA treats these as dots and compatibility-maps full-width digits/letters to ASCII: decide on the FOLDED form (so "１２７.０.０.１" is 127.0.0.1).
        for dot in ["\u{3002}", "\u{FF61}", "\u{FF0E}", "\u{2024}"] { host = host.replacingOccurrences(of: dot, with: ".") }
        host = host.precomposedStringWithCompatibilityMapping.lowercased()
        if host.hasSuffix(".") { host.removeLast() }                                                    // "localhost." is localhost
        if host.contains("%") { return .failure(.host("percent-encoded host")) }
        if !host.unicodeScalars.allSatisfy({ $0.isASCII }) {                                            // an internationalised name: letters, digits, hyphen and dots only
            guard host.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "-" || $0 == "." || $0.properties.generalCategory == .nonspacingMark }) else { return .failure(.host("invalid characters")) }
        }
        let port = comps.port ?? (scheme == "https" ? 443 : 80)
        let literal = AddressClassifier.parseLiteral(host)
        do {
            guard allowedPorts.contains(port) else { return .failure(.port(port)) }
            if let literal {
                if let why = AddressClassifier.nonPublicReason(literal) { return .failure(.privateAddress(why)) }
            } else {
                if Self.blockedHosts.contains(host) { return .failure(.host(host)) }
                if Self.blockedSuffixes.contains(where: { host.hasSuffix($0) }) { return .failure(.host("internal name “\(host)”")) }
                if !host.contains(".") { return .failure(.host("single-label name “\(host)”")) }
                if host.split(separator: ".").contains(where: { $0.isEmpty || $0.count > 63 }) { return .failure(.host("malformed name")) }
                if host.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0.unicodeScalars.contains { $0.properties.generalCategory == .nonspacingMark }) }) { return .failure(.host("invalid characters")) }
            }
        }
        return .success(ValidatedURL(url: url, host: host, port: port, isHTTPS: scheme == "https", literal: literal))
    }

    /// After DNS: EVERY address the name resolved to must be public (one private answer is enough to refuse — DNS-rebinding style tricks).
    func checkResolved(_ addresses: [NetworkAddress], for v: ValidatedURL) -> URLRejection? {
        guard !addresses.isEmpty else { return .resolutionFailed(v.host) }
        for a in addresses { if let why = AddressClassifier.nonPublicReason(a) { return .privateAddress("\(v.host) → \(a): \(why)") } }
        return nil
    }

    /// A redirect must pass the same checks again, may not leave https, and the chain is bounded.
    func checkRedirect(from: ValidatedURL, to rawLocation: URL, hop: Int, maxHops: Int = 5) -> Result<ValidatedURL, URLRejection> {
        if hop > maxHops { return .failure(.tooManyRedirects) }
        switch validate(url: rawLocation) {
        case .failure(let e): return .failure(e)
        case .success(let next):
            if from.isHTTPS && !next.isHTTPS { return .failure(.redirectDowngrade) }
            return .success(next)
        }
    }
}

// MARK: - DNS

protocol HostResolving: Sendable {
    func resolve(_ host: String) async throws -> [NetworkAddress]
}

/// getaddrinfo on a background queue (system resolver, no third-party DNS).
struct SystemHostResolver: HostResolving {
    func resolve(_ host: String) async throws -> [NetworkAddress] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(host, nil, &hints, &res)
                guard rc == 0, let first = res else { cont.resume(throwing: URLRejection.resolutionFailed(host)); return }
                defer { freeaddrinfo(first) }
                var out: [NetworkAddress] = []
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let cur = p {
                    if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr {
                        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in
                            let n = UInt32(bigEndian: s.pointee.sin_addr.s_addr)
                            out.append(.v4([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]))
                        }
                    } else if cur.pointee.ai_family == AF_INET6, let sa = cur.pointee.ai_addr {
                        sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in
                            out.append(.v6(withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) }))
                        }
                    }
                    p = cur.pointee.ai_next
                }
                cont.resume(returning: out)
            }
        }
    }
}

/// Policy + DNS in one place: nothing is requested before `authorize` says yes, and every redirect hop asks again.
actor URLGate {
    let policy: URLPolicy
    private let resolver: any HostResolving
    private var cache: [String: (at: Date, addresses: [NetworkAddress])] = [:]

    init(policy: URLPolicy = .production, resolver: any HostResolving = SystemHostResolver()) { self.policy = policy; self.resolver = resolver }

    func authorize(_ raw: String) async -> Result<ValidatedURL, URLRejection> {
        switch policy.validate(raw) { case .failure(let e): return .failure(e); case .success(let v): return await resolveAndCheck(v) }
    }
    func authorize(url: URL) async -> Result<ValidatedURL, URLRejection> {
        switch policy.validate(url: url) { case .failure(let e): return .failure(e); case .success(let v): return await resolveAndCheck(v) }
    }

    func authorizeRedirect(from: ValidatedURL, to location: URL, hop: Int) async -> Result<ValidatedURL, URLRejection> {
        switch policy.checkRedirect(from: from, to: location, hop: hop) { case .failure(let e): return .failure(e); case .success(let v): return await resolveAndCheck(v) }
    }

    private func resolveAndCheck(_ v: ValidatedURL) async -> Result<ValidatedURL, URLRejection> {
        if let lit = v.literal { return policy.checkResolved([lit], for: v).map { .failure($0) } ?? .success(v) }
        if let hit = cache[v.host], Date().timeIntervalSince(hit.at) < 60 { return policy.checkResolved(hit.addresses, for: v).map { .failure($0) } ?? .success(v) }
        do {
            let addrs = try await resolver.resolve(v.host)
            cache[v.host] = (Date(), addrs)
            if cache.count > 200 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < 60 } }
            return policy.checkResolved(addrs, for: v).map { .failure($0) } ?? .success(v)
        } catch let e as URLRejection { return .failure(e) } catch { return .failure(.resolutionFailed(v.host)) }
    }
}

// MARK: - Canonical and storable forms

enum CanonicalURL {
    private static let trackingKeys: Set<String> = ["fbclid", "gclid", "gclsrc", "dclid", "msclkid", "yclid", "mc_cid", "mc_eid", "igshid", "ref", "ref_src", "ref_url", "spm", "_hsenc", "_hsmi", "mkt_tok", "s_cid", "cmpid", "oly_enc_id", "oly_anon_id", "vero_id", "wickedid"]

    /// Lower-cased scheme/host, default port and fragment dropped, tracking parameters removed, remaining parameters sorted.
    static func make(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased(); c.fragment = nil
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        if let items = c.queryItems {
            let kept = items.filter { i in let k = i.name.lowercased(); return !(k.hasPrefix("utm_") || trackingKeys.contains(k)) }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        var path = c.percentEncodedPath
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        c.percentEncodedPath = path
        return c.string ?? url.absoluteString
    }

    /// Key used to recognise the same source behind mirrors/tracking variants (`www.` and a trailing slash do not make a new source).
    static func dedupeKey(_ url: URL) -> String {
        var s = make(url).lowercased()
        s = s.replacingOccurrences(of: "://www.", with: "://")
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
        return s
    }

    private static let secretQueryKeys = try! NSRegularExpression(pattern: "^(?:token|access_token|id_token|auth|authorization|key|api[_-]?key|apikey|sig|signature|secret|password|passwd|session|sid|jwt|code|x-amz-[a-z-]+|x-goog-[a-z-]+|googleaccessid|policy|se|sp|sv|sr|st|skoid|sktid)$", options: .caseInsensitive)

    /// What may be stored/logged: no credentials, no query values that look like tokens or signatures (redirect and CDN URLs carry them).
    static func forStorage(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return OutputSanitizer.sanitize(url.absoluteString) }
        c.user = nil; c.password = nil; c.fragment = nil
        if let items = c.queryItems {
            c.queryItems = items.map { i in
                let isSecret = secretQueryKeys.firstMatch(in: i.name, range: NSRange(i.name.startIndex..., in: i.name)) != nil
                return isSecret ? URLQueryItem(name: i.name, value: "REDACTED") : URLQueryItem(name: i.name, value: i.value.map { OutputSanitizer.sanitize(String($0.prefix(200))) })
            }
        }
        return OutputSanitizer.sanitize(c.string ?? url.absoluteString)
    }
    static func forStorage(_ raw: String) -> String { URL(string: raw).map(forStorage) ?? OutputSanitizer.sanitize(String(raw.prefix(300))) }
}
