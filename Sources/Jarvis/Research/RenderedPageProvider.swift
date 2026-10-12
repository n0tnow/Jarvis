import Foundation
import AppKit
import WebKit

/// Rendered-page retrieval (V0.9 browser tier). Chosen over Playwright after evaluating it (Apache-2.0, but needs Node plus a ~150+ MB
/// downloaded Chromium per Mac and a second process tree JARVIS would have to supervise): the system WebKit is already on the machine, is
/// owned by this process (its helper processes exit with it), needs no download, and runs with a NON-PERSISTENT website data store — a
/// dedicated, empty, throw-away profile. It never touches Safari/Chrome profiles, cookies, passwords or the Keychain, and there is no
/// credential entry. The page is read, never operated: JARVIS evaluates ONE fixed extraction script (a compile-time constant), never
/// model- or page-provided JavaScript.
///
/// Used only when plain HTTP returned a JavaScript shell and a budgeted browser navigation is allowed. Every navigation (including redirects)
/// is revalidated by the URL gate; a content rule list blocks sub-resource requests to localhost/private/link-local addresses and non-http(s) schemes.
@MainActor
final class RenderedPageProvider: NSObject {
    struct Page: Sendable { var finalURL: URL; var title: String; var text: String; var html: String; var links: [PageLink] }

    /// The extraction script. A constant: nothing from the network, the page or a model is ever concatenated into it.
    static let extractionScript = """
    (function () {
      var out = {title: document.title || "", text: "", html: "", links: []};
      try { out.text = (document.body && document.body.innerText || "").slice(0, 90000); } catch (e) {}
      try { out.html = document.documentElement.outerHTML.slice(0, 1500000); } catch (e) {}
      try {
        var as = document.querySelectorAll("a[href]");
        for (var i = 0; i < as.length && i < 300; i++) { out.links.push([as[i].href, (as[i].innerText || "").slice(0, 160)]); }
      } catch (e) {}
      return JSON.stringify(out);
    })();
    """

    /// WebKit content-blocker rules (the url-filter dialect has no alternation, so one rule per range): no sub-resource may reach loopback,
    /// private, link-local, IPv6-literal or non-http(s) targets; media and fonts are not loaded.
    static let blockedURLFilters = ["^https?://localhost", "^https?://127\\.", "^https?://10\\.", "^https?://192\\.168\\.", "^https?://172\\.1[6-9]\\.", "^https?://172\\.2[0-9]\\.", "^https?://172\\.3[01]\\.",
                                    "^https?://169\\.254\\.", "^https?://0\\.0\\.0\\.0", "^https?://\\[", "^file:", "^ftp:", "^https?://[^/]*\\.local[:/]", "^https?://[^/]*\\.internal[:/]"]
    static var blockRules: String {
        let blocks = blockedURLFilters.map { "{\"trigger\": {\"url-filter\": \"\($0)\"}, \"action\": {\"type\": \"block\"}}" }
        let media = "{\"trigger\": {\"url-filter\": \".*\", \"resource-type\": [\"media\", \"font\"]}, \"action\": {\"type\": \"block\"}}"
        return "[" + (blocks + [media]).joined(separator: ",") + "]"
    }
    private(set) var contentRulesActive = false

    private(set) var activeNavigations = 0
    private var webView: WKWebView?
    private var window: NSWindow?
    private var ruleList: WKContentRuleList?
    private var teardown: Task<Void, Never>?
    var idleTeardown: TimeInterval = 30
    private let gate: URLGate
    private var continuation: CheckedContinuation<Result<Void, ResearchFailure>, Never>?
    private var navigationError: ResearchFailure?
    private(set) var processStarted = false

    init(gate: URLGate) { self.gate = gate; super.init() }

    var isLoaded: Bool { webView != nil }

