//  AppDelegate.swift — lifecycle, the goblin:// scheme, the global hotkey.
//
//  Single instance: the login item starts one copy at login, and double-clicking the
//  app afterwards starts a second. Two copies means two status items and two file
//  watchers, so the newcomer hands over to the incumbent and quits.

import AppKit
import UserNotifications
import os

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let log = Logger(subsystem: "goblin.bar", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handOverToIncumbent() else { return }
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()

        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }

        let store = AppStore.shared
        store.start()
        Notifier.shared.drain()
        BarIcon.warmAnimation()

        // The icon animates while reviewing, driven by the same snapshot the label reads.
        Task { @MainActor in
            var last: BarGlyph? = nil
            while true {
                let g = store.snapshot.glyph
                if g != last { BarAnimator.shared.update(for: g); last = g }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }

        Hotkey.shared.register { Task { @MainActor in WindowManager.shared.toggleQuick() } }

        if !store.cliConfigured { log.error("no engine found: the app has nothing to drive") }
        launchOptions(store)
    }

    /// Developer and demo switches, ignored in a normal launch:
    ///   --open-job <id> | --open-settings | --open-welcome | --open-quick
    private func launchOptions(_ store: AppStore) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in await Snapshotter.run(into: dir) }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let i = args.firstIndex(of: "--open-job"), i + 1 < args.count { WindowManager.shared.showJob(args[i + 1]) }
            if args.contains("--open-settings") { WindowManager.shared.showSettings() }
            if args.contains("--open-welcome") { WindowManager.shared.showWelcome() }
            if args.contains("--open-quick") { WindowManager.shared.toggleQuick() }
            if !store.snapshot.setupComplete && store.snapshot.loaded && !args.contains("--no-welcome") {
                WindowManager.shared.showWelcome()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { Hotkey.shared.unregister() }

    // MARK: goblin://review/2456  ·  goblin://review/owner/repo/2456  ·  goblin://job/<id>

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "goblin" { Task { @MainActor in await Self.handle(url) } }
    }

    @MainActor
    static func handle(_ url: URL) async {
        let store = AppStore.shared
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        guard let verb = parts.first else { return }
        switch verb {
        case "review":
            // A link is somebody else's input: it can start a review, but only a
            // preview one — never a post — and the person still sees it before anything
            // leaves the machine.
            let rest = parts.dropFirst()
            let text: String
            if rest.count >= 3 { text = "\(rest[rest.startIndex])/\(rest[rest.startIndex + 1])#\(rest[rest.startIndex + 2])" }
            else { text = rest.joined() }
            guard let ref = PRRef.parse(text) else { store.say("That link doesn't point at a pull request.", .error); return }
            var o = ReviewOptions(); o.mode = .preview
            if ref.slug == nil { o.repo = store.snapshot.settings.lastRepo.isEmpty ? nil : store.snapshot.settings.lastRepo }
            if let job = await store.startReview(ref, options: o) { WindowManager.shared.showJob(job.id) }
        case "job":
            if parts.count > 1 { WindowManager.shared.showJob(parts[1]) }
        case "settings":
            WindowManager.shared.showSettings()
        default: break
        }
    }

    // MARK: notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            // The engine's banner text is "#2456 is ready to read…": open the newest
            // review waiting on you.
            if let job = AppStore.shared.readyJobs.first { WindowManager.shared.showJob(job.id) }
        }
    }

    // MARK: single instance

    private func handOverToIncumbent() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        // A snapshot run draws offscreen and exits; it must not defer to a running app.
        if CommandLine.arguments.contains("--snapshot") { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
        guard let other = others.first else { return false }
        other.activate(options: [])
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - The main menu

/// An .accessory app never shows its main menu, but NSApp still routes ⌘-key
/// equivalents through it. With no Edit menu, ⌘V does nothing in a text field — no
/// beep, no error, the field just stays empty. This is that menu.
enum MainMenu {
    static func install() {
        let root = NSMenu()
        let appItem = NSMenuItem(); let app = NSMenu(title: "Merge Goblin")
        app.addItem(withTitle: "About Merge Goblin", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Merge Goblin", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Merge Goblin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app; root.addItem(appItem)

        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        func add(_ t: String, _ sel: String, _ k: String, _ mods: NSEvent.ModifierFlags = [.command]) {
            let i = NSMenuItem(title: t, action: NSSelectorFromString(sel), keyEquivalent: k)
            i.keyEquivalentModifierMask = mods; edit.addItem(i)
        }
        add("Undo", "undo:", "z"); add("Redo", "redo:", "Z", [.command, .shift]); edit.addItem(.separator())
        add("Cut", "cut:", "x"); add("Copy", "copy:", "c"); add("Paste", "paste:", "v"); add("Select All", "selectAll:", "a")
        editItem.submenu = edit; root.addItem(editItem)

        let winItem = NSMenuItem(); let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win; root.addItem(winItem)
        NSApp.mainMenu = root
        NSApp.windowsMenu = win
    }
}
