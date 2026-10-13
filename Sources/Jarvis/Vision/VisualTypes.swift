import Foundation
import CoreGraphics
import ImageIO

// MARK: - General visual grounding (V0.13, DEC-191…): image + a bounded question → typed observations. NEVER an authority.
//
// A visual provider is a PERCEPTION component. What it returns is untrusted data that JARVIS validates (boxes are normalised and bounded, text is sanitised and scanned,
// instructions inside a picture are data) and classifies (the same consequence classes as the rest of Computer Use). There is no field in any type here that can carry an
// action, a coordinate for the actuator, a command or an approval: a model-provided region only ever becomes a `VisionProposal`, which the executor still checks for
// freshness, bounds, occlusion, user interference and policy before anything is pressed.

enum VisualConfidenceClass: String, Codable, Sendable, Comparable {
    case low, medium, high
    static func < (a: Self, b: Self) -> Bool { [Self.low, .medium, .high].firstIndex(of: a)! < [Self.low, .medium, .high].firstIndex(of: b)! }
}

/// Where a picture came from decides which providers may see it (privacy first).
enum VisualSensitivity: String, Codable, Sendable {
    /// Any application window the user has open: may contain anything → on-device providers only.
    case desktop
    /// A render of the user's OWN project (a Unity game camera): still the user's work, never sent to free cloud; a subscription provider only when the user allowed it.
    case project
    /// A synthetic benchmark / fixture image that contains nothing private.
    case synthetic
}

enum VisualProviderClass: String, Codable, Sendable {
    case onDevice, subscription, freeCloud
    func mayReceive(_ s: VisualSensitivity, cloudAllowed: Bool) -> Bool {
        switch (self, s) {
        case (.onDevice, _): true
        case (.subscription, .desktop): false
        case (.subscription, .project): cloudAllowed
        case (.subscription, .synthetic): true
        case (.freeCloud, .synthetic): true
        case (.freeCloud, _): false
        }
    }
}

/// A rectangle normalised to the picture: 0…1, origin top-left. Built only through `VisualRegion(checking:)`.
struct VisualRegion: Equatable, Codable, Sendable {
    var x0: Double, y0: Double, x1: Double, y1: Double

    static let minSide = 0.002
    /// A "control" that covers most of the window is not a control.
    static let maxArea = 0.55

    init?(checking raw: [Double], maxArea: Double = VisualRegion.maxArea) {
        guard raw.count == 4, raw.allSatisfy({ $0.isFinite }) else { return nil }
        let c = raw.map { min(max($0, 0), 1) }
        guard c[2] - c[0] >= Self.minSide, c[3] - c[1] >= Self.minSide, (c[2] - c[0]) * (c[3] - c[1]) <= maxArea else { return nil }
        x0 = c[0]; y0 = c[1]; x1 = c[2]; y1 = c[3]
    }
    var width: Double { x1 - x0 }
    var height: Double { y1 - y0 }
    var area: Double { width * height }
    var center: CGPoint { CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2) }
    func iou(_ o: VisualRegion) -> Double {
        let ix = max(0, min(x1, o.x1) - max(x0, o.x0)), iy = max(0, min(y1, o.y1) - max(y0, o.y0))
        let inter = ix * iy
        return inter / max(1e-9, area + o.area - inter)
    }
    func contains(_ p: CGPoint) -> Bool { p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1 }
    /// Window-relative logical points (top-left origin) — the unit `VisionProposal` and `Coordinates` use.
    func rect(inWindow size: CGSize) -> CGRect { CGRect(x: x0 * size.width, y: y0 * size.height, width: width * size.width, height: height * size.height) }
}

struct VisualObservation: Equatable, Sendable {
    enum Kind: String, Sendable { case text, control, object, scene, measurement }
    var kind: Kind
    var label: String
    var region: VisualRegion?
    var confidence: VisualConfidenceClass
}

