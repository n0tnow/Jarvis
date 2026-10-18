import Foundation

// MARK: - Provider resilience policy (V1.0 reliability pass)
//
// The supervisor already persists failure / cooldown records per engine (`CooldownPolicy`) and restarts the local worker once. This is the PURE rule set around it, written so it can be tested without a provider:
//   · a bounded retry schedule (exponential, capped, a hard maximum) for TRANSIENT failures only — a timeout, rate limit, exhausted balance, authentication or API change is never "retried until it works";
//   · a circuit per provider: closed → open after N consecutive failures (cooldown grows by `CooldownPolicy`) → half-open after the cooldown (ONE probe) → closed on success;
//   · fallback candidates in the caller's preference order that skip an open circuit, the provider that just failed, and ANY paid provider — a paid provider is only ever used when the user chose it explicitly,
//     and an explicit choice never falls back to anything else;
//   · Jev (the optional classifier) uses the same vocabulary but its own breaker (`JevDecisionProvider`); it is never a fallback for an answer.

enum ProviderCostClass: String, Codable, Sendable, CaseIterable {
    case local, subscription, freeCloud, paid
}

enum ProviderFailureKind: String, Codable, Sendable, CaseIterable {
    case offline, crashed, timeout, rateLimited, outOfBalance, authentication, apiChanged, malformed, cancelled
    /// Worth ONE bounded retry after a short backoff: the thing may clear in moments.
    var isTransient: Bool { self == .offline || self == .crashed }
    /// Opens the circuit at once: waiting a few seconds will not fix it.
    var opensImmediately: Bool { self == .outOfBalance || self == .authentication || self == .apiChanged }
}

struct RetrySchedule: Equatable, Sendable {
    var base: TimeInterval = 2
    var factor = 2.0
    var cap: TimeInterval = 30
    var maxAttempts = 2                     // retries AFTER the first try

    func delay(afterAttempt n: Int) -> TimeInterval { min(cap, base * pow(factor, Double(max(0, n)))) }
    func shouldRetry(_ failure: ProviderFailureKind, retriesSoFar: Int) -> Bool { failure.isTransient && retriesSoFar < maxAttempts }
}

enum CircuitState: Equatable, Sendable {
    case closed
    case open(until: Date)
    /// The cooldown is over: exactly one probe request may go through.
    case halfOpen
}

struct ProviderCircuit: Equatable, Sendable {
    var consecutiveFailures = 0
    var openedUntil: Date?
    var probeInFlight = false
    var lastFailure: ProviderFailureKind?
    var totalFailures = 0
    var totalSuccesses = 0
}

final class ProviderResilienceBook: @unchecked Sendable {
    private let lock = NSLock()
    private var circuits: [String: ProviderCircuit] = [:]
    let cooldown: CooldownPolicy
    let failuresToOpen: Int
    private let clock: @Sendable () -> Date

    init(cooldown: CooldownPolicy = CooldownPolicy(), failuresToOpen: Int = 2, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.cooldown = cooldown; self.failuresToOpen = max(1, failuresToOpen); self.clock = clock
    }

    func state(_ provider: String) -> CircuitState {
        lock.lock(); defer { lock.unlock() }
        return stateLocked(provider)
    }

    private func stateLocked(_ provider: String) -> CircuitState {
        guard let c = circuits[provider], let until = c.openedUntil else { return .closed }
        return clock() < until ? .open(until: until) : .halfOpen
    }

    /// May this provider be asked right now? Half-open allows ONE probe at a time.
    func admit(_ provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch stateLocked(provider) {
        case .closed: return true
        case .open: return false
        case .halfOpen:
            var c = circuits[provider] ?? ProviderCircuit()
            if c.probeInFlight { return false }
            c.probeInFlight = true; circuits[provider] = c
            return true
        }
    }

    func recordSuccess(_ provider: String) {
        lock.lock(); defer { lock.unlock() }
        var c = circuits[provider] ?? ProviderCircuit()
        c.consecutiveFailures = 0; c.openedUntil = nil; c.probeInFlight = false; c.totalSuccesses += 1
        circuits[provider] = c
    }

    func recordFailure(_ provider: String, _ kind: ProviderFailureKind) {
        guard kind != .cancelled else { lock.lock(); circuits[provider]?.probeInFlight = false; lock.unlock(); return }      // a user cancel is not the provider's fault
        lock.lock(); defer { lock.unlock() }
        var c = circuits[provider] ?? ProviderCircuit()
        c.consecutiveFailures += 1; c.totalFailures += 1; c.lastFailure = kind; c.probeInFlight = false
        if kind.opensImmediately || c.consecutiveFailures >= failuresToOpen {
            let length = kind.opensImmediately ? cooldown.maxSeconds : max(cooldown.baseSeconds, cooldown.duration(forConsecutiveFailures: c.consecutiveFailures))
            c.openedUntil = clock().addingTimeInterval(length)
        }
        circuits[provider] = c
    }

    func circuit(_ provider: String) -> ProviderCircuit { lock.lock(); defer { lock.unlock() }; return circuits[provider] ?? ProviderCircuit() }
}

struct FallbackCandidate: Equatable, Sendable {
    var id: String
    var cost: ProviderCostClass
}

enum FallbackPolicy {
    /// The providers that may serve a request after `failed` could not, in the caller's order. Rules, in force always:
    ///   · an EXPLICIT user choice never falls back (the answer is: say it failed);
    ///   · the provider that just failed and any provider whose circuit is open are skipped;
    ///   · a PAID provider is never an automatic fallback — only `explicitlyChosen` may be one.
    static func candidates(order: [FallbackCandidate], failed: String?, explicitChoice: String?, book: ProviderResilienceBook) -> [FallbackCandidate] {
        guard explicitChoice == nil else { return [] }
        return order.filter { c in
            c.id != failed && c.cost != .paid && { if case .open = book.state(c.id) { return false }; return true }()
        }
    }

    /// Whether `provider` may be used for a request at all under the cost rules: paid only when explicitly chosen.
    static func mayUse(_ c: FallbackCandidate, explicitChoice: String?) -> Bool { c.cost != .paid || explicitChoice == c.id }
}
