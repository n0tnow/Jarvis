# V0.14 guards (sourced by scripts/verify.sh after helpers pass/fail/v09_none/nonc exist). One function per guard keeps the quoting readable.
AD=Sources/Jarvis/Adaptive; CP=Sources/Jarvis/Capabilities
has() { grep -qF -- "$2" "$1" || echo "missing in $1: $2"; }

g14_orchestrator() {
  grep -rnE '(class|struct|enum|actor) +[A-Za-z]*(SelfImprove|Adaptive|MCP|Learning|Skill)[A-Za-z]*Orchestrat' Sources | nonc
  grep -rnE 'planOrchestrated|saveGraph|AgentJob\(|\.agents\.run|ManagerAgentRunner|StepAgentRunner' $AD $CP | grep -v 'SelfImprovement.swift' | nonc
}
v09_none "there is no second orchestrator: no SelfImprovementOrchestrator / AdaptiveOrchestrator / MCPOrchestrator type exists, and the adaptive and capability layers never run agents, plan graphs or save graphs themselves" "$(g14_orchestrator)"

g14_selfsource() {
  grep -rnE 'ProjectTools|WorkspaceGuard|AssetImporter|\.write\(to:|createFile\(|replaceItem|\.removeItem\(|moveItem|FileHandle\(forWriting' $AD | nonc
  local n; n=$(grep -rn 'engine.submit(' $AD | nonc | wc -l | tr -d ' ')
  [ "$n" = "1" ] || echo "expected exactly one engine.submit in the adaptive layer, found $n"
  grep -rn 'engine.submit(' $AD | nonc | grep -v 'SelfImprovement.swift'
}
v09_none "JARVIS changes its own source ONLY by creating an ordinary V0.12 development task: the adaptive layer has no file write, no project tool, no importer, and exactly one engine.submit (SelfImprovement.swift, started from an approved request)" "$(g14_selfsource)"

g14_selfgate() {
  has $AD/SelfImprovement.swift 'level() >= .approvedSelfImprovement'
  has $AD/SelfImprovement.swift 'cp.isClean'
  has $AD/SelfImprovement.swift 'p.checkpoint = cp'
  has $AD/SelfImprovement.swift 'NOT promoted'
  has $AD/LearningModel.swift 'case observe = 0, learn = 1, experiment = 2, propose = 3, approvedSelfImprovement = 4'
  has Sources/Jarvis/Core/Preferences.swift '?? .experiment'
}
v09_none "a self-change needs level 4 (no level 5), an HUD-decided request, a recorded checkpoint and a CLEAN working tree; a failed change is never promoted; the default level is Experiment" "$(g14_selfgate)"

g14_approval() {
  has $AD/LearningModel.swift 'enum AdaptiveDecisionSource: String, Sendable { case hud, test }'
  grep -rnE 'adaptiveDecisions|AdaptiveDecisionService|approveByStandingPolicy|decisions\.(approve|deny)' Sources/Jarvis/Voice Sources/Jarvis/Services/Conversation Sources/Jarvis/Memory Sources/Jarvis/Proactive Sources/Jarvis/Orchestration | nonc
  grep -rnE 'decisions\.approve\(|approveByStandingPolicy\(' $AD $CP | nonc | grep -vE 'AdaptiveViewModels.swift|LearningService.swift|AdaptiveDecisions.swift'
}
v09_none "approval is HUD-only: AdaptiveDecisionSource has exactly hud and test (no voice, no text, no model); the voice, conversation, memory, proactive and orchestration layers cannot decide a request; only the HUD view models and the standing-policy path call approve" "$(g14_approval)"

g14_rules() {
  has $AD/LearningModel.swift 'case requireExperiment, requireExtraValidation, requireIndependentReview, preferWorkflow, avoidSource, addWarning, preferCapability'
  awk '/enum RuleActionKind/,/^}/' $AD/LearningModel.swift | grep -E '^ *case ' | grep -iE 'approve|grant|install|delete|send[^a]|purchase|sandbox|shell|execute|remove' | nonc
  awk '/static func applyLearnedRequirements/,/^    }/' Sources/Jarvis/Tasks/TaskEngine+Orchestration.swift | grep -E 'plan\.steps\.remove|plan\.steps = |removeAll|removeLast|removeFirst' | head -3
}
v09_none "learned rules are DATA from a closed vocabulary that can only ADD requirements: the seven listed actions, none named approve / grant / install / delete / send / purchase / sandbox / shell / execute, and the engine's use of them only appends a test, a review or a warning" "$(g14_rules)"

