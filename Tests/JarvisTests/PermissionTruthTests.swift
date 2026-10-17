import Testing
import Foundation
@testable import Jarvis

// V1.0 stabilisation fix 3 — permission truth: the rows read the OS answer for THIS build, Recheck re-reads it, and permission / feature / activity are different facts.
// (No test touches the real TCC database or asks macOS for anything: the OS answers are injected.)

@MainActor
private final class PermWorld {
    var ax: PermissionStatus = .notDetermined
    var screen: PermissionStatus = .notDetermined
    var mic: PermissionStatus = .notDetermined
    var identity: CodeIdentity? = CodeIdentity(bundlePath: "/Applications/JARVIS.app", bundleID: "dev.jarvis.Jarvis", signingIdentifier: "dev.jarvis.Jarvis", cdhash: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", adHoc: true, teamID: nil)
    var changed = false
    var wakeOn = false
    var detector: WakeDetectorProbe = .stopped
    var voiceOn = true
    lazy var service: ReadinessService = {
        var p = ReadinessProbes()
        p.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        p.installedMode = { true }
        p.schemaVersion = { 14 }
        p.accessibility = { [unowned self] in self.ax }
        p.screenRecording = { [unowned self] in self.screen }
        p.microphone = { [unowned self] in self.mic }
        p.identity = { [unowned self] in self.identity }
        p.identityChanged = { [unowned self] in self.changed }
        p.wakeWord = { [unowned self] in (true, self.wakeOn, "") }
        p.wakeDetector = { [unowned self] in self.detector }
        p.pushToTalk = { [unowned self] in (self.voiceOn, true, true, true) }
        return ReadinessService(probes: p)
    }()
    func item(_ id: String) -> ReadinessItem { service.refresh().item(id)! }
}

@Suite("Fix 3 · permission truth")
@MainActor
struct PermissionTruthTests {
    @Test("Accessibility: the row follows the OS answer for this build and a Recheck re-reads it (no restart)")
    func accessibilityFollowsTheOS() {
        let w = PermWorld()
        #expect(w.item("computer.ax").state == .permissionNeeded)
        #expect(w.item("computer.ax").action == .allowAccessibility)
        w.ax = .granted                                                              // the user allowed it in System Settings; the same ReadinessService, no restart
        #expect(w.item("computer.ax").state == .ready && w.item("computer.ax").action == nil)
        w.ax = .notDetermined
        #expect(w.item("computer.ax").state == .permissionNeeded)
    }

    @Test("an ad-hoc build explains the real limitation: permissions belong to the exact build")
    func adHocExplanation() {
        let w = PermWorld()
        w.changed = true
        let d = w.item("computer.ax").detail
        #expect(d.contains("This build is new since JARVIS last ran") && d.contains("a1b2c3d4") && d.contains("remove it with −") && d.contains("/Applications/JARVIS.app"), Comment(rawValue: d))
        let id = w.item("core.identity")
        #expect(id.state == .ready && id.detail.contains("ad-hoc signature a1b2c3d4") && id.detail.contains("macOS treats each build as a new app"), Comment(rawValue: id.detail))
        // a stable identity gets no such warning
        w.identity?.adHoc = false; w.identity?.teamID = "ABCDE12345"
        #expect(!w.item("computer.ax").detail.contains("remove it with −"))
    }

    @Test("a copy that is not /Applications/JARVIS.app is flagged: macOS judges it separately")
    func nonCanonicalCopy() {
        let w = PermWorld()
        w.identity?.bundlePath = "/Users/x/Jarvis/build/package/JARVIS.app"
        let id = w.item("core.identity")
        #expect(id.state != .ready && id.detail.contains("NOT the installed copy"), Comment(rawValue: id.detail))
    }

    @Test("Screen Recording permission, visual feature and window capture are three different facts")
    func permissionFeatureActivity() {
        let w = PermWorld()
        #expect(w.item("computer.screen").state == .optionalAbsent && w.item("computer.screen").detail.contains("Restart JARVIS"))
        #expect(w.item("computer.capture").state == .optionalAbsent)
        w.screen = .granted
        #expect(w.item("computer.screen").state == .ready)
        #expect(w.item("computer.capture").state == .notRunning, "permission READY but capture IDLE")
        #expect(w.item("computer.capture").detail.contains("Idle") && w.item("computer.capture").detail.contains("No continuous capture"))
    }

    @Test("Wake Word: the switch and the detector are different facts and the rows agree with the detector")
    func wakeRows() {
        let w = PermWorld()
        w.wakeOn = false; w.detector = .stopped
        #expect(w.item("voice.wake").state == .off && w.item("voice.wake").action == .turnOnWake)
        w.wakeOn = true; w.detector = .running
        #expect(w.item("voice.wake").state == .ready && w.item("voice.wake").detail.contains("RUNNING"))
        w.detector = .starting
        #expect(w.item("voice.wake").state == .unknown)
        w.detector = .paused
        #expect(w.item("voice.wake").state == .notRunning && w.item("voice.wake").detail.contains("paused"))
        w.detector = .stopped
        if case .degraded = w.item("voice.wake").state {} else { Issue.record("ON + stopped must be degraded, got \(w.item("voice.wake").state)") }
        w.detector = .error("microphone access is not allowed")
        let e = w.item("voice.wake")
        if case .degraded(let why) = e.state { #expect(why == "microphone access is not allowed") } else { Issue.record("expected an error state") }
        #expect(e.detail.hasPrefix("ERROR"))
    }

    @Test("a relaunch flag is not a developer flag (it keeps production storage and the single-instance rule)")
    func relaunchIsPlain() {
        #expect(SingleInstance.isPlainLaunch(["Jarvis", "--relaunched"]))
        #expect(!SingleInstance.isPlainLaunch(["Jarvis", "--smoke-test"]))
    }
}
