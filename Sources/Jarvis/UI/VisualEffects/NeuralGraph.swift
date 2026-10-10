import Foundation

/// Deterministic PRNG (SplitMix64): the same seed always yields the same graph, so the network looks
/// identical every time the HUD opens instead of being random noise.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A small sparse computational graph in unit space (0…1 × 0…1). Generated once; never regenerated.
struct NeuralGraph: Sendable {
    struct Node: Sendable {
        var x: Double
        var y: Double
        /// 0.35 (far) … 1 (near): scales opacity, size and drift for subtle parallax.
        var depth: Double
        var phase: Double
    }
    struct Edge: Sendable { let a: Int; let b: Int }

    let nodes: [Node]
    let edges: [Edge]
    /// Edge indices touching each node (for signals chaining onward).
    let incident: [[Int]]

    static let defaultSeed: UInt64 = 0x4A41_5256_4953_0011

    /// Jittered grid → each node linked to its two nearest neighbours (deduplicated). Sparse by construction.
    static func generate(columns: Int = 9, rows: Int = 5, seed: UInt64 = defaultSeed) -> NeuralGraph {
        var rng = SeededGenerator(seed: seed)
        var nodes: [Node] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let jx = Double.random(in: -0.36...0.36, using: &rng)
                let jy = Double.random(in: -0.36...0.36, using: &rng)
                nodes.append(Node(
                    x: min(0.99, max(0.01, (Double(c) + 0.5 + jx) / Double(columns))),
                    y: min(0.99, max(0.01, (Double(r) + 0.5 + jy) / Double(rows))),
                    depth: Double.random(in: 0.35...1, using: &rng),
                    phase: Double.random(in: 0...(2 * .pi), using: &rng)
                ))
            }
        }

        // Wide screens: scale x so "nearest" is judged in a roughly isotropic space.
        let aspect = 1.6
        func dist(_ i: Int, _ j: Int) -> Double {
            let dx = (nodes[i].x - nodes[j].x) * aspect, dy = nodes[i].y - nodes[j].y
            return (dx * dx + dy * dy).squareRoot()
        }
        var seen = Set<Int>()
        var edges: [Edge] = []
        for i in nodes.indices {
            let nearest = nodes.indices.filter { $0 != i }.sorted { dist(i, $0) < dist(i, $1) }.prefix(2)
            for j in nearest {
                let key = min(i, j) * nodes.count + max(i, j)
                if seen.insert(key).inserted { edges.append(Edge(a: min(i, j), b: max(i, j))) }
            }
        }
        var incident = Array(repeating: [Int](), count: nodes.count)
        for (k, e) in edges.enumerated() { incident[e.a].append(k); incident[e.b].append(k) }
        return NeuralGraph(nodes: nodes, edges: edges, incident: incident)
    }
}

/// How active the network is for a given JARVIS state.
struct NeuralProfile: Equatable, Sendable {
    var spawnRate: Double      // new signals per second
    var speed: Double          // fraction of an edge travelled per second
    var chain: Double          // probability a signal continues to a neighbouring edge
    var inward: Bool           // bias signals toward the centre ("incoming" feel)
    var strength: Double       // 0…1 brightness of signals
    var maxActive: Int
    var fps: Double            // display-link rate for this state (0 = static)

    static func profile(for state: JarvisState, sinceEnter: Double = .infinity) -> NeuralProfile {
        let calm = NeuralProfile(spawnRate: 0.25, speed: 0.5, chain: 0, inward: false, strength: 0.45, maxActive: 2, fps: 5)
        switch state {
        case .idle: return calm
        case .listening: return NeuralProfile(spawnRate: 1.6, speed: 0.9, chain: 0.2, inward: true, strength: 0.8, maxActive: 6, fps: 12)
        case .thinking: return NeuralProfile(spawnRate: 3.2, speed: 1.4, chain: 0.65, inward: false, strength: 1.0, maxActive: 12, fps: 15)
        case .working: return NeuralProfile(spawnRate: 2.2, speed: 1.0, chain: 0.45, inward: false, strength: 0.85, maxActive: 9, fps: 12)
        case .waitingForApproval: return NeuralProfile(spawnRate: 0.5, speed: 0.6, chain: 0.1, inward: false, strength: 0.55, maxActive: 3, fps: 6)
        case .completed: return sinceEnter < 2.5 ? NeuralProfile(spawnRate: 0.6, speed: 0.9, chain: 0.3, inward: false, strength: 0.7, maxActive: 5, fps: 12) : calm
        case .error: return sinceEnter < 1.5 ? NeuralProfile(spawnRate: 0.4, speed: 0.8, chain: 0, inward: false, strength: 0.5, maxActive: 4, fps: 12) : calm
        }
    }
}