g14_admission() {
  has $AD/LearningService.swift 'func admit(_ d: CandidateDraft'
  for k in 'LearningGate.refuseText' 'evidenceResolves' 'overgeneralization' 'LearningGate.problems(in: rule)' 'audit("refused"'; do has $AD/LearningService.swift "$k"; done
  grep -rn 'repository.save(c)\|repository?.save(c)\|repo.save(c)' $AD | grep -v 'LearningService.swift' | nonc
}
v09_none "learning text is gated: every candidate passes ONE admission door (secret, authority, injection, vocabulary, evidence, overgeneralisation), refusals are audited, and an authority-shaped statement is never stored" "$(g14_admission)"

g14_memory() {
  grep -rnE 'LearningService|SelfImprovement|MCPRegistry|AdaptiveDecision|LearnedRule|LearningCandidate' Sources/Jarvis/Memory | nonc
  grep -rnE 'MemoryService|ProjectMemory|memory\.admit|ProjectContextBuilder' $AD | nonc
}
v09_none "memory cannot activate learning or approve self-modification, and learning never writes memory: the memory layer knows nothing about learning / MCP / self-improvement, and the adaptive layer never touches the memory service" "$(g14_memory)"

g14_activation() {
  grep -rn 'to: .active\|\.status = .active\|status: .active' $CP | nonc | grep -vE 'MCPRegistry.swift|MCPModel.swift|SkillRegistry.swift'
  awk '/case .discovered: \[/{print} /case .inspected: \[/{print} /case .sandboxed: \[/{print} /case .benchmarked: \[/{print} /case .recommended: \[/{print}' $CP/MCPModel.swift | grep -E '\.active|\.installed'
  local n; n=$(grep -c 'to: .active' $CP/MCPRegistry.swift); [ "$n" -le 3 ] || echo "too many direct activations ($n)"
}
v09_none "an MCP never becomes active by itself: ACTIVE is reachable only through an approved request (install / enable / revalidation) and the status machine has no edge from discovered, inspected, sandboxed, benchmarked or recommended to active or installed" "$(g14_activation)"

g14_requests() {
  grep -rnE 'requestInstall\(|requestUpdate\(|requestRemoval\(|executeInstall|executeRemoval|executeUpdate' Sources | nonc | grep -vE 'Capabilities/MCPRegistry.swift|Adaptive/AdaptiveAssistant.swift|Adaptive/AdaptiveViewModels.swift|App/McpLiveTest.swift|App/AdaptiveLiveTest.swift|UI/FullHUD/Capabilities/CapabilitiesSectionView.swift|Services/Demo/AdaptiveDemo.swift'
}
v09_none "registration, update and removal are never automatic: they are created only as REQUESTS by the view model, the conversation assistant or a test, and executed only by AdaptiveDecisionService after a decision" "$(g14_requests)"

g14_removal() {
  awk '/private func executeRemoval/,/^    }/' $CP/MCPRegistry.swift | grep -E 'removeItem\(at: dir\)|removeItem\(atPath: dir\)' | grep -v 'isEmpty' | nonc
  has $CP/MCPRegistry.swift 'S_IFLNK'
  has $CP/MCPRegistry.swift 'activeTaskIDs(s.id)'
  has $CP/MCPRegistry.swift '!clean.contains("..")'
  has $CP/MCPRegistry.swift 'hasPrefix(ProcessInfoPath.canonical(serversDirectory.path)'
}
v09_none "MCP removal deletes only JARVIS-owned files: exact recorded paths inside JARVIS' own server folder (no wildcard, no traversal, symlinks removed not followed), active tasks re-checked at execution, a folder only when empty" "$(g14_removal)"

g14_mcpauthority() {
  grep -rnE 'TaskCapability|CapabilitySet|ComputerPolicy|OpportunityPolicy|ProposalService|ApprovalGuard|taskEngine|\.submit\(' $CP | grep -vE 'SkillRegistry.swift|MCPInspectionRules.swift' | nonc
  has $CP/MCPClient.swift 'OutputSanitizer.sanitize'
  has $CP/MCPClient.swift 'UntrustedContent.scan'
}
v09_none "an MCP can never grant authority: server output is data (sanitised, bounded, instruction-shaped text only counted) and the capability layer references no approval, policy, task-capability or proposal code" "$(g14_mcpauthority)"