/// A coarse spatial relation between two observations ("Save" is right of "Cancel"). Descriptive only.
struct VisualRelation: Equatable, Sendable {
    var subject: String
    var relation: String
    var object: String
}

/// A place that may be what was asked for. `safety` is JARVIS' own classification of the control's label AND of the text actually printed inside the region.
struct VisualTargetCandidate: Equatable, Sendable {
    var label: String
    var region: VisualRegion
    var confidence: VisualConfidenceClass
    var safety: Consequence
    var sources: [String]
    /// What the on-device text recogniser reads inside the region (cross-check against a model that might label a purchase button "Save").
    var printedText: String?
}

struct VisualAnswer: Sendable {
    var found = false
    var ambiguous = false
    var candidates: [VisualTargetCandidate] = []
    var observations: [VisualObservation] = []
    var relations: [VisualRelation] = []
    /// A bounded, sanitised description / answer (never an instruction to anyone).
    var text: String?
    var provider = ""
    var seconds = 0.0
    var peakMegabytes: Int?
    /// Hash of the picture analysed (the evidence identity; the pixels are never stored).
    var pictureHash = ""
    /// Instruction-like text that appeared in the picture or the answer: recorded, never obeyed.
    var injectionNotes: [String] = []
    /// Why the provider declined (no match, several matches, unavailable): honest abstention.
    var abstainReason: String?
    var abstained: Bool { !found || ambiguous }
}

enum VisualQuery: Equatable, Sendable {
    /// “the Save button”, “the gear icon”, “the blue cube”.
    case locate(String)
    /// A bounded question about what is visible.
    case describe(String)

    var text: String { switch self { case .locate(let s), .describe(let s): s } }
}

// MARK: Validation of whatever a provider returned

enum VisualOutputValidator {
    static let maxCandidates = 8
    static let maxLabel = 60
    static let maxText = 600

    /// Raw provider candidates → validated regions. Malformed, non-finite, degenerate or screen-sized boxes are dropped; near-duplicates merge.
    static func regions(_ raw: [(label: String, box: [Double])]) -> [(label: String, region: VisualRegion)] {
        var out: [(String, VisualRegion)] = []
        for c in raw.prefix(maxCandidates * 2) {
            guard let r = VisualRegion(checking: c.box) else { continue }
            if out.contains(where: { $0.1.iou(r) > 0.6 }) { continue }
            out.append((OutputSanitizer.sanitize(String(c.label.prefix(maxLabel))), r))
            if out.count == maxCandidates { break }
        }
        return out
    }

    /// Provider text: sanitised, bounded, and scanned. Anything that reads like an instruction is NOTED; the text stays data.
    static func text(_ raw: String) -> (text: String, notes: [String]) {
        let clean = OutputSanitizer.sanitize(String(raw.prefix(maxText)))
        return (clean, UntrustedContent.scan(clean).map { "instruction-like text: \($0)" })
    }

    /// The effective consequence of a candidate: the WORST of what the provider called it, what is printed in it, and what was asked for (“the delete icon” is a deletion
    /// whatever a model labels it). Text can only RAISE the class, never lower it.
    static func safety(label: String, printedText: String?, requested: String? = nil) -> Consequence {
        var worst = ConsequenceClassifier.classify(label: label)
        for extra in [printedText, requested.map(VisualQueryText.label(from:))].compactMap({ $0 }) where !extra.isEmpty {
            let c = ConsequenceClassifier.classify(label: extra)
            if worst.blockedForever { break }
            if c.blockedForever || c.risk > worst.risk || (c != .ordinary && worst == .ordinary) { worst = c }
        }
        return worst
    }
}

/// Picture bytes in memory only (PNG/JPEG encoded for a helper or a provider). Never written by this layer.
enum VisualImageCoding {
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
    static func cgImage(png: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    static func hash(_ data: Data) -> String { Redactor.sha256(data).prefix(16).description }
}
