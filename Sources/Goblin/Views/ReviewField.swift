//  ReviewField.swift — "type 2456, press return."
//
//  The whole point of the app in one control. It parses as you type (instant, local),
//  asks the engine what the ref means (debounced, network), shows you the PR title so
//  you know it is the right one BEFORE a model is spent on it, and starts the job.

import SwiftUI

@MainActor
@Observable
final class ReviewInput {
    var text = "" { didSet { if text != oldValue { textChanged() } } }
    var options = ReviewOptions()
    var repoChoice: String? = nil { didSet { if repoChoice != oldValue { textChanged() } } }
    var resolution: Resolution? = nil
    private(set) var resolving = false
    private(set) var starting = false

    private var task: Task<Void, Never>?
    let store: AppStore

    init(store: AppStore) { self.store = store }

    var ref: PRRef? { PRRef.parse(text) }

    /// Everything that could be the repo for a bare number: the current one, the
    /// watched ones, then any reviewed recently.
    var repoCandidates: [String] {
        var seen: [String] = []
        let recent = store.history.map(\.repo) + store.jobs.map(\.repo)
        for s in [store.snapshot.settings.lastRepo] + store.snapshot.repos.map(\.slug) + extraCandidates + recent {
            if !s.isEmpty, Pattern.repoSlug.accepts(s), !seen.contains(s) { seen.append(s) }
        }
        return seen
    }

    /// The repo a bare number means, before anything is typed. Same rule as the engine
    /// (lib/review.sh ref_repo_resolve): the last one used, else the only watched one.
    var defaultRepo: String? {
        let last = store.snapshot.settings.lastRepo
        if !last.isEmpty { return last }
        let enabled = store.snapshot.repos.filter(\.enabled).map(\.slug)
        return enabled.count == 1 ? enabled[0] : nil
    }

    /// What the switcher in front of the field shows: the link's repo when the text
    /// names one, else the chosen repo.
    var currentRepo: String? { ref?.slug ?? repoChoice ?? defaultRepo }

    /// Switch repos up front. Remembered (lastRepo), so the next number means it too.
    func chooseRepo(_ slug: String) {
        guard Pattern.repoSlug.accepts(slug) else { return }
        repoChoice = slug
        if slug != store.snapshot.settings.lastRepo {
            Task { await store.perform(.setLastRepo(slug)) }
        }
    }
    private var extraCandidates: [String] = []

    var canStart: Bool {
        guard ref != nil, !starting else { return false }
        if case .found = resolution { return true }
        return false
    }

    private func textChanged() {
        task?.cancel()
        resolution = nil
        guard let ref else { resolving = false; return }
        resolving = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            let repo = self.repoChoice ?? self.defaultRepo
            let r = await self.store.resolve(ref, repo: ref.slug == nil ? repo : nil)
            guard !Task.isCancelled else { return }
            self.resolving = false
            if case .needsRepo(let c) = r { self.extraCandidates = c }
            self.resolution = r
        }
    }

    func useClipboard(_ ref: PRRef) {
        repoChoice = nil
        text = ref.canonical
        store.dismissClipboard()
    }

    /// Starts the review. Returns the job if it started.
    @discardableResult
    func submit() async -> Job? {
        guard let ref, case .found(let pr)? = resolution, !starting else { return nil }
        starting = true
        defer { starting = false }
        var o = options
        // Pin the repo the person was SHOWN, so the job cannot resolve differently from
        // what was on screen (a different cwd, a changed "last repo").
        o.repo = ref.slug == nil ? pr.repo : nil
        let job = await store.startReview(ref, options: o)
        if job != nil {
            text = ""
            options.force = false
        }
        return job
    }
}

