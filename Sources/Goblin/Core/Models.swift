//  Models.swift — the engine's files, as values.
//
//  Everything here is a read-only view of JSON the CLI wrote. The app never writes
//  these files; it asks the CLI to (see Command.swift). Parsing goes through `JSON`,
//  which defaults instead of failing, so an engine one release ahead or behind
//  degrades a field rather than the screen.

import Foundation

// MARK: - Severity

enum Severity: String, CaseIterable, Identifiable {
    case blocker, convention, risk, nit, question
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blocker: return "Blocker"
        case .convention: return "Convention"
        case .risk: return "Risk"
        case .nit: return "Nit"
        case .question: return "Question"
        }
    }
    var emoji: String {
        switch self {
        case .blocker: return "🔴"
        case .convention: return "🟠"
        case .risk: return "🟡"
        case .nit: return "⚪"
        case .question: return "🔵"
        }
    }
}

// MARK: - Jobs

enum JobPhase: String, CaseIterable {
    case queued, fetching, reading, reviewing, ready, posting, done, failed, skipped, cancelled, discarded

    var isActive: Bool {
        switch self {
        case .queued, .fetching, .reading, .reviewing, .posting: return true
        default: return false
        }
    }
    /// Waiting on a person.
    var needsYou: Bool { self == .ready }

    var label: String {
        switch self {
        case .queued: return "Waiting for a free slot"
        case .fetching: return "Fetching the diff"
        case .reading: return "Reading the code"
        case .reviewing: return "Reviewing"
        case .ready: return "Ready to read"
        case .posting: return "Posting to GitHub"
        case .done: return "Posted"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        case .discarded: return "Discarded"
        }
    }

    /// Position on the progress track, 0...4. Terminal states sit at the end.
    var step: Int {
        switch self {
        case .queued: return 0
        case .fetching: return 1
        case .reading: return 2
        case .reviewing: return 3
        case .ready, .posting, .done: return 4
        default: return 0
        }
    }
}

struct Job: Identifiable, Equatable {
    let id: String
    let repo: String
    let number: Int
    var title: String
    var url: String
    var phase: JobPhase
    var mode: ReviewMode
    var focus: ReviewFocus
    var provider: String      // the one actually used, once known
    var author: String
    var createdAt: Date
    var updatedAt: Date
    var pid: Int
    var error: String
    var errorDetail: String
    var reason: String        // why a skipped job was skipped
    var counts: String        // "🔴 1 blocker · ⚪ 1 nit"
    var findingCount: Int
    var reviewURL: String
    var costUsd: Double
    var headChanged: Bool

    var ref: String { "\(repo)#\(number)" }
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var displayTitle: String { title.isEmpty ? ref : title }

    init?(json: JSON) {
        guard let id = json["id"].string, Pattern.jobId.accepts(id),
              let repo = json["repo"].string, let number = json["number"].int else { return nil }
        self.id = id
        self.repo = repo
        self.number = number
        title = json["title"].string("")
        url = json["url"].string("")
        phase = JobPhase(rawValue: json["phase"].string("queued")) ?? .queued
        mode = ReviewMode(rawValue: json["mode"].string("preview")) ?? .preview
        focus = ReviewFocus(rawValue: json["focus"].string("full")) ?? .full
        provider = json["providerUsed"].string(json["provider"].string(""))
        author = json["author"].string("")
        createdAt = Date(timeIntervalSince1970: json["createdAt"].double(0))
        updatedAt = Date(timeIntervalSince1970: json["updatedAt"].double(json["createdAt"].double(0)))
        pid = json["pid"].int(0)
        error = json["error"].string("")
        errorDetail = json["errorDetail"].string("")
        reason = json["reason"].string("")
        counts = json["result"]["counts"].string("")
        findingCount = json["result"]["findings"].int(0)
        reviewURL = json["result"]["reviewUrl"].string("")
        costUsd = json["result"]["costUsd"].double(0)
        headChanged = json["headChanged"].bool(false)
    }

    /// A job whose worker is gone but whose file still says it is working was killed
    /// (reboot, crash, force quit). Same rule as job_reconcile in lib/jobs.sh, applied
    /// on read so the UI never shows a spinner for something that is not running.
    mutating func reconcile(now: Date = Date()) {
        guard phase.isActive else { return }
        if pid > 0 {
            if kill(pid_t(pid), 0) == 0 || errno == EPERM { return }
        } else if now.timeIntervalSince(createdAt) < 30 {
            return
        }
        phase = .failed
        error = "interrupted"
        errorDetail = "The review process stopped before it finished."
    }

