//  WindowManager.swift — the app's windows, opened from anywhere.

import AppKit
import SwiftUI

@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]
    private var quick: QuickPanel?

    private func show(id: String, title: String, size: NSSize, minSize: NSSize? = nil,
                      resizable: Bool = true, content: () -> AnyView) {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        if let minSize { w.contentMinSize = minSize }
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("goblin.\(id.split(separator: ":").first ?? "")")
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showJob(_ id: String) {
        guard Pattern.jobId.accepts(id) else { return }
        let store = AppStore.shared
        let title = store.job(id).map { "\($0.ref) — Review" } ?? "Review"
        show(id: "job:\(id)", title: title, size: NSSize(width: 760, height: 680), minSize: NSSize(width: 620, height: 520)) {
            AnyView(ReviewWindowView(store: store, jobID: id))
        }
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { SettingsNavigation.shared.pane = pane }
        show(id: "settings", title: "Merge Goblin Settings", size: NSSize(width: 760, height: 560), minSize: NSSize(width: 680, height: 460)) {
            AnyView(SettingsView(store: AppStore.shared))
        }
    }

    func showWelcome() {
        show(id: "welcome", title: "Welcome to the Merge Goblin", size: NSSize(width: 620, height: 600), resizable: false) {
            AnyView(WelcomeView(store: AppStore.shared) { [weak self] in self?.close("welcome") })
        }
    }

    func close(_ id: String) { windows[id]?.close() }

    /// The ⌥⌘G panel: a single field floating over whatever you are doing.
    func toggleQuick() {
        if let q = quick, q.isVisible { q.close(); return }
        let q = quick ?? QuickPanel(store: AppStore.shared) { [weak self] job in
            self?.quick?.close()
            // Opening the window for something that takes minutes would steal focus
            // from what you were doing; the popover and a notification are enough.
            _ = job
        }
        quick = q
        q.present()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let key = windows.first(where: { $0.value === w })?.key else { return }
        windows[key] = nil
    }
}

// MARK: - The quick-review panel

final class QuickPanel: NSPanel {
    private let input: ReviewInput
    private let onStarted: (Job) -> Void

    init(store: AppStore, onStarted: @escaping (Job) -> Void) {
        input = ReviewInput(store: store)
        self.onStarted = onStarted
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        let root = QuickPanelView(input: input, store: store) { [weak self] job in self?.onStarted(job) }
        let host = NSHostingView(rootView: root)
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    func present() {
        input.text = ""
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - f.height * 0.2))
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

struct QuickPanelView: View {
    @Bindable var input: ReviewInput
    let store: AppStore
    var onStarted: (Job) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReviewField(input: input, store: store, onStarted: onStarted)
                .padding(16)
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .padding(1)
    }
}
