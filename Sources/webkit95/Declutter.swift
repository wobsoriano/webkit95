import AppKit
import WebKit
import Webkit95Agent
import Webkit95Kit

/// POSTs to Jev with URLSession. Ephemeral: no cookies, no cache, no stored credentials. Redirects
/// are refused, so the Authorization header never reaches another host, and the body is read only
/// up to the cap.
final class URLSessionJevTransport: NSObject, JevTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func post(_ request: URLRequest, maxBytes: Int) async throws(JevTransportError) -> JevHTTPReply {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw JevTransportError.network("The server's reply was not HTTP.") }
            if (300..<400).contains(http.statusCode) { throw JevTransportError.redirected }
            if http.expectedContentLength > Int64(maxBytes) { throw JevTransportError.oversized }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBytes { throw JevTransportError.oversized }
            }
            return JevHTTPReply(status: http.statusCode, url: http.url, body: body)
        } catch let error as JevTransportError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw .timeout
        } catch let error as URLError {
            throw .network(error.localizedDescription)
        } catch {
            throw .network("The request failed.")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// App wide Declutter state: the key (looked up once), the Jev client, the template cache, the
/// Auto Declutter sites and the consent, each saved in the support directory.
@MainActor
final class DeclutterService {
    let policy = DeclutterPolicy.standard
    let client: JevClient
    private(set) var sites: DeclutterSites
    private(set) var consent: DeclutterConsent?
    private(set) var cache: TemplateCache
    /// Real or fake, for the control socket and the log.
    private(set) var apiCalls = 0
    private let environment: [String: String]
    private let probeAllowed: Bool
    private var keyLookup: Task<JevKey?, Never>?
    private let cacheURL: URL
    private let sitesFile: JSONFile<DeclutterSites>
    private let consentFile: JSONFile<DeclutterConsent>

    init(supportDir: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        self.environment = environment
        // A debug build pointed at a fake server takes the key from its own environment only, so
        // the real key in the login shell can never reach the fake.
        probeAllowed = !JevEndpoint.isOverridden(environment: environment, debug: debug)
        var timeout: TimeInterval = 20
        #if DEBUG
        if let t = environment["WEBKIT95_JEV_TIMEOUT"].flatMap(Double.init), t > 0 { timeout = t }
        #endif
        client = JevClient(endpoint: JevEndpoint.resolve(environment: environment, debug: debug),
                           transport: URLSessionJevTransport(), timeout: timeout, policy: policy)
        cacheURL = supportDir.appendingPathComponent("declutter-templates.json")
        sitesFile = JSONFile(supportDir.appendingPathComponent("declutter-sites.json"))
        consentFile = JSONFile(supportDir.appendingPathComponent("declutter-consent.json"))
        cache = TemplateCache.load(from: cacheURL, limit: policy.cacheLimit)
        sites = sitesFile.load() ?? DeclutterSites()
        consent = consentFile.load()
    }

    var hasConsent: Bool { consent?.isCurrent == true }

    func recordConsent() {
        consent = DeclutterConsent()
        do { try consentFile.save(DeclutterConsent()) } catch { log("declutter consent: \(error)") }
    }

    func setAuto(_ on: Bool, host: String) {
        if on { sites.add(host) } else { sites.remove(host) }
        do { try sitesFile.save(sites) } catch { log("declutter sites: \(error)") }
    }

    func cachedRules(_ key: TemplateKey) -> [HideRule]? {
        let rules = cache.lookup(key)
        if rules != nil { saveCache() }
        return rules
    }

    func store(_ key: TemplateKey, rules: [HideRule], candidateCount: Int) {
        cache.store(key, rules: rules, candidateCount: candidateCount)
        saveCache()
    }

    private func saveCache() {
        do { try cache.save(to: cacheURL) } catch { log("declutter cache: \(error)") }
    }

    /// From the environment, else one login shell probe per launch.
    func key() async -> JevKey? {
        if let keyLookup { return await keyLookup.value }
        let environment = environment
        let probeAllowed = probeAllowed
        let lookup = Task.detached {
            JevKey.resolve(environment: environment) { probeAllowed ? LoginShellVariable.probe(JevKey.variableNames) : nil }
        }
        keyLookup = lookup
        return await lookup.value
    }

    func classify(_ candidates: [Candidate], kind: PageKind, key: JevKey) async throws(DeclutterFailure) -> JevResult {
        apiCalls += 1
        do {
            let result = try await client.classify(candidates, kind: kind, key: key)
            let usage = result.response.usage
            log("declutter: \(candidates.count) candidates, sent \(result.requestBytes) B, got \(result.responseBytes) B in \(result.latency), model \(result.response.model ?? "?"), tokens in \(usage?.inputTokens.map(String.init) ?? "?") out \(usage?.outputTokens.map(String.init) ?? "?"), ignored ids \(result.response.ignoredIDs.count)")
            return result
        } catch {
            log("declutter: request failed, \(error)")
            throw error
        }
    }
}

/// One window's Declutter runs. A new page, or a navigation while a run waits, discards the run.
@MainActor
final class DeclutterRunner {
    enum Trigger { case manual, auto }

    /// The last run, for the control socket and the evaluation script. Never holds the key.
    struct Report {
        var candidates: [Candidate] = []
        var rules: [HideRule] = []
        var fromCache = false
        var result: JevResult?
        /// The status bar text the run ended with; the bar itself shows link hovers too.
        var status = ""
    }

    private weak var controller: BrowserWindowController?
    private var generation = 0
    private(set) var report = Report()
    private var service: DeclutterService { App.shared.declutter }

    init(controller: BrowserWindowController) {
        self.controller = controller
    }

    func pageStarted() {
        generation += 1
        controller?.setDeclutter(.idle)
    }

    func pageFinished() {
        guard let c = controller else { return }
        c.setAutoDeclutter(service.sites.contains(c.webView.url?.host))
        if c.state.autoDeclutter && service.hasConsent { run(.auto) }
    }

    func run(_ trigger: Trigger) {
        guard let c = controller, !c.state.declutter.isRunning else { return }
        let url = c.webView.url
        if let skip = DeclutterEligibility.check(url) {
            if trigger == .manual { c.showStatusNote(DeclutterOutcome.skipped(skip).status) }
            return
        }
        guard service.hasConsent else {
            if trigger == .manual { askConsent { [weak self] in self?.run(.manual) } }
            return
        }
        generation += 1
        let run = generation
        report = Report()
        c.setDeclutter(.running(progress: 0.1))
        c.showStatusNote("Decluttering...")
        Task { await perform(run, url: url) }
    }

    func undo() {
        guard let c = controller, c.state.declutter == .applied else { return }
        let run = generation
        Task {
            _ = try? await DeclutterScript.call(c.webView, "undo()")
            guard run == generation else { return }
            c.setDeclutter(.idle)
            c.showStatusNote(DeclutterOutcome.undone.status)
        }
    }

    func toggleAuto() {
        guard let c = controller, let host = c.webView.url?.host, DeclutterEligibility.check(c.webView.url) == nil else { return }
        if service.sites.contains(host) {
            service.setAuto(false, host: host)
            App.shared.windows.forEach { $0.declutter.refreshAuto() }
            c.showStatusNote("Auto Declutter is off for \(host)")
            return
        }
        let enable = { [weak self] in
            guard let self else { return }
            self.service.setAuto(true, host: host)
            App.shared.windows.forEach { $0.declutter.refreshAuto() }
            self.run(.manual)
        }
        if service.hasConsent { enable() } else { askConsent(enable) }
    }

    func refreshAuto() {
        guard let c = controller else { return }
        c.setAutoDeclutter(service.sites.contains(c.webView.url?.host))
    }

    private func askConsent(_ accepted: @escaping () -> Void) {
        guard let c = controller else { return }
        c.present(DialogView.messageBox(kind: "declutter-consent", title: DeclutterConsent.title, icon: .question,
                                        message: DeclutterConsent.message, buttons: [("ok", "OK"), ("cancel", "Cancel")],
                                        defaultButton: "cancel", cancelButton: "cancel") { [weak self] id in
            guard id == "ok", let self else { return }
            self.service.recordConsent()
            accepted()
        })
    }

    private struct Applied: Decodable { let hidden: Int }

    private func perform(_ run: Int, url: URL?) async {
        guard let c = controller else { return }
        let policy = service.policy
        let current = { [weak self] in self?.generation == run && self?.controller != nil }
        do {
            let scan = try JSONDecoder().decode(PageScan.self, from: try await DeclutterScript.call(
                c.webView, "scan(maxRaw, maxMatches)", arguments: ["maxRaw": 300, "maxMatches": policy.maxMatches]))
            guard current() else { return }
            if let sensitive = scan.sensitive { return finish(run, .skipped(sensitive.skipReason)) }
            guard let url, let key = TemplateKey.make(url: url, signals: scan.signals, policy: policy) else {
                return finish(run, .skipped(.notWeb))
            }
            var fromCache = true
            var rules: [HideRule]
            if let cached = service.cachedRules(key) {
                rules = cached
                report.fromCache = true
            } else {
                fromCache = false
                let candidates = Candidate.build(scan.candidates, policy: policy)
                report.candidates = candidates
                if candidates.isEmpty {
                    rules = []
                } else {
                    c.setDeclutter(.running(progress: 0.4))
                    guard let jevKey = await service.key() else { throw DeclutterFailure.noKey }
                    guard current() else { return }
                    let result = try await service.classify(candidates, kind: key.kind, key: jevKey)
                    guard current() else { return }
                    report.result = result
                    rules = HideRule.from(result.response.decisions, candidates: candidates, policy: policy)
                    service.store(key, rules: rules, candidateCount: candidates.count)
                }
            }
            report.rules = rules
            if rules.isEmpty { return finish(run, .nothing(fromCache: fromCache)) }
            c.setDeclutter(.running(progress: 0.8))
            let measure = try JSONDecoder().decode(PageMeasure.self, from: try await DeclutterScript.call(
                c.webView, "measure(selectors)", arguments: ["selectors": rules.map(\.selector.raw)]))
            guard current() else { return }
            switch HideGuard.plan(rules, measure: measure, policy: policy) {
            case .nothing:
                finish(run, .nothing(fromCache: fromCache))
            case let .refuse(violation):
                finish(run, .refused(violation))
            case let .hide(selectors):
                let applied = try JSONDecoder().decode(Applied.self, from: try await DeclutterScript.call(
                    c.webView, "apply(selectors)", arguments: ["selectors": selectors.map(\.raw)]))
                guard current() else { return }
                finish(run, applied.hidden > 0 ? .hid(count: applied.hidden, fromCache: fromCache) : .nothing(fromCache: fromCache))
            }
        } catch let failure as DeclutterFailure {
            guard current() else { return }
            c.setDeclutter(.idle)
            c.showStatusNote("Declutter failed. Nothing was hidden.")
            c.showMessage(kind: "declutter-error", title: DeclutterConsent.title, icon: .error, message: failure.message)
        } catch {
            guard current() else { return }
            log("declutter: page script failed, \(error)")
            c.setDeclutter(.idle)
            c.showStatusNote("Declutter could not read this page. Nothing was hidden.")
        }
    }

    private func finish(_ run: Int, _ outcome: DeclutterOutcome) {
        guard run == generation, let c = controller else { return }
        if case .hid = outcome { c.setDeclutter(.applied) } else { c.setDeclutter(.idle) }
        report.status = outcome.status
        c.showStatusNote(outcome.status)
    }
}