    var failureMessage: String {
        if !errorDetail.isEmpty { return errorDetail }
        switch error {
        case "interrupted": return "The review process stopped before it finished."
        case "timeout": return "The AI took too long and was stopped."
        case "auth": return "GitHub is not signed in as the configured account."
        case "provider": return "No AI CLI is installed and signed in."
        case "quota": return "The AI subscription hit its usage limit."
        case "not_found": return "That pull request was not found, or this account cannot see it."
        case "": return "The review did not finish."
        default: return "The review failed (\(error))."
        }
    }

    var skipMessage: String {
        switch reason {
        case "already_reviewed": return "The Goblin already reviewed this exact commit."
        case "closed": return "This pull request is already merged or closed."
        default: return "Skipped."
        }
    }
}

// MARK: - A review waiting to be read

struct Finding: Identifiable, Equatable {
    let id: String
    var path: String?
    var line: Int?
    var startLine: Int?
    var severity: Severity
    var title: String
    var body: String
    var suggestion: String?
    /// GitHub will accept it as a comment on a diff line. If not, it rides in the
    /// review body instead — it is still posted, just not pinned.
    var anchored: Bool

    var location: String? {
        guard let path, !path.isEmpty else { return nil }
        guard let line else { return path }
        if let s = startLine, s != line { return "\(path):\(s)–\(line)" }
        return "\(path):\(line)"
    }

    init(json: JSON) {
        id = json["id"].string(UUID().uuidString)
        path = json["path"].string
        line = json["line"].int
        startLine = json["start_line"].int
        severity = Severity(rawValue: json["severity"].string("nit")) ?? .nit
        title = json["title"].string("")
        body = json["body"].string("")
        suggestion = json["suggestion"].string
        anchored = json["anchored"].bool(true)
    }
}

struct IntentNote: Equatable {
    let issue: String
    let verdict: String
    let body: String

    var headline: String {
        switch verdict {
        case "fulfils": return "Matches what the issue asked"
        case "partial": return "Only part of what the issue asked"
        case "diverges": return "Not what the issue asked"
        default: return "Could not tell"
        }
    }
}

struct ReviewPreview: Equatable {
    let repo: String
    let number: Int
    let head: String
    let base: String
    let title: String
    let url: String
    let provider: String
    let model: String
    let costUsd: Double
    var summary: String
    let intent: IntentNote?
    let risk: String          // "low" | "medium" | "high", or "" when the model did not say
    let blastRadius: String
    let files: Int
    let additions: Int
    let deletions: Int
    var findings: [Finding]

    init?(json: JSON) {
        guard json.exists, let repo = json["slug"].string, let n = json["pr"].int else { return nil }
        self.repo = repo
        number = n
        head = json["head"].string("")
        base = json["base"].string("")
        title = json["title"].string("")
        url = json["url"].string("")
        provider = json["provider"].string("")
        model = json["model"].string("")
        costUsd = json["costUsd"].double(0)
        summary = json["summary"].string("")
        let r = json["assessment"]["risk"].string("")
        risk = ["low", "medium", "high"].contains(r) ? r : ""
        blastRadius = json["assessment"]["blast_radius"].string("")
        files = json["files"].int(0)
        additions = json["additions"].int(0)
        deletions = json["deletions"].int(0)
        findings = json["findings"].array.map(Finding.init(json:))
        if json["intent"].exists, json["intent"]["verdict"].string != "no_ticket" {
            intent = IntentNote(issue: json["intent"]["issue"].string(""),
                                verdict: json["intent"]["verdict"].string("unknown"),
                                body: json["intent"]["body"].string(""))
        } else {
            intent = nil
        }
    }
}

/// What a person changed in a preview. Serialised to jobs/<id>/edits.json, which the
/// CLI validates again (review_apply_edits) before anything is posted.
struct ReviewEdits: Equatable {
    var dropped: Set<String> = []
    var edited: [String: FindingEdit] = [:]
    var summary: String? = nil

    var isEmpty: Bool { dropped.isEmpty && edited.isEmpty && summary == nil }

