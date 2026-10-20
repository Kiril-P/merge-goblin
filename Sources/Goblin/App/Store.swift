//  Store.swift — everything the UI shows, and everything it can do.
//
//  One observable object. Views read properties and call methods; nothing else in
//  the app touches the CLI or the files. State comes from two places:
//
//    * files the engine writes (uistate.json, inbox.json, events.jsonl, jobs/*), read
//      directly and re-read when the directory changes — free, and instant;
//    * the CLI, for things no file write can announce (is the scheduler loaded? which
//      gh account is active? what does #2456 resolve to?).
//
//  The app never writes engine state. Anything that changes it is a `Command`.

import AppKit
import Observation
import os

enum LoadState: Equatable {
    case idle, loading, loaded
    case failed(String)
}

struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// What `goblin resolve` said about a ref.
enum Resolution: Equatable {
    case found(ResolvedPR)
    case needsRepo(candidates: [String])
    case failed(String)
}

struct ResolvedPR: Equatable {
    let repo: String
    let number: Int
    let title: String
    let state: String       // open | closed
    let merged: Bool
    let draft: Bool
    let author: String
    let url: String

    var ref: String { "\(repo)#\(number)" }
    var isOpen: Bool { state == "open" && !merged }
}

struct RepoResult: Identifiable, Equatable {
    let slug: String
    let description: String
    let isPrivate: Bool
    let permission: String
    let watched: Bool
    var id: String { slug }
}

struct ReviewOptions: Equatable {
    var mode: ReviewMode? = nil           // nil = whatever Settings says
    var focus: ReviewFocus = .full
    var provider: ProviderId? = nil       // nil = the configured one
    var model: String = ""
    var force = false
    var repo: String? = nil               // only used when the ref is a bare number
}

@MainActor
@Observable
final class AppStore {

    static let shared = AppStore()

    // MARK: published state

    private(set) var snapshot = Snapshot()
    private(set) var jobs: [Job] = []
    private(set) var queue: [QueuedPR] = []
    private(set) var history: [HistoryEntry] = []
    private(set) var providers: [ProviderInfo] = []
    /// provider name -> the models it offers (`goblin provider models`). Loaded on first use.
    private(set) var modelCatalog: [String: [ModelOption]] = [:]
    private var modelsLoading: Set<String> = []
    private(set) var providersState: LoadState = .idle
    /// How the findings we posted fared; nil until the first read finishes.
    private(set) var stats: ReviewStats?
    /// Reviews per day and per model over the last two weeks, from events.jsonl.
    private(set) var usage = UsageReport()
    /// What each teammate's Goblin did lately; nil until the first read finishes.
    private(set) var fleetStatus: FleetStatus?
    private(set) var fleetState: LoadState = .idle
    private var fleetReadAt: Date?
    private(set) var statsState: LoadState = .idle
    private var statsReadAt: Date?
    private(set) var doctor: [DoctorCheck] = []
    private(set) var doctorState: LoadState = .idle
    private(set) var accounts: [(login: String, active: Bool, configured: Bool)] = []
    private(set) var clipboard: PRRef?
    private(set) var toast: Toast?
    private(set) var loginItemOn = false
    /// True while `goblin update install` runs. On success the app quits and the engine
    /// opens the new copy, so this never needs to go back to false after a success.
    private(set) var updateInstalling = false

    /// A person's unsaved changes to each waiting review, by job id.
    var edits: [String: ReviewEdits] = [:]
    @ObservationIgnored private var previewCache: [String: ReviewPreview] = [:]
    /// Jobs with a post in flight from this window. The engine only reports `posting`
    /// once it has started, and a second click before that must not start a second post.
    var postingJobs: Set<String> = []

    var cliConfigured: Bool { CLI.shared.isConfigured }
    var home: String { CLI.shared.home }

    // MARK: derived

