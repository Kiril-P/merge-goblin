//  Interactions.swift — everything you can see, you can act on.
//
//  The rule this file serves: if the popover SHOWS a fact (the account, the provider,
//  the model, a review, a PR), clicking it should lead to changing it or opening it.
//  Text that looks like a setting but is dead ink teaches people the app is a display.

import SwiftUI
import AppKit

// MARK: - A word that is also a menu

/// Inline text that reads as part of a sentence but highlights under the pointer and
/// opens a menu: "@you · cursor · composer-2.5", each word a switch.
struct InlineMenu<Items: View>: View {
    let text: String
    var help: String = ""
    @ViewBuilder var items: () -> Items
    @State private var hovering = false

    var body: some View {
        Menu { items() } label: {
            Text(verbatim: text).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0)))
            .foregroundStyle(hovering ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        .help(help)
    }
}

// MARK: - The header line: who, with what, which model

struct IdentityLine: View {
    let store: AppStore
    var windows: WindowManager = .shared

    private var s: Snapshot { store.snapshot }
    private var provider: ProviderId { ProviderId(rawValue: s.providerId) ?? .claude }
    private var models: [ModelOption] { store.modelCatalog[s.providerId] ?? [] }

    var body: some View {
        if s.login.isEmpty {
            Button("not set up yet — start setup") { windows.showWelcome() }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
        } else {
            HStack(spacing: 0) {
                account
                dot
                providerMenu
                dot
                modelMenu
            }
            .font(.system(size: 11.5))
            .padding(.leading, -4)
        }
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary).padding(.horizontal, 1) }

    private var account: some View {
        InlineMenu(text: "@\(s.login)", help: "The GitHub account reviews are posted as") {
            let others = store.accounts.map(\.login).filter { $0 != s.login }
            if others.isEmpty {
                Text("No other GitHub accounts signed in")
            } else {
                Section("Review as") {
                    Button { } label: { Label("@\(s.login)", systemImage: "checkmark") }
                    ForEach(others, id: \.self) { login in
                        Button("@\(login)") {
                            Task { await store.perform(.setIdentity(login: login), success: "Now reviewing as @\(login).") }
                        }
                    }
                }
            }
            Divider()
            Button("Open @\(s.login) on GitHub") { store.openURL("https://github.com/\(s.login)") }
            Button("Account settings…") { windows.showSettings(.general) }
        }
        .task { if store.accounts.isEmpty { await store.refreshAccounts() } }
    }

    private var providerMenu: some View {
        InlineMenu(text: s.providerId, help: "The AI that does the reviewing — click to switch") {
            Section("Reviewer") {
                ForEach(ProviderId.allCases, id: \.self) { p in
                    let info = store.providers.first { $0.name == p.rawValue }
                    let ready = info?.ready ?? false
                    Button {
                        guard p != provider else { return }
                        Task { await store.perform(.setProvider(p), success: "\(info?.displayName ?? p.rawValue) will do the reviewing.") }
                    } label: {
                        if p == provider {
                            Label(info?.displayName ?? p.rawValue, systemImage: "checkmark")
                        } else {
                            Text(verbatim: (info?.displayName ?? p.rawValue) + (ready || info == nil ? "" : " — not signed in"))
                        }
                    }
                    .disabled(info != nil && !ready && p != provider)
                }
            }
            Divider()
            Button("Reviewer settings…") { windows.showSettings(.reviewer) }
        }
        .task { if store.providers.isEmpty { await store.refreshProviders() } }
    }

    private var levels: [String] { ProviderInfo.effortLevels(s.providerId) }

    private var modelMenu: some View {
        let current = s.providerModel
        let name = current.isEmpty ? "default model" : ModelCatalog.label(for: current, in: models, defaultLabel: "default model")
        return InlineMenu(text: ModelEffort.label(model: name, effort: levels.isEmpty ? "" : s.providerEffort),
                          help: "The model — click to switch") {
            item(ModelOption(id: "", label: "Provider default"))
            Divider()
            if models.count > ModelCatalog.groupingThreshold {
                ForEach(ModelCatalog.grouped(models)) { group in
                    Menu(group.vendor) {
                        ForEach(group.families) { family in
                            if family.options.count == 1, let only = family.options.first {
                                item(only)
                            } else {
                                Menu(family.title) { ForEach(family.options) { item($0) } }
                            }
                        }
                    }
                }
            } else if models.isEmpty {
                Text(store.isLoadingModels(s.providerId) ? "Loading models…" : "No model list from \(s.providerId)")
            } else {
                ForEach(models) { item($0) }
            }
            Divider()
            Button("Reviewer settings…") { windows.showSettings(.reviewer) }
        }
        .task(id: s.providerId) { await store.loadModels(s.providerId) }
    }

    /// A Cursor model is already one variant; a Claude or Codex model opens onto its efforts.
    @ViewBuilder private func item(_ o: ModelOption) -> some View {
        if levels.isEmpty {
            Button { set(o.id, effort: s.providerEffort) } label: { check(o.id == s.providerModel, o.label) }
        } else {
            ModelEffort.Variants(option: o, levels: levels, model: s.providerModel, effort: s.providerEffort) { m, e in
                set(m, effort: e)
            }
        }
    }

    private func set(_ model: String, effort: String) {
        let modelChanged = model != s.providerModel, effortChanged = !levels.isEmpty && effort != s.providerEffort
        guard modelChanged || effortChanged else { return }
        let name = model.isEmpty ? "\(s.providerId)'s default model" : ModelCatalog.label(for: model, in: models)
        Task {
            if modelChanged, !(await store.perform(.setProviderModel(provider: provider, model: model))) { return }
            if effortChanged, !(await store.perform(.setProviderEffort(provider: provider, effort: effort))) { return }
            store.say("Reviews now use \(ModelEffort.label(model: name, effort: levels.isEmpty ? "" : effort)).", .info)
        }
    }

    @ViewBuilder private func check(_ on: Bool, _ label: String) -> some View {
        if on { Label(label, systemImage: "checkmark") } else { Text(verbatim: label) }
    }
}

