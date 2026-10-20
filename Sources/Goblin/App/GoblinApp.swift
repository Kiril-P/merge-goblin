//  GoblinApp.swift — the app's entry point.
//
//  A MenuBarExtra and nothing else: every other window (a review, settings, the
//  welcome flow, the quick-review panel) is owned by WindowManager, so the hotkey, a
//  goblin:// link and a notification click can all open one without needing a SwiftUI
//  scene to be on screen to ask.

import SwiftUI

@main
struct GoblinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore.shared
    @State private var bar = BarAnimator.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store, bar: bar)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The icon, plus the number of PRs waiting. The image is a template, so macOS inks it
/// for light, dark, a highlighted bar and Increase Contrast without a colour here.
struct MenuBarLabel: View {
    let store: AppStore
    let bar: BarAnimator

    var body: some View {
        let s = store.snapshot
        HStack(spacing: 3) {
            Image(nsImage: BarIcon.image(for: s.glyph, frame: bar.frame))
            if s.barCount > 0 {
                Text("\(s.barCount)").font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        }
        .accessibilityLabel("Merge Goblin, \(s.statusLine)")
    }
}

/// Ten frames a second while reviewing, and nothing at all otherwise. Reduce Motion
/// gets one static frame: a timer that never starts is the cheapest accessibility win.
@MainActor
@Observable
final class BarAnimator {
    static let shared = BarAnimator()
    private(set) var frame = 0
    private var timer: Timer?

    func update(for glyph: BarGlyph) {
        let animate = glyph == .reviewing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.frame = ((self?.frame ?? 0) + 1) % BarIcon.animationFrames }
            }
        } else if !animate {
            timer?.invalidate(); timer = nil; frame = 0
        }
    }
}
