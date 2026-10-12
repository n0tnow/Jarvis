import Foundation

/// Bridges the @MainActor browser tier to the `RenderedFetching` seam the pipeline uses.
struct RenderedBridge: RenderedFetching {
    let provider: RenderedPageProvider
    let gate: URLGate
    func render(_ url: URL) async -> Result<RenderedPageProvider.Page, ResearchFailure> {
        await provider.render(url)
    }
}

/// Everything the task engine needs to run research and acquisition steps. Built once by `AppContext`; tests build one over a fixture server.
final class ResearchServices: @unchecked Sendable {
    let client: WebClient
    let providers: [any SearchProvider]
    let rendered: (any RenderedFetching)?
    let persistence: SQLiteResearchPersistence?
    let acquisition: AcquisitionService
    let paths: JarvisPaths
    let browser: RenderedPageProvider?

    init(client: WebClient, providers: [any SearchProvider], rendered: (any RenderedFetching)? = nil, browser: RenderedPageProvider? = nil, persistence: SQLiteResearchPersistence? = nil, paths: JarvisPaths) {
        self.client = client; self.providers = providers; self.rendered = rendered; self.browser = browser; self.persistence = persistence; self.paths = paths
        self.acquisition = AcquisitionService(downloader: Downloader(client: client), paths: paths, store: persistence)
    }

    static let defaultProviders: [any SearchProvider] = [UnityDocsProvider(), DuckDuckGoHTMLProvider(), GitHubSearchProvider(), HackerNewsProvider(), StackExchangeProvider(), PolyHavenProvider(), KenneyProvider()]

    @MainActor
    static func standard(paths: JarvisPaths, repository: JarvisRepository?, artifacts: ArtifactStore?) -> ResearchServices {
        let gate = URLGate()
        let client = WebClient(gate: gate)
        let browser = RenderedPageProvider(gate: gate)
        let persistence = repository.map { SQLiteResearchPersistence(repository: $0, artifacts: artifacts) }
        return ResearchServices(client: client, providers: defaultProviders, rendered: RenderedBridge(provider: browser, gate: gate), browser: browser, persistence: persistence, paths: paths)
    }
}
