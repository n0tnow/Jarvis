import Observation

/// Bridges `@Observable` models to AppKit: runs `onChange` whenever anything read inside
/// `track` changes, and keeps re-arming itself. Event-driven — no polling, no timers.
@MainActor
func observeContinuously(track: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    withObservationTracking {
        track()
    } onChange: {
        Task { @MainActor in
            onChange()
            observeContinuously(track: track, onChange: onChange)
        }
    }
}
