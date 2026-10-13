import Foundation
import CoreGraphics

/// Deterministic pixel facts about a picture held in memory (no model): used where "is it broken?" has a measurable answer.
enum PictureAnalysis {
    /// Share of pixels that are (near) magenta — Unity's colour for a missing shader or an unsupported material. A render that is mostly magenta is BROKEN, not "stylised".
    static func magentaFraction(png: Data) -> Double {
        guard let img = VisualImageCoding.cgImage(png: png) else { return 0 }
        let w = min(img.width, 256), h = min(img.height, 256)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4) { if px[i] > 200 && px[i + 2] > 200 && px[i + 1] < 80 { n += 1 } }
        return Double(n) / Double(w * h)
    }
}
