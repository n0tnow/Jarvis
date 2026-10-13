import Foundation

/// What the Project card shows about the open Unity scene (V0.13.1). A SUBSET of the scene profile — never the hierarchy. It is read from a RUNNING editor when the card refreshes
/// (never on a timer, never by launching an editor); when no editor is connected the last reading is shown only as HISTORY, labelled with its age, and never as the present.
struct UnitySceneFacts: Codable, Equatable, Sendable {
    var scene: String
    var objectCount: Int
    var cameras: Int
    var lights: Int
    var missingScripts: Int
    var missingReferences: Int
    var isPlaying: Bool
    var hasUnsavedChanges: Bool
    var capturedAt: Date
    /// true ONLY for a reading taken from a connected editor in THIS refresh; a remembered reading is never live.
    var live: Bool

    /// Older than this, even a remembered reading is described as long ago rather than "a moment ago".
    static let staleAfter: TimeInterval = 5 * 60

    init(scene: String, objectCount: Int, cameras: Int, lights: Int, missingScripts: Int, missingReferences: Int, isPlaying: Bool, hasUnsavedChanges: Bool, capturedAt: Date = Date(), live: Bool) {
        self.scene = scene; self.objectCount = objectCount; self.cameras = cameras; self.lights = lights; self.missingScripts = missingScripts; self.missingReferences = missingReferences
        self.isPlaying = isPlaying; self.hasUnsavedChanges = hasUnsavedChanges; self.capturedAt = capturedAt; self.live = live
    }

    /// From the editor's `sceneProfile` answer plus its Play Mode flag.
    init(profile r: [String: Any], isPlaying: Bool, now: Date = Date()) {
        func n(_ k: String) -> Int { (r[k] as? NSNumber)?.intValue ?? 0 }
        self.init(scene: (r["scene"] as? String) ?? "?", objectCount: n("objectCount"), cameras: n("cameras"), lights: n("lights"), missingScripts: n("missingScripts"), missingReferences: n("missingReferences"),
                  isPlaying: isPlaying, hasUnsavedChanges: r["dirty"] as? Bool == true, capturedAt: now, live: true)
    }

    var brokenReferences: Int { missingScripts + missingReferences }

    /// The same reading, remembered: never live.
    var remembered: UnitySceneFacts { var c = self; c.live = false; return c }

    /// The label a reader must see next to the numbers: where they come from and how old they are.
    func freshness(now: Date = Date()) -> String {
        if live { return "live — read from the running editor just now" }
        let age = max(0, now.timeIntervalSince(capturedAt))
        let when = age < 90 ? "a moment ago" : age < 3_600 ? "\(Int(age / 60)) min ago" : age < 172_800 ? "\(Int(age / 3_600)) h ago" : "\(Int(age / 86_400)) days ago"
        return "last known (\(when)) — the editor is not connected, so this may be out of date"
    }

    /// Concise problems only; empty when there is nothing to warn about.
    var warnings: [String] {
        var w: [String] = []
        if brokenReferences > 0 { w.append("\(brokenReferences) broken reference\(brokenReferences == 1 ? "" : "s") (\(missingScripts) missing script\(missingScripts == 1 ? "" : "s"), \(missingReferences) missing reference\(missingReferences == 1 ? "" : "s"))") }
        if cameras == 0 { w.append("no camera in the scene") }
        if lights == 0 { w.append("no light in the scene") }
        if hasUnsavedChanges { w.append("unsaved changes") }
        return w
    }

    /// "FixtureScene · 18 objects · 1 camera · 2 lights · Edit Mode · saved" (the numbers only; the freshness label is shown separately).
    var line: String {
        "\((scene as NSString).lastPathComponent.replacingOccurrences(of: ".unity", with: "")) · \(objectCount) object\(objectCount == 1 ? "" : "s") · \(cameras) camera\(cameras == 1 ? "" : "s") · \(lights) light\(lights == 1 ? "" : "s") · \(isPlaying ? "Play Mode" : "Edit Mode") · \(hasUnsavedChanges ? "unsaved" : "saved")"
    }
}
