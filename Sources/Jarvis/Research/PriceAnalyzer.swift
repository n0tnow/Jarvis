import Foundation

/// Current-price verification (V0.9). "Free" is a FACT that needs CURRENT evidence from an AUTHORITATIVE source (the marketplace page, the
/// publisher's product page, the registry/API). It is never inferred from a search snippet, an old article, a forum post, a cached "$0",
/// or a file name containing "free". Everything that cannot be shown stays UNKNOWN — and UNKNOWN is never treated as free.
struct PriceInput: Sendable {
    var sourceID: UUID
    var url: String
    var authoritative: Bool             // official product page, marketplace listing, publisher site, official API
    var snippetOnly: Bool               // seen only as a search-result snippet
    var retrievedAt: Date
    var page: ExtractedPage?
    var structured: (amount: Double, currency: String?)?      // from an API response
    var text: String
}

enum PriceAnalyzer {
    private static let currencySymbols: [Character: String] = ["$": "USD", "€": "EUR", "£": "GBP", "₺": "TRY", "¥": "JPY"]

    static func assess(_ inputs: [PriceInput], now: Date = Date(), freshness: Freshness = .current) -> PriceAssessment {
        guard !inputs.isEmpty else { return .unknown }
        let usable = inputs.filter { !$0.snippetOnly }
        guard !usable.isEmpty else {
            var a = PriceAssessment.unknown
            a.note = "only search snippets were seen — a snippet is not evidence for price"
            return a
        }
        let verdicts = usable.map { (input: $0, verdict: examine($0)) }
        let authoritative = verdicts.filter { $0.input.authoritative }
        guard !authoritative.isEmpty else {
            var a = PriceAssessment.unknown
            if let v = verdicts.first(where: { $0.verdict.state == .freeVerified || $0.verdict.state == .paidVerified }) {
                a.note = "a non-official page says \(v.verdict.state == .freeVerified ? "free" : "paid") — not accepted as evidence; the official listing was not available"
            } else { a.note = "no official page was readable" }
            return a
        }
        // Newest authoritative evidence wins; a stale one cannot make a current claim.
        let newest = authoritative.max { $0.input.retrievedAt < $1.input.retrievedAt }!
        let decided = authoritative.filter { [.freeVerified, .paidVerified].contains($0.verdict.state) }
        if Set(decided.map { $0.verdict.state }).count > 1 {
            var a = PriceAssessment.unknown
            a.note = "official sources disagree about the price (free vs paid) — verify manually"
            a.evidence = decided.compactMap { $0.verdict.evidence }
            return a
        }
        var result = newest.verdict
        if let first = decided.first { result = first.verdict }
        var out = PriceAssessment(state: result.state, amount: result.amount, currency: result.currency, evidence: authoritative.compactMap { $0.verdict.evidence }.prefix(3).map { $0 },
                                  verifiedAt: newest.input.retrievedAt, note: result.note)
        if now.timeIntervalSince(newest.input.retrievedAt) > freshness.maxAge, [.freeVerified, .paidVerified].contains(out.state) {
            out.note = ((out.note.map { $0 + "; " }) ?? "") + "evidence is older than \(Int(freshness.maxAge / 3600)) h — re-verify before acting"
        }
        return out
    }

    struct Verdict { var state: PriceState; var amount: Double?; var currency: String?; var evidence: EvidenceRef?; var note: String? }