g14_wrappers() {
  has $CP/MCPRegistry.swift 'tool.risk != .broad'
  has $CP/MCPRegistry.swift '!w.envelope.isNeverAutomatic'
  has $CP/MCPRegistry.swift 'Self.validate(args, against: w)'
  has $CP/MCPRegistry.swift 'context.userPresent'
  grep -rn 'conn.call(\|connection.call(' $CP Sources/Jarvis/Tasks Sources/Jarvis/Orchestration | nonc | grep -vE 'MCPRegistry.swift|MCPBenchmark.swift'
}
v09_none "agents never see a raw MCP tool: only typed wrappers inside the registered envelope, never a BROAD (shell / arbitrary code) tool, never-automatic envelopes need a person present, and arguments are validated by JARVIS" "$(g14_wrappers)"

g14_env() {
  grep -rn 'ProcessInfo.processInfo.environment\|ProviderEnvironment.make' $CP | nonc
  for k in '(deny network*)' '(deny file-write*)' '(deny file-read*' 'looksSecret' 'SSH_AUTH_SOCK'; do has $CP/MCPSandbox.swift "$k"; done
}
v09_none "an MCP never inherits your environment or secrets: the sandbox environment is built from scratch (no process environment), secret-shaped names/values are dropped, and the Seatbelt profile denies the network, writes outside the folder and home reads" "$(g14_env)"

g14_scope() {
  has $CP/MCPRegistry.swift 'filter { $0 != "*" && !$0.isEmpty }'
  grep -rniE 'autoUpdate|automaticUpdate|autoInstall|checkForUpdates' $AD $CP | grep -v 'MCPInspectionRules.swift' | nonc
  grep -rnE 'Timer\.|scheduledTimer|DispatchSource|asyncAfter|DispatchQueue.*after' $AD $CP Sources/Jarvis/Research/MCPDiscovery.swift | nonc
}
v09_none "MCP servers have no wildcard filesystem scope, no automatic update and no hidden persistence: the allowed-project list drops \"*\", there is no auto-update path and no timer (a server runs on demand with a one-shot idle stop)" "$(g14_scope)"

g14_idle() {
  grep -rnE 'MCPDiscovery\(|discovery\.search\(|\.search\(domain' Sources | nonc | grep -vE 'Research/MCPDiscovery.swift|Adaptive/AdaptiveAssistant.swift|AppContext.swift|App/McpLiveTest.swift'
  grep -rnE 'learning\.extract\(|\.extract\(reason' Sources | nonc | grep -vE 'Adaptive/LearningService.swift|AdaptiveViewModels.swift|App/AdaptiveLiveTest.swift|Services/Demo/AdaptiveDemo.swift'
  grep -rnE 'MCPBenchmarkRunner.run\(' Sources | nonc | grep -vE 'Capabilities/MCPBenchmark.swift|AdaptiveAssistant.swift|AdaptiveViewModels.swift|App/McpLiveTest.swift'
}
v09_none "nothing runs while idle: discovery, learning extraction and benchmarks start only from a user request, a finished task or a live test — never from a timer, a launch or a poll" "$(g14_idle)"

g14_storage() {
  awk '/static let v13/,0' Sources/Jarvis/Persistence/Migrations.swift | grep -nEi 'blob|png|image|screenshot|transcript|reasoning|thought|raw_output|password|secret' | nonc
  local n; n=$(grep -c 'lclean' Sources/Jarvis/Persistence/LearningRepository.swift); [ "$n" -ge 8 ] || echo "learning rows are not sanitised ($n)"
}
v09_none "learning stores no secret, no picture, no raw tool output and no reasoning: rows are sanitised on write and the v13/v14 schema has no blob, image, transcript or reasoning column" "$(g14_storage)"

g14_routing() {
  has $AD/LearningModel.swift 'static let limit = 0.2'
  has Sources/Jarvis/Intelligence/RoutingTypes.swift 'min(RoutingAdjustment.limit'
  awk '/private static func explicitFree|private static func explicitPremium|private static func explicitLocal/,/^    }/' Sources/Jarvis/Intelligence/ModelRouter.swift | grep -n 'bias' | head -2
}
v09_none "learned routing nudges are bounded (|bias| ≤ 0.2) and only order providers that are already eligible; an explicit provider choice never reads them" "$(g14_routing)"

g14_target() {
  grep -rn 'selfRepositoryPath = ' Sources | nonc | grep -vE 'App/AdaptiveLiveTest.swift'
}
v09_none "the production repository of JARVIS is never a self-change target unless configured: selfRepositoryPath is assigned only by live tests (disposable fixtures); the app default is none" "$(g14_target)"
