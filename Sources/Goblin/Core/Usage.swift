import Foundation

/// How much reviewing has been done lately, read from the tail of events.jsonl.
///
/// One review is one model run. A review you read first shows up twice in the file —
/// `previewed` when the model finished, `posted` when you sent it — so a `posted` that
/// follows a `previewed` of the same PR is the second half of one review, not a second
/// review. Its cost was already recorded with the preview (the engine writes 0 on the
/// post), so dollars never double either.
///
/// Dollars are only real where the provider reports them (Claude). The subscription
/// CLIs report usage but not money, so their rows count reviews instead of showing $0.
struct UsageReport: Equatable {
    struct Day: Equatable, Identifiable {
        let date: Date        // local midnight
        var reviews = 0
        var failed = 0
        var id: Date { date }
    }

    struct ModelRow: Equatable, Identifiable {
        let provider: String
        let model: String
        var reviews = 0
        var failed = 0
        var costUsd = 0.0
        var id: String { "\(provider)/\(model)" }
        /// Claude reports dollars; anything that ever reported a cost does too.
        var costKnown: Bool { provider == "claude" || costUsd > 0 }

        var providerName: String {
            switch provider {
            case "claude": return "Claude"
            case "codex": return "Codex"
            case "cursor": return "Cursor"
            case "": return "Unknown"
            default: return provider.capitalized
            }
        }
        var modelName: String { model.isEmpty || model == provider ? "default model" : model }
    }

    static let span = 14

    /// Oldest first, exactly `span` entries, today last. Days with nothing are zeros.
    let days: [Day]
    /// Most reviews first.
    let models: [ModelRow]

    var totalReviews: Int { days.reduce(0) { $0 + $1.reviews } }
    var totalFailed: Int { days.reduce(0) { $0 + $1.failed } }
    var totalCost: Double { models.reduce(0) { $0 + $1.costUsd } }
    var anyCostKnown: Bool { models.contains { $0.costKnown && $0.costUsd > 0 } }
    var isEmpty: Bool { totalReviews == 0 && totalFailed == 0 }
    var busiestDay: Int { days.map(\.reviews).max() ?? 0 }

    init(days: [Day] = [], models: [ModelRow] = []) {
        self.days = days
        self.models = models
    }

    /// - Parameter eventsText: lines of events.jsonl, oldest first (a tail is fine: a cut
    ///   first line is simply skipped, as is anything that is not an event).
    init(eventsText: String, now: Date = Date(), calendar: Calendar = .current, span: Int = UsageReport.span) {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(span - 1), to: today) ?? today
        var days = (0..<span).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }.map { Day(date: $0) }
        var rows: [String: ModelRow] = [:]
        var order: [String] = []
        // previews not yet posted, by repo#number — each can absorb one later `posted`
        var waiting: [String: Int] = [:]

        for line in eventsText.split(separator: "\n", omittingEmptySubsequences: true) {
            let j = JSON.parse(String(line))
            guard let status = j["status"].string, let at = j["at"].double else { continue }
            let key = "\(j["repo"].string(""))#\(j["number"].int(0))"
            var isReview = false, isFailure = false
            switch status {
            case "previewed":
                waiting[key, default: 0] += 1
                isReview = true
            case "posted":
                if let w = waiting[key], w > 0 { waiting[key] = w - 1 } else { isReview = true }
            case "failed":
                isFailure = true
            default:
                continue
            }

            let date = Date(timeIntervalSince1970: at)
            guard date >= first, date <= now.addingTimeInterval(60) else { continue }
            let idx = calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? -1
            if days.indices.contains(idx) {
                if isReview { days[idx].reviews += 1 }
                if isFailure { days[idx].failed += 1 }
            }

            let provider = j["provider"].string("")
            let model = j["model"].string("")
            let id = "\(provider)/\(model)"
            if rows[id] == nil { rows[id] = ModelRow(provider: provider, model: model); order.append(id) }
            if isReview { rows[id]?.reviews += 1 }
            if isFailure { rows[id]?.failed += 1 }
            rows[id]?.costUsd += max(0, j["costUsd"].double(0))
        }

        self.days = days
        self.models = order.compactMap { rows[$0] }
            .filter { $0.reviews + $0.failed > 0 || $0.costUsd > 0 }
            .sorted { ($0.reviews, $0.costUsd) > ($1.reviews, $1.costUsd) }
    }

    /// "$1.24", or "<$0.01" for a cost that rounds to nothing but is not nothing.
    static func dollars(_ v: Double) -> String {
        if v > 0 && v < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", v)
    }
}