struct ReviewField: View {
    @Bindable var input: ReviewInput
    var store: AppStore
    var autofocus = true
    var onStarted: (Job) -> Void = { _ in }
    @FocusState private var focused: Bool
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RepoSwitch(input: input, store: store)
                TextField(input.currentRepo == nil ? "owner/repo#2456 or a PR link" : "PR number or link",
                          text: $input.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { go() }
                if input.resolving || input.starting {
                    ProgressView().controlSize(.small)
                } else if !input.text.isEmpty {
                    Button { input.text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("Clear")
                }
                Button(action: go) {
                    HStack(spacing: 4) { Text("Review"); Image(systemName: "return").font(.system(size: 10, weight: .bold)) }
                }
                .buttonStyle(.goblinPrimarySmall)
                .disabled(!input.canStart)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: focused ? 1.5 : 0.5))

            feedback
            if showOptions { optionsPanel }
            footer
        }
        .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
    }

    private func go() {
        Task {
            if let job = await input.submit() { onStarted(job) }
        }
    }

    // MARK: feedback line

    @ViewBuilder private var feedback: some View {
        if input.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let clip = store.clipboard {
                Button { input.useClipboard(clip) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 11))
                        Text("Review \(clip.display) from your clipboard").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("use").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
            }
        } else if input.ref == nil {
            Label("That doesn't look like a pull request. Try 2456 or a GitHub link.", systemImage: "questionmark.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let r = input.resolution {
            switch r {
            case .found(let pr): resolved(pr)
            case .needsRepo(let candidates): repoPicker(candidates: candidates)
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if input.resolving {
            Text("Looking it up…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func resolved(_ pr: ResolvedPR) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(pr.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            HStack(spacing: 6) {
                Button { store.openURL(pr.url) } label: {
                    Chip(text: pr.ref, symbol: "arrow.triangle.branch", tint: Theme.accent).modifier(LiftOnHover())
                }
                .buttonStyle(.plain).help("Open the pull request on GitHub")
                if !pr.author.isEmpty { Chip(text: "@\(pr.author)") }
                if pr.draft { Chip(text: "draft", tint: Color(nsColor: .systemOrange)) }
                if !pr.isOpen { Chip(text: pr.merged ? "merged" : "closed", symbol: "exclamationmark.circle", tint: Color(nsColor: .systemRed)) }
            }
            if !pr.isOpen {
                Text("This pull request is already \(pr.merged ? "merged" : "closed"). The Goblin will skip it unless you choose “Review anyway” in options.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func repoPicker(candidates: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Which repo is #\(input.ref?.number ?? 0) in?").font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(candidates.isEmpty ? input.repoCandidates : candidates, id: \.self) { c in
                    Button(c) { input.chooseRepo(c) }.buttonStyle(.goblinSmall)
                }
            }
            if candidates.isEmpty && input.repoCandidates.isEmpty {
                Text(verbatim: "Or paste the full link, or type owner/repo#\(input.ref?.number ?? 0).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: options

    private var footer: some View {
        HStack(spacing: 8) {
            let mode = input.options.mode ?? ReviewMode(rawValue: store.snapshot.settings.manualReviewMode) ?? .preview
            // Click to flip, for this review only (Settings holds the default).
            Button {
                withAnimation(Motion.quick) { input.options.mode = (mode == .preview ? .post : .preview) }
            } label: {
                Chip(text: mode == .preview ? "Preview first" : "Posts directly",
                     symbol: mode == .preview ? "eye" : "paperplane", tint: mode == .preview ? Theme.accent : Color(nsColor: .systemOrange))
                    .modifier(LiftOnHover())
            }
            .buttonStyle(.plain)
            .help(mode == .preview ? "You read it before anything is posted. Click to post this one directly."
                                   : "This review posts as soon as it finishes. Click to read it first.")
            if input.options.focus != .full { Chip(text: input.options.focus.rawValue.capitalized) }
            if input.options.force { Chip(text: "Review anyway", tint: Color(nsColor: .systemOrange)) }
            Spacer()
            Button { withAnimation(Motion.quick) { showOptions.toggle() } } label: {
                HStack(spacing: 3) {
                    Text("Options")
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showOptions ? 90 : 0))
                        .font(.system(size: 9, weight: .bold))
                }.font(.system(size: 11.5)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
    }

    private var optionsPanel: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("When it's done", selection: Binding(
                    get: { input.options.mode ?? ReviewMode(rawValue: store.snapshot.settings.manualReviewMode) ?? .preview },
                    set: { input.options.mode = $0 })) {
                    Text("Let me read it first").tag(ReviewMode.preview)
                    Text("Post it").tag(ReviewMode.post)
                }.pickerStyle(.segmented)
                Picker("Focus", selection: $input.options.focus) {
                    Text("Full review").tag(ReviewFocus.full)
                    Text("Security").tag(ReviewFocus.security)
                    Text("Summary").tag(ReviewFocus.summary)
                }.pickerStyle(.segmented)
                HStack {
                    Picker("Reviewer", selection: Binding(
                        get: { input.options.provider?.rawValue ?? "" },
                        set: { input.options.provider = ProviderId(rawValue: $0); input.options.model = "" })) {
                        Text("Default (\(store.snapshot.providerId.capitalized))").tag("")
                        ForEach(store.providers.filter(\.ready)) { p in Text(p.displayName).tag(p.name) }
                    }
                    if let p = store.providers.first(where: { $0.name == (input.options.provider?.rawValue ?? store.snapshot.providerId) }) {
                        HStack {
                            Text("Model")
                            ModelMenu(store: store, provider: p.name, selection: $input.options.model, defaultLabel: "Default")
                        }
                    }
                }
                Toggle("Review anyway, even if already reviewed or closed", isOn: $input.options.force)
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
            .font(.system(size: 12))
        }
    }
}

// MARK: - The repo a number belongs to

/// Sits in front of the field: "mobile-app #". Pick the repo first, then type a number,
/// instead of discovering the repo only after a lookup. A pasted link names its own
/// repo, so then it just shows that one.
struct RepoSwitch: View {
    @Bindable var input: ReviewInput
    let store: AppStore
    var windows: WindowManager = .shared
    @State private var hovering = false

    private var fromLink: Bool { input.ref?.slug != nil }

    var body: some View {
        Menu {
            let current = input.currentRepo
            let all = input.repoCandidates
            let watched = Set(store.snapshot.repos.map(\.slug))
            if all.isEmpty {
                Text("No repositories yet")
            }
            if !all.filter(watched.contains).isEmpty {
                Section("Watched") {
                    ForEach(all.filter(watched.contains), id: \.self) { item($0, current) }
                }
            }
            if !all.filter({ !watched.contains($0) }).isEmpty {
                Section("Recent") {
                    ForEach(all.filter { !watched.contains($0) }, id: \.self) { item($0, current) }
                }
            }
            Divider()
            Button("Add a repository…") { windows.showSettings(.repos) }
            Text("Any other repo: paste a link, or type owner/repo#123")
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: label).lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 12, weight: .semibold))
                if !fromLink {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text("#").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(input.ref == nil ? Color.secondary : Theme.accent)
                    .padding(.leading, 3)
            }
            .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.accent.opacity(hovering && !fromLink ? 0.16 : 0.09)))
            .foregroundStyle(input.currentRepo == nil ? Color.secondary : Theme.accent)
            .frame(maxWidth: 170, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(fromLink)
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        .help(fromLink ? "The link names this repo" : (input.currentRepo.map { "Reviewing PRs in \($0) — click to switch" } ?? "Choose a repo"))
        .accessibilityLabel(input.currentRepo.map { "Repository \($0)" } ?? "Choose a repository")
    }

    private var label: String {
        guard let r = input.currentRepo else { return "Pick a repo" }
        return String(r.split(separator: "/").last ?? Substring(r))
    }

    @ViewBuilder private func item(_ slug: String, _ current: String?) -> some View {
        Button { input.chooseRepo(slug) } label: {
            if slug == current { Label(slug, systemImage: "checkmark") } else { Text(verbatim: slug) }
        }
    }
}
