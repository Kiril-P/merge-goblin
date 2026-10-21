//  WelcomeModel.swift — the state behind the first-run flow.
//
//  The engine decides which step is first incomplete (`goblin wizard state`); this
//  model only walks the person through them. Every network-touching call is a
//  closure on the model so the screenshot run can substitute fixed data and never
//  reach GitHub or the machine's real accounts.

import AppKit
import Observation

// MARK: - What `goblin wizard state --json` says

struct WizardAccount: Identifiable, Equatable {
    let login: String
    let active: Bool
    let configured: Bool
    let hasToken: Bool
    var id: String { login }
}

struct WizardState: Equatable {
    var step = "account"
    var ghInstalled = true
    var jqInstalled = true
    var gitInstalled = true
    var accounts: [WizardAccount] = []
    var identity = ""
    var provider = ""
    var repos: [String] = []
    var setupComplete = false

    /// (tool, the one command that installs it)
    var missingDeps: [(name: String, brew: String)] {
        var out: [(String, String)] = []
        if !ghInstalled { out.append(("gh", "brew install gh")) }
        if !jqInstalled { out.append(("jq", "brew install jq")) }
        if !gitInstalled { out.append(("git", "xcode-select --install")) }
        return out
    }

    init() {}

    init(json j: JSON) {
        step = j["step"].string("account")
        ghInstalled = j["deps"]["gh"].bool(true)
        jqInstalled = j["deps"]["jq"].bool(true)
        gitInstalled = j["deps"]["git"].bool(true)
        accounts = j["accounts"].array.compactMap { a in
            a["login"].string.map {
                WizardAccount(login: $0, active: a["active"].bool(false),
                              configured: a["configured"].bool(false), hasToken: a["hasToken"].bool(true))
            }
        }
        identity = j["identity"]["githubLogin"].string("")
        provider = j["provider"].string("")
        repos = j["repos"]["configured"].array.compactMap { $0["slug"].string }
        setupComplete = j["setup"]["complete"].bool(false)
    }
}

extension AppStore {
    /// One call for the whole first paint: dependencies, accounts, providers, repos.
    func wizardState() async -> WizardState? {
        guard let out = try? await CLI.shared.run(.wizardState) else { return nil }
        let j = JSON.parse(out.stdout)
        return j.exists ? WizardState(json: j) : nil
    }
}

// MARK: - The browser sign-in

struct GitHubLoginState: Equatable {
    enum Phase: String { case idle, waiting, done, failed }
    var phase: Phase = .idle
    var code = ""
    var error = ""

    init(phase: Phase = .idle, code: String = "", error: String = "") {
        self.phase = phase; self.code = code; self.error = error
    }

    init(text: String) {
        let j = JSON.parse(text)
        phase = Phase(rawValue: j["state"].string("idle")) ?? .idle
        code = j["code"].string("")
        error = j["error"].string("")
    }
}

// MARK: - Steps

enum WelcomeStep: Int, CaseIterable, Identifiable {
    case account, provider, repos, done
    var id: Int { rawValue }

    var title: String { ["GitHub", "Reviewer", "Repos", "Ready"][rawValue] }

    /// Where to resume: the first thing the engine says is still missing.
    static func resume(from engine: String) -> WelcomeStep {
        switch engine {
        case "account": return .account
        case "provider": return .provider
        case "repos": return .repos
        default: return .done
        }
    }
}

// MARK: - The model

@MainActor
@Observable
final class WelcomeModel {
    let store: AppStore

    var step: WelcomeStep = .account
    private(set) var wizard = WizardState()
    private(set) var loaded = false
    private(set) var loadFailed = false

    // 1 · GitHub
    var selectedLogin = ""
    private(set) var login = GitHubLoginState()
    private(set) var startingLogin = false

    // 2 · Reviewer
    private(set) var providers: [ProviderInfo] = []
    private(set) var providersState: LoadState = .idle
    var chosenProvider = ""

