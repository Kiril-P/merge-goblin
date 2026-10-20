//  StatsViews.swift — "how is he doing?": what became of the findings the Goblin posted.
//
//  Honest by construction: the headline says "likely addressed" (resolved or outdated is
//  a proxy), nothing is shown when there is nothing to show, and a failed read keeps the
//  last numbers instead of inventing zeros.

import SwiftUI

enum StatsCopy {
    static let explain = """
    Likely addressed: the thread was resolved, or GitHub marked it outdated because the code under it changed. \
    Discussed: still open, but someone replied. Silent: still open, nobody said anything. \
    Outdated can also come from an unrelated edit, so this is a hint, not a verdict.
    """

    static func headline(_ s: ReviewStats) -> String {
        let findings = "\(s.total.n) finding\(s.total.n == 1 ? "" : "s") on \(s.prs) PR\(s.prs == 1 ? "" : "s")"
        guard let pct = ReviewStats.percent(s.addressedRate) else { return "Last \(s.days) days · \(findings)" }
        return "Last \(s.days) days · \(findings) · \(pct) likely addressed"
    }
}

/// A proportional bar: addressed, discussed, silent. Colour is never the only carrier,
/// the numbers sit beside it.
private struct OutcomeBar: View {
    let tally: ReviewStats.Tally
    var body: some View {
        GeometryReader { geo in
            let total = max(tally.n, 1)
            HStack(spacing: 1.5) {
                segment(tally.addressed, total, Theme.accent, geo.size.width)
                segment(tally.discussed, total, Color(nsColor: .systemBlue), geo.size.width)
                segment(tally.silent, total, Color(nsColor: .tertiaryLabelColor), geo.size.width)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4)))
        .accessibilityHidden(true)
    }

    @ViewBuilder private func segment(_ n: Int, _ total: Int, _ color: Color, _ width: CGFloat) -> some View {
        if n > 0 { Rectangle().fill(color).frame(width: max(2, width * CGFloat(n) / CGFloat(total))) }
    }
}

/// The compact card at the top of the popover's Recent tab. Shows nothing until there is
/// something to report.
struct StatsCard: View {
    let store: AppStore

    var body: some View {
        Group {
            if let s = store.stats, !s.isEmpty {
                Card(padding: 11) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(StatsCopy.headline(s)).font(.system(size: 12, weight: .semibold))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            refreshButton
                        }
                        OutcomeBar(tally: s.total)
                        HStack(spacing: 10) {
                            legend("\(s.total.addressed) addressed", Theme.accent)
                            legend("\(s.total.discussed) discussed", Color(nsColor: .systemBlue))
                            legend("\(s.total.silent) silent", Color(nsColor: .tertiaryLabelColor))
                        }
                        if s.skipped > 0 {
                            Text("\(s.skipped) PR\(s.skipped == 1 ? "" : "s") could not be read and \(s.skipped == 1 ? "is" : "are") not counted.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                .help(StatsCopy.explain)
            }
        }
        .task { await store.loadStats() }
    }

    private var refreshButton: some View {
        Button { Task { await store.loadStats(refresh: true) } } label: {
            if store.statsState == .loading { ProgressView().controlSize(.mini) }
            else { Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold)) }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .disabled(store.statsState == .loading)
        .help("Ask GitHub again")
        .accessibilityLabel("Refresh")
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The fuller breakdown in Settings → About: totals, then one row per severity.
struct StatsGroup: View {
    let store: AppStore

    var body: some View {
        Group {
            if let s = store.stats, !s.isEmpty {
                SettingsGroup(title: "How he's doing", footer: StatsCopy.explain) {
                    SettingRow(title: StatsCopy.headline(s),
                               hint: "\(s.total.addressed) addressed · \(s.total.discussed) discussed · \(s.total.silent) silent",
                               last: s.bySeverity.isEmpty) {
                        refreshControl
                    }
                    ForEach(Array(s.bySeverity.enumerated()), id: \.element.name) { i, row in
                        severityRow(row.name, row.tally, last: i == s.bySeverity.count - 1)
                    }
                }
            } else if case .failed(let message) = store.statsState {
                StatusLine(kind: .warning, text: message)
            }
        }
        .task { await store.loadStats() }
    }

    @ViewBuilder private var refreshControl: some View {
        if store.statsState == .loading { ProgressView().controlSize(.small) }
        else { Button("Refresh") { Task { await store.loadStats(refresh: true) } }.buttonStyle(.goblinSmall) }
    }

    private func severityRow(_ name: String, _ t: ReviewStats.Tally, last: Bool) -> some View {
        let severity = Severity(rawValue: name)
        return SettingRow(title: severity?.label ?? name.capitalized,
                          hint: "\(t.n) finding\(t.n == 1 ? "" : "s") · \(t.addressed) addressed · \(t.discussed) discussed · \(t.silent) silent",
                          last: last) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(ReviewStats.percent(Double(t.addressed) / Double(max(t.n, 1))) ?? "—")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                OutcomeBar(tally: t).frame(width: 90)
            }
        }
    }
}
