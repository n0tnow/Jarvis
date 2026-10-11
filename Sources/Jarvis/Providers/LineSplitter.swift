import Foundation

/// Splits a byte stream into complete lines. Operates on BYTES and only decodes whole lines, so a multi-byte UTF-8
/// character (Turkish ğüşiöç, emoji…) split across two reads is never corrupted. Handles \n and \r\n, partial lines, no loss/duplication.
struct LineSplitter {
    /// A provider that never prints a newline must not grow memory without bound.
    static let maxLineBytes = 8 * 1024 * 1024
    private var buffer = Data()
    private(set) var overflowed = false

    mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        if buffer.count > Self.maxLineBytes, buffer.firstIndex(of: 0x0A) == nil { buffer = Data(); overflowed = true }
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(Data(line))
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        return lines
    }

    /// Remaining bytes without a trailing newline (call at EOF).
    mutating func flush() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}