    /// Loads `url` (already authorized by the caller), lets scripts settle, extracts text/HTML/links, tears the page down.
    func render(_ url: URL, timeout: TimeInterval = 25, settle: TimeInterval = 1.5) async -> Result<Page, ResearchFailure> {
        teardown?.cancel()
        activeNavigations += 1
        defer { activeNavigations -= 1; scheduleTeardown() }
        let wv: WKWebView
        do { wv = try await ensureWebView() } catch { return .failure(.providerFailed("the rendering engine could not start")) }
        navigationError = nil
        let loaded: Result<Void, ResearchFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, ResearchFailure>, Never>) in
                self.continuation = cont
                wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    self?.finish(.failure(.timeout)); wv.stopLoading()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(.cancelled)); self?.webView?.stopLoading() }
        }
        if case .failure(let f) = loaded { return .failure(f) }
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))          // scripts that build the page after load
        if Task.isCancelled { return .failure(.cancelled) }
        do {
            guard let json = try await wv.evaluateJavaScript(Self.extractionScript) as? String, let v = JSONValue.parse(json) else { return .failure(.providerFailed("the page could not be read")) }
            let links = (v["links"]?.array ?? []).compactMap { l -> PageLink? in
                guard let href = l[0]?.string else { return nil }
                return PageLink(href: href, text: l[1]?.string ?? "")
            }
            return .success(Page(finalURL: wv.url ?? url, title: v["title"]?.string ?? "", text: v["text"]?.string ?? "", html: v["html"]?.string ?? "", links: links))
        } catch { return .failure(.providerFailed("the page could not be read")) }
    }

    private func finish(_ r: Result<Void, ResearchFailure>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: r)
    }

    private func ensureWebView() async throws -> WKWebView {
        if let webView { return webView }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()                   // a dedicated, empty, throw-away profile
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.suppressesIncrementalRendering = true
        if ruleList == nil {
            ruleList = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "jarvis-research-block", encodedContentRuleList: Self.blockRules)
        }
        if let ruleList { cfg.userContentController.add(ruleList); contentRulesActive = true }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.customUserAgent = WebClient.defaultUserAgent + " AppleWebKit"
        // An unattached WKWebView is throttled by WebKit; an off-screen, never-shown window keeps timers running without any UI.
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.contentView = wv
        w.orderBack(nil)
        webView = wv; window = w; processStarted = true
        return wv
    }

    private func scheduleTeardown() {
        guard activeNavigations == 0 else { return }
        teardown?.cancel()
        teardown = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.idleTeardown * 1_000_000_000))
            if !Task.isCancelled, self.activeNavigations == 0 { self.shutdown() }
        }
    }

    /// Memory pressure (ResourceManager, V0.9): an IDLE browser is released at once; one that is navigating finishes its page first (its idle teardown follows).
    func releaseUnderPressure() { if activeNavigations == 0 { shutdown() } }

    /// Stops loading, closes the throw-away window and releases the web view (its WebContent process exits with it).
    func shutdown() {
        teardown?.cancel(); teardown = nil
        finish(.failure(.cancelled))
        webView?.stopLoading()
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        window?.contentView = nil; window?.close()
        webView = nil; window = nil
    }
}

extension RenderedPageProvider: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" { return .allow }
        switch await gate.authorize(url: url) {
        case .success: return .allow
        case .failure(let e): navigationError = .blockedByURLPolicy(e.description); return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // A download is acquisition, a different authority: the browser tier only ever renders pages.
        if !navigationResponse.canShowMIMEType { navigationError = .unsupportedContent(navigationResponse.response.mimeType ?? "unknown"); return .cancel }
        if let http = navigationResponse.response as? HTTPURLResponse, http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true {
            navigationError = .unsupportedContent("attachment"); return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(navigationError ?? TransferHandler.map(error as NSError))) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(navigationError ?? TransferHandler.map(error as NSError))) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(.providerFailed("the rendering process ended"))) }

    // Pages cannot open windows, and JavaScript dialogs are answered "no" — nothing a page asks for ever reaches the user or the system.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }
}


/// How research reacts to system pressure (DEC-103): under memory pressure plain HTTP is preferred over the heavier browser tier — the task stays correct, a
/// JavaScript-only page is then reported as "needs the browser" instead of being rendered. Pure so it is testable.
enum ResearchResourcePolicy {
    static func allowsBrowser(memory: MemoryPressureLevel, thermalSerious: Bool = false) -> Bool { memory == .normal && !thermalSerious }
}
