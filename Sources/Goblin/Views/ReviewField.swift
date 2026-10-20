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

    /// Everything that could be the repo for a bare number.
    var repoCandidates: [String] {
        var seen: [String] = []
        for s in [store.snapshot.settings.lastRepo] + store.snapshot.repos.map(\.slug) + extraCandidates {
            if !s.isEmpty, !seen.contains(s) { seen.append(s) }
        }
        return seen
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
            let repo = self.repoChoice
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
            repoChoice = nil
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
                Image(systemName: "number")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(input.ref == nil ? Color.secondary : Theme.accent)
                TextField("Review a PR — 2456 or a link", text: $input.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { go() }
                if input.resolving || input.starting {
                    ProgressView().controlSize(.small)
                } else if !input.text.isEmpty {
                    Button { input.text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
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
                if input.ref?.slug == nil {
                    Menu {
                        ForEach(input.repoCandidates, id: \.self) { c in
                            Button(c) { input.repoChoice = c }
                        }
                    } label: { Chip(text: pr.ref, symbol: "arrow.triangle.branch", tint: Theme.accent) }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                } else {
                    Chip(text: pr.ref, symbol: "arrow.triangle.branch", tint: Theme.accent)
                }
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
                    Button(c) { input.repoChoice = c }.buttonStyle(.goblinSmall)
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
            Chip(text: mode == .preview ? "Preview first" : "Posts directly",
                 symbol: mode == .preview ? "eye" : "paperplane", tint: mode == .preview ? Theme.accent : Color(nsColor: .systemOrange))
            if input.options.focus != .full { Chip(text: input.options.focus.rawValue.capitalized) }
            if input.options.force { Chip(text: "Review anyway", tint: Color(nsColor: .systemOrange)) }
            Spacer()
            Button { withAnimation(.snappy(duration: 0.2)) { showOptions.toggle() } } label: {
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
