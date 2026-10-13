import Foundation

// MARK: - The observe → act → inspect → correct loop (pure part)
//
// OBSERVE (capture + the editor's geometry) → PLAN one small correction → ACT through typed operations → VERIFY structure → INSPECT again → stop when the objective holds or the rounds are
// spent. The strategies are deterministic and explainable; a model is not needed to decide "the object is outside the frustum, aim the camera" or "there is no light, add one". Only
// OBJECTIVE failures are corrected (outside the frustum, no contrast, a blown-out or black frame); taste is never "corrected".

struct LightFact: Equatable, Sendable { var path: String; var enabled: Bool; var intensity: Double; var type: String }

struct FrameFacts: Equatable, Sendable {
    var visibility: UnityObjectVisibility
    var luminance: UnityLuminance
    var lights: [LightFact]
    var ambientIntensity: Double
    var cameraPath: String
    var cameraPosition: [Double]
    var objectPosition: [Double]?
    var objectRadius: Double
}

enum CorrectionAction: Equatable, Sendable {
    case aimCamera(path: String, position: [Double], rotation: [Double])
    case addFillLight
    case setLightIntensity(path: String, to: Double)
    case setAmbient(to: Double)

    var summary: String {
        switch self {
        case .aimCamera(let p, _, _): "aim \(p) at the object"
        case .addFillLight: "add a directional fill light"
        case .setLightIntensity(let p, let v): "raise \(p) to intensity \(String(format: "%.1f", v))"
        case .setAmbient(let v): "raise the ambient light to \(String(format: "%.1f", v))"
        }
    }
}

enum OperatorCorrection {
    static let maxIntensity = 4.0
    static let maxAmbient = 1.6
    /// Names the fill light JARVIS creates, so a later session can recognise it as its own.
    static let fillLightName = "JARVIS Fill Light"

    /// Unity Euler angles (degrees; x pitch, y yaw, z 0) that make a camera at `from` look at `to`.
    static func lookAt(from: [Double], to: [Double]) -> [Double] {
        let dx = to[0] - from[0], dy = to[1] - from[1], dz = to[2] - from[2]
        let horizontal = (dx * dx + dz * dz).squareRoot()
        let yaw = atan2(dx, dz) * 180 / .pi
        let pitch = atan2(-dy, horizontal) * 180 / .pi
        return [pitch, yaw, 0].map { ($0 * 100).rounded() / 100 }
    }

    /// A camera spot that frames an object of `radius` from the front (−z side) and a little above.
    static func framingPosition(object: [Double], radius: Double) -> [Double] {
        let r = max(radius, 0.5)
        return [object[0], object[1] + max(1, r * 0.8), object[2] - max(3, r * 3.5)].map { ($0 * 100).rounded() / 100 }
    }

    /// The next correction for a frame that does not show the object clearly, or nil when nothing objective is left to try / the object cannot be corrected.
    static func plan(round: Int, _ f: FrameFacts) -> (actions: [CorrectionAction], reason: String)? {
        let v = f.visibility
        guard v.exists else { return nil }
        // 1. Geometry first: outside the frustum, behind the camera or smaller than a speck → aim/reposition the camera.
        if !v.inFrustum || v.partlyBehindCamera && v.areaFraction < UnityObjectVisibility.minArea || v.areaFraction < UnityObjectVisibility.minArea {
            guard let o = f.objectPosition, o.count == 3, f.cameraPosition.count == 3 else { return nil }
            let pos = framingPosition(object: o, radius: f.objectRadius)
            if round > 1, pos == f.cameraPosition { return nil }
            return ([.aimCamera(path: f.cameraPath, position: pos, rotation: lookAt(from: pos, to: o))], v.inFrustum ? "the object is in the frustum but only \(String(format: "%.2f", v.areaFraction * 100)) % of the frame" : "the object is outside the camera's view")
        }
        // 2. Light: in view but not distinguishable from its surroundings (or the whole frame is black).
        let dark = v.contrast < UnityObjectVisibility.minContrast || f.luminance.darkFraction > 0.9
        guard dark else { return nil }                                          // visible by the numbers: nothing to correct
        let enabled = f.lights.filter(\.enabled)
        if enabled.isEmpty { return ([.addFillLight], "there is no enabled light in the scene") }
        let brightest = enabled.max { $0.intensity < $1.intensity }!
        var actions: [CorrectionAction] = []
        let factor = round <= 1 ? 2.0 : 1.6
        if brightest.intensity < maxIntensity { actions.append(.setLightIntensity(path: brightest.path, to: min(maxIntensity, max(brightest.intensity * factor, brightest.intensity + 0.6)))) }
        if f.ambientIntensity < maxAmbient { actions.append(.setAmbient(to: min(maxAmbient, f.ambientIntensity + (round <= 1 ? 0.4 : 0.6)))) }
        if actions.isEmpty { return nil }
        return (actions, "the object has too little contrast with its surroundings (\(String(format: "%.2f", v.contrast))) under the current light")
    }
}

/// Objective facts versus taste. The operator reports measurements as measurements, a model's reading as “model-observed”, and never reports a taste word as a passed check.
enum OperatorFindingClass: String, Sendable { case objective = "OBJECTIVE", modelObserved = "MODEL-OBSERVED", subjective = "SUBJECTIVE" }

enum OperatorJudgement {
    private static let taste = ["beautiful", "beautifully", "pretty", "nice looking", "looks good", "looks great", "cinematic", "perfect", "best", "fun", "cool", "stunning", "atmospheric", "moody", "güzel", "guzel", "harika", "mükemmel", "mukemmel", "estetik", "hoş", "hos", "havalı", "havali", "sinematik"]

    /// Taste words in a user's goal: the measurable part can be done and proven, the rest is the user's call.
    static func subjectiveWords(in goal: String) -> [String] {
        let t = ResearchText.fold(goal)
        return taste.filter { t.contains(ResearchText.fold($0)) }
    }

    static func footnote(for goal: String) -> String? {
        let w = subjectiveWords(in: goal)
        return w.isEmpty ? nil : "SUBJECTIVE: “\(w.prefix(3).joined(separator: "”, “"))” is a matter of taste — I checked only what can be measured (visibility, contrast, compile state); whether it is what you want is your call."
    }
}
