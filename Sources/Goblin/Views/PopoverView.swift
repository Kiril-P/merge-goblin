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

    @MainActor
    init(store: AppStore, startOn: Tab = .queue) {
        self.store = store
        _tab = State(initialValue: startOn)
    }

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
                    if !store.liveJobs.isEmpty { liveSection.transition(Motion.row) }
                    listSection
                }
                .padding(14)
                .animation(Motion.spring, value: store.liveJobs.map(\.id))
                .animation(Motion.spring, value: store.liveJobs.map(\.phase))
            }
            .scrollIndicators(.never)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 400, height: 580)
        .background {
            // ⌘1 / ⌘2 switch tabs, ⌘, opens Settings
            Group {
                Button("") { withAnimation(Motion.spring) { tab = .queue } }.keyboardShortcut("1", modifiers: .command)
                Button("") { withAnimation(Motion.spring) { tab = .recent } }.keyboardShortcut("2", modifiers: .command)
                Button("") { windows.showSettings() }.keyboardShortcut(",", modifiers: .command)
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .background(.background)
        .toasts(store)
        .onAppear { store.refreshFromCLI() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Button { windows.showSettings() } label: {
                GoblinAvatar(size: 34)
                    .opacity(store.snapshot.enabled || !store.snapshot.loaded ? 1 : 0.5)
                    .saturation(store.snapshot.enabled || !store.snapshot.loaded ? 1 : 0)
                    .modifier(Bob(active: store.snapshot.jobsActive > 0 || store.snapshot.state == "reviewing"))
                    .modifier(LiftOnHover())
            }
            .buttonStyle(.plain).help("Settings")
            VStack(alignment: .leading, spacing: 1) {
                Text("Merge Goblin").font(.system(size: 14, weight: .bold))
                IdentityLine(store: store)
            }
            Spacer()
            StatePill(store: store)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background {
            // a faint wash of the state's colour behind the header: green on duty, blue at
            // work, grey when off. It changes with the state, smoothly.
            LinearGradient(colors: [headerTint.opacity(0.13), headerTint.opacity(0.0)], startPoint: .top, endPoint: .bottom)
                .animation(Motion.spring, value: headerTint)
        }
    }

    private var headerTint: Color {
        let s = store.snapshot
        if !s.enabled || !s.setupComplete { return .gray }
        if s.jobsActive > 0 || s.state == "reviewing" { return Color(nsColor: .systemBlue) }
        if s.snoozeUntil != nil || s.state == "paused" { return Color(nsColor: .systemYellow) }
        return Theme.accent
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
                    .contextMenu { JobContextMenu(job: job, store: store) }
                    .transition(Motion.row)
            }
        }
    }

    // MARK: waiting / recent

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlideTabs(items: [.init(value: Tab.queue, title: "Waiting for you", count: store.queue.count),
                              .init(value: Tab.recent, title: "Recent")],
                      selection: $tab)

            switch tab {
            case .queue:
                if store.queue.isEmpty {
                    EmptyState(symbol: "tray", mascot: .empty, title: "Nothing is waiting on you",
                               subtitle: store.snapshot.repos.isEmpty
                                 ? "Add a repository and the Goblin will watch it."
                                 : "PRs that ask for your review show up here.")
                    HStack {
                        Spacer()
                        Button(store.snapshot.repos.isEmpty ? "Add a repository" : "Watched repositories…") { windows.showSettings(.repos) }
                            .buttonStyle(store.snapshot.repos.isEmpty ? .goblinPrimarySmall : .goblinQuiet)
                        Spacer()
                    }
                } else {
                    ForEach(Array(store.queue.prefix(8).enumerated()), id: \.element.id) { i, pr in
                        QueueRow(pr: pr, store: store) { pr in queueReview(pr) }
                        .contextMenu { QueueContextMenu(pr: pr, store: store) { queueReview($0) } }
                        .arrive(Double(i) * 0.035)
                    }
                }
            case .recent:
                let items = store.recent
                if items.isEmpty {
                    EmptyState(symbol: "clock", mascot: .idleWave, title: "No reviews yet", subtitle: "Reviews you ask for, and the ones the Goblin does on its own, land here.")
                } else {
                    StatsCard(store: store).arrive()
                    ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { i, item in
                        RecentRow(item: item, store: store) { windows.showJob($0.id) }
                            .contextMenu {
                                if let j = item.job { JobContextMenu(job: j, store: store) }
                                else if let e = item.entry { EntryContextMenu(entry: e, store: store) }
                            }
                            .arrive(Double(i) * 0.035)
                    }
                }
            }
        }
        .id(tab)   // each tab arrives fresh, so its rows animate in
    }

    private func queueReview(_ pr: QueuedPR) {
        Task {
            input.repoChoice = nil
            input.text = "\(pr.repo)#\(pr.number)"
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
                Button("Watched repositories…") { windows.showSettings(.repos) }
                Button("Health check…") { windows.showSettings(.health) }
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
            if store.snapshot.spendToday > 0 || store.snapshot.reviewsToday > 0 {
                Button { withAnimation(Motion.spring) { tab = .recent } } label: {
                    Text(verbatim: store.snapshot.spendToday > 0
                         ? String(format: "$%.2f today", store.snapshot.spendToday)
                         : "\(store.snapshot.reviewsToday) today")
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).hoverRow()
                .help("\(store.snapshot.reviewsToday) review\(store.snapshot.reviewsToday == 1 ? "" : "s") posted today"
                      + (store.snapshot.spendToday > 0 ? String(format: ", $%.2f reported", store.snapshot.spendToday) : "")
                      + " — click for recent reviews")
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

/// The goblin in a pose, for empty states and moods. Transparent PNGs from design/mascot.
struct Mascot: View {
    enum Pose: String { case idleWave = "idle-wave", sleeping, reviewing, alert, empty }
    let pose: Pose
    var size: CGFloat
    init(_ pose: Pose, size: CGFloat = 96) { self.pose = pose; self.size = size }
    var body: some View {
        if let url = Bundle.main.url(forResource: "mascot-\(pose.rawValue)", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

/// The on/off state as one tappable pill: green and "on duty" when working, and a
/// menu for the other states. It replaces a toggle plus a status line.
struct StatePill: View {
    let store: AppStore

    var body: some View {
        let s = store.snapshot
        Menu {
            Text(s.statusLine.isEmpty ? label.capitalized : s.statusLine)
            Divider()
            if s.enabled {
                Button("Turn off") { store.setPower(false) }
                Button("Snooze for an hour") { store.snooze(.hour) }
                Button("Snooze until tomorrow") { store.snooze(.tomorrow) }
            } else {
                Button("Turn on") { store.setPower(true) }
            }
            if s.snoozeUntil != nil { Button("Stop snoozing") { store.snooze(.clear) } }
            Divider()
            Button("What he does on his own…") { WindowManager.shared.showSettings(.behaviour) }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if busy {
                        Circle().stroke(color.opacity(0.6), lineWidth: 1.5).frame(width: 8, height: 8)
                            .modifier(Ripple())
                    }
                    Circle().fill(color.gradient).frame(width: 8, height: 8)
                }
                Text(label).font(.system(size: 12, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .animation(Motion.spring, value: label)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(s.statusLine)
    }

    private var busy: Bool { store.snapshot.jobsActive > 0 || store.snapshot.state == "reviewing" }

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
    var mascot: Mascot.Pose? = nil
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 6) {
            if let mascot {
                Mascot(mascot, size: 96)
            } else {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.tertiary)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 12)
    }
}

/// A gentle up-and-down while the goblin is working. Off under Reduce Motion.
struct Bob: ViewModifier {
    let active: Bool
    @State private var up = false
    func body(content: Content) -> some View {
        content
            .offset(y: active && up ? -2 : 0)
            .rotationEffect(.degrees(active && up ? -3 : 0), anchor: .bottom)
            .onChange(of: active, initial: true) { _, on in
                guard on, !Motion.reduced else { up = false; return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

/// A ring that spreads out from the status dot while a review runs.
struct Ripple: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.9)
            .onAppear {
                guard !Motion.reduced else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// A small rise under the pointer, for things that are buttons but don't look like one.
struct LiftOnHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !Motion.reduced ? 1.06 : 1)
            .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 5, y: 2)
            .onHover { h in withAnimation(Motion.quick) { hovering = h } }
    }
}
