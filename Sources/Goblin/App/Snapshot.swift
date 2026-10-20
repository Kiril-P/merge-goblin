//  Snapshot.swift — render the real views to PNGs, headlessly.
//
//      GOBLIN_HOME=$(scripts/demo-home.sh /tmp/demo >/dev/null; echo /tmp/demo) \
//        GoblinBar --snapshot /tmp/shots
//
//  Used to look at the UI without a screen-recording permission, and to keep the
//  README's screenshots honest: they are the app, drawn from demo data, not a mockup.

import AppKit
import SwiftUI

@MainActor
enum Snapshotter {
    static func run(into dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = AppStore.shared
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        store.reload()

        let readyID = store.readyJobs.first?.id ?? ""
        let runningID = store.activeJobs.first?.id ?? ""
        let failedID = store.jobs.first { $0.phase == .failed }?.id ?? ""

        for scheme in [ColorScheme.dark, .light] {
            let tag = scheme == .dark ? "dark" : "light"
            await shot(PopoverView(store: store), 400, 580, scheme, "\(dir)/popover-\(tag).png")
            await shot(typedField(store), 400, 200, scheme, "\(dir)/field-typed-\(tag).png")
            if !readyID.isEmpty { await shot(ReviewWindowView(store: store, jobID: readyID), 760, 760, scheme, "\(dir)/review-ready-\(tag).png") }
            if !runningID.isEmpty { await shot(ReviewWindowView(store: store, jobID: runningID), 760, 520, scheme, "\(dir)/review-running-\(tag).png") }
            if !failedID.isEmpty { await shot(ReviewWindowView(store: store, jobID: failedID), 760, 420, scheme, "\(dir)/review-failed-\(tag).png") }
            await shot(SettingsView(store: store), 760, 560, scheme, "\(dir)/settings-\(tag).png")
            await shot(WelcomeView(store: store, model: WelcomeSamples.model(store, .account)) {}, 620, 600, scheme, "\(dir)/welcome-\(tag).png")
        }
        for (name, step, variant) in WelcomeSamples.variants {
            await shot(WelcomeView(store: store, model: WelcomeSamples.model(store, step, variant)) {}, 620, 600, .dark, "\(dir)/welcome-\(name)-dark.png")
        }
        await shot(WelcomeView(store: store, model: WelcomeSamples.model(store, .repos)) {}, 620, 600, .light, "\(dir)/welcome-repos-light.png")
        seedSettings(store)
        for scheme in [ColorScheme.dark, .light] {
            let tag = scheme == .dark ? "dark" : "light"
            await shot(PopoverView(store: store, startOn: .recent), 400, 580, scheme, "\(dir)/popover-recent-\(tag).png")
            for pane in SettingsPane.allCases {
                SettingsNavigation.shared.pane = pane
                await shot(SettingsView(store: store), 760, 640, scheme, "\(dir)/settings-\(pane.rawValue)-\(tag).png")
            }
        }
        NSApp.terminate(nil)
    }

    /// Settings panes that ask the machine (accounts, doctor, GitHub search) get fixed
    /// answers, so the shots never depend on who ran them or touch the network.
    private static func seedSettings(_ store: AppStore) {
        store.seedForSnapshot(
            doctor: [
                DoctorCheck(id: "gh", status: .ok, check: "GitHub CLI", detail: "gh 2.86 — signed in as @linus", fix: ""),
                DoctorCheck(id: "provider", status: .ok, check: "AI reviewer", detail: "Claude Code is ready", fix: ""),
                DoctorCheck(id: "clones", status: .warn, check: "Local clone of acme/billing-api", detail: "Not cloned yet, so the first review will clone it.", fix: "goblin doctor --fix"),
                DoctorCheck(id: "agent", status: .fail, check: "Scheduler", detail: "The launch agent is installed but not running.", fix: "launchctl kickstart gui/501/app.mergegoblin.agent"),
            ],
            accounts: [("linus", true, true), ("linus-work", false, false)],
            stats: ReviewStats(days: 30, prs: 14, total: .init(n: 37, addressed: 19, discussed: 6, silent: 12), bySeverity: [
                (name: "blocker", tally: .init(n: 4, addressed: 3, discussed: 1, silent: 0)),
                (name: "risk", tally: .init(n: 15, addressed: 9, discussed: 2, silent: 4)),
                (name: "convention", tally: .init(n: 11, addressed: 5, discussed: 2, silent: 4)),
                (name: "nit", tally: .init(n: 7, addressed: 2, discussed: 1, silent: 4)),
            ]))
        store.repoSearchOverride = { _ in [
            RepoResult(slug: "acme/billing-api", description: "Invoices, plans and proration", isPrivate: true, permission: "ADMIN", watched: true),
            RepoResult(slug: "acme/web-app", description: "The customer dashboard", isPrivate: true, permission: "WRITE", watched: false),
            RepoResult(slug: "acme/mobile-app", description: "iOS and Android", isPrivate: false, permission: "WRITE", watched: false),
        ] }
    }