// MARK: - Right-click menus for the things in lists

enum Clipboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct JobContextMenu: View {
    let job: Job
    let store: AppStore
    var windows: WindowManager = .shared
    var body: some View {
        Button(job.phase == .ready ? "Read review" : "Open") { windows.showJob(job.id) }
        if job.phase == .ready {
            if store.pendingSends[job.id] != nil {
                Button("Undo") { store.undoPending(job.id) }
            } else {
                Button("Post to GitHub") { store.schedulePost(job) }
                Button("Discard") { store.scheduleDiscard(job) }
            }
        }
        if job.phase.isActive { Button("Cancel review") { store.cancel(job) } }
        Divider()
        if !job.reviewURL.isEmpty { Button("Open the review on GitHub") { store.openURL(job.reviewURL) } }
        Button("Open the pull request") { store.openURL(job.url) }
        Button("Copy link") { Clipboard.copy(job.url); store.say("Link copied.", .success) }
        if !job.phase.isActive && job.phase != .ready {
            Divider()
            Button("Review again") { ReviewAgain.start(job.repo, job.number, store: store) }
        }
    }
}

struct EntryContextMenu: View {
    let entry: HistoryEntry
    let store: AppStore
    var body: some View {
        Button("Open the pull request") { store.openURL(entry.url) }
        Button("Copy link") { Clipboard.copy(entry.url); store.say("Link copied.", .success) }
        Divider()
        Button("Review again") { ReviewAgain.start(entry.repo, entry.number, store: store) }
    }
}

struct QueueContextMenu: View {
    let pr: QueuedPR
    let store: AppStore
    var review: (QueuedPR) -> Void
    var body: some View {
        Button("Review it") { review(pr) }
        Button("Open the pull request") { store.openURL(pr.url) }
        Button("Copy link") { Clipboard.copy(pr.url); store.say("Link copied.", .success) }
    }
}

enum ReviewAgain {
    @MainActor
    static func start(_ repo: String, _ number: Int, store: AppStore) {
        guard let ref = PRRef.parse("\(repo)#\(number)") else { return }
        var o = ReviewOptions(); o.force = true; o.mode = .preview
        Task { if let j = await store.startReview(ref, options: o) { WindowManager.shared.showJob(j.id) } }
    }
}