    // 3 · Repos
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    private(set) var hits: [RepoResult] = []
    private(set) var searching = false
    private(set) var searchError: String?
    private(set) var chosen: [String] = []

    // 4 · Done
    private(set) var completed = false

    private(set) var working = false

    // Seams: the screenshot run replaces these; nothing else does.
    var fetchWizard: () async -> WizardState?
    var startLogin: () async -> GitHubLoginState
    var pollLogin: () async -> GitHubLoginState
    var fetchProviders: () async -> ([ProviderInfo], LoadState)
    var searchRepos: (String) async throws -> [RepoResult]
    var pollInterval: UInt64 = 2_000_000_000

    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let pinnedStep: Bool

    init(store: AppStore, initialStep: WelcomeStep? = nil) {
        self.store = store
        pinnedStep = initialStep != nil
        if let initialStep { step = initialStep }
        fetchWizard = { await store.wizardState() }
        startLogin = { await WelcomeModel.runLogin(.githubLoginStart) }
        pollLogin = { await WelcomeModel.runLogin(.githubLoginStatus) }
        fetchProviders = {
            await store.refreshProviders()
            return (store.providers, store.providersState)
        }
        searchRepos = { try await store.searchRepos($0) }
    }

    /// `github-login` prints its JSON even when it exits non-zero (gh missing), so a
    /// CLI failure is still read as JSON before being treated as an error.
    private static func runLogin(_ c: Command) async -> GitHubLoginState {
        do {
            return GitHubLoginState(text: try await CLI.shared.run(c).stdout)
        } catch let f as CLI.Failure {
            if case .cliError(let m, _) = f, JSON.parse(m).exists { return GitHubLoginState(text: m) }
            return GitHubLoginState(phase: .failed, error: f.errorDescription ?? "Could not start the sign-in.")
        } catch {
            return GitHubLoginState(phase: .failed, error: error.localizedDescription)
        }
    }

    // MARK: derived

    var canContinue: Bool {
        switch step {
        case .account: return wizard.missingDeps.isEmpty && !selectedLogin.isEmpty
        case .provider: return chosenProviderInfo?.ready == true
        case .repos: return !chosen.isEmpty
        case .done: return true
        }
    }

    var chosenProviderInfo: ProviderInfo? { providers.first { $0.name == chosenProvider } }

    // MARK: loading

    func load() async {
        guard !loaded else { return }
        await reloadWizard()
        loaded = true
        switch step {
        case .provider: await loadProviders()
        case .repos: scheduleSearch(immediately: true)
        case .done: await completeSetup()
        case .account: break
        }
    }

    func reloadWizard() async {
        guard let w = await fetchWizard() else { loadFailed = true; return }
        loadFailed = false
        wizard = w
        if selectedLogin.isEmpty || !w.accounts.contains(where: { $0.login == selectedLogin }) {
            selectedLogin = w.identity.isEmpty
                ? (w.accounts.first { $0.active }?.login ?? w.accounts.first?.login ?? "")
                : w.identity
        }
        if chosenProvider.isEmpty { chosenProvider = w.provider.isEmpty ? store.snapshot.providerId : w.provider }
        if chosen.isEmpty { chosen = w.repos }
        if !pinnedStep && !loaded { step = .resume(from: w.step) }
    }

    func loadProviders() async {
        providersState = .loading
        let (rows, state) = await fetchProviders()
        providers = rows
        providersState = state
        // Offer a sensible default: keep the configured one if it works, else the
        // first that does.
        if chosenProviderInfo?.ready != true, let first = rows.first(where: \.ready) { chosenProvider = first.name }
    }

    // MARK: navigation

    func next() async {
        guard canContinue, !working else { return }
        working = true
        defer { working = false }
        switch step {
        case .account:
            if selectedLogin != wizard.identity {
                guard await store.perform(.setIdentity(login: selectedLogin)) else { return }
                await reloadWizard()
            }
            step = .provider
            await loadProviders()
        case .provider:
            if let p = ProviderId(rawValue: chosenProvider), store.snapshot.providerId != chosenProvider {
                guard await store.perform(.setProvider(p)) else { return }
            }
            step = .repos
            scheduleSearch(immediately: true)
        case .repos:
            step = .done
            await completeSetup()
        case .done: break
        }
    }

