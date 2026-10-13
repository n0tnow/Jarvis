import Foundation
import CoreGraphics
import Vision

// MARK: - Providers (perception only)

enum VisualCapability: String, Sendable { case locateText, locateControl, locateObject, describe }

enum VisualProviderError: Error, Equatable, CustomStringConvertible {
    case unavailable(String), timedOut, badAnswer(String), refusedByPolicy(String)
    var description: String {
        switch self {
        case .unavailable(let w): "the visual provider is unavailable: \(w)"
        case .timedOut: "the visual provider timed out"
        case .badAnswer(let w): "the visual provider sent an invalid answer: \(w)"
        case .refusedByPolicy(let w): w
        }
    }
}

protocol VisualProvider: Sendable {
    var id: String { get }
    var providerClass: VisualProviderClass { get }
    var capabilities: Set<VisualCapability> { get }
    /// Installed and startable (asking never starts or downloads anything).
    var isAvailable: Bool { get }
    /// `png` is the same picture as `image`, encoded once by the caller (memory only).
    func analyze(png: Data, image: CGImage, query: VisualQuery) async throws -> VisualAnswer
}

// MARK: Apple Vision: on-device text recognition (OCR-only provider)

/// Knows exactly what it knows: where a TEXT label is. It cannot find an icon-only control, an object in a 3D scene or judge a pose — it says so instead of guessing.
struct AppleVisionProvider: VisualProvider {
    let id = "apple-vision-ocr"
    let providerClass = VisualProviderClass.onDevice
    let capabilities: Set<VisualCapability> = [.locateText, .describe]
    var isAvailable: Bool { true }