/// Bounded signal simulation. Fixed-capacity pools; nothing is allocated per frame.
struct NeuralSimulation {
    struct Pulse: Sendable {
        var edge: Int
        var forward: Bool
        var progress: Double
        var strength: Double
    }

    static let maxPulses = 14

    private(set) var pulses: [Pulse] = []
    private(set) var energy: [Double]
    private var rng: SeededGenerator
    private var spawnCredit = 0.0

    init(nodeCount: Int, seed: UInt64 = 0x51_6E_65_75) {
        energy = Array(repeating: 0, count: nodeCount)
        rng = SeededGenerator(seed: seed)
        pulses.reserveCapacity(Self.maxPulses)
    }

    mutating func reset() {
        pulses.removeAll(keepingCapacity: true)
        for i in energy.indices { energy[i] = 0 }
        spawnCredit = 0
    }

    mutating func step(dt: Double, profile: NeuralProfile, graph: NeuralGraph) {
        guard !graph.edges.isEmpty else { return }
        let dt = min(max(dt, 0), 0.1)

        // decay node glow
        let decay = exp(-dt * 1.8)
        for i in energy.indices { energy[i] *= decay }

        // advance signals; on arrival light the node and maybe continue along a neighbouring edge
        var i = 0
        while i < pulses.count {
            pulses[i].progress += dt * profile.speed
            if pulses[i].progress >= 1 {
                let p = pulses[i]
                let e = graph.edges[p.edge]
                let arrival = p.forward ? e.b : e.a
                energy[arrival] = min(1, energy[arrival] + p.strength)
                pulses.remove(at: i)
                if Double.random(in: 0...1, using: &rng) < profile.chain, pulses.count < min(profile.maxActive, Self.maxPulses) {
                    let options = graph.incident[arrival].filter { $0 != p.edge }
                    if let next = options.randomElement(using: &rng) {
                        pulses.append(Pulse(edge: next, forward: graph.edges[next].a == arrival, progress: 0, strength: p.strength * 0.9))
                    }
                }
                continue
            }
            i += 1
        }

        // spawn
        spawnCredit += dt * profile.spawnRate
        while spawnCredit >= 1 {
            spawnCredit -= 1
            guard pulses.count < min(profile.maxActive, Self.maxPulses) else { spawnCredit = 0; break }
            spawn(graph: graph, inward: profile.inward, strength: profile.strength)
        }
    }

    /// One-shot effect on entering a state (completed: settling ripple outward; error: brief disruption).
    mutating func burst(for state: JarvisState, graph: NeuralGraph) {
        switch state {
        case .completed:
            for _ in 0..<6 where pulses.count < Self.maxPulses { spawn(graph: graph, inward: false, strength: 0.7, preferCentre: true) }
        case .error:
            for _ in 0..<4 where pulses.count < Self.maxPulses { spawn(graph: graph, inward: false, strength: 0.8) }
            for i in energy.indices where i % 3 == 0 { energy[i] = 0.7 }
        default: break
        }
    }

    private mutating func spawn(graph: NeuralGraph, inward: Bool, strength: Double, preferCentre: Bool = false) {
        func centreDistance(_ n: Int) -> Double {
            let dx = graph.nodes[n].x - 0.5, dy = graph.nodes[n].y - 0.5
            return (dx * dx + dy * dy).squareRoot()
        }
        var edgeIndex = Int.random(in: 0..<graph.edges.count, using: &rng)
        if preferCentre {
            // among a few random candidates pick the edge nearest the centre
            let candidates = (0..<4).map { _ in Int.random(in: 0..<graph.edges.count, using: &rng) }
            edgeIndex = candidates.min { centreDistance(graph.edges[$0].a) < centreDistance(graph.edges[$1].a) } ?? edgeIndex
        }
        let e = graph.edges[edgeIndex]
        var forward = Bool.random(using: &rng)
        if inward { forward = centreDistance(e.b) < centreDistance(e.a) }
        if preferCentre { forward = centreDistance(e.b) > centreDistance(e.a) }   // outward ripple
        pulses.append(Pulse(edge: edgeIndex, forward: forward, progress: 0, strength: strength))
    }
}