    func skip() async {
        switch step {
        case .provider: step = .repos; scheduleSearch(immediately: true)
        case .repos: step = .done; await completeSetup()
        default: break
        }
    }

    func back() {
        guard let prev = WelcomeStep(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    func jump(to s: WelcomeStep) {
        guard s.rawValue < step.rawValue else { return }
        step = s
    }

    func completeSetup() async {
        guard !completed else { return }
        completed = await store.perform(.wizardComplete)
        // An app from a disk image or a cask never ran install.sh, so nothing would
        // watch the chosen repos. Skipped when a scheduler already exists, so a source
        // install keeps pointing at its own copy of the engine.
        if completed, !store.snapshot.agentInstalled {
            await store.perform(.agent(.install))
        }
        // On by default; the last step shows the switch, so it is a choice, not a surprise.
        if completed, Bundle.main.bundlePath.hasSuffix(".app"), !LoginItem.isInstalled {
            await store.setLoginItem(true)
        }
    }

    // MARK: GitHub sign-in

    func choose(login l: String) { selectedLogin = l }

    func signIn() async {
        startingLogin = true
        login = await startLogin()
        startingLogin = false
        guard login.phase == .waiting else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let s = await self.pollLogin()
                // The code is only printed once; keep showing the one we have.
                self.login = GitHubLoginState(phase: s.phase, code: s.code.isEmpty ? self.login.code : s.code, error: s.error)
                if s.phase == .done {
                    await self.reloadWizard()
                    if let a = self.wizard.accounts.first(where: { $0.active }) { self.selectedLogin = a.login }
                    self.login = GitHubLoginState()
                    return
                }
                if s.phase != .waiting { return }
            }
        }
    }

    func cancelSignIn() {
        pollTask?.cancel()
        login = GitHubLoginState()
    }

    func recheckDeps() async { await reloadWizard() }

    // MARK: repos

    func isChosen(_ slug: String) -> Bool { chosen.contains(slug) }

    func toggle(_ slug: String) async {
        if isChosen(slug) {
            if await store.perform(.repoRemove(slug: slug)) { chosen.removeAll { $0 == slug } }
        } else {
            if await store.perform(.repoAdd(slug: slug)) { chosen.append(slug) }
        }
    }

    /// The CLI only accepts letters, digits, space and `._/-`; anything else typed is
    /// simply not part of a repo name.
    static func sanitised(_ q: String) -> String {
        String(q.filter { $0.isASCII && ($0.isLetter || $0.isNumber || " ._/-".contains($0)) }.prefix(80))
    }

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        guard step == .repos || immediately else { return }
        searching = true
        searchTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                let rows = try await self.searchRepos(Self.sanitised(self.query))
                guard !Task.isCancelled else { return }
                self.hits = rows
                self.searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.hits = []
                self.searchError = (error as? LocalizedError)?.errorDescription ?? "Could not search your repositories."
            }
            self.searching = false
        }
    }

    func retrySearch() { scheduleSearch(immediately: true) }
}

// MARK: - Provider copy

extension ProviderInfo {
    /// What to type to get this provider working — the install line if it is
    /// missing, the sign-in line if it is installed but signed out.
    var fixCommand: String {
        if !available {
            switch name {
            case "claude": return "curl -fsSL https://claude.ai/install.sh | bash"
            case "codex": return "npm i -g @openai/codex"
            case "cursor": return "curl https://cursor.com/install -fsS | bash"
            default: return ""
            }
        }
        switch name {
        case "claude": return "claude"
        case "codex": return "codex login"
        case "cursor": return "cursor-agent login"
        default: return ""
        }
    }

    var statusText: String { ready ? "Ready" : (available ? "Needs sign-in" : "Not installed") }
}

enum WelcomeClipboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
