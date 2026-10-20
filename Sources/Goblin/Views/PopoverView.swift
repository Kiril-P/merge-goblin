//  PopoverView.swift — what the menu bar icon opens.
//
//  Three things, in the order a person needs them: ask for a review, see what is
//  happening, see what is waiting. Settings, health and quit are one line at the
//  bottom — they are not what this is for.

import SwiftUI

struct PopoverView: View {
    @Bindable var store: AppStore
    @State private var input = ReviewInput(store: .shared)
    @State private var tab: Tab = .queue
    var windows: WindowManager = .shared

    enum Tab: String, CaseIterable { case queue = "Waiting", recent = "Recent" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.snapshot.setupComplete && store.snapshot.loaded {
                        setupBanner
                    } else {
                        ReviewField(input: input, store: store, onStarted: { _ in })
                    }
                    if !store.liveJobs.isEmpty { liveSection }
                    listSection
                }
                .padding(14)
            }
            .scrollIndicators(.never)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 400, height: 580)
        .background(.background)
        .toasts(store)
        .onAppear { store.refreshFromCLI() }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 8) {
            GoblinAvatar(size: 76)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            VStack(spacing: 2) {
                Text("Merge Goblin").font(.system(size: 16, weight: .bold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            StatePill(store: store)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
    }

    private var subtitle: String {
        let s = store.snapshot
        if s.login.isEmpty { return "not set up yet" }
        let model = s.providerModel.isEmpty ? "" : " · \(s.providerModel)"
        return "@\(s.login) · \(s.providerId)\(model)"
    }

    private var setupBanner: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Let's get you set up").font(.system(size: 14, weight: .bold))
                Text("Pick a GitHub account and an AI subscription, and the Goblin is ready. It takes a minute.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Button("Start setup") { windows.showWelcome() }.buttonStyle(.goblinPrimary)
            }
        }
    }

    // MARK: live jobs

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: store.activeJobs.isEmpty ? "Ready to read" : "In progress")
            ForEach(store.liveJobs.prefix(5)) { job in
                JobRow(job: job, store: store) { windows.showJob($0.id) }
            }
        }
    }

    // MARK: waiting / recent

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                Text(verbatim: "Waiting for you\(store.queue.isEmpty ? "" : " (\(store.queue.count))")").tag(Tab.queue)
                Text("Recent").tag(Tab.recent)
            }.pickerStyle(.segmented).labelsHidden()

            switch tab {
            case .queue:
                if store.queue.isEmpty {
                    EmptyState(symbol: "tray", title: "Nothing is waiting on you",
                               subtitle: store.snapshot.repos.isEmpty
                                 ? "Add a repository in Settings and the Goblin will watch it."
                                 : "PRs that ask for your review show up here.")
                } else {
                    ForEach(store.queue.prefix(8)) { pr in
                        QueueRow(pr: pr, store: store) { pr in
                            Task {
                                input.repoChoice = nil
                                input.text = "\(pr.repo)#\(pr.number)"
                            }
                        }
                    }
                }
            case .recent:
                let items = store.recent
                if items.isEmpty {
                    EmptyState(symbol: "clock", title: "No reviews yet", subtitle: "Reviews you ask for, and the ones the Goblin does on its own, land here.")
                } else {
                    ForEach(items.prefix(10)) { RecentRow(item: $0, store: store) { windows.showJob($0.id) } }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button { windows.showSettings() } label: { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.goblinQuiet)
            Menu {
                Button("Snooze for an hour") { store.snooze(.hour) }
                Button("Snooze until tomorrow") { store.snooze(.tomorrow) }
                if store.snapshot.snoozeUntil != nil { Button("Stop snoozing") { store.snooze(.clear) } }
                Divider()
                Button("Open log") { store.openLog() }
                Button("Copy diagnostics") { store.copyDiagnostics() }
                if store.snapshot.updateAvailable {
                    Divider()
                    Button("Update available: v\(store.snapshot.updateLatest)") { store.openURL(store.snapshot.updateURL) }
                }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if store.snapshot.spendToday > 0 {
                Text(String(format: "$%.2f today", store.snapshot.spendToday)).font(.caption).foregroundStyle(.tertiary)
            } else if store.snapshot.reviewsToday > 0 {
                Text(verbatim: "\(store.snapshot.reviewsToday) today").font(.caption).foregroundStyle(.tertiary)
            }
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.goblinQuiet)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

// MARK: - Pieces

struct GoblinAvatar: View {
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "goblin-avatar", withExtension: "png"), let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Text("👺").font(.system(size: size * 0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// The on/off state as one tappable pill: green and "on duty" when working, and a
/// menu for the other states. It replaces a toggle plus a status line.
struct StatePill: View {
    let store: AppStore

    var body: some View {
        let s = store.snapshot
        Menu {
            if s.enabled {
                Button("Turn off") { store.setPower(false) }
            } else {
                Button("Turn on") { store.setPower(true) }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(s.statusLine)
    }

    private var label: String {
        let s = store.snapshot
        if !s.setupComplete { return "set up" }
        if !s.enabled { return "off" }
        if s.snoozeUntil != nil { return "snoozed" }
        if s.jobsActive > 0 || s.state == "reviewing" { return "reviewing" }
        if s.state == "paused" { return s.pausedReason == "quota" ? "daily cap" : "paused" }
        return "on duty"
    }
    private var color: Color {
        let s = store.snapshot
        if !s.setupComplete || !s.identityOK { return Color(nsColor: .systemOrange) }
        if !s.enabled { return .secondary }
        if s.snoozeUntil != nil || s.state == "paused" { return Color(nsColor: .systemYellow) }
        if s.jobsActive > 0 || s.state == "reviewing" { return Color(nsColor: .systemBlue) }
        return Theme.accent
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 12)
    }
}
