import Foundation

/// The sanitization boundary for DETERMINISTIC TOOL output (build/test/git…), the counterpart of `SafeProvider` for model output (V0.4, DEC-029).
///
///   ManagedProcess → raw lines → StreamSanitizer → safe text ─┬─► ExecutionHub console of the tool's run
///                                                              └─► `tail` (bounded; the only text a step result / report / SQLite may carry)
///
/// Raw tool output is never forwarded, stored or shown: there is no accessor for it.
@MainActor
final class SafeToolOutput {
    static let tailLimit = 12_000
    private let sanitizer = StreamSanitizer()
    private let runID: UUID?
    private let hub: ExecutionHub?
    private(set) var tail = ""

    init(runID: UUID?, hub: ExecutionHub?) { self.runID = runID; self.hub = hub }

    /// One raw output line (without its newline).
    func feed(_ rawLine: String) { emit(sanitizer.feed(rawLine + "\n")) }

    func finish() { emit(sanitizer.flush()) }

    private func emit(_ safe: String) {
        guard !safe.isEmpty else { return }
        tail += safe
        if tail.count > Self.tailLimit { tail = String(tail.suffix(Self.tailLimit)) }
        if let runID { hub?.appendOutput(runID, safe) }
    }
}
