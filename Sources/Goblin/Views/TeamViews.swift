//  TeamViews.swift — one teammate per row: is their Goblin around, and what did it do?
//
//  Everything shown is a trace left on GitHub (see lib/fleet.sh). A Goblin with nothing
//  to review leaves none, so the words are "active", "last seen" and "no sign yet",
//  never "offline", and colour is never the only carrier.

import SwiftUI

struct TeamMemberRow: View {
    let login: String
    let member: FleetStatus.Member?
    let isMe: Bool
    let loading: Bool
    var last = false
    var remove: () -> Void

    var body: some View {
        SettingRow(title: isMe ? "@\(login) (you)" : "@\(login)", hint: hint, last: last) {
            HStack(spacing: 10) {
                PresenceBadge(presence: member?.presence, reviewing: !(member?.reviewing.isEmpty ?? true), loading: loading)
                Button(action: remove) {
                    Image(systemName: "minus.circle").font(.system(size: 13))
                }.buttonStyle(.goblinQuiet).help("Remove")
            }
        }
    }

    private var hint: String? {
        guard let m = member else { return loading ? nil : "Not checked yet." }
        var parts: [String] = []
        if let r = m.reviewing.first {
            parts.append("Reviewing \(r.shortRef) now")
        } else {
            switch m.presence {
            case .active: parts.append(isMe ? "On duty on this Mac" : "Active in the last few minutes")
            case .seen: parts.append("Last seen \(m.lastSeen.map { Ago.short($0) } ?? "a while ago")")
            case .unknown: parts.append("No sign yet")
            }
        }
        if !m.recent.isEmpty {
            let list = m.recent.prefix(3).map { "\($0.shortRef) \(Ago.short($0.at))" }
            parts.append("reviewed " + list.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

private struct PresenceBadge: View {
    let presence: FleetStatus.Presence?
    let reviewing: Bool
    let loading: Bool

    var body: some View {
        if presence == nil && loading {
            ProgressView().controlSize(.mini)
        } else {
            HStack(spacing: 5) {
                dot
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(presence == .active ? Theme.accent : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background((presence == .active ? Theme.accent : Color.secondary).opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var dot: some View {
        switch presence {
        case .active:
            ZStack {
                // the same ring as the menu bar's status dot while a review runs
                if reviewing {
                    Circle().stroke(Theme.accent.opacity(0.6), lineWidth: 1.5).frame(width: 7, height: 7)
                        .modifier(Ripple())
                }
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
            }
        case .seen:
            Circle().fill(Color.secondary.opacity(0.7)).frame(width: 7, height: 7)
        default:
            Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1).frame(width: 7, height: 7)
        }
    }

    private var label: String {
        switch presence {
        case .active: return reviewing ? "Reviewing" : "Active"
        case .seen: return "Seen"
        default: return "No sign"
        }
    }
}
