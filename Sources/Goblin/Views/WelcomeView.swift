//  WelcomeView.swift — first run: GitHub, a reviewer, repos, go.
//
//  Four short steps, one primary button each. The engine reports which step is the
//  first incomplete one, so a person who quit halfway resumes where they stopped.

import SwiftUI

struct WelcomeView: View {
    let store: AppStore
    var done: () -> Void
    @State private var model: WelcomeModel
    @State private var input: ReviewInput

    init(store: AppStore, initialStep: WelcomeStep? = nil, model: WelcomeModel? = nil, done: @escaping () -> Void) {
        self.store = store
        self.done = done
        _model = State(initialValue: model ?? WelcomeModel(store: store, initialStep: initialStep))
        _input = State(initialValue: ReviewInput(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                Group {
                    switch model.step {
                    case .account: AccountStep(model: model)
                    case .provider: ProviderStep(model: model)
                    case .repos: ReposStep(model: model)
                    case .done: DoneStep(model: model, input: input, store: store)
                    }
                }
                .padding(.horizontal, 36).padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .id(model.step)
                .transition(.opacity)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 620, height: 600)
        .background(.background)
        .animation(Motion.reduced ? .easeOut(duration: 0.12) : .spring(duration: 0.35, bounce: 0.12), value: model.step)
        .task { await model.load() }
        .modifier(ToastHost(store: store))
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                GoblinAvatar(size: 56)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: headline).font(.system(size: 21, weight: .semibold))
                    Text(verbatim: subhead).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            StepIndicator(current: model.step) { model.jump(to: $0) }
        }
        .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 16)
    }

    private var headline: String {
        switch model.step {
        case .account: return "Meet the Merge Goblin"
        case .provider: return "Pick the brain"
        case .repos: return "Where does it work?"
        case .done: return "You're all set"
        }
    }

    private var subhead: String {
        switch model.step {
        case .account: return "It reviews pull requests for you. First, who are you on GitHub?"
        case .provider: return "It runs on the AI subscription you already pay for."
        case .repos: return "Pick repos to watch. Any PR can still be reviewed by number."
        case .done: return "Type a PR number and the Goblin goes to work."
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.step != .account {
                Button("Back") { model.back() }.buttonStyle(.goblin)
            }
            Spacer()
            switch model.step {
            case .provider:
                if model.chosenProviderInfo?.ready != true {
                    Button("Skip for now") { Task { await model.skip() } }.buttonStyle(.goblinQuiet)
                }
                primary("Continue")
            case .repos:
                if model.chosen.isEmpty {
                    Button("Skip — I'll review by number") { Task { await model.skip() } }.buttonStyle(.goblinQuiet)
                }
                primary("Continue")
            case .done:
                Button("Finish") { done() }.buttonStyle(.goblinPrimary).keyboardShortcut(.defaultAction)
            case .account:
                primary("Continue")
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 14)
    }

    private func primary(_ title: String) -> some View {
        Button {
            Task { await model.next() }
        } label: {
            HStack(spacing: 6) {
                if model.working { ProgressView().controlSize(.small) }
                Text(title)
            }
        }
        .buttonStyle(.goblinPrimary)
        .disabled(!model.canContinue || model.working)
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Step indicator

private struct StepIndicator: View {
    let current: WelcomeStep
    var jump: (WelcomeStep) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WelcomeStep.allCases) { s in
                let past = s.rawValue < current.rawValue
                let now = s == current
                Button { jump(s) } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(now || past ? Theme.accent : Color.primary.opacity(0.1)).frame(width: 18, height: 18)
                            if past {
                                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                            } else {
                                Text(verbatim: "\(s.rawValue + 1)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(now ? Color.black.opacity(0.8) : .secondary)
                            }
                        }
                        Text(verbatim: s.title)
                            .font(.system(size: 12, weight: now ? .semibold : .regular))
                            .foregroundStyle(now ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!past)
                if s != WelcomeStep.allCases.last {
                    Capsule().fill(past ? Theme.accent.opacity(0.7) : Color.primary.opacity(0.1)).frame(height: 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Shared bits

private struct CopyLine: View {
    let command: String
    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Copy") { WelcomeClipboard.copy(command) }.buttonStyle(.goblinSmall)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

private struct Failure: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
            Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 1 · GitHub

private struct AccountStep: View {
    @Bindable var model: WelcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.loaded && !model.loadFailed {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else if model.loadFailed {
                Failure(text: "Could not read this Mac's setup. Quit and reopen the Goblin, or run `goblin doctor` in Terminal.")
                Button("Try again") { Task { await model.reloadWizard() } }.buttonStyle(.goblin)
            } else if !model.wizard.missingDeps.isEmpty {
                deps
            } else if model.wizard.accounts.isEmpty || model.login.phase != .idle {
                signIn
            } else {
                accounts
            }
        }
    }

    private var deps: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Install the missing tools")
            ForEach(model.wizard.missingDeps, id: \.name) { dep in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color(nsColor: .systemRed))
                            Text(verbatim: dep.name).font(.system(size: 13, weight: .semibold))
                            Text("isn't installed").foregroundStyle(.secondary)
                        }
                        CopyLine(command: dep.brew)
                    }
                }
            }
            Text("Run that in Terminal, then check again.").font(.callout).foregroundStyle(.secondary)
            Button("Check again") { Task { await model.recheckDeps() } }.buttonStyle(.goblin)
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "GitHub account", trailing: "Reviews are posted as this person")
            ForEach(model.wizard.accounts) { a in
                Button { model.choose(login: a.login) } label: {
                    Card(padding: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: model.selectedLogin == a.login ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(model.selectedLogin == a.login ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: a.login).font(.system(size: 14, weight: .semibold))
                                Text(a.active ? "Signed in with the GitHub CLI" : "Saved on this Mac")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !a.hasToken {
                                Chip(text: "Needs sign-in", symbol: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemOrange))
                            }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(model.selectedLogin == a.login ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            if model.wizard.accounts.first(where: { $0.login == model.selectedLogin })?.hasToken == false {
                Failure(text: "This account has no saved token, so the Goblin couldn't post as it. Run `gh auth login` or add another account.")
            }
            Button("Add another account…") { Task { await model.signIn() } }.buttonStyle(.goblinQuiet)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.login.phase {
            case .waiting:
                Card(padding: 20) {
                    VStack(spacing: 12) {
                        Text("Enter this code on GitHub").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(verbatim: model.login.code)
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .tracking(3).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("Copy code") { WelcomeClipboard.copy(model.login.code) }.buttonStyle(.goblin)
                            Button("Cancel") { model.cancelSignIn() }.buttonStyle(.goblinQuiet)
                        }
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to approve in the browser…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            case .failed:
                Failure(text: model.login.error.isEmpty ? "The sign-in didn't finish." : model.login.error)
                Text("You can also sign in yourself in Terminal:").font(.callout).foregroundStyle(.secondary)
                CopyLine(command: "gh auth login")
                HStack {
                    Button("Try again") { Task { await model.signIn() } }.buttonStyle(.goblin)
                    Button("Check again") { Task { await model.recheckDeps() ; model.cancelSignIn() } }.buttonStyle(.goblinQuiet)
                }
            default:
                Card(padding: 20) {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 30)).foregroundStyle(Theme.accent)
                        Text("Sign in with GitHub").font(.system(size: 15, weight: .semibold))
                        Text("The Goblin uses the GitHub CLI, so your password never touches this app.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button {
                            Task { await model.signIn() }
                        } label: {
                            HStack(spacing: 6) {
                                if model.startingLogin { ProgressView().controlSize(.small) }
                                Text("Sign in with GitHub")
                            }
                        }
                        .buttonStyle(.goblinPrimary).disabled(model.startingLogin)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - 2 · Reviewer

private struct ProviderStep: View {
    @Bindable var model: WelcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.providersState {
            case .idle, .loading:
                if model.providers.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for AI tools on this Mac…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else { cards }
            case .failed(let message):
                Failure(text: message)
                Button("Try again") { Task { await model.loadProviders() } }.buttonStyle(.goblin)
            case .loaded:
                cards
            }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Reviewer")
            ForEach(model.providers) { p in
                let selected = model.chosenProvider == p.name
                Button { model.chosenProvider = p.name } label: {
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 16)).foregroundStyle(selected ? Theme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: p.displayName).font(.system(size: 14, weight: .semibold))
                                    Text(verbatim: p.ready ? (p.authMode.isEmpty ? "Uses your subscription" : p.authMode) : (p.note.isEmpty ? p.statusText : p.note))
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Chip(text: p.statusText,
                                     symbol: p.ready ? "checkmark" : (p.available ? "person.crop.circle.badge.exclamationmark" : "arrow.down.circle"),
                                     tint: p.ready ? Theme.accent : Color(nsColor: .systemOrange))
                            }
                            if selected && !p.ready && !p.fixCommand.isEmpty {
                                Text(p.available ? "Sign in once in Terminal, then re-check:" : "Install it in Terminal, then re-check:")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                CopyLine(command: p.fixCommand)
                            }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            Button {
                Task { await model.loadProviders() }
            } label: {
                HStack(spacing: 6) {
                    if model.providersState == .loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    Text("Re-check")
                }
            }
            .buttonStyle(.goblinSmall)
        }
    }
}

// MARK: - 3 · Repositories

private struct ReposStep: View {
    @Bindable var model: WelcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your repositories", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                if model.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))

            if !model.chosen.isEmpty {
                FlowChips(items: model.chosen) { slug in Task { await model.toggle(slug) } }
            }

            if let error = model.searchError {
                Failure(text: error)
                Button("Try again") { model.retrySearch() }.buttonStyle(.goblin)
            } else if model.hits.isEmpty && !model.searching {
                Text(model.query.isEmpty ? "No repositories found for this account." : "Nothing matches “\(model.query)”.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.hits.prefix(8).enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider().opacity(0.4) }
                        row(r)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
        }
    }

    private func row(_ r: RepoResult) -> some View {
        let on = model.isChosen(r.slug)
        return Button { Task { await model.toggle(r.slug) } } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: r.slug).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if r.isPrivate { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    if !r.description.isEmpty {
                        Text(verbatim: r.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 17)).foregroundStyle(on ? Theme.accent : .secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FlowChips: View {
    let items: [String]
    var remove: (String) -> Void
    var body: some View {
        // Few enough that a wrapping HStack is overkill; two lines of chips at most.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { s in
                    Button { remove(s) } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: s).font(.system(size: 12, weight: .medium))
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(Theme.accent)
                        .background(Theme.accentSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Stop watching \(s)")
                }
            }
        }
    }
}

// MARK: - 4 · Done

private struct DoneStep: View {
    let model: WelcomeModel
    let input: ReviewInput
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(text: "What the Goblin will do")
                    bullet("magnifyingglass", model.chosen.isEmpty
                           ? "Wait for you. No repositories are watched, so reviews start when you ask."
                           : "Watch \(model.chosen.count == 1 ? model.chosen[0] : "\(model.chosen.count) repositories") for PRs that need you.")
                    bullet("text.badge.checkmark", "Review each one and show you the result first.")
                    bullet("hand.raised", "Post nothing to GitHub until you say so.")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Three ways to ask")
                HStack(alignment: .top, spacing: 10) {
                    way("menubar.rectangle", "Menu bar", "Click the Goblin and type a PR number.")
                    way("command", "⌥⌘G", "From anywhere on your Mac.")
                    way("link", "Links", "Open goblin://review/owner/repo/123")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Try it now")
                ReviewField(input: input, store: store, autofocus: false)
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.accent)
            Text(verbatim: text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func way(_ symbol: String, _ title: String, _ text: String) -> some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.accent)
                Text(verbatim: title).font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
