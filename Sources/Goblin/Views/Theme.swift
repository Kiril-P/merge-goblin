//  Theme.swift — colour, type and the few shapes everything else is built from.
//
//  The look is "a well-behaved Mac app": system materials, SF Pro, SF Symbols, and one
//  accent. No colour is hard-coded where a semantic one exists, so light mode, dark
//  mode, Increase Contrast and Reduce Transparency all work without a line of
//  special-casing here.

import SwiftUI
import AppKit

enum Theme {
    /// The Goblin's green. Lighter on dark backgrounds so it keeps its contrast.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.82, blue: 0.52, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.52, blue: 0.28, alpha: 1)
    })
    static let accentSoft = accent.opacity(0.14)

    static let card = Color(nsColor: .controlBackgroundColor).opacity(0.65)
    static let hairline = Color(nsColor: .separatorColor).opacity(0.6)
    static let fieldFill = Color(nsColor: .textBackgroundColor).opacity(0.55)

    static func color(for s: Severity) -> Color {
        switch s {
        case .blocker: return Color(nsColor: .systemRed)
        case .convention: return Color(nsColor: .systemOrange)
        case .risk: return Color(nsColor: .systemYellow)
        case .nit: return Color(nsColor: .systemGray)
        case .question: return Color(nsColor: .systemBlue)
        }
    }

    static func color(for p: JobPhase) -> Color {
        switch p {
        case .ready, .done: return accent
        case .failed: return Color(nsColor: .systemRed)
        case .skipped, .cancelled, .discarded: return .secondary
        default: return Color(nsColor: .systemBlue)
        }
    }

    static func symbol(for p: JobPhase) -> String {
        switch p {
        case .queued: return "hourglass"
        case .fetching: return "arrow.down.circle"
        case .reading: return "doc.text.magnifyingglass"
        case .reviewing: return "sparkles"
        case .ready: return "text.badge.checkmark"
        case .posting: return "paperplane"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "forward.circle"
        case .cancelled: return "xmark.circle"
        case .discarded: return "trash"
        }
    }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

struct SeverityBadge: View {
    let severity: Severity
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.color(for: severity)).frame(width: 7, height: 7)
            Text(severity.label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.color(for: severity).opacity(0.14), in: Capsule())
        .foregroundStyle(Theme.color(for: severity))
    }
}

// MARK: - Buttons

struct GoblinButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain, destructive }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = {
            switch kind {
            case .primary: return Color(nsColor: .black).opacity(0.85)
            case .destructive: return Color(nsColor: .systemRed)
            default: return .primary
            }
        }()
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 4 : 7)
            .foregroundStyle(fg)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                .strokeBorder(kind == .primary ? .clear : Theme.hairline, lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return Theme.accent.opacity(pressed ? 0.8 : 1)
        case .secondary: return Color(nsColor: .controlColor).opacity(pressed ? 0.55 : 0.9)
        case .destructive: return Color(nsColor: .systemRed).opacity(pressed ? 0.2 : 0.1)
        case .plain: return pressed ? Color.primary.opacity(0.08) : .clear
        }
    }
}

extension ButtonStyle where Self == GoblinButtonStyle {
    static var goblinPrimary: GoblinButtonStyle { .init(kind: .primary) }
    static var goblin: GoblinButtonStyle { .init(kind: .secondary) }
    static var goblinSmall: GoblinButtonStyle { .init(kind: .secondary, compact: true) }
    static var goblinPrimarySmall: GoblinButtonStyle { .init(kind: .primary, compact: true) }
    static var goblinQuiet: GoblinButtonStyle { .init(kind: .plain, compact: true) }
    static var goblinDestructive: GoblinButtonStyle { .init(kind: .destructive, compact: true) }
}

// MARK: - Toast

struct ToastHost: ViewModifier {
    let store: AppStore
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = store.toast {
                HStack(spacing: 8) {
                    Image(systemName: t.kind == .error ? "exclamationmark.circle.fill"
                                    : t.kind == .success ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(t.kind == .error ? Color(nsColor: .systemRed) : t.kind == .success ? Theme.accent : .secondary)
                    Text(t.text).font(.system(size: 12.5)).lineLimit(3)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}
extension View {
    func toasts(_ store: AppStore) -> some View { modifier(ToastHost(store: store)) }
}

// MARK: - Time

enum Ago {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, s / 60))m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
    static func elapsed(_ since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}
