import AppKit
import SwiftUI

/// SwiftUI wrapper. It only pushes *state changes* into the AppKit view (event-driven); it never animates
/// per frame, so SwiftUI's attribute graph is not invalidated while signals travel.
struct NeuralBackground: NSViewRepresentable {
    let state: JarvisState
    let isAnimating: Bool

    func makeNSView(context: Context) -> NeuralNetworkNSView { NeuralNetworkNSView() }

    func updateNSView(_ view: NeuralNetworkNSView, context: Context) {
        view.tint = NSColor(state.tint)
        view.state = state
        view.isAnimating = isAnimating
    }
}