    static func recognise(_ image: CGImage) -> [(text: String, box: VisualRegion?, rawBox: CGRect)] {
        var out: [(String, VisualRegion?, CGRect)] = []
        let request = VNRecognizeTextRequest { req, _ in
            for o in (req.results as? [VNRecognizedTextObservation]) ?? [] {
                guard let top = o.topCandidates(1).first else { continue }
                // Vision boxes are bottom-left normalised; the validated region is top-left normalised.
                let b = o.boundingBox
                out.append((top.string, VisualRegion(checking: [b.minX, 1 - b.maxY, b.maxX, 1 - b.minY], maxArea: 0.9), b))
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        let langs = ["en-US", "tr-TR"].filter { supported.contains($0) }
        request.recognitionLanguages = langs.isEmpty ? ["en-US"] : langs
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return out
    }

    /// What is printed inside a normalised region (the cross-check for a model-proposed target).
    static func text(in region: VisualRegion, of image: CGImage) -> String? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = 0.01
        let r = CGRect(x: max(0, region.x0 - pad) * w, y: max(0, region.y0 - pad) * h, width: min(1, region.width + 2 * pad) * w, height: min(1, region.height + 2 * pad) * h).integral
        guard r.width >= 8, r.height >= 8, let crop = image.cropping(to: r) else { return nil }
        let t = recognise(crop).map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : OutputSanitizer.sanitize(String(t.prefix(80)))
    }

    func analyze(png: Data, image: CGImage, query: VisualQuery) async throws -> VisualAnswer {
        let t0 = Date()
        var a = VisualAnswer(); a.provider = id; a.pictureHash = VisualImageCoding.hash(png)
        let texts = Self.recognise(image)
        switch query {
        case .describe:
            let joined = texts.map(\.text).joined(separator: " · ")
            let v = VisualOutputValidator.text(joined.isEmpty ? "No text was recognised." : "Text visible: " + joined)
            a.text = v.text; a.injectionNotes = v.notes; a.found = !texts.isEmpty
            a.observations = texts.prefix(30).map { VisualObservation(kind: .text, label: String($0.text.prefix(60)), region: $0.box, confidence: .medium) }
        case .locate(let label):
            let want = ComputerText.menuKey(VisualQueryText.label(from: label))
            guard !want.isEmpty else { a.abstainReason = "nothing to look for"; return a }
            var exact: [VisualTargetCandidate] = [], partial: [VisualTargetCandidate] = []
            for (text, box, _) in texts {
                guard let box else { continue }
                let k = ComputerText.menuKey(text)
                let cand = VisualTargetCandidate(label: String(text.prefix(60)), region: box, confidence: k == want ? .high : .medium, safety: VisualOutputValidator.safety(label: text, printedText: nil), sources: [id], printedText: text)
                if k == want { exact.append(cand) } else if k.contains(want) { partial.append(cand) }
            }
            let pool = exact.isEmpty ? partial : exact
            a.candidates = pool; a.found = !pool.isEmpty; a.ambiguous = pool.count > 1
            if pool.isEmpty { a.abstainReason = "no text matching “\(label.prefix(40))” was recognised (an icon-only control cannot be found by text recognition)" }
            else if pool.count > 1 { a.abstainReason = "\(pool.count) places show that text" }
        }
        a.seconds = Date().timeIntervalSince(t0)
        return a
    }
}

// MARK: Provider choice (pure)

/// Which provider answers a question: capability first, then privacy, then cost (on-device before anything else). Pure and unit-tested.
enum VisualProviderSelection {
    static func choose(for query: VisualQuery, sensitivity: VisualSensitivity, among providers: [any VisualProvider], cloudAllowed: Bool = false, preferText: Bool = true) -> [any VisualProvider] {
        let wanted: VisualCapability
        switch query {
        case .describe: wanted = .describe
        case .locate(let l): wanted = looksLikeText(l) && preferText ? .locateText : .locateControl
        }
        let eligible = providers.filter { $0.isAvailable && $0.providerClass.mayReceive(sensitivity, cloudAllowed: cloudAllowed) }
        // Text-looking queries try the cheap exact tool first, then whoever else can do it; other queries need a model.
        let ranked = eligible.filter { $0.capabilities.contains(wanted) || (wanted == .locateText && ($0.capabilities.contains(.locateControl) || $0.capabilities.contains(.locateObject))) || (wanted == .locateControl && $0.capabilities.contains(.locateObject)) }
        return ranked.sorted { a, b in
            let order: [VisualProviderClass] = [.onDevice, .subscription, .freeCloud]
            let ia = order.firstIndex(of: a.providerClass)!, ib = order.firstIndex(of: b.providerClass)!
            if ia != ib { return ia < ib }
            let ta = a.capabilities.contains(.locateText) && !a.capabilities.contains(.locateControl), tb = b.capabilities.contains(.locateText) && !b.capabilities.contains(.locateControl)
            return wanted == .locateText ? (ta && !tb) : (!ta && tb)
        }
    }

    /// “the Save button” (a quoted/plain label) versus “the gear icon” / “the blue cube” (something that has no text to read).
    static func looksLikeText(_ label: String) -> Bool {
        let t = ResearchText.fold(label)
        for w in ["icon", "symbol", "glyph", "image", "picture", "cube", "sphere", "object", "character", "light", "ikon", "simge", "resim", "kup", "kure", "nesne"] where t.contains(w) { return false }
        return true
    }
}


/// “the Save button” → “Save”; “the Export menu item” → “Export”; a quoted label wins. Pure.
enum VisualQueryText {
    private static let lead: Set<String> = ["the", "a", "an", "this", "that", "bu", "su"]
    private static let trail: Set<String> = ["button", "buton", "icon", "ikon", "item", "link", "tab", "field", "menu", "label", "checkbox", "control", "option", "entry", "text"]
    static func label(from query: String) -> String {
        for q in ["\"", "“", "'"] { if let a = query.firstIndex(of: Character(q)), let b = query[query.index(after: a)...].firstIndex(where: { "\"”'".contains($0) }), b > a { let inner = String(query[query.index(after: a)..<b]); if !inner.isEmpty { return inner } } }
        var words = query.split(separator: " ").map(String.init)
        while let f = words.first, lead.contains(f.lowercased()) { words.removeFirst() }
        while let l = words.last, trail.contains(l.lowercased()), words.count > 1 { words.removeLast() }
        return words.joined(separator: " ")
    }
}