    var activeJobs: [Job] { jobs.filter { $0.phase.isActive } }
    var readyJobs: [Job] { jobs.filter { $0.phase == .ready } }
    /// Jobs worth putting in front of the person: working, or waiting on them.
    var liveJobs: [Job] { jobs.filter { $0.phase.isActive || $0.phase == .ready } }

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    /// The most recent finished things: manual jobs plus the engine's own posted and
    /// failed events, without listing one review twice.
    var recent: [RecentItem] {
        var items: [RecentItem] = []
        let finished = jobs.filter { !$0.phase.isActive && $0.phase != .ready }
        for j in finished where j.phase != .discarded && j.phase != .cancelled {
            items.append(RecentItem(id: "job-\(j.id)", at: j.updatedAt, job: j, entry: nil))
        }
        for e in history where e.kind != .previewed {
            let dup = finished.contains {
                $0.repo == e.repo && $0.number == e.number && abs($0.updatedAt.timeIntervalSince(e.at)) < 180
            }
            if !dup { items.append(RecentItem(id: "ev-\(e.id)", at: e.at, job: nil, entry: e)) }
        }
        return items.sorted { $0.at > $1.at }
    }

    // MARK: lifecycle

    private let log = Logger(subsystem: "goblin.bar", category: "store")
    private var homeSource: DispatchSourceFileSystemObject?
    private var jobsStream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var tick: Timer?
    private var lastPasteboardCount = -1
    private var dismissedClipboard: PRRef?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        reload()
        watch()
        tick = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        tick?.tolerance = 0.5
        refreshFromCLI()
        Task { await refreshProviders() }
    }

    private var heartbeatCount = 0
    private func heartbeat() {
        pollClipboard()
        heartbeatCount += 1
        // A running job's elapsed time and pid liveness want a refresh even when no
        // file changed; five minutes keeps launchd-dependent facts honest too.
        if jobs.contains(where: { $0.phase.isActive }) { reloadJobs() }
        if heartbeatCount % 200 == 0 { refreshFromCLI() }
    }

    // MARK: reading files

    func reload() {
        reloadSnapshot()
        reloadJobs()
        reloadQueue()
        reloadHistory()
        loginItemOn = LoginItem.isInstalled
    }

    private func path(_ name: String) -> String { (home as NSString).appendingPathComponent(name) }

    private func reloadSnapshot() {
        let next = Snapshot(json: JSON.read(path: path("uistate.json")), config: JSON.read(path: path("config.json")))
        if next != snapshot { snapshot = next }
    }

    func reloadJobs() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: CLI.shared.jobsPath) else {
            if !jobs.isEmpty { jobs = [] }
            return
        }
        var out: [Job] = []
        for n in names where Pattern.jobId.accepts(n) {
            let file = (CLI.shared.jobsPath as NSString).appendingPathComponent("\(n)/job.json")
            guard var j = Job(json: JSON.read(path: file)) else { continue }
            j.reconcile()
            out.append(j)
        }
        out.sort { $0.createdAt > $1.createdAt }
        let capped = Array(out.prefix(80))
        if capped != jobs { jobs = capped }
    }

    private func reloadQueue() {
        let inbox = JSON.read(path: path("inbox.json"))
        let next: [QueuedPR] = inbox["prs"].array.compactMap { e in
            guard let url = e["url"].string, !url.isEmpty else { return nil }
            if let s = e["state"].string, s != "waiting" { return nil }
            return QueuedPR(repo: e["repo"].string(""), number: e["number"].int(0),
                            title: e["title"].string(""), url: url, author: e["author"].string(""))
        }
        if next != queue { queue = next }
    }

    private func reloadHistory() {
        // Only the tail: events.jsonl only ever grows, and the list shows the last 80.
        guard let text = Self.tail(path("events.jsonl"), bytes: 256 * 1024) else {
            history = []
            if !usage.isEmpty { usage = UsageReport(eventsText: "") }
            return
        }
        // 256 KB is well over two weeks of events for anyone; the usage view only needs 14 days.
        let nextUsage = UsageReport(eventsText: text)
        if nextUsage != usage { usage = nextUsage }
        var rows: [HistoryEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).suffix(80) {
            let j = JSON.parse(String(line))
            guard let status = j["status"].string else { continue }
            let kind: HistoryEntry.Kind
            switch status {
            case "posted": kind = .posted
            case "failed": kind = .failed
            case "previewed": kind = .previewed
            default: continue
            }
            let at = j["at"].double(0)
            rows.append(HistoryEntry(
                id: "\(Int(at))-\(j["number"].int(0))-\(status)", kind: kind,
                repo: j["repo"].string(""), number: j["number"].int(0), title: j["title"].string(""),
                url: j["url"].string(""), at: Date(timeIntervalSince1970: at),
                provider: j["provider"].string(""), model: j["model"].string(""),
                costUsd: j["costUsd"].double(0), reason: j["reason"].string("")))
        }
        let next = Array(rows.reversed())
        if next != history { history = next }
    }

    nonisolated static func tail(_ file: String, bytes: Int) -> String? {
        guard let h = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // A cut in the middle of a line leaves a fragment; drop it.
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }

    /// The review waiting in jobs/<id>/preview, read once and cached. A job that is
    /// not ready, or whose file is unreadable, simply has none.
    func preview(for id: String) -> ReviewPreview? {
        if let c = previewCache[id] { return c }
        let file = (CLI.shared.jobsPath as NSString).appendingPathComponent("\(id)/preview/review.json")
        guard let p = ReviewPreview(json: JSON.read(path: file)) else { return nil }
        previewCache[id] = p
        return p
    }

    // MARK: watching

    private func watch() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: CLI.shared.jobsPath, withIntermediateDirectories: true)

        // Top-level files (uistate, inbox, events, config). Every writer replaces the
        // file with mv, so the watch is on the DIRECTORY: a watch on the file would be
        // orphaned by the first write.
        let fd = open(home, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            src.setEventHandler { [weak self] in
                Notifier.shared.drain()
                Task { @MainActor in self?.scheduleReload() }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            homeSource = src
        } else {
            log.error("cannot watch \(self.home, privacy: .public)")
        }

        // jobs/<id>/job.json is replaced inside a subdirectory, which a directory
        // watch on jobs/ would not see. FSEvents is recursive and cheap here because
        // only job files live under it (clones are under repos/, elsewhere).
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            // A running worker appends to log.txt many times a second; only the files the
            // UI actually reads (job.json, the preview) are worth a reload.
            let list = unsafeBitCast(paths, to: NSArray.self)
            var relevant = false
            for i in 0..<count {
                let p = (list[i] as? String) ?? ""
                if p.hasSuffix("/job.json") || p.contains("/preview/") || p.hasSuffix("/edits.json") { relevant = true; break }
            }
            guard relevant else { return }
            let store = Unmanaged<AppStore>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in store.scheduleReload() }
        }
        if let stream = FSEventStreamCreate(
            nil, callback, &ctx, [CLI.shared.jobsPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)) {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
            jobsStream = stream
        }
    }

    /// One logical change is several file events (status.json, then uistate.json, then
    /// job.json); coalesce so the UI does not flicker through the in-between states.
    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.previewCache = self?.previewCache.filter { id, _ in
                    let p = self?.job(id)?.phase
                    return p == .ready || p == .posting || p == .failed
                } ?? [:]
                self?.reload()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: clipboard

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        guard let text = pb.string(forType: .string), let ref = PRRef.firstLink(in: text) else {
            if clipboard != nil { clipboard = nil }
            return
        }
        if ref != dismissedClipboard, ref != clipboard { clipboard = ref }
    }

    func dismissClipboard() {
        dismissedClipboard = clipboard
        clipboard = nil
    }

    // MARK: toasts

    func say(_ text: String, _ kind: Toast.Kind = .info) {
        let t = Toast(kind: kind, text: text)
        toast = t
        let id = t.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: kind == .error ? 6_000_000_000 : 3_000_000_000)
            if self?.toast?.id == id { self?.toast = nil }
        }
    }

    // MARK: CLI-backed reads

    func refreshFromCLI() {
        guard cliConfigured else { return }
        Task {
            if let out = try? await CLI.shared.run(.state) {
                _ = out
                reloadSnapshot()
            }
        }
    }

    func refreshProviders() async {
        guard cliConfigured else { providersState = .failed("The Goblin's command line tool is missing from this app."); return }
        providersState = .loading
        do {
            let out = try await CLI.shared.run(.providers(refresh: true))
            let rows = JSON.parse(out.stdout).array.map(ProviderInfo.init(json:)).filter { !$0.name.isEmpty }
            providers = rows
            providersState = .loaded
        } catch {
            // Never a silent empty list: "no AI CLIs found" when three are installed is
            // the bug this state exists to make impossible.
            providersState = .failed((error as? LocalizedError)?.errorDescription ?? "Could not check the AI CLIs.")
        }
    }

    /// The models a provider offers. Quietly keeps whatever it had if the CLI fails, and
    /// falls back to the built-in few so the menu is never empty for a provider that works.
    func loadModels(_ provider: String, refresh: Bool = false) async {
        guard let id = ProviderId(rawValue: provider), cliConfigured,
              refresh || modelCatalog[provider] == nil, modelsLoading.insert(provider).inserted else { return }
        defer { modelsLoading.remove(provider) }
        if let out = try? await CLI.shared.run(.providerModels(id, refresh: refresh)) {
            let options = ModelCatalog.parse(JSON.parse(out.stdout))
            if !options.isEmpty { modelCatalog[provider] = options; return }
        }
        if modelCatalog[provider] == nil {
            modelCatalog[provider] = ProviderInfo.fallbackModels(provider).map { ModelOption(id: $0, label: $0) }
        }
    }


    /// Reads the findings' fate back from GitHub (the CLI caches it for hours, so opening
    /// the popover is cheap). Keeps the last numbers on a failure instead of blanking them.
    func loadStats(refresh: Bool = false) async {
        // The CLI caches for hours; asking again within minutes only spawns a process.
        if !refresh, stats != nil, let at = statsReadAt, Date().timeIntervalSince(at) < 600 { return }
        guard cliConfigured, statsState != .loading else { return }
        statsState = .loading
        do {
            let out = try await CLI.shared.run(.stats(days: 30, refresh: refresh))
            guard let parsed = ReviewStats(json: JSON.parse(out.stdout)) else {
                statsState = .failed("The Goblin could not read how its findings fared.")
                return
            }
            stats = parsed
            statsReadAt = Date()
            statsState = .loaded
        } catch {
            statsState = .failed((error as? LocalizedError)?.errorDescription ?? "Could not read how the findings fared.")
        }
    }

    /// Asks the engine what each teammate's Goblin left on GitHub. The engine caches for a
    /// few minutes; within two of the last read this does not even spawn it. Keeps the
    /// last answer on a failure rather than blanking the list.
    func loadFleetStatus(refresh: Bool = false) async {
        // Fresh enough, and about the same people: nothing to ask.
        if !refresh, let f = fleetStatus, let at = fleetReadAt, Date().timeIntervalSince(at) < 120,
           Set(f.members.map { $0.login.lowercased() }) == Set(snapshot.fleet.map { $0.lowercased() }) { return }
        guard cliConfigured, fleetState != .loading, !snapshot.fleet.isEmpty else { return }
        fleetState = .loading
        do {
            let out = try await CLI.shared.run(.fleetStatus(refresh: refresh))
            let j = JSON.parse(out.stdout)
            if let parsed = FleetStatus(json: j) {
                fleetStatus = parsed
                fleetReadAt = Date()
                fleetState = .loaded
            } else {
                fleetState = .failed(FleetStatus.failure(j) ?? "Could not see what the team is doing.")
            }
        } catch {
            fleetState = .failed((error as? LocalizedError)?.errorDescription ?? "Could not see what the team is doing.")
        }
    }

    func isLoadingModels(_ provider: String) -> Bool { modelsLoading.contains(provider) && modelCatalog[provider] == nil }

    func runDoctor(fix: Bool = false) async {
        doctorState = .loading
        do {
            let out = try await CLI.shared.run(.doctor(fix: fix))
            let j = JSON.parse(out.stdout)
            doctor = j["checks"].array.enumerated().map { i, c in
                DoctorCheck(id: "\(i)-\(c["check"].string(""))",
                            status: DoctorCheck.Status(rawValue: c["status"].string("ok")) ?? .ok,
                            check: c["check"].string(""), detail: c["detail"].string(""), fix: c["fix"].string(""))
            }
            doctorState = .loaded
            reloadSnapshot()
        } catch {
            doctorState = .failed((error as? LocalizedError)?.errorDescription ?? "The checks did not finish.")
        }
    }

    func refreshAccounts() async {
        guard let out = try? await CLI.shared.run(.accounts) else { return }
        accounts = JSON.parse(out.stdout).array.compactMap { a in
            a["login"].string.map { ($0, a["active"].bool(false), a["configured"].bool(false)) }
        }
    }

    // MARK: reviews

    /// Replaces the CLI lookup. Only the snapshot run and tests set it, so they never
    /// reach GitHub.
    var resolveOverride: ((PRRef, String?) async -> Resolution)?

    /// Ask the engine what a ref means, without reviewing anything.
    func resolve(_ ref: PRRef, repo: String?) async -> Resolution {
        if let resolveOverride { return await resolveOverride(ref, repo) }
        do {
            let out = try await CLI.shared.run(.resolve(ref: ref, repo: repo))
            return Self.parseResolution(out.stdout)
        } catch let f as CLI.Failure {
            if case .cliError(let m, _) = f, JSON.parse(m).exists { return Self.parseResolution(m) }
            return .failed(f.errorDescription ?? "Could not look that up.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func parseResolution(_ text: String) -> Resolution {
        let j = JSON.parse(text)
        if j["ok"].bool(false), let repo = j["repo"].string, let n = j["number"].int {
            return .found(ResolvedPR(repo: repo, number: n, title: j["title"].string(""),
                                     state: j["state"].string("open"), merged: j["merged"].bool(false),
                                     draft: j["draft"].bool(false), author: j["author"].string(""),
                                     url: j["url"].string("")))
        }
        if j["error"].string == "needs_repo" {
            return .needsRepo(candidates: j["candidates"].array.compactMap(\.string))
        }
        return .failed(j["message"].string("Could not look that up."))
    }

    /// Start a review. Returns the new job (already on disk), or nil after saying why.
    @discardableResult
    func startReview(_ ref: PRRef, options: ReviewOptions = ReviewOptions()) async -> Job? {
        let mode = options.mode ?? ReviewMode(rawValue: snapshot.settings.manualReviewMode) ?? .preview
        do {
            let out = try await CLI.shared.run(.review(
                ref: ref, repo: options.repo, mode: mode, focus: options.focus,
                provider: options.provider, model: options.model.isEmpty ? nil : options.model,
                force: options.force))
            let j = JSON.parse(out.stdout)
            reload()
            if let job = Job(json: j) { return job }
            return nil
        } catch let f as CLI.Failure {
            if case .cliError(let m, _) = f, JSON.parse(m).exists {
                say(JSON.parse(m)["message"].string("Could not start that review."), .error)
            } else {
                say(f.errorDescription ?? "Could not start that review.", .error)
            }
            return nil
        } catch {
            say(error.localizedDescription, .error)
            return nil
        }
    }

    func cancel(_ job: Job) {
        Task {
            do {
                _ = try await CLI.shared.run(.cancelJob(job: job.id))
                edits[job.id] = nil
            } catch {
                say((error as? LocalizedError)?.errorDescription ?? "Could not discard that review.", .error)
            }
            reload()
        }
    }

    /// Posts the preview (with any edits made in this app). True once GitHub has it.
    @discardableResult
    func post(_ job: Job) async -> Bool {
        guard postingJobs.insert(job.id).inserted else { return false }
        defer { postingJobs.remove(job.id) }
        // The edits are written to the job's own directory, never passed as a path.
        let dir = (CLI.shared.jobsPath as NSString).appendingPathComponent(job.id)
        let file = (dir as NSString).appendingPathComponent("edits.json")
        let e = edits[job.id] ?? ReviewEdits()
        if e.isEmpty {
            try? FileManager.default.removeItem(atPath: file)
        } else {
            do { try e.jsonData().write(to: URL(fileURLWithPath: file), options: .atomic) }
            catch { say("Could not save your edits.", .error); return false }
        }
        do {
            _ = try await CLI.shared.run(.postReview(job: job.id))
            edits[job.id] = nil
            reload()
            say("Posted to GitHub.", .success)
            return self.job(job.id)?.phase != .failed
        } catch {
            reload()
            say((error as? LocalizedError)?.errorDescription ?? "Posting failed.", .error)
            return false
        }
    }

    // MARK: repository search (Settings)

    /// Replaces the CLI lookup. Only the snapshot run and tests set it.
    var repoSearchOverride: ((String) async -> [RepoResult])?

    /// Search the repos this account can see. Throws a readable message on failure.
    func searchRepos(_ query: String) async throws -> [RepoResult] {
        if let repoSearchOverride { return await repoSearchOverride(query) }
        let out = try await CLI.shared.run(.repoSearch(query: query, limit: 30))
        let j = JSON.parse(out.stdout)
        if let e = j["error"].string, !e.isEmpty { throw CLI.Failure.cliError(message: e, exit: 1) }
        return j["repos"].array.compactMap { r in
            guard let slug = r["slug"].string else { return nil }
            return RepoResult(slug: slug, description: r["description"].string(""),
                              isPrivate: r["private"].bool(false), permission: r["permission"].string(""),
                              watched: r["watched"].bool(false))
        }
    }

    /// Fixed data for the screenshot run, so it never depends on the machine it runs on.
    func seedForSnapshot(doctor checks: [DoctorCheck], accounts accs: [(login: String, active: Bool, configured: Bool)],
                         stats seeded: ReviewStats? = nil, fleet: FleetStatus? = nil) {
        if let seeded { stats = seeded; statsReadAt = Date(); statsState = .loaded }
        if let fleet { fleetStatus = fleet; fleetReadAt = Date(); fleetState = .loaded }
        doctor = checks
        doctorState = .loaded
        accounts = accs
        modelCatalog = [
            "claude": [ModelOption(id: "sonnet", label: "Sonnet (latest)"), ModelOption(id: "opus", label: "Opus (latest)")],
            "codex": [ModelOption(id: "gpt-6.1-sol", label: "GPT-6.1-Sol")],
            "cursor": [ModelOption(id: "composer-2.5", label: "Composer 2.5")],
        ]
    }

    // MARK: settings & plumbing

    /// Run a mutating command, report failure, and re-read state. Settings views call
    /// this and nothing else.
    @discardableResult
    func perform(_ command: Command, success: String? = nil) async -> Bool {
        do {
            _ = try await CLI.shared.run(command)
            reload()
            refreshFromCLI()
            if let success { say(success, .success) }
            return true
        } catch {
            say((error as? LocalizedError)?.errorDescription ?? "That did not work.", .error)
            reload()
            return false
        }
    }

    // MARK: updating the app

    /// Offered only when the engine runs from inside this app's bundle: that bundle is
    /// what the engine replaces. A source install updates with git pull instead.
    var canInstallUpdate: Bool { snapshot.updateAvailable && CLI.shared.engineSource == .bundled }

    /// Download, verify and swap in the latest release, then quit so the engine can
    /// open the new copy. Every check (checksum, version, signing team) is the engine's;
    /// this only reports what it said.
    func installUpdate() async {
        guard canInstallUpdate, !updateInstalling else { return }
        updateInstalling = true
        let latest = snapshot.updateLatest
        say("Downloading v\(latest). The Goblin restarts when it is in place.")
        var failure = "The update did not install."
        do {
            let out = try await CLI.shared.run(.installUpdate)
            let j = JSON.parse(out.stdout)
            if j["ok"].bool(false) {
                say("Updated to v\(j["version"].string(latest)). Restarting…", .success)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                NSApp.terminate(nil)
                return
            }
            failure = j["message"].string(failure)
        } catch let f as CLI.Failure {
            // A refusal arrives as JSON on stdout with a non-zero exit.
            if case .cliError(let m, _) = f, JSON.parse(m).exists {
                failure = JSON.parse(m)["message"].string(failure)
            } else {
                failure = f.errorDescription ?? failure
            }
        } catch {
            failure = error.localizedDescription
        }
        updateInstalling = false
        say(failure, .error)
    }

    func setPower(_ on: Bool) { Task { await perform(.power(on: on)) } }
    func snooze(_ kind: SnoozeKind) { Task { await perform(.snooze(kind: kind)) } }

    func openURL(_ s: String) {
        guard Command.isHTTPS(s), let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }
    func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: CLI.shared.logPath)) }
    func revealHome() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: home)]) }

    func copyDiagnostics() {
        var lines = [
            "Merge Goblin \(snapshot.version) (engine: \(CLI.shared.engineSource.rawValue))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "account: \(snapshot.login) · provider: \(snapshot.providerId)\(snapshot.providerModel.isEmpty ? "" : "/\(snapshot.providerModel)")",
            "state: \(snapshot.state) · \(snapshot.statusLine)",
            "scheduler: installed=\(snapshot.agentInstalled) running=\(snapshot.agentRunning)",
        ]
        for j in jobs.prefix(5) { lines.append("job \(j.id) \(j.ref) \(j.phase.rawValue) \(j.error)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        say("Diagnostics copied.", .success)
    }
}

struct RecentItem: Identifiable {
    let id: String
    let at: Date
    let job: Job?
    let entry: HistoryEntry?
}

// MARK: - Login item

/// The login item is a LaunchAgent (see templates/bar-agent.plist.tmpl for why it is
/// not SMAppService). Swift only reads its existence; writing goes through the CLI.
enum LoginItem {
    static var label: String {
        let user = NSUserName().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
            .map(String.init).joined()
        return "com.\(user.isEmpty ? "user" : user).goblin.bar"
    }
    static var plistPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }
}
