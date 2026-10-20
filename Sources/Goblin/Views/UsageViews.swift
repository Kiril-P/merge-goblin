//  UsageViews.swift — how much reviewing he has done lately, and what it cost.
//
//  Read straight from events.jsonl (see UsageReport). Dollars only where the provider
//  reports them; a subscription CLI's row counts reviews, because "$0.00" would be a lie.

import Charts
import SwiftUI

struct UsageGroup: View {
    let store: AppStore
    private var usage: UsageReport { store.usage }

    var body: some View {
        SettingsGroup(title: "Usage", footer: footer) {
            if usage.isEmpty {
                StatusLine(kind: .info, text: "No reviews in the last two weeks.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(headline).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 8)
                        if usage.anyCostKnown {
                            Text(UsageReport.dollars(usage.totalCost))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .help("What the providers that report cost said these reviews cost")
                        }
                    }
                    UsageChart(days: usage.days)
                        .frame(height: 96)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                Divider().opacity(0.6).padding(.leading, 14)
                ForEach(Array(usage.models.enumerated()), id: \.element.id) { i, row in
                    modelRow(row, last: i == usage.models.count - 1)
                }
            }
        }
    }

    private var headline: String {
        let n = usage.totalReviews
        var s = "\(n) review\(n == 1 ? "" : "s") in the last \(UsageReport.span) days"
        if usage.totalFailed > 0 { s += " · \(usage.totalFailed) failed" }
        return s
    }

    private var footer: String {
        "A review you read first is counted once, when it ran. Only Claude reports what a review cost; the other subscriptions count reviews instead."
    }

    private func modelRow(_ row: UsageReport.ModelRow, last: Bool) -> some View {
        var hint = "\(row.reviews) review\(row.reviews == 1 ? "" : "s")"
        if row.failed > 0 { hint += " · \(row.failed) failed" }
        if row.costKnown, row.reviews > 0, row.costUsd > 0 {
            hint += " · about \(UsageReport.dollars(row.costUsd / Double(row.reviews))) each"
        }
        return SettingRow(title: "\(row.providerName) · \(row.modelName)", hint: hint, last: last) {
            Text(row.costKnown ? UsageReport.dollars(row.costUsd) : "\(row.reviews) review\(row.reviews == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(row.costKnown ? .primary : .secondary)
        }
    }
}

/// Reviews per day: one series, so no legend; the title says what it is. Hover a day for
/// its exact number.
private struct UsageChart: View {
    let days: [UsageReport.Day]
    @State private var selected: Date?

    private var selectedDay: UsageReport.Day? {
        guard let selected else { return nil }
        return days.first { Calendar.current.isDate($0.date, inSameDayAs: selected) }
    }

    var body: some View {
        Chart {
            ForEach(days) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Reviews", d.reviews), width: .ratio(0.62))
                    .foregroundStyle(Theme.accent.opacity(selectedDay == nil || selectedDay?.date == d.date ? 1 : 0.45))
                    .cornerRadius(3)
            }
            if let d = selectedDay {
                RuleMark(x: .value("Day", d.date, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(d)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYScale(domain: 0...max(3, (days.map(\.reviews).max() ?? 0)))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                    .font(.system(size: 9.5))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 9.5))
            }
        }
        .animation(Motion.quick, value: selected)
        .accessibilityElement()
        .accessibilityLabel("Reviews per day, last \(days.count) days")
        .accessibilityValue(days.map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())): \($0.reviews)" }.joined(separator: ", "))
    }

    private func tooltip(_ d: UsageReport.Day) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(d.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 10, weight: .semibold))
            Text("\(d.reviews) review\(d.reviews == 1 ? "" : "s")\(d.failed > 0 ? " · \(d.failed) failed" : "")")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}