    private static func typedField(_ store: AppStore) -> some View {
        let input = ReviewInput(store: store)
        input.options.focus = .full
        let pr = ResolvedPR(repo: "acme/billing-api", number: 873, title: "Fix proration when a plan changes mid-cycle",
                            state: "open", merged: false, draft: false, author: "linus", url: "")
        store.resolveOverride = { _, _ in .found(pr) }
        input.text = "873"
        return ReviewField(input: input, store: store, autofocus: false)
            .padding(14)
            .background(.background)
    }

    private static func shot<V: View>(_ view: V, _ w: CGFloat, _ h: CGFloat, _ scheme: ColorScheme, _ path: String) async {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: w, height: h))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrame(NSRect(x: -4000, y: -4000, width: w, height: h), display: false)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        window.orderOut(nil)
    }
}


// MARK: - Welcome flow samples (canned: no GitHub, no real accounts)

@MainActor
enum WelcomeSamples {
    enum Variant { case normal, noAccount, missingDeps, waiting, failedLogin, providerNone, providerFailed }

    static let variants: [(String, WelcomeStep, Variant)] = [
        ("account", .account, .normal),
        ("signin", .account, .noAccount),
        ("code", .account, .waiting),
        ("login-failed", .account, .failedLogin),
        ("deps", .account, .missingDeps),
        ("provider", .provider, .normal),
        ("provider-none", .provider, .providerNone),
        ("provider-failed", .provider, .providerFailed),
        ("repos", .repos, .normal),
        ("done", .done, .normal),
    ]

    private static func provider(_ name: String, available: Bool, authed: Bool, mode: String = "") -> ProviderInfo {
        ProviderInfo(json: JSON.parse("{\"name\":\"\(name)\",\"available\":\(available),\"authed\":\(authed),\"authMode\":\"\(mode)\"}"))
    }

    static func model(_ store: AppStore, _ step: WelcomeStep, _ v: Variant = .normal) -> WelcomeModel {
        let m = WelcomeModel(store: store, initialStep: step)
        var w = WizardState()
        w.identity = "kiril"
        w.provider = "claude"
        w.repos = ["acme/billing-api"]
        w.accounts = [WizardAccount(login: "kiril", active: true, configured: true, hasToken: true),
                      WizardAccount(login: "kiril-naiss", active: false, configured: false, hasToken: false)]
        switch v {
        case .noAccount, .waiting, .failedLogin: w.accounts = []; w.identity = ""
        case .missingDeps: w.ghInstalled = false; w.jqInstalled = false
        default: break
        }
        let wizard = w
        m.fetchWizard = { wizard }
        m.startLogin = { GitHubLoginState(phase: .waiting, code: "4F2A-91BC") }
        m.pollLogin = { GitHubLoginState(phase: .waiting) }
        m.fetchProviders = {
            switch v {
            case .providerNone:
                return ([provider("claude", available: false, authed: false),
                         provider("codex", available: true, authed: false),
                         provider("cursor", available: false, authed: false)], .loaded)
            case .providerFailed: return ([], .failed("Could not check the AI CLIs."))
            default:
                return ([provider("claude", available: true, authed: true, mode: "Claude subscription"),
                         provider("codex", available: true, authed: false),
                         provider("cursor", available: false, authed: false)], .loaded)
            }
        }
        m.searchRepos = { q in
            let all = [
                RepoResult(slug: "acme/billing-api", description: "Invoices, plans and proration", isPrivate: true, permission: "ADMIN", watched: true),
                RepoResult(slug: "acme/web", description: "The customer dashboard", isPrivate: true, permission: "WRITE", watched: false),
                RepoResult(slug: "acme/infra", description: "Terraform and deploy tooling", isPrivate: true, permission: "WRITE", watched: false),
                RepoResult(slug: "kiril/dotfiles", description: "", isPrivate: false, permission: "ADMIN", watched: false),
            ]
            return q.isEmpty ? all : all.filter { $0.slug.contains(q.lowercased()) }
        }
        m.pollInterval = 3_600_000_000_000
        switch v {
        case .waiting: Task { await m.load(); await m.signIn() }
        case .failedLogin:
            m.startLogin = { GitHubLoginState(phase: .failed, error: "GitHub didn't answer in time.") }
            Task { await m.load(); await m.signIn() }
        default: break
        }
        return m
    }
}
