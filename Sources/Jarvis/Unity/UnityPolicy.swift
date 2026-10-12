import Foundation

/// The deterministic rules in front of every Unity operation. Pure functions of (operation, task capabilities, editor status):
/// nothing here talks to Unity, so each rule is unit-testable and independent of any model.
enum UnityPolicy {
    enum Decision: Equatable {
        case allow
        case deny(FailureCategory, String)
        /// The operation is allowed only after the user approves this exact action (user-owned unsaved work, deletion).
        case needsApproval(action: String, reason: String, risk: RiskClass)
    }

    /// Scene/asset paths that may appear in operations: project-relative, inside Assets/, no traversal.
    static func isSafeProjectPath(_ p: String) -> Bool {
        !p.isEmpty && p.hasPrefix("Assets/") && !p.contains("..") && !p.contains("//") && !p.hasPrefix("/") && !p.contains("\0") && p.count <= 240
    }

    static func authorize(_ op: UnityOperation, capabilities: CapabilitySet, status: UnityStatusSnapshot?, destructiveRequested: Bool, approvedDirtyScenes: Set<String> = []) -> Decision {
        // Deletion is not a task capability: it is allowed only when the user's goal asked for it, and then per action through an approval.
        if case .deleteGameObject(let t) = op {
            guard destructiveRequested else { return .deny(.securityBlocked, "Deleting Unity objects was not requested in the goal.") }
            guard t.isPrecise else { return .deny(.ambiguousTarget, "A GameObject to delete must be identified by path or global ID, not by name.") }
            if let denied = editorStateDenial(op, status: status) { return denied }
            return .needsApproval(action: "Delete Unity object \(t.display)", reason: "Deleting a GameObject changes the scene. JARVIS records an Undo step, but the deletion is permanent once the scene is saved.", risk: .high)
        }
        guard capabilities.allows(op.capability) else { return .deny(.capabilityDenied, "This task does not grant \(op.capability.rawValue).") }

        // Paths named by an operation must stay inside the project's Assets folder.
        switch op {
        case .openScene(let p), .saveScene(let p): if !isSafeProjectPath(p) { return .deny(.workspaceViolation, "\(p) is not a scene inside Assets/.") }
        case .createPrefab(_, let p): if !isSafeProjectPath(p) { return .deny(.workspaceViolation, "\(p) is not a path inside Assets/.") }
        case .listRootGameObjects(let s?, _): if !isSafeProjectPath(s) { return .deny(.workspaceViolation, "\(s) is not a scene inside Assets/.") }
        default: break
        }
        if case .shutdown = op, status?.owned != true { return .deny(.securityBlocked, "JARVIS only closes an editor it started itself.") }

        // Mutations must name exactly one object.
        switch op {
        case .addComponent(let t, _, _), .setSerializedProperty(let t, _, _, _, _, _), .createPrefab(let t, _):
            if !t.isPrecise { return .deny(.ambiguousTarget, "A GameObject must be identified by path or global ID, not by name \"\(t.name ?? "?")\".") }
        case .createGameObject(_, _, let parent, _, _, _, _, _):
            if let parent, !parent.isPrecise { return .deny(.ambiguousTarget, "The parent must be identified by path or global ID.") }
        default: break
        }

        if let denied = editorStateDenial(op, status: status) { return denied }

        // Unsaved work that is not JARVIS' own is never overwritten silently.
        if op.isPersistentMutation, let status {
            let dirty = status.userDirtyScenes.filter { !approvedDirtyScenes.contains($0.path) }
            if !dirty.isEmpty {
                let names = dirty.map { $0.path.isEmpty ? "(untitled)" : $0.path }.joined(separator: ", ")
                return .needsApproval(action: "Modify Unity scene with your unsaved changes: \(names)",
                                      reason: "The scene has unsaved changes JARVIS did not make. Saving it would include them. JARVIS only continues if you approve.", risk: .high)
            }
        }
        return .allow
    }

    /// Editor-state rules that no approval can override (Play Mode, compilation, project errors).
    static func editorStateDenial(_ op: UnityOperation, status: UnityStatusSnapshot?) -> Decision? {
        guard let status else { return nil }
        if op.isPersistentMutation {
            if status.isPlaying || status.state == "playing" || status.state == "enteringPlay" || status.state == "paused" {
                return .deny(.unsafeEditorState, "Persistent project changes are not allowed while Play Mode is active. Exit Play Mode first.")
            }
            if status.isCompiling || status.state == "importing" { return .deny(.unsafeEditorState, "Unity is compiling or importing; the change was not applied.") }
        }
        switch op {
        case .enterPlayMode: if status.compileFailed { return .deny(.compileFailed, "The project has script compile errors; Play Mode cannot be entered.") }
        case .openScene: if status.isPlaying { return .deny(.unsafeEditorState, "Scenes cannot be switched during Play Mode.") }
            if !status.scenes.filter(\.dirty).isEmpty { return .deny(.unsafeEditorState, "A loaded scene has unsaved changes; opening another scene would discard them.") }
        case .runTests, .requestCompilation:
            if status.isPlaying { return .deny(.unsafeEditorState, "Tests and compilation do not run during Play Mode.") }
            if case .runTests = op, !status.scenes.filter(\.dirty).isEmpty { return .deny(.unsafeEditorState, "A loaded scene has unsaved changes; the Unity test runner would discard or prompt for them.") }
        default: break
        }
        return nil
    }

    // MARK: Identity

    enum Resolution: Equatable {
        case unique(UnityObjectRef)
        case none
        case ambiguous([UnityObjectRef])
    }

    /// Resolution of a lookup result: exactly one match is usable; several are NEVER resolved by picking the first.
    static func resolve(_ candidates: [UnityObjectRef]) -> Resolution {
        switch candidates.count { case 0: .none; case 1: .unique(candidates[0]); default: .ambiguous(candidates) }
    }

    static func ambiguityMessage(name: String, candidates: [UnityObjectRef]) -> String {
        "\(candidates.count) GameObjects are named “\(name)” (" + candidates.prefix(4).map { ($0.indexedPath ?? $0.path) + " in " + ($0.scene.isEmpty ? "unsaved scene" : $0.scene) }.joined(separator: "; ") + (candidates.count > 4 ? "; …" : "") + "). Tell me which one (its hierarchy path)."
    }

    // MARK: Play Mode for non-Unity writes

    /// Script (or other project file) edits must not happen while the editor is in Play Mode.
    static func allowsProjectFileEdit(status: UnityStatusSnapshot?) -> Decision {
        guard let status else { return .allow }
        if status.isPlaying || status.state == "playing" || status.state == "paused" || status.state == "enteringPlay" {
            return .deny(.unsafeEditorState, "Unity is in Play Mode; project files are not edited until it is back in Edit Mode.")
        }
        return .allow
    }
}
