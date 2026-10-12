import Foundation

/// The wake acknowledgement sound: two soft rising sine tones with smooth edges (≈ 170 ms, quiet). Generated, not a recording — nothing to license or store.
enum WakeCue {
    static let block: PCMBlock = {
        let rate = PCMResampler.outputRate
        func tone(_ hz: Double, _ seconds: Double) -> [Float] {
            let n = Int(seconds * rate)
            return (0..<n).map { i in
                let t = Double(i) / rate
                let edge = min(1, min(Double(i), Double(n - i)) / (0.012 * rate))                 // 12 ms fade in/out: no click
                return Float(sin(2 * .pi * hz * t) * 0.16 * edge)
            }
        }
        return PCMBlock(samples: tone(740, 0.075) + [Float](repeating: 0, count: Int(0.012 * rate)) + tone(988, 0.095), sampleRate: rate)
    }()
}
