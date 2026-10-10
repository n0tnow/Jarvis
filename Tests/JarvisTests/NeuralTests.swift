import Foundation
import Testing
@testable import Jarvis

@Suite("Neural background")
struct NeuralTests {
    @Test func graphIsDeterministicForASeed() {
        let a = NeuralGraph.generate(seed: 42), b = NeuralGraph.generate(seed: 42), c = NeuralGraph.generate(seed: 43)
        #expect(a.nodes.map(\.x) == b.nodes.map(\.x))
        #expect(a.edges.map { [$0.a, $0.b] } == b.edges.map { [$0.a, $0.b] })
        #expect(a.nodes.map(\.x) != c.nodes.map(\.x))
    }

    @Test func graphIsSparseAndWellFormed() {
        let g = NeuralGraph.generate()
        #expect(g.nodes.count == 45)
        #expect(g.edges.count >= g.nodes.count && g.edges.count <= g.nodes.count * 2)
        #expect(g.edges.allSatisfy { $0.a != $0.b && g.nodes.indices.contains($0.a) && g.nodes.indices.contains($0.b) })
        #expect(Set(g.edges.map { "\($0.a)-\($0.b)" }).count == g.edges.count)   // no duplicates
        #expect(g.nodes.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) && (0.35...1).contains($0.depth) })
        #expect(g.incident.indices.allSatisfy { !g.incident[$0].isEmpty })        // no isolated nodes
    }

    @Test func simulationStaysBoundedForEveryState() {
        let g = NeuralGraph.generate()
        for state in JarvisState.allCases {
            var sim = NeuralSimulation(nodeCount: g.nodes.count)
            sim.burst(for: state, graph: g)
            for _ in 0..<3000 {   // ~50 s at 60 Hz of simulated time
                sim.step(dt: 1.0 / 60, profile: .profile(for: state, sinceEnter: 0), graph: g)
                #expect(sim.pulses.count <= NeuralSimulation.maxPulses)
            }
            #expect(sim.energy.allSatisfy { (0...1).contains($0) })
            #expect(sim.pulses.allSatisfy { $0.progress >= 0 && $0.progress < 1 && g.edges.indices.contains($0.edge) })
        }
    }

    @Test func activityScalesWithState() {
        func averagePulses(_ state: JarvisState) -> Double {
            let g = NeuralGraph.generate()
            var sim = NeuralSimulation(nodeCount: g.nodes.count)
            var total = 0
            for _ in 0..<1800 { sim.step(dt: 1.0 / 30, profile: .profile(for: state), graph: g); total += sim.pulses.count }
            return Double(total) / 1800
        }
        #expect(averagePulses(.idle) < averagePulses(.working))
        #expect(averagePulses(.working) < averagePulses(.thinking))
        #expect(averagePulses(.waitingForApproval) < averagePulses(.working))
    }

    @Test func frameRatesAreCappedAndCalmWhenIdle() {
        #expect(JarvisState.allCases.allSatisfy { NeuralProfile.profile(for: $0).fps <= 15 })
        #expect(NeuralProfile.profile(for: .idle).fps < NeuralProfile.profile(for: .thinking).fps)
        // completed / error settle back to the calm profile
        #expect(NeuralProfile.profile(for: .completed, sinceEnter: 10) == NeuralProfile.profile(for: .idle))
        #expect(NeuralProfile.profile(for: .error, sinceEnter: 10) == NeuralProfile.profile(for: .idle))
    }

    @Test func burstAndResetBehave() {
        let g = NeuralGraph.generate()
        var sim = NeuralSimulation(nodeCount: g.nodes.count)
        sim.burst(for: .completed, graph: g)
        #expect(!sim.pulses.isEmpty)
        sim.reset()
        #expect(sim.pulses.isEmpty && sim.energy.allSatisfy { $0 == 0 })
        sim.burst(for: .idle, graph: g)
        #expect(sim.pulses.isEmpty)
    }
}

@Suite("Compact HUD geometry")
struct CompactGeometryTests {
    @Test func canonicalSizeIsFixedAndRoomy() {
        #expect(CompactHUDLayout.size == CGSize(width: 392, height: 448))
        #expect(CompactHUDLayout.taskCardHeight < CompactHUDLayout.size.height / 2)
        #expect(CompactHUDLayout.transition >= 0.15 && CompactHUDLayout.transition <= 0.3)
    }
}
