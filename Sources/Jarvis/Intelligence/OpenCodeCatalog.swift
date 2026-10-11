import Foundation

/// One model as reported by `opencode models --verbose` (fields we use; everything else ignored).
struct OpenCodeModelInfo: Equatable, Sendable {
    var providerID: String
    var modelID: String
    var name: String
    var status: String?
    var apiURL: String?
    var costInput: Double?
    var costOutput: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
    var contextLimit: Int?
    var supportsTools: Bool?
    var supportsReasoning: Bool?
    /// v2 only (`Model.Info.enabled`); nil for the classic catalog.
    var enabled: Bool?
    /// The classic catalog carries the endpoint URL (host-checked); the v2 `Model.Info` schema has none.
    var hasEndpointURL = true

    var fullID: String { "\(providerID)/\(modelID)" }
}

/// Pure parser for `opencode models [provider] --verbose`: blocks of `provider/model` followed by a pretty-printed JSON object.
enum OpenCodeCatalog {
    static func parse(_ output: String) -> [OpenCodeModelInfo] {
        let lines = output.components(separatedBy: "\n")
        var result: [OpenCodeModelInfo] = []
        var i = 0
        while i < lines.count {
            let header = lines[i].trimmingCharacters(in: .whitespaces)
            guard isModelHeader(header), i + 1 < lines.count, lines[i + 1].hasPrefix("{") else { i += 1; continue }
            var j = i + 1
            var block = ""
            var depth = 0, inString = false, escaped = false, done = false
            while j < lines.count, !done {
                let line = lines[j]
                block += line + "\n"
                for ch in line {
                    if inString {
                        if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                    } else if ch == "\"" { inString = true }
                    else if ch == "{" { depth += 1 }
                    else if ch == "}" { depth -= 1; if depth == 0 { done = true } }
                }
                j += 1
            }
            if done, let info = decode(header: header, json: block) { result.append(info) }
            i = j
        }
        return result
    }

    /// OpenCode 1.19+ (v2): `opencode api model.list` → `{"location":…,"data":[Model.Info…]}` (documented operation).
    /// `cost` is an ARRAY of tiers; a model is only zero-priced if EVERY tier component is zero, so the maxima are taken.
    static func parseModelList(_ output: String) -> [OpenCodeModelInfo] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))) as? [String: Any],
              let data = obj["data"] as? [[String: Any]] else { return [] }
        func num(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue) }
        var out: [OpenCodeModelInfo] = []
        for m in data {
            guard let id = m["id"] as? String, let provider = m["providerID"] as? String else { continue }
            let tiers = (m["cost"] as? [[String: Any]]) ?? []
            func maxOf(_ pick: ([String: Any]) -> Double?) -> Double? {
                let vals = tiers.compactMap(pick)
                return vals.count == tiers.count && !vals.isEmpty ? vals.max() : nil       // any tier with a missing price ⇒ unknown
            }
            let caps = m["capabilities"] as? [String: Any]
            out.append(OpenCodeModelInfo(
                providerID: provider, modelID: (m["modelID"] as? String) ?? id, name: (m["name"] as? String) ?? id,
                status: m["status"] as? String, apiURL: nil,
                costInput: maxOf { num($0["input"]) }, costOutput: maxOf { num($0["output"]) },
                cacheRead: maxOf { num(($0["cache"] as? [String: Any])?["read"]) }, cacheWrite: maxOf { num(($0["cache"] as? [String: Any])?["write"]) },
                contextLimit: ((m["limit"] as? [String: Any])?["context"] as? NSNumber)?.intValue,
                supportsTools: caps?["tools"] as? Bool, supportsReasoning: nil,
                enabled: m["enabled"] as? Bool, hasEndpointURL: false))
        }
        return out
    }

    /// `provider/model` ids only (the non-verbose listing).
    static func parseIDs(_ output: String) -> [String] {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(isModelHeader)
    }

    private static func isModelHeader(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._/:-]*$"#, options: .regularExpression) != nil
    }

    private static func decode(header: String, json: String) -> OpenCodeModelInfo? {
        guard let data = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let parts = header.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let cost = o["cost"] as? [String: Any]
        let cache = cost?["cache"] as? [String: Any]
        let caps = o["capabilities"] as? [String: Any]
        func num(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue) }
        return OpenCodeModelInfo(
            providerID: (o["providerID"] as? String) ?? parts[0],
            modelID: (o["id"] as? String) ?? parts[1],
            name: (o["name"] as? String) ?? parts[1],
            status: o["status"] as? String,
            apiURL: (o["api"] as? [String: Any])?["url"] as? String,
            costInput: num(cost?["input"]), costOutput: num(cost?["output"]),
            cacheRead: num(cache?["read"]), cacheWrite: num(cache?["write"]),
            contextLimit: ((o["limit"] as? [String: Any])?["context"] as? NSNumber)?.intValue,
            supportsTools: caps?["toolcall"] as? Bool, supportsReasoning: caps?["reasoning"] as? Bool)
    }
}

