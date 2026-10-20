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
    /// Text on a filled accent button: white on the deep light-mode green (about 5:1),
    /// near-black on the bright dark-mode green. Black on the light green was about 4:1.
    static let onAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.05, alpha: 0.92) : NSColor.white
    })
    /// systemYellow text on a pale tint is about 1.5:1 in light mode; a dark amber reads.
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow : NSColor(srgbRed: 0.58, green: 0.38, blue: 0.0, alpha: 1)
    })

    static let card = Color(nsColor: .controlBackgroundColor).opacity(0.65)
    static let hairline = Color(nsColor: .separatorColor).opacity(0.6)
    static let fieldFill = Color(nsColor: .textBackgroundColor).opacity(0.55)

    static func color(for s: Severity) -> Color {
        switch s {
        case .blocker: return Color(nsColor: .systemRed)
        case .convention: return Color(nsColor: .systemOrange)
        case .risk: return Theme.amber
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

// MARK: - Motion

/// The app's few animations, in one place, so Reduce Motion is honoured everywhere by
/// construction: movement becomes a short fade, and nothing loops.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation { reduced ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.2) }
    static var quick: Animation { reduced ? .easeOut(duration: 0.1) : .snappy(duration: 0.2) }
    /// For rows that come and go in a list.
    static var row: AnyTransition {
        reduced ? .opacity
                : .asymmetric(insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)),
                              removal: .opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// Fades and lifts content in once, `delay` seconds after it first appears: how a list
/// arrives without every row landing in the same frame.
struct Arrive: ViewModifier {
    var delay: Double = 0
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduced ? 0 : 6)
            .onAppear {
                withAnimation(Motion.reduced ? .easeOut(duration: 0.12) : .spring(duration: 0.45, bounce: 0.15).delay(delay)) { shown = true }
            }
    }
}
extension View {
    func arrive(_ delay: Double = 0) -> some View { modifier(Arrive(delay: delay)) }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    /// A coloured edge on the leading side: what kind of thing this card is, at a glance.
    var accent: Color? = nil
    /// Lifts a little under the pointer. For cards that open something when clicked.
    var interactive = false
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(padding)
            .padding(.leading, accent == nil ? 0 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(interactive && hovering ? 0.035 : 0)))
            }
            .overlay(alignment: .leading) {
                if let accent {
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, style: .continuous)
                        .fill(accent.gradient).frame(width: 3.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(interactive && hovering ? Theme.hairline.opacity(1.6) : Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(interactive && hovering ? 0.10 : 0.0), radius: 8, y: 3)
            .scaleEffect(interactive && hovering && !Motion.reduced ? 1.004 : 1)
            .onHover { h in withAnimation(Motion.quick) { hovering = h } }
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

    func makeBody(configuration: Configuration) -> some View {
        GoblinButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

/// The body is a view of its own so it can know about hover: a button that answers the
/// pointer before it is pressed feels alive, and one that only reacts on press feels dead.
private struct GoblinButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: GoblinButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 4 : 7)
            .foregroundStyle(foreground)
            .background(background(pressed), in: shape)
            .overlay {
                if kind == .primary {
                    // a faint top highlight, so the primary action reads as raised
                    shape.fill(LinearGradient(colors: [.white.opacity(hovering ? 0.22 : 0.14), .clear],
                                              startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
            }
            .overlay(shape.strokeBorder(kind == .primary ? .clear : Theme.hairline, lineWidth: 0.5))
            .shadow(color: kind == .primary && enabled ? Theme.accent.opacity(hovering ? 0.35 : 0.18) : .clear,
                    radius: hovering ? 7 : 4, y: 2)
            .scaleEffect(pressed && !Motion.reduced ? 0.965 : 1)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(Motion.quick) { hovering = h && enabled } }
            .animation(Motion.quick, value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onAccent
        case .destructive: return Color(nsColor: .systemRed)
        default: return .primary
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return Theme.accent.opacity(pressed ? 0.8 : 1)
        case .secondary: return Color(nsColor: .controlColor).opacity(pressed ? 0.55 : hovering ? 1 : 0.85)
        case .destructive: return Color(nsColor: .systemRed).opacity(pressed ? 0.22 : hovering ? 0.16 : 0.1)
        case .plain: return pressed ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.06) : .clear
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
                        .symbolEffect(.bounce, options: .nonRepeating, value: Motion.reduced ? 0 : t.id.hashValue)
                    Text(t.text).font(.system(size: 12.5)).lineLimit(3)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(12)
                // Reduce Motion: it fades in place instead of sliding up.
                .transition(Motion.reduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.spring, value: store.toast)
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

// MARK: - Severity counts

/// "🔴 1 blocker · 🟡 2 risk", the engine's summary line, drawn as small coloured dots
/// with numbers instead of emoji. Anything it cannot parse is shown as the text it is.
struct SeverityCounts: View {
    let text: String
    var size: CGFloat = 11.5

    static func parse(_ text: String) -> [(Severity, Int)]? {
        let parts = text.components(separatedBy: " · ")
        var out: [(Severity, Int)] = []
        for p in parts {
            let words = p.split(separator: " ").map(String.init)
            guard let n = words.compactMap({ Int($0) }).first,
                  let word = words.last?.lowercased(),
                  let sev = Severity.allCases.first(where: { word.hasPrefix($0.rawValue) }) else { return nil }
            out.append((sev, n))
        }
        return out.isEmpty ? nil : out
    }

    var body: some View {
        if let parsed = Self.parse(text) {
            HStack(spacing: 9) {
                ForEach(parsed, id: \.0) { sev, n in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.color(for: sev).gradient).frame(width: 7, height: 7)
                        Text(verbatim: "\(n) \(n == 1 ? sev.label.lowercased() : sev.plural)")
                    }
                }
            }
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        } else {
            Text(text).font(.system(size: size)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Tabs

/// A segmented control whose selection glides between tabs. The system one snaps.
struct GlideTabs<T: Hashable>: View {
    struct Item { let value: T; let title: String; var count: Int = 0 }
    let items: [Item]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection
                Button { withAnimation(Motion.spring) { selection = item.value } } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                        if item.count > 0 {
                            Text(verbatim: "\(item.count)")
                                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(on ? Theme.accent.opacity(0.22) : Color.primary.opacity(0.08), in: Capsule())
                                .foregroundStyle(on ? Theme.accent : .secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Rows

/// A list row that answers the pointer: a soft highlight, nothing more.
struct HoverRow: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.055 : 0)))
            .onHover { h in withAnimation(Motion.quick) { hovering = h } }
    }
}
extension View {
    func hoverRow() -> some View { modifier(HoverRow()) }
}
