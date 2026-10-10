import Foundation

/// ⚠️ DEMO DATA ONLY. Nothing here is produced by a real agent, project or tool.
/// Production code must not depend on this folder; only `AppContext` seeds the store with it.
enum DemoData {
    static let multiplayerTaskTitle = "Multiplayer Synchronization"

    static func multiplayerTask(now: Date = .now) -> JarvisTask {
        let elapsed: TimeInterval = 17 * 60 + 12
        return JarvisTask(
            title: multiplayerTaskTitle,
            details: "Keep player state consistent between host and clients in the prototype.",
            status: .running,
            createdAt: now.addingTimeInterval(-elapsed - 120),
            startedAt: now.addingTimeInterval(-elapsed),
            completedAt: nil,
            steps: [
                TaskStep(title: "Analyze project", status: .completed),
                TaskStep(title: "Inspect networking", status: .completed),
                TaskStep(title: "Modify implementation", status: .completed),
                TaskStep(title: "Compile", status: .active),
                TaskStep(title: "Run multiplayer tests", status: .pending),
                TaskStep(title: "Review results", status: .pending),
            ],
            accumulatedRunTime: elapsed,
            runningSince: now
        )
    }

    static func otherTasks(now: Date = .now) -> [JarvisTask] {
        [
            JarvisTask(
                title: "Profile server tick",
                details: "Measure simulation cost per tick under load.",
                status: .queued,
                createdAt: now.addingTimeInterval(-600),
                steps: [
                    TaskStep(title: "Capture baseline", status: .pending),
                    TaskStep(title: "Analyze hotspots", status: .pending),
                ]
            ),
            JarvisTask(
                title: "Write release notes",
                details: "Summarize last week's changes.",
                status: .completed,
                createdAt: now.addingTimeInterval(-7200),
                startedAt: now.addingTimeInterval(-7000),
                completedAt: now.addingTimeInterval(-6400),
                steps: [
                    TaskStep(title: "Collect changes", status: .completed),
                    TaskStep(title: "Draft notes", status: .completed),
                ],
                accumulatedRunTime: 600
            ),
        ]
    }

    static func tasks(now: Date = .now) -> [JarvisTask] {
        [multiplayerTask(now: now)] + otherTasks(now: now)
    }

    static func activity(now: Date = .now) -> [ActivityEvent] {
        [
            ActivityEvent(timestamp: now.addingTimeInterval(-17 * 60), message: "Project analyzed", kind: .success),
            ActivityEvent(timestamp: now.addingTimeInterval(-12 * 60), message: "Network architecture inspected", kind: .info),
            ActivityEvent(timestamp: now.addingTimeInterval(-6 * 60), message: "Implementation updated", kind: .success),
            ActivityEvent(timestamp: now.addingTimeInterval(-2 * 60), message: "Unity compilation passed", kind: .success),
            ActivityEvent(timestamp: now.addingTimeInterval(-45), message: "Multiplayer testing started", kind: .info),
        ]
    }

    static let project = ProjectSummary(name: "Unity Multiplayer Prototype", kind: "Unity · C#", branch: "feature/netsync")

    static let agents: [AgentSlot] = [
        AgentSlot(name: "Planner", role: "Task decomposition", status: .idle),
        AgentSlot(name: "Coding", role: "Implementation", status: .active),
        AgentSlot(name: "Research", role: "Docs & lookup", status: .standby),
        AgentSlot(name: "QA", role: "Verification", status: .standby),
    ]

    static let tools: [ToolSlot] = [
        ToolSlot(name: "Unity MCP", availability: .notConnected, plannedFor: "V0.9"),
        ToolSlot(name: "Browser", availability: .notConnected, plannedFor: "V0.10"),
        ToolSlot(name: "Terminal", availability: .notConnected, plannedFor: "V0.3"),
        ToolSlot(name: "Codex / Claude", availability: .notConnected, plannedFor: "V0.3"),
    ]

    static let approval = ApprovalRequest(
        title: "Run multiplayer tests",
        detail: "Starts two local Unity instances (host + client) for about 3 minutes."
    )
}
