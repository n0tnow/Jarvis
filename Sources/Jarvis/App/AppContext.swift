import Foundation
import Observation
import SwiftUI

/// Composition root: owns the long-lived objects. Everything here outlives every window —
/// closing the Full HUD or Compact HUD never tears any of it down.
@MainActor
@Observable
final class AppContext {
    let store: JarvisStore
    let hud: HUDState
    let preferences: Preferences

    let conversation: ConversationStore
    @ObservationIgnored private(set) var conversationService: ConversationService!
    @ObservationIgnored private(set) var windowManager: WindowManager!

    /// Views and (later) the intent layer talk to windows only through this protocol.
    var windows: any JarvisWindowControlling { windowManager }

    init(seedDemoData: Bool = true) {
        store = JarvisStore()
        hud = HUDState()
        preferences = Preferences()
        conversation = ConversationStore()
        if seedDemoData { DemoScenario.seed(store) }
        windowManager = WindowManager(context: self)
        conversationService = ConversationService(store: store, conversation: conversation, windows: windowManager)
    }
}
