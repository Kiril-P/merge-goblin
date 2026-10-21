import Foundation

/// How the findings the Goblin posted actually fared (`goblin stats --json`).
///
/// "Addressed" is a proxy: the thread was resolved, or GitHub marked it outdated because
/// the code under it changed. It reads as "likely addressed", never "was right".
struct ReviewStats: Equatable {
    struct Tally: Equatable {
        var n = 0, addressed = 0, discussed = 0, silent = 0
    }

    let days: Int
    let prs: Int
    let skipped: Int
    let total: Tally
    /// Severity name -> counts, in the order the Goblin grades them (worst first).
    let bySeverity: [(name: String, tally: Tally)]

    /// Nil when there were no findings, so the UI never shows "0%" for "no data".
    var addressedRate: Double? { total.n == 0 ? nil : Double(total.addressed) / Double(total.n) }
    var isEmpty: Bool { total.n == 0 }

    init?(json: JSON) {
        guard json["error"].string == nil, let days = json["days"].int else { return nil }
        self.days = days
        prs = json["prs"].int(0)
        skipped = json["skipped"].int(0)
        total = Tally(n: json["findings"].int(0), addressed: json["addressed"].int(0),
                      discussed: json["discussed"].int(0), silent: json["silent"].int(0))
        let order = ["blocker", "risk", "convention", "nit"]
        let rows = (json["bySeverity"].object ?? [:]).keys.map { key -> (String, Tally) in
            let j = json["bySeverity"][key]
            return (key, Tally(n: j["n"].int(0), addressed: j["addressed"].int(0),
                               discussed: j["discussed"].int(0), silent: j["silent"].int(0)))
        }
        bySeverity = rows.sorted {
            let a = order.firstIndex(of: $0.0) ?? order.count, b = order.firstIndex(of: $1.0) ?? order.count
            return a == b ? $0.0 < $1.0 : a < b
        }.map { (name: $0.0, tally: $0.1) }
    }

    static func == (l: ReviewStats, r: ReviewStats) -> Bool {
        l.days == r.days && l.prs == r.prs && l.skipped == r.skipped && l.total == r.total
            && l.bySeverity.map(\.name) == r.bySeverity.map(\.name)
            && l.bySeverity.map(\.tally) == r.bySeverity.map(\.tally)
    }

    init(days: Int, prs: Int, skipped: Int = 0, total: Tally, bySeverity: [(name: String, tally: Tally)]) {
        self.days = days; self.prs = prs; self.skipped = skipped
        self.total = total; self.bySeverity = bySeverity
    }

    /// "37%", or nil when there is nothing to take a rate of.
    static func percent(_ rate: Double?) -> String? {
        rate.map { "\(Int(($0 * 100).rounded()))%" }
    }
}