    static func examine(_ input: PriceInput) -> Verdict {
        func ev(_ excerpt: String, _ field: String) -> EvidenceRef { EvidenceRef(sourceID: input.sourceID, excerpt: String(excerpt.prefix(240)), field: field, retrievedAt: input.retrievedAt) }
        let page = input.page
        if page?.isLoginWall == true { return Verdict(state: .requiresLoginToVerify, note: "the page needs a login before it shows a price") }
        if page?.isCaptchaChallenge == true { return Verdict(state: .unknown, note: "the site showed a CAPTCHA challenge instead of the page") }

        // 1. an API/structured amount
        if let s = input.structured { return classify(amount: s.amount, currency: s.currency, text: input.text, evidence: ev("price \(s.amount) \(s.currency ?? "")", "api.price")) }

        // 2. schema.org JSON-LD offers
        if let page {
            for node in page.jsonLD {
                let offers = node["offers"].map { $0.array ?? [$0] } ?? (node["@type"]?.string == "Offer" ? [node] : [])
                for offer in offers {
                    let avail = offer["availability"]?.string?.lowercased() ?? ""
                    if avail.contains("outofstock") || avail.contains("discontinued") || avail.contains("soldout") { return Verdict(state: .unavailable, evidence: ev("availability: \(avail)", "jsonld.offers.availability"), note: "the listing says it is not available") }
                    if let price = offer["price"]?.double ?? offer["lowPrice"]?.double {
                        let cur = offer["priceCurrency"]?.string
                        return classify(amount: price, currency: cur, text: input.text, evidence: ev("price \(offer["price"]?.string ?? offer["lowPrice"]?.string ?? "?") \(cur ?? "")", "jsonld.offers.price"))
                    }
                }
            }
            // 3. meta tags
            if let amount = (page.meta["product:price:amount"] ?? page.meta["og:price:amount"]).flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }) {
                let cur = page.meta["product:price:currency"] ?? page.meta["og:price:currency"]
                return classify(amount: amount, currency: cur, text: input.text, evidence: ev("price \(amount) \(cur ?? "")", "meta.price"))
            }
        }

        // 4. visible text, line by line (a price line is short and sits next to a purchase/price cue)
        let lines = input.text.split(separator: "\n").map { String($0).collapsedWhitespace }
        let lower = input.text.lowercased()
        if lower.contains("not available in your region") || lower.contains("unavailable in your country") { return Verdict(state: .regionDependent, note: "availability depends on the region") }
        if lower.contains("no longer available") || lower.contains("this asset has been removed") || lower.contains("has been unpublished") { return Verdict(state: .unavailable, note: "the page says it is no longer available") }
        let subscription = lower.contains("included with") && (lower.contains("subscription") || lower.contains("asset store pro")) || lower.contains("per month") || lower.contains("/month") || lower.contains("/mo ")
        if lower.contains("free trial") || lower.contains("start your trial") { return Verdict(state: .other, evidence: Grounding.excerpt(in: input.text, matching: "free trial|start your trial").map { ev($0, "text") }, note: "a trial is not free — it can convert to a paid plan") }

        var freeLine: String?, paidLine: String?, paidAmount: Double?, paidCurrency: String?
        let freeRe = try! NSRegularExpression(pattern: "^(?:price[:\\s]*)?(?:free|free download|free asset|get it free|download for free|\\$0(?:[.,]00)?|€0(?:[.,]00)?|£0(?:[.,]00)?|0[.,]00\\s?(?:₺|tl|€|\\$|usd|eur)?|₺0(?:[.,]00)?|pay what you want|name your own price|\\$0 or more)$", options: .caseInsensitive)
        let priceRe = try! NSRegularExpression(pattern: "(?:^|\\s)([$€£₺])\\s?(\\d{1,4}(?:[.,]\\d{2})?)|(\\d{1,4}(?:[.,]\\d{2})?)\\s?(₺|€|£|\\$|usd|eur|tl)\\b", options: .caseInsensitive)
        let cue = try! NSRegularExpression(pattern: "price|buy|purchase|add to cart|checkout|order|license|satın|fiyat|sepete", options: .caseInsensitive)
        for (i, line) in lines.enumerated() where line.count <= 90 {
            let range = NSRange(line.startIndex..., in: line)
            if freeLine == nil, freeRe.firstMatch(in: line, range: range) != nil { freeLine = line }
            if paidLine == nil, let m = priceRe.firstMatch(in: line, range: range) {
                let near = (lines[max(0, i - 2)...min(lines.count - 1, i + 2)]).joined(separator: " ")
                if cue.firstMatch(in: near, range: NSRange(near.startIndex..., in: near)) != nil || line.count <= 14 {
                    func g(_ n: Int) -> String? { Range(m.range(at: n), in: line).map { String(line[$0]) } }
                    let amountText = (g(2) ?? g(3))?.replacingOccurrences(of: ",", with: ".")
                    if let a = amountText.flatMap(Double.init), a > 0 {
                        paidAmount = a; paidLine = line
                        if let sym = g(1)?.first { paidCurrency = currencySymbols[sym] } else if let c = g(4) { paidCurrency = c.uppercased() == "TL" ? "TRY" : (currencySymbols[c.first ?? " "] ?? c.uppercased()) }
                    }
                }
            }
        }
        let promo = lower.contains("limited time") || lower.contains("free for a limited") || lower.contains("% off") || lower.contains("sale ends") || lower.contains("was $") || lower.contains("regular price") || lower.contains("temporarily free")
        if let freeLine, promo { return Verdict(state: .promotion, amount: 0, evidence: ev(freeLine, "text"), note: "free only during a promotion — the price may change") }
        if freeLine != nil, paidLine != nil { return Verdict(state: .unknown, evidence: ev(freeLine! + " | " + paidLine!, "text"), note: "the page shows both a free and a paid price (edition or option) — verify manually") }
        if let freeLine {
            if subscription { return Verdict(state: .subscriptionIncluded, evidence: ev(freeLine, "text"), note: "free only with a subscription") }
            let pwyw = freeLine.lowercased().contains("pay what") || freeLine.lowercased().contains("name your") || freeLine.lowercased().contains("or more")
            return Verdict(state: .freeVerified, amount: 0, evidence: ev(freeLine, "text"), note: pwyw ? "pay-what-you-want with a zero minimum" : nil)
        }
        // A publisher that says, on its own page, that its assets are free ("available for free", "free of charge") — for catalogues without a price field.
        if paidLine == nil, !subscription, let ex = Grounding.excerpt(in: input.text, matching: "(?:are|is) available for free|available for free|free of charge|completely free|100% free|free to download|always free|free for (?:personal and )?commercial") {
            return Verdict(state: .freeVerified, amount: 0, evidence: ev(ex, "text"), note: "the publisher states its assets are free (no per-item price on the page)")
        }
        if let paidLine, let paidAmount { return Verdict(state: .paidVerified, amount: paidAmount, currency: paidCurrency, evidence: ev(paidLine, "text")) }
        return Verdict(state: subscription ? .subscriptionIncluded : .unknown, note: "no price could be read from this page")
    }

    private static func classify(amount: Double, currency: String?, text: String, evidence: EvidenceRef) -> Verdict {
        let lower = text.lowercased()
        if amount > 0 { return Verdict(state: .paidVerified, amount: amount, currency: currency, evidence: evidence) }
        let promo = lower.contains("limited time") || lower.contains("% off") || lower.contains("temporarily free") || lower.contains("sale ends") || lower.contains("regular price")
        if promo { return Verdict(state: .promotion, amount: 0, currency: currency, evidence: evidence, note: "free only during a promotion — the price may change") }
        if lower.contains("free trial") && !lower.contains("free download") { return Verdict(state: .other, amount: 0, currency: currency, evidence: evidence, note: "a trial is not free") }
        return Verdict(state: .freeVerified, amount: 0, currency: currency, evidence: evidence)
    }
}
