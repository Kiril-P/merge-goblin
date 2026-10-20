//  SettingsView.swift — the Settings window: a sidebar and one pane at a time.
//
//  Every control applies the moment it changes, through `store.perform(Command)`:
//  there is no Save button to forget, and a failure shows up as a toast with the
//  control snapping back to what the engine actually has. Panes live in
//  SettingsPanes.swift; the small building blocks they share are here.

import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reviewer, repos, team, behaviour, notifications, health, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .reviewer: return "Reviewer"
        case .repos: return "Repositories"
        case .team: return "Team"
        case .behaviour: return "Behaviour"
        case .notifications: return "Notifications"
        case .health: return "Health"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .reviewer: return "sparkles"
        case .repos: return "shippingbox"
        case .team: return "person.2"
        case .behaviour: return "slider.horizontal.3"
        case .notifications: return "bell"
        case .health: return "heart.text.square"
        case .about: return "info.circle"
        }
    }
}

@MainActor @Observable final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var pane: SettingsPane = .general
}

struct SettingsView: View {
    @Bindable var store: AppStore
    @State private var nav = SettingsNavigation.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(.background)
        .toasts(store)
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                Button { nav.pane = pane } label: {
                    HStack(spacing: 9) {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(pane.title).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                        if badge(pane) { Circle().fill(Color(nsColor: .systemOrange)).frame(width: 7, height: 7) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(nav.pane == pane ? Theme.accent : Color.primary)
                    .background(nav.pane == pane ? Theme.accentSoft : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                GoblinAvatar(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Merge Goblin").font(.system(size: 11.5, weight: .semibold))
                    Text(store.snapshot.version.isEmpty ? "" : "v\(store.snapshot.version)")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 2)
        }
        .padding(10)
        .frame(width: 188)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    /// A small dot on the panes that need attention, so a problem is visible without
    /// opening each one.
    private func badge(_ pane: SettingsPane) -> Bool {
        switch pane {
        case .reviewer: return store.providersState == .loaded && !store.providers.contains(where: \.ready)
        case .health: return store.doctor.contains { $0.status == .fail }
        case .general: return !store.snapshot.identityOK
        default: return false
        }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        switch nav.pane {
        case .general: GeneralPane(store: store)
        case .reviewer: ReviewerPane(store: store)
        case .repos: ReposPane(store: store)
        case .team: TeamPane(store: store)
        case .behaviour: BehaviourPane(store: store)
        case .notifications: NotificationsPane(store: store)
        case .health: HealthPane(store: store)
        case .about: AboutPane(store: store)
        }
    }
}

// MARK: - Building blocks

/// A scrolling page with a big title and a one-line description.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

/// A titled group of rows inside one card, separated by hairlines.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { SectionLabel(text: title) }
            Card(padding: 0) {
                VStack(spacing: 0) { content() }
            }
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }
}

/// One line: a title with an optional hint on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var hint: String? = nil
    var last = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let hint {
                        Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if !last { Divider().opacity(0.6).padding(.leading, 14) }
        }
    }
}

/// A switch that flips at once and settles on whatever the engine reports. If the
/// command fails the toast says why and the switch returns to the real value.
struct FlagRow: View {
    let store: AppStore
    let title: String
    var hint: String? = nil
    let value: Bool
    var enabled = true
    var last = false
    let command: (Bool) -> Command
    @State private var local: Bool

    init(store: AppStore, title: String, hint: String? = nil, value: Bool, enabled: Bool = true,
         last: Bool = false, command: @escaping (Bool) -> Command) {
        self.store = store; self.title = title; self.hint = hint; self.value = value
        self.enabled = enabled; self.last = last; self.command = command
        _local = State(initialValue: value)
    }

    var body: some View {
        SettingRow(title: title, hint: hint, last: last) {
            Toggle("", isOn: Binding(get: { local }, set: { new in
                local = new
                Task { if await !store.perform(command(new)) { local = value } }
            }))
            .toggleStyle(.switch).labelsHidden().tint(Theme.accent).disabled(!enabled)
        }
        .onChange(of: value) { _, new in local = new }
    }
}

/// A number with − / + buttons. Changes are sent once you stop clicking, so holding
/// the button down is one command rather than thirty.
struct NumberRow: View {
    let store: AppStore
    let title: String
    var hint: String? = nil
    let value: Int
    let range: ClosedRange<Int>
    var unit: String? = nil
    var zeroLabel: String? = nil
    var last = false
    let command: (Int) -> Command
    @State private var local: Int
    @State private var pending: Task<Void, Never>?

    init(store: AppStore, title: String, hint: String? = nil, value: Int, range: ClosedRange<Int>,
         unit: String? = nil, zeroLabel: String? = nil, last: Bool = false, command: @escaping (Int) -> Command) {
        self.store = store; self.title = title; self.hint = hint; self.value = value; self.range = range
        self.unit = unit; self.zeroLabel = zeroLabel; self.last = last; self.command = command
        _local = State(initialValue: value)
    }

    var body: some View {
        SettingRow(title: title, hint: hint, last: last) {
            HStack(spacing: 8) {
                Text(display).font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(minWidth: 64, alignment: .trailing)
                Stepper("", value: Binding(get: { local }, set: { set($0) }), in: range)
                    .labelsHidden()
            }
        }
        .onChange(of: value) { _, new in local = new }
    }

    private var display: String {
        if local == 0, let zeroLabel { return zeroLabel }
        return unit.map { "\(local) \($0)" } ?? String(local)
    }

    private func set(_ new: Int) {
        local = new
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            if await !store.perform(command(new)) { local = value }
        }
    }
}

/// Plain status line used by lists that can be loading, empty or failed.
struct StatusLine: View {
    enum Kind { case loading, info, warning, error }
    let kind: Kind
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .loading: ProgressView().controlSize(.small)
            case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(nsColor: .systemRed))
            }
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}
