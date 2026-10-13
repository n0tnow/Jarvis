import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

// MARK: - Window-scoped screenshots and local, on-device vision (DEC-135…)
//
//  • ONE window per capture (never the desktop, never other applications), held in memory only, released when the call returns.
//  • Needs Screen Recording — and only this file asks for it, and only after `CGPreflightScreenCaptureAccess()` said yes (an explicit user action asks).
//  • "Vision" here is Apple's on-device text recogniser: no model download, no network, no cloud, no API key. It answers "where is the control that says …".
//    A cloud multimodal model is NOT used: the available subscription routes are text-in/text-out CLIs and sending a screenshot to a cloud provider has no
//    verified-free, privacy-safe route (see docs/GENERAL_COMPUTER_USE.md → Vision research).

enum WindowCapture {
    static func capture(windowID: UInt32, expectedFrame: CGRect) async throws -> CapturedWindow {
        guard CGPreflightScreenCaptureAccess() else { throw BackendError.captureUnavailable("Screen Recording permission is not granted") }
        let t0 = Date()
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw BackendError.captureUnavailable(error.localizedDescription) }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw BackendError.captureUnavailable("the window is not on screen") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(window.frame.width * scale))
        cfg.height = max(1, Int(window.frame.height * scale))
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.scalesToFit = false
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) }
        catch { throw BackendError.captureUnavailable(error.localizedDescription) }
        return CapturedWindow(image: image, scale: scale, windowFrame: window.frame, fingerprint: fingerprint(of: image), capturedAt: Date(), duration: Date().timeIntervalSince(t0))
    }

    /// 8×8 average hash. A few bytes describe what the window looked like; no pixels are kept anywhere.
    static func fingerprint(of image: CGImage) -> UInt64 {
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) >= mean { hash |= 1 << UInt64(i) }
        return hash
    }
}

// MARK: Vision proposals (a proposal is NOT an action)

struct VisionProposal: Equatable, Sendable {
    var label: String                  // what was recognised
    var box: CGRect                    // window-relative logical points, top-left origin
    var reason: String
    var source: String
}

protocol VisionProposing: Sendable {
    var name: String { get }
    /// Where on THIS window image is the control that says `label`? Proposals only — JARVIS validates freshness, bounds and policy before any click.
    func propose(label: String, image: CGImage, scale: CGFloat) async -> [VisionProposal]
}

struct AppleVisionOCR: VisionProposing {
    let name = "Apple Vision on-device text recognition"

    func recognise(_ image: CGImage) async -> [(text: String, box: CGRect)] {
        await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let found = (req.results as? [VNRecognizedTextObservation])?.compactMap { o -> (String, CGRect)? in
                    guard let top = o.topCandidates(1).first else { return nil }
                    return (top.string, o.boundingBox)
                } ?? []
                cont.resume(returning: found)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false              // UI labels are not prose
            let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
            request.recognitionLanguages = ["en-US", "tr-TR"].filter { supported.contains($0) }.isEmpty ? ["en-US"] : ["en-US", "tr-TR"].filter { supported.contains($0) }
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { cont.resume(returning: []) }
        }
    }

    func propose(label: String, image: CGImage, scale: CGFloat) async -> [VisionProposal] {
        let want = ComputerText.menuKey(label)
        guard !want.isEmpty else { return [] }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        var exact: [VisionProposal] = [], partial: [VisionProposal] = []
        for (text, box) in await recognise(image) {
            let k = ComputerText.menuKey(text)
            let rect = Coordinates.visionBoxToWindowRect(box, windowSize: size)
            if k == want { exact.append(VisionProposal(label: text, box: rect, reason: "the text “\(text.prefix(40))” was recognised in the window", source: name)) }
            else if k.contains(want) { partial.append(VisionProposal(label: text, box: rect, reason: "recognised text contains the label", source: name)) }
        }
        return exact.isEmpty ? partial : exact
    }
}

/// A model-based vision provider is deliberately not wired: there is no verified-free, subscription-backed route that accepts an image with the privacy
/// guarantees this layer requires. The type exists so the routing code and the UI can say so truthfully.
struct UnavailableModelVision: VisionProposing {
    let name = "Model vision (not available)"
    func propose(label: String, image: CGImage, scale: CGFloat) async -> [VisionProposal] { [] }
}
