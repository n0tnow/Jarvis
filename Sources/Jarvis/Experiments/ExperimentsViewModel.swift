import Foundation
import Observation

/// What the Experiments card shows, read from the repository on demand (opening the Tasks screen, a finished task, a project change). It polls nothing and never writes.
@MainActor
@Observable
final class ExperimentsViewModel {
    private let repository: JarvisRepository?
    private(set) var experiments: [ExperimentRecord] = []
    private(set) var observations: [VisualObservationRecord] = []

    init(repository: JarvisRepository?) { self.repository = repository }

    func refresh() {
        experiments = (try? repository?.recentExperiments(limit: 4)) ?? []
        observations = (try? repository?.recentVisualObservations(limit: 6)) ?? []
    }
}
