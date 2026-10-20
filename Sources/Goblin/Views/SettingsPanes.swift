//  SettingsPanes.swift — one view per sidebar entry.
//
//  Every value shown comes from `store.snapshot` (what the engine published) and every
//  change goes out as a typed `Command`. Nothing here builds an argument list, and the
//  only free text — a model name, a repo, a login, a search — is checked against its
//  `Pattern` before the Command that would carry it can even be constructed.

import SwiftUI

// MARK: - General

struct GeneralPane: View {
    @Bindable var store: AppStore
    @State private var intervalDirty = false

    private var s: Snapshot { store.snapshot }

    var body: some View {
        SettingsPage(title: "General", subtitle: "Who the Goblin reviews as, and when he is on duty.") {
            account
            duty
            manual
            shortcuts
        }
        .task { await store.refreshAccounts() }
    }

    // MARK: account

    private var logins: [String] {
        var l = store.accounts.map(\.login)
        if !s.login.isEmpty, !l.contains(s.login) { l.insert(s.login, at: 0) }
        return l
    }

    private var account: some View {
        SettingsGroup(title: "GitHub account",
                      footer: "Reviews are posted from this account, clearly labelled as automated.") {
            SettingRow(title: "Reviewing as", hint: "Pick any account you are signed in to with gh.", last: s.identityOK) {
                if logins.count > 1 {
                    Picker("", selection: Binding(
                        get: { s.login },
                        set: { new in Task { await store.perform(.setIdentity(login: new), success: "Now reviewing as @\(new).") } })) {
                        ForEach(logins, id: \.self) { Text("@\($0)").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                } else {
                    Chip(text: s.login.isEmpty ? "not set" : "@\(s.login)", symbol: "person.crop.circle",
                         tint: s.login.isEmpty ? Color(nsColor: .systemOrange) : Theme.accent)
                }
            }
            if !s.identityOK {
                let active = store.accounts.first(where: \.active)?.login ?? "another account"
                SettingRow(title: "gh is using @\(active)",
                           hint: "The Goblin reviews as @\(s.login), but gh is signed in as someone else, so reviews would be refused. Switch gh back.",
                           last: true) {
                    Button("Switch gh to @\(s.login)") {
                        Task { await store.perform(.fixAccount, success: "gh is now using @\(s.login).") }
                    }.buttonStyle(.goblinPrimarySmall)
                }
            }
        }
    }

    // MARK: duty

    private var duty: some View {
        SettingsGroup(title: "On duty") {
            SettingRow(title: "Review my requests automatically",
                       hint: s.enabled ? "He checks your repos on a schedule and reviews what asks for you." : "Off. Nothing is reviewed unless you ask for it by number.") {
                Toggle("", isOn: Binding(get: { s.enabled }, set: { store.setPower($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            FlagRow(store: store, title: "Open at login",
                    hint: "Starts the menu bar app when you log in.",
                    value: store.loginItemOn, command: { .loginItem(on: $0) })
            SettingRow(title: "Check for new requests every",
                       hint: s.agentInstalled ? (s.agentRunning ? "The scheduler is running." : "The scheduler is installed but not running.")
                                              : "No scheduler is installed. Run the installer to add one.",
                       last: true) {
                HStack(spacing: 10) {
                    if intervalDirty {
                        Button("Apply now") {
                            Task { if await store.perform(.agent(.reload), success: "Scheduler reloaded.") { intervalDirty = false } }
                        }.buttonStyle(.goblinPrimarySmall)
                    }
                    IntervalStepper(store: store, seconds: s.settings.intervalSeconds) { intervalDirty = true }
                }
            }
        }
    }

    // MARK: review by number

    private var manual: some View {
        SettingsGroup(title: "Review by number") {
            SettingRow(title: "When a review finishes",
                       hint: s.settings.manualReviewMode == "preview"
                         ? "You read it first, can edit or drop findings, then post it."
                         : "It is posted straight away, with no chance to read it first.") {
                Picker("", selection: Binding(
                    get: { ReviewMode(rawValue: s.settings.manualReviewMode) ?? .preview },
                    set: { new in Task { await store.perform(.setManualReviewMode(new)) } })) {
                    Text("Let me read it first").tag(ReviewMode.preview)
                    Text("Post it").tag(ReviewMode.post)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            NumberRow(store: store, title: "Reviews at the same time",
                      hint: "More than one runs side by side, except on the same repo.",
                      value: s.settings.maxConcurrentJobs, range: 1...8, last: true,
                      command: { .setMaxConcurrentJobs($0) })
        }
    }

    private var shortcuts: some View {
        SettingsGroup(title: "Ways to start one") {
            SettingRow(title: "Quick review", hint: "A field floats over whatever you are doing. Type 2456, press return.") {
                Chip(text: "⌥⌘G", tint: Theme.accent)
            }
            SettingRow(title: "Links", hint: "Shows up in a browser, a script or a Shortcut. Always opens as a preview.") {
                Text(verbatim: "goblin://review/2456").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            SettingRow(title: "Terminal", hint: "Uses the repo of the folder you are in.", last: true) {
                Text(verbatim: "goblin review 2456").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The schedule interval, shown in minutes and stored in seconds.
private struct IntervalStepper: View {
    let store: AppStore
    let seconds: Int
    var changed: () -> Void
    @State private var minutes: Int
    @State private var pending: Task<Void, Never>?

    init(store: AppStore, seconds: Int, changed: @escaping () -> Void) {
        self.store = store; self.seconds = seconds; self.changed = changed
        _minutes = State(initialValue: max(1, seconds / 60))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: minutes == 1 ? "1 minute" : "\(minutes) minutes")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(minWidth: 84, alignment: .trailing)
            Stepper("", value: Binding(get: { minutes }, set: { set($0) }), in: 1...1440).labelsHidden()
        }
        .onChange(of: seconds) { _, new in minutes = max(1, new / 60) }
    }

    private func set(_ new: Int) {
        minutes = new
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            if await store.perform(.setIntervalMinutes(new)) { changed() } else { minutes = max(1, seconds / 60) }
        }
    }
}

// MARK: - Reviewer

struct ReviewerPane: View {
    @Bindable var store: AppStore

    var body: some View {
        SettingsPage(title: "Reviewer",
                     subtitle: "The AI subscription that does the reviewing. The Goblin drives a command line tool you are already signed in to — no API keys.") {
            switch store.providersState {
            case .failed(let m) where store.providers.isEmpty:
                SettingsGroup {
                    StatusLine(kind: .error, text: m)
                }
            case .idle where store.providers.isEmpty, .loading where store.providers.isEmpty:
                SettingsGroup { StatusLine(kind: .loading, text: "Checking which AI tools are installed and signed in…") }
            default:
                if store.providers.isEmpty {
                    SettingsGroup { StatusLine(kind: .warning, text: "No AI command line tools were found. Install one below, then check again.") }
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.providers) { ProviderCard(store: store, provider: $0) }
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { await store.refreshProviders() }
                } label: {
                    HStack(spacing: 6) {
                        if store.providersState == .loading { ProgressView().controlSize(.small) }
                        Text(store.providersState == .loading ? "Checking…" : "Check again")
                    }
                }
                .buttonStyle(.goblin).disabled(store.providersState == .loading)
                if case .failed(let m) = store.providersState, !store.providers.isEmpty {
                    Text(m).font(.caption).foregroundStyle(Color(nsColor: .systemRed)).lineLimit(2)
                }
                Spacer()
                Text("Each provider bills your own subscription.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .task { if store.providersState == .idle { await store.refreshProviders() } }
    }
}

private struct ProviderCard: View {
    let store: AppStore
    let provider: ProviderInfo
    private var saved: String { store.snapshot.settings.models[provider.name] ?? provider.model }
    private var isCurrent: Bool { store.snapshot.providerId == provider.name }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(provider.ready ? Theme.accentSoft : Color.primary.opacity(0.07)).frame(width: 34, height: 34)
                        Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(provider.ready ? Theme.accent : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                            if !provider.vendor.isEmpty { Text(provider.vendor).font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                        }
                        Text(details).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    statusChip
                    if isCurrent {
                        Chip(text: "In use", symbol: "checkmark", tint: Theme.accent)
                    } else if provider.ready {
                        Button("Use") { Task { await store.perform(.setProvider(ProviderId(rawValue: provider.name) ?? .claude), success: "\(provider.displayName) will do the reviewing.") } }
                            .buttonStyle(.goblinSmall).disabled(ProviderId(rawValue: provider.name) == nil)
                    }
                }
                if provider.ready { modelRow } else { notReady }
            }
        }
    }

    private var symbol: String {
        switch provider.name { case "claude": return "sparkles"; case "codex": return "terminal"; case "cursor": return "cursorarrow.rays"; default: return "cpu" }
    }

    private var details: String {
        var parts: [String] = []
        if !provider.version.isEmpty { parts.append(provider.version) }
        if !provider.authMode.isEmpty { parts.append("signed in: \(provider.authMode)") }
        if provider.ready { parts.append(provider.costKnown ? "reports cost" : "counts reviews, not dollars") }
        return parts.isEmpty ? "not installed" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusChip: some View {
        if provider.ready { Chip(text: "Ready", symbol: "checkmark.circle.fill", tint: Theme.accent) }
        else if provider.available { Chip(text: "Needs sign-in", symbol: "person.crop.circle.badge.exclamationmark", tint: Color(nsColor: .systemOrange)) }
        else { Chip(text: "Not installed", symbol: "arrow.down.circle", tint: .secondary) }
    }

    private var modelRow: some View {
        HStack(spacing: 8) {
            Text("Model").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            ModelMenu(store: store, provider: provider.name,
                      selection: Binding(get: { saved }, set: { choose($0) }))
        }
    }

    private func choose(_ model: String) {
        guard model != saved, let id = ProviderId(rawValue: provider.name) else { return }
        let label = ModelCatalog.label(for: model, in: store.modelCatalog[provider.name] ?? [])
        Task {
            await store.perform(.setProviderModel(provider: id, model: model),
                                success: model.isEmpty ? "Using \(provider.displayName)'s default model." : "Model set to \(label).")
        }
    }

    private var notReady: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider.available ? "Sign in to use it:" : "To use it:").font(.system(size: 12, weight: .semibold))
            Text(provider.installHint).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Repositories

struct ReposPane: View {
    @Bindable var store: AppStore
    @State private var query = ""
    @State private var results: [RepoResult] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var manual = ""

    private var configured: Set<String> { Set(store.snapshot.repos.map(\.slug)) }
    private var queryValid: Bool { Pattern.searchQuery.accepts(query) }
    private var manualValid: Bool { Pattern.repoSlug.accepts(manual) }

    var body: some View {
        SettingsPage(title: "Repositories", subtitle: "The repos the Goblin watches for pull requests that ask for your review. Review by number works on any repo you can see.") {
            watched
            search
            manualAdd
        }
    }

    // MARK: watched

    private var watched: some View {
        SettingsGroup(title: "Watching") {
            if store.snapshot.repos.isEmpty {
                StatusLine(kind: .info, text: "Nothing yet. Search below, or paste owner/name.")
            }
            ForEach(Array(store.snapshot.repos.enumerated()), id: \.element.slug) { i, repo in
                SettingRow(title: repo.slug, hint: repo.enabled ? nil : "Paused — not being watched.",
                           last: i == store.snapshot.repos.count - 1) {
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { repo.enabled },
                            set: { on in Task { await store.perform(.repoEnable(slug: repo.slug, on: on)) } }))
                            .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                        Button { Task { await store.perform(.repoRemove(slug: repo.slug), success: "Stopped watching \(repo.slug).") } } label: {
                            Image(systemName: "trash").font(.system(size: 12))
                        }.buttonStyle(.goblinQuiet).help("Stop watching")
                    }
                }
            }
        }
    }

    // MARK: search

    private var search: some View {
        SettingsGroup(title: "Add a repository") {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the repos you can see", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if searching { ProgressView().controlSize(.small) }
                else if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider().opacity(0.6)
            if !queryValid {
                StatusLine(kind: .warning, text: "Search uses letters, numbers and . _ - / only.")
            } else if let e = searchError {
                StatusLine(kind: .error, text: e)
            } else if results.isEmpty && !searching {
                StatusLine(kind: .info, text: query.isEmpty ? "No repositories to show." : "No repository matches “\(query)”.")
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                resultRow(r, last: i == results.count - 1)
            }
        }
        .task(id: query) { await runSearch() }
    }

    private func resultRow(_ r: RepoResult, last: Bool) -> some View {
        let added = r.watched || configured.contains(r.slug)
        return SettingRow(title: r.slug, hint: r.description.isEmpty ? nil : r.description, last: last) {
            HStack(spacing: 8) {
                if r.isPrivate { Chip(text: "private", symbol: "lock.fill") }
                if added {
                    Chip(text: "Watching", symbol: "checkmark", tint: Theme.accent)
                } else {
                    Button("Add") { add(r.slug) }.buttonStyle(.goblinSmall)
                }
            }
        }
    }

    private func runSearch() async {
        guard queryValid else { results = []; searchError = nil; return }
        searching = true
        // Typing is cheap; the engine call is not. Wait for a pause.
        try? await Task.sleep(nanoseconds: query.isEmpty ? 0 : 350_000_000)
        guard !Task.isCancelled else { return }
        do {
            let r = try await store.searchRepos(query)
            guard !Task.isCancelled else { return }
            results = r; searchError = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = (error as? LocalizedError)?.errorDescription ?? "The search failed."
        }
        searching = false
    }

    private func add(_ slug: String) {
        Task { if await store.perform(.repoAdd(slug: slug), success: "Now watching \(slug).") { await runSearch() } }
    }

    // MARK: manual

    private var manualAdd: some View {
        SettingsGroup(title: "Or type it", footer: "Use owner/name, like acme/widgets.") {
            SettingRow(title: "Repository", last: true) {
                HStack(spacing: 8) {
                    TextField("owner/name", text: $manual)
                        .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 5).frame(width: 190)
                        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(manual.isEmpty || manualValid ? Theme.hairline : Color(nsColor: .systemRed).opacity(0.7), lineWidth: 0.5))
                        .onSubmit(addManual)
                    Button("Add", action: addManual).buttonStyle(.goblinPrimarySmall).disabled(!manualValid).fixedSize()
                }
            }
        }
    }

    private func addManual() {
        guard manualValid else { return }
        let slug = manual
        Task { if await store.perform(.repoAdd(slug: slug), success: "Now watching \(slug).") { manual = "" } }
    }
}

// MARK: - Team

struct TeamPane: View {
    @Bindable var store: AppStore
    @State private var login = ""

    private var valid: Bool { Pattern.githubLogin.accepts(login) }
    private var fleet: [String] { store.snapshot.fleet }

    var body: some View {
        SettingsPage(title: "Team",
                     subtitle: "Teammates who also run the Goblin, so that exactly one of you reviews each pull request.") {
            SettingsGroup {
                FlagRow(store: store, title: "Share the work with them",
                        hint: "Each PR is assigned to one person on the list. If that person's Mac looks asleep, someone else picks it up.",
                        value: store.snapshot.settings.fleetAssignment, last: true,
                        command: { .setFlag(key: .fleetAssignment, on: $0) })
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Teammates", trailing: statusNote)
                    if !fleet.isEmpty { refreshButton }
                }
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        if fleet.isEmpty { StatusLine(kind: .info, text: "Just you. Add a teammate's GitHub username if they run the Goblin too.") }
                        if case .failed(let m) = store.fleetState, store.fleetStatus == nil, !fleet.isEmpty {
                            StatusLine(kind: .warning, text: m)
                            Divider().opacity(0.6).padding(.leading, 14)
                        }
                        ForEach(Array(fleet.enumerated()), id: \.element) { i, name in
                            TeamMemberRow(login: name, member: store.fleetStatus?.member(name),
                                          isMe: name.caseInsensitiveCompare(store.snapshot.login) == .orderedSame,
                                          loading: store.fleetState == .loading, last: i == fleet.count - 1) {
                                Task { await store.perform(.fleetRemove(login: name)) }
                            }
                            .transition(Motion.row)
                        }
                    }
                }
                .animation(Motion.spring, value: fleet)
                if !fleet.isEmpty {
                    Text("Read from what each Goblin leaves on GitHub in your watched repos: the claim it takes while reviewing, and the markers on what it posts. One with nothing to review leaves no trace, so “no sign” does not mean offline.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
                }
            }
            .task(id: fleet) { await store.loadFleetStatus() }
            SettingsGroup(footer: "GitHub usernames use letters, numbers and hyphens.") {
                SettingRow(title: "Add a teammate", last: true) {
                    HStack(spacing: 8) {
                        TextField("github username", text: $login)
                            .textFieldStyle(.plain).font(.system(size: 12.5))
                            .padding(.horizontal, 9).padding(.vertical, 5).frame(width: 190)
                            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(login.isEmpty || valid ? Theme.hairline : Color(nsColor: .systemRed).opacity(0.7), lineWidth: 0.5))
                            .onSubmit(add)
                        Button("Add", action: add).buttonStyle(.goblinPrimarySmall).disabled(!valid || fleet.contains(login)).fixedSize()
                    }
                }
            }
        }
    }

    /// "checked 2m ago", or why the list may be old.
    private var statusNote: String? {
        guard let f = store.fleetStatus, !fleet.isEmpty else { return nil }
        if f.stale { return "GitHub unreachable · as of \(Ago.short(f.at))" }
        if case .failed = store.fleetState { return "last checked \(Ago.short(f.at))" }
        return f.reposFailed > 0 ? "checked \(Ago.short(f.at)) · \(f.reposFailed) repo\(f.reposFailed == 1 ? "" : "s") unreadable"
                                 : "checked \(Ago.short(f.at))"
    }

    private var refreshButton: some View {
        Button { Task { await store.loadFleetStatus(refresh: true) } } label: {
            if store.fleetState == .loading { ProgressView().controlSize(.mini) }
            else { Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold)) }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .disabled(store.fleetState == .loading)
        .help("Ask GitHub again")
        .accessibilityLabel("Refresh teammates")
    }

    private func add() {
        guard valid, !fleet.contains(login) else { return }
        let name = login
        Task { if await store.perform(.fleetAdd(login: name)) { login = "" } }
    }
}

// MARK: - Behaviour

struct BehaviourPane: View {
    @Bindable var store: AppStore
    @State private var verdict: VerdictMode

    init(store: AppStore) {
        self.store = store
        _verdict = State(initialValue: VerdictMode(rawValue: store.snapshot.settings.verdictMode) ?? .comment)
    }

    private var s: Snapshot.Settings { store.snapshot.settings }

    var body: some View {
        SettingsPage(title: "Behaviour", subtitle: "How the Goblin words his reviews, and what he leaves alone.") {
            verdictCards
            SettingsGroup(title: "Reviews he does on his own") {
                let current = AutoPost(rawValue: s.autoPost) ?? .always
                SettingRow(title: "When one is ready", hint: current.hint, last: true) {
                    Picker("", selection: Binding(
                        get: { current },
                        set: { new in Task { await store.perform(.setAutoPost(new)) } })) {
                        ForEach(AutoPost.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            SettingsGroup(title: "Approving") {
                FlagRow(store: store, title: "Allow approving a clean PR",
                        hint: verdict == .full
                          ? "Only when there are no findings at all. Approving under your name can't be taken back."
                          : "Needs “Full verdict” above.",
                        value: s.allowApprove, enabled: verdict == .full, last: true,
                        command: { .setAllowApprove($0) })
            }
            SettingsGroup(title: "What he looks at") {
                FlagRow(store: store, title: "Only look at what changed since last time",
                        hint: "On a new push, skip findings he already posted.",
                        value: s.incrementalReview, command: { .setFlag(key: .incrementalReview, on: $0) })
                FlagRow(store: store, title: "Leave PRs a person already reviewed",
                        hint: "Once a colleague has left a real review, an automated one is just noise.",
                        value: s.skipIfHumanReviewed, command: { .setFlag(key: .skipIfHumanReviewed, on: $0) })
                FlagRow(store: store, title: "Double-check before posting",
                        hint: "A second look tries to disprove each finding before an unattended review posts. Costs about twice as much; previews skip it.",
                        value: s.refutePass, command: { .setFlag(key: .refutePass, on: $0) })
                FlagRow(store: store, title: "Show a status on the commit",
                        hint: "A small “Merge Goblin / review” check next to the PR's other checks.",
                        value: s.postCommitStatus, last: true, command: { .setFlag(key: .postCommitStatus, on: $0) })
            }
            SettingsGroup(title: "Limits", footer: "Limits protect your subscription from a big backlog. They don't apply to a review you ask for by number.") {
                NumberRow(store: store, title: "Reviews per day", hint: "He stops for the day after this many.",
                          value: s.maxReviewsPerDay, range: 0...500, unit: "a day", zeroLabel: "No cap",
                          command: { .setMaxReviewsPerDay($0) })
                NumberRow(store: store, title: "Reviews per check", hint: "Stops a backlog running away.",
                          value: s.maxReviewsPerRun, range: 1...50, command: { .setMaxReviewsPerRun($0) })
                NumberRow(store: store, title: "Findings per review", hint: "Keeps a review readable.",
                          value: s.maxFindings, range: 1...200, last: true, command: { .setMaxFindings($0) })
            }
        }
        .onChange(of: s.verdictMode) { _, new in verdict = VerdictMode(rawValue: new) ?? .comment }
    }

    private var verdictCards: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "Verdict")
            VStack(spacing: 8) {
                option(.comment, "Comment only", "Posts his findings as a comment. Never approves, never blocks. The safe default.")
                option(.requestChanges, "Request changes on blockers", "If he finds a blocker the review asks for changes; otherwise it is a comment.")
                option(.full, "Full verdict", "Can request changes, and approve a clean PR if you allow approving below.")
            }
        }
    }

    private func option(_ mode: VerdictMode, _ title: String, _ hint: String) -> some View {
        let on = verdict == mode
        return Button {
            guard !on else { return }
            let before = verdict
            verdict = mode
            Task { if await !store.perform(.setVerdictMode(mode)) { verdict = before } }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15)).foregroundStyle(on ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: on ? 1 : 0.5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @Bindable var store: AppStore
    private var s: Snapshot.Settings { store.snapshot.settings }

    var body: some View {
        SettingsPage(title: "Notifications", subtitle: "When the Goblin taps you on the shoulder.") {
            SettingsGroup {
                FlagRow(store: store, title: "A review starts", hint: "Only for reviews he starts on his own; ones you ask for show their own progress.",
                        value: s.notifyStarted, command: { .setFlag(key: .notifyStarted, on: $0) })
                FlagRow(store: store, title: "A review is posted or ready to read",
                        value: s.notifyPosted, command: { .setFlag(key: .notifyPosted, on: $0) })
                FlagRow(store: store, title: "A review fails",
                        value: s.notifyFailed, command: { .setFlag(key: .notifyFailed, on: $0) })
                FlagRow(store: store, title: "He hits the daily cap",
                        value: s.notifyBudget, last: true, command: { .setFlag(key: .notifyBudget, on: $0) })
            }
            SettingsGroup {
                FlagRow(store: store, title: "Play a sound", value: s.notifySound, last: true,
                        command: { .setFlag(key: .notifySound, on: $0) })
            }
        }
    }
}

// MARK: - Health

struct HealthPane: View {
    @Bindable var store: AppStore

    private var fails: Int { store.doctor.filter { $0.status == .fail }.count }
    private var warns: Int { store.doctor.filter { $0.status == .warn }.count }
    private var running: Bool { store.doctorState == .loading }

    var body: some View {
        SettingsPage(title: "Health", subtitle: "Checks that GitHub, your AI tools, the clones and the scheduler are all in order.") {
            HStack(spacing: 8) {
                Button { Task { await store.runDoctor() } } label: {
                    HStack(spacing: 6) {
                        if running { ProgressView().controlSize(.small) }
                        Text(running ? "Checking…" : "Run checks")
                    }
                }.buttonStyle(.goblinPrimary).disabled(running)
                Button("Fix what can be fixed") { Task { await store.runDoctor(fix: true) } }
                    .buttonStyle(.goblin).disabled(running || fails + warns == 0)
                Spacer()
                if store.doctorState == .loaded {
                    if fails > 0 { Chip(text: "\(fails) failing", symbol: "xmark.octagon.fill", tint: Color(nsColor: .systemRed)) }
                    if warns > 0 { Chip(text: "\(warns) to look at", symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange)) }
                    if fails + warns == 0 { Chip(text: "All good", symbol: "checkmark.circle.fill", tint: Theme.accent) }
                }
            }
            checks
            SettingsGroup(title: "Tools") {
                SettingRow(title: "Copy diagnostics", hint: "Version, account, provider and the last few reviews — safe to paste into a bug report.") {
                    Button("Copy") { store.copyDiagnostics() }.buttonStyle(.goblinSmall)
                }
                SettingRow(title: "Open the log") { Button("Open") { store.openLog() }.buttonStyle(.goblinSmall) }
                SettingRow(title: "Show the Goblin's folder", hint: store.home, last: true) {
                    Button("Reveal in Finder") { store.revealHome() }.buttonStyle(.goblinSmall)
                }
            }
        }
        .task { if store.doctorState == .idle { await store.runDoctor() } }
    }

    @ViewBuilder private var checks: some View {
        switch store.doctorState {
        case .failed(let m): SettingsGroup { StatusLine(kind: .error, text: m) }
        case .idle where store.doctor.isEmpty, .loading where store.doctor.isEmpty:
            SettingsGroup { StatusLine(kind: .loading, text: "Running the checks…") }
        default:
            if store.doctor.isEmpty {
                SettingsGroup { StatusLine(kind: .info, text: "Run the checks to see how things look.") }
            } else {
                SettingsGroup {
                    ForEach(Array(store.doctor.enumerated()), id: \.element.id) { i, c in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: icon(c.status)).foregroundStyle(color(c.status))
                                .font(.system(size: 14, weight: .semibold)).frame(width: 18).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.check).font(.system(size: 13, weight: .medium))
                                if !c.detail.isEmpty { Text(c.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                if c.status != .ok, !c.fix.isEmpty {
                                    Text(c.fix).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(color(c.status))
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        if i < store.doctor.count - 1 { Divider().opacity(0.6).padding(.leading, 43) }
                    }
                }
            }
        }
    }

    private func icon(_ s: DoctorCheck.Status) -> String {
        switch s { case .ok: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill" }
    }
    private func color(_ s: DoctorCheck.Status) -> Color {
        switch s { case .ok: return Theme.accent; case .warn: return Color(nsColor: .systemOrange); case .fail: return Color(nsColor: .systemRed) }
    }
}

// MARK: - About

struct AboutPane: View {
    @Bindable var store: AppStore

    private var engine: String {
        switch CLI.shared.engineSource {
        case .bundled: return "built into this app"
        case .installed: return "from your install"
        case .none: return "not found"
        }
    }

    var body: some View {
        SettingsPage(title: "About") {
            Card(padding: 18) {
                HStack(spacing: 16) {
                    GoblinAvatar(size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("The Merge Goblin").font(.system(size: 18, weight: .bold))
                        Text("guards the merge button").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Chip(text: store.snapshot.version.isEmpty ? "version unknown" : "v\(store.snapshot.version)")
                            Chip(text: "engine \(engine)")
                        }.padding(.top, 3)
                    }
                    Spacer(minLength: 0)
                }
            }
            if store.snapshot.updateAvailable {
                SettingsGroup {
                    SettingRow(title: "Version \(store.snapshot.updateLatest) is available",
                               hint: "The Goblin never updates himself. Download it, or run brew upgrade.", last: true) {
                        Button("Get it") { store.openURL(store.snapshot.updateURL) }.buttonStyle(.goblinPrimarySmall)
                            .disabled(store.snapshot.updateURL.isEmpty)
                    }
                }
            }
            UsageGroup(store: store)
            StatsGroup(store: store)
            SettingsGroup(title: "How it works") {
                SettingRow(title: "He reads your repo's own review rules.", hint: "No configuration needed; a review guide in the repo is followed.")
                { EmptyView() }
                SettingRow(title: "He uses the AI subscription you already pay for.", hint: "Nothing is sent anywhere except to the tool you signed in to.")
                { EmptyView() }
                SettingRow(title: "He posts one clearly labelled review.", hint: "From your account, advisory only: it never approves or blocks unless you say so.", last: true)
                { EmptyView() }
            }
            SettingsGroup(title: "More") {
                SettingRow(title: "Project page") {
                    Button("Open on GitHub") { store.openURL("https://github.com/Kiril-P/merge-goblin") }.buttonStyle(.goblinSmall)
                }
                SettingRow(title: "Log file", last: true) { Button("Open") { store.openLog() }.buttonStyle(.goblinSmall) }
            }
        }
    }
}