/// How catalog data becomes registry records. THE cost rule lives here (DEC-022):
///   price verified zero (all components) + status active + keyless Zen provider  → FREE pool
///   price missing/unreadable                                                      → unknown (never routed automatically)
///   any component > 0                                                             → paid (blocked)
/// A model is NEVER free because of its name, a cached flag, or a third-party list.
enum OpenCodeModelRegistry {
    /// Providers whose zero-priced models are served by the keyless OpenCode Zen free tier. `opencode-go` is a
    /// credentialed plan and is deliberately NOT here.
    static let keylessFreeProviders: Set<String> = ["opencode"]
    static let freeHost = "opencode.ai"

    /// How long a "free" verification stays valid without re-reading provider data.
    static let verificationMaxAge: TimeInterval = 24 * 3600

    /// A model can stay `active` in the catalog while the API already answers 404/410 ("has been deprecated"). The provider
    /// error text and the registry marker below let JARVIS block it even though the catalog still lists it.
    static let removedErrorText = "model removed"
    static let removedMarker = "provider reports the model as removed (404/410)"
    static let removedSticky: TimeInterval = 24 * 3600

    static func pricing(of m: OpenCodeModelInfo) -> PricingStatus {
        guard let i = m.costInput, let o = m.costOutput, i >= 0, o >= 0 else { return .unknown }
        let cache = [m.cacheRead, m.cacheWrite].compactMap { $0 }
        if cache.contains(where: { $0 < 0 }) { return .unknown }
        return (i == 0 && o == 0 && cache.allSatisfy { $0 == 0 }) ? .verifiedZero : .paid
    }

    /// Documented data handling (OpenCode Zen docs, read 2026-10-11). Unlisted models are `.unknown` → treated as "may train".
    static func dataPolicy(forProviderModel id: String) -> DataPolicy {
        switch id {
        case "space-bunny-free", "longcat-2.5-preview-free", "step-5-preview-free": return .zeroRetention
        case "big-pickle", "exo-free", "mimo-v2.6-flash-free", "mimo-v2.5-free", "ling-3.1-flash-free",
             "ling-3.0-flash-fin-free", "muse-spark-1.3-contributor-free": return .mayTrain
        case "nemotron-3-ultra-free", "nemotron-3.5-lightning-free": return .trialLogged
        default: return .unknown
        }
    }

    static func record(from m: OpenCodeModelInfo, verifiedAt: Date, source: String, existing: ModelRecord? = nil) -> ModelRecord {
        var r = existing ?? ModelRecord(id: m.fullID, engine: .openCode, provider: m.providerID, providerModelID: m.modelID, displayName: m.name)
        r.displayName = m.name
        r.availability = (m.status == "active" && m.enabled != false) ? .available : (m.status == nil ? .unknown : .unavailable)
        r.pricingStatus = pricing(of: m)
        r.inputPrice = m.costInput; r.outputPrice = m.costOutput
        r.contextLimit = m.contextLimit
        r.dataPolicy = dataPolicy(forProviderModel: m.modelID)
        r.capabilities.supportsTools = m.supportsTools ?? false
        r.capabilities.supportsReasoning = m.supportsReasoning ?? false
        r.capabilities.supportsStreaming = false          // OpenCode run output is message-level (docs/OPENCODE_RESEARCH.md)
        r.updatedAt = verifiedAt

        let host = m.apiURL.flatMap { URLComponents(string: $0)?.host }
        // Classic catalog: the endpoint must be the Zen host. v2 `Model.Info` has no URL: the provider id is the (documented) signal.
        let keyless = keylessFreeProviders.contains(m.providerID) && (host == freeHost || !m.hasEndpointURL)
        // A model the API itself reported as removed stays blocked for a day, whatever the catalog says.
        if let e = existing, e.blockedReason == removedMarker, let at = e.lastHealthCheck, verifiedAt.timeIntervalSince(at) < removedSticky {
            r.freeVerified = false; r.availability = .unavailable; r.blockedReason = removedMarker
            return r
        }
        if r.blockedReason == removedMarker { r.blockedReason = nil }
        switch r.pricingStatus {
        case .verifiedZero where keyless && r.availability == .available:
            r.freeVerified = true; r.freeVerifiedAt = verifiedAt; r.freeVerificationSource = source
            if r.blockedReason?.hasPrefix("provider data") == true || r.blockedReason?.hasPrefix("served through") == true { r.blockedReason = nil }
        case .verifiedZero where !keyless:
            r.freeVerified = false
            r.blockedReason = "served through a credentialed plan (\(m.providerID)), not the keyless free tier"
        case .verifiedZero:
            r.freeVerified = false
            r.blockedReason = "provider data: model not active"
        case .paid:
            r.freeVerified = false
            r.blockedReason = "provider data: price > 0"
        case .unknown:
            r.freeVerified = false
            r.blockedReason = "provider data: price unknown"
        }
        return r
    }

    /// True when the free verification is recent enough to rely on (stale ⇒ re-read provider data first).
    static func isVerificationFresh(_ m: ModelRecord, now: Date = Date()) -> Bool {
        guard m.freeVerified, let at = m.freeVerifiedAt else { return false }
        return now.timeIntervalSince(at) <= verificationMaxAge
    }
}