    func jsonData() -> Data {
        var obj: [String: Any] = [:]
        if !dropped.isEmpty { obj["drop"] = dropped.sorted() }
        var edit: [String: Any] = [:]
        for (id, e) in edited where !dropped.contains(id) {
            let d = e.asDictionary
            if !d.isEmpty { edit[id] = d }
        }
        if !edit.isEmpty { obj["edit"] = edit }
        if let summary, !summary.isEmpty { obj["summary"] = summary }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

struct FindingEdit: Equatable {
    var severity: Severity?
    var title: String?
    var body: String?

    var asDictionary: [String: Any] {
        var d: [String: Any] = [:]
        if let severity { d["severity"] = severity.rawValue }
        if let title { d["title"] = title }
        if let body { d["body"] = body }
        return d
    }
}

// MARK: - The inbox, history, providers

struct QueuedPR: Identifiable, Equatable {
    let repo: String
    let number: Int
    let title: String
    let url: String
    let author: String
    var id: String { "\(repo)#\(number)" }
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

struct HistoryEntry: Identifiable, Equatable {
    enum Kind { case posted, failed, previewed }
    let id: String
    let kind: Kind
    let repo: String
    let number: Int
    let title: String
    let url: String
    let at: Date
    let provider: String
    let model: String
    let costUsd: Double
    let reason: String
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

struct ProviderInfo: Identifiable, Equatable {
    let name: String
    let available: Bool
    let authed: Bool
    let authMode: String
    let version: String
    let model: String
    let costKnown: Bool
    let current: Bool
    let note: String
    var id: String { name }
    var ready: Bool { available && authed }

    var displayName: String {
        switch name {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        default: return name.capitalized
        }
    }
    var vendor: String {
        switch name {
        case "claude": return "Anthropic"
        case "codex": return "OpenAI"
        case "cursor": return "Cursor"
        default: return ""
        }
    }
    var installHint: String {
        switch name {
        case "claude": return "Install Claude Code from claude.ai/code, then run `claude` once to sign in."
        case "codex": return "npm i -g @openai/codex, then `codex login`."
        case "cursor": return "curl https://cursor.com/install -fsS | bash, then `cursor-agent login`."
        default: return note
        }
    }
    /// Only used when `goblin provider models` fails: a short list that is always valid.
    static func fallbackModels(_ name: String) -> [String] {
        name == "claude" ? ["sonnet", "opus", "haiku"] : []
    }

    init(json: JSON) {
        name = json["name"].string("")
        available = json["available"].bool(false)
        authed = json["authed"].bool(false)
        authMode = json["authMode"].string("")
        version = json["version"].string("")
        model = json["model"].string("")
        costKnown = json["costKnown"].bool(false)
        current = json["current"].bool(false)
        note = json["note"].string("")
    }
}

// MARK: - The published state (uistate.json)

struct Snapshot: Equatable {
    var loaded = false
    var setupComplete = true
    var enabled = true
    var state = "idle"
    var pausedReason = ""
    var activity = ""
    var snoozeUntil: Date? = nil
    var glyph: BarGlyph = .idle
    var barCount = 0
    var statusLine = ""
    var login = ""
    var identityOK = true
    var providerId = "claude"
    var providerModel = ""
    var reviewsToday = 0
    var reviewsTotal = 0
    var spendToday = 0.0
    var version = ""
    var updateAvailable = false
    var updateLatest = ""
    var updateURL = ""
    var agentInstalled = false
    var agentRunning = false
    var waiting = 0
    var jobsActive = 0
    var jobsReady = 0
    var repos: [(slug: String, enabled: Bool)] = []
    var fleet: [String] = []
    var settings = Settings()

    struct Settings: Equatable {
        var verdictMode = "comment"
        var allowApprove = false
        var maxReviewsPerDay = 20
        var maxReviewsPerRun = 5
        var maxFindings = 25
        var intervalSeconds = 900
        var incrementalReview = true
        var postCommitStatus = true
        var postIntentComment = true
        var fleetAssignment = true
        var skipIfHumanReviewed = true
        var refutePass = true
        var manualReviewMode = "preview"
        var maxConcurrentJobs = 2
        var lastRepo = ""
        var notifyStarted = true
        var notifyPosted = true
        var notifyFailed = true
        var notifyBudget = true
        var notifySound = true
        var models: [String: String] = [:]
    }

    static func == (a: Snapshot, b: Snapshot) -> Bool {
        a.loaded == b.loaded && a.state == b.state && a.glyph == b.glyph && a.barCount == b.barCount
            && a.statusLine == b.statusLine && a.login == b.login && a.providerId == b.providerId
            && a.providerModel == b.providerModel && a.reviewsToday == b.reviewsToday
            && a.spendToday == b.spendToday && a.enabled == b.enabled && a.setupComplete == b.setupComplete
            && a.snoozeUntil == b.snoozeUntil && a.waiting == b.waiting && a.jobsActive == b.jobsActive
            && a.jobsReady == b.jobsReady && a.settings == b.settings && a.updateAvailable == b.updateAvailable
            && a.agentRunning == b.agentRunning && a.identityOK == b.identityOK && a.activity == b.activity
            && a.repos.map(\.slug) == b.repos.map(\.slug) && a.repos.map(\.enabled) == b.repos.map(\.enabled)
            && a.fleet == b.fleet && a.pausedReason == b.pausedReason && a.reviewsTotal == b.reviewsTotal
            && a.version == b.version && a.updateLatest == b.updateLatest && a.updateURL == b.updateURL
            && a.agentInstalled == b.agentInstalled
    }

    init() {}

    init(json ui: JSON, config: JSON) {
        loaded = ui.exists
        // Absent means "assume fine": showing a first-run flow to someone who has been
        // using this for a month would be far worse than not showing it at all.
        setupComplete = ui["setup"]["complete"].bool(true)
        enabled = ui["enabled"].bool(true)
        state = ui["state"].string("idle")
        pausedReason = ui["pausedReason"].string("")
        activity = ui["activity"].string("")
        let snooze = ui["snoozeUntil"].double(0)
        snoozeUntil = snooze > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: snooze) : nil
        glyph = BarGlyph(rawValue: ui["bar"]["glyph"].string("idle")) ?? .idle
        if !setupComplete { glyph = .error }
        barCount = setupComplete ? max(0, ui["bar"]["count"].int(0)) : 0
        statusLine = ui["bar"]["tooltip"].string("")
        login = ui["identity"]["login"].string("")
        identityOK = ui["identity"]["ok"].bool(true)
        providerId = ui["provider"]["id"].string("claude")
        providerModel = ui["provider"]["model"].string("")
        reviewsToday = ui["reviews"]["today"].int(0)
        reviewsTotal = ui["reviews"]["total"].int(0)
        spendToday = ui["spendUsd"]["today"].double(0)
        version = ui["goblin"]["version"].string("")
        updateAvailable = ui["update"]["available"].bool(false)
        updateLatest = ui["update"]["latest"].string("")
        updateURL = ui["update"]["url"].string("")
        agentInstalled = ui["agent"]["installed"].bool(false)
        agentRunning = ui["agent"]["running"].bool(false)
        waiting = ui["inbox"]["waiting"].int(0)
        jobsActive = ui["jobs"]["active"].int(0)
        jobsReady = ui["jobs"]["ready"].int(0)
        repos = ui["repos"].array.compactMap { r in
            r["slug"].string.map { ($0, r["enabled"].bool(true)) }
        }
        fleet = ui["fleet"].array.compactMap(\.string)

        let s = ui["settings"]
        var st = Settings()
        st.verdictMode = s["verdictMode"].string("comment")
        st.allowApprove = s["allowApprove"].bool(false)
        st.maxReviewsPerDay = s["maxReviewsPerDay"].int(20)
        st.maxReviewsPerRun = s["maxReviewsPerRun"].int(5)
        st.maxFindings = s["maxFindings"].int(25)
        st.intervalSeconds = s["intervalSeconds"].int(900)
        st.incrementalReview = s["incrementalReview"].bool(true)
        st.postCommitStatus = s["postCommitStatus"].bool(true)
        st.postIntentComment = s["postIntentComment"].bool(true)
        st.fleetAssignment = s["fleetAssignment"].bool(true)
        st.skipIfHumanReviewed = s["skipIfHumanReviewed"].bool(true)
        st.refutePass = s["refutePass"].bool(true)
        st.manualReviewMode = s["manualReviewMode"].string("preview")
        st.maxConcurrentJobs = s["maxConcurrentJobs"].int(2)
        st.lastRepo = s["lastRepo"].string("")
        st.notifyStarted = s["notify"]["started"].bool(true)
        st.notifyPosted = s["notify"]["posted"].bool(true)
        st.notifyFailed = s["notify"]["failed"].bool(true)
        st.notifyBudget = s["notify"]["budget"].bool(true)
        st.notifySound = s["notify"]["sound"].bool(true)
        for (k, v) in (s["providers"].object ?? [:]) { st.models[k] = JSON(v)["model"].string("") }
        settings = st
    }
}

// MARK: - Doctor

struct DoctorCheck: Identifiable, Equatable {
    enum Status: String { case ok, warn, fail }
    let id: String
    let status: Status
    let check: String
    let detail: String
    let fix: String
}
