import XCTest
@testable import Goblin

final class UsageTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Skopje")!
        return c
    }()
    /// 2026-10-20 15:00 local
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))! }

    private func ev(_ status: String, daysAgo: Int, hour: Int = 10, repo: String = "acme/widgets", n: Int = 1,
                    provider: String = "claude", model: String = "sonnet", cost: Double = 0) -> String {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!
        let at = day.addingTimeInterval(Double(hour) * 3600).timeIntervalSince1970
        return #"{"at":\#(Int(at)),"number":\#(n),"repo":"\#(repo)","status":"\#(status)","provider":"\#(provider)","model":"\#(model)","costUsd":\#(cost),"title":"t","url":"u","reason":""}"#
    }

    private func report(_ lines: [String]) -> UsageReport {
        UsageReport(eventsText: lines.joined(separator: "\n"), now: now, calendar: cal)
    }

    func testFourteenDaysOldestFirstWithZeros() {
        let r = report([ev("posted", daysAgo: 0, cost: 0.4), ev("posted", daysAgo: 13, n: 2, cost: 0.1)])
        XCTAssertEqual(r.days.count, 14)
        XCTAssertEqual(r.days.first?.date, cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now)))
        XCTAssertEqual(r.days.last?.date, cal.startOfDay(for: now))
        XCTAssertEqual(r.days.map(\.reviews), [1] + Array(repeating: 0, count: 12) + [1])
        XCTAssertEqual(r.totalReviews, 2)
    }

    func testOlderThanTheWindowIsLeftOut() {
        let r = report([ev("posted", daysAgo: 14, cost: 9), ev("posted", daysAgo: 30, cost: 9)])
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.totalCost, 0)
        XCTAssertTrue(r.models.isEmpty)
    }

    func testAPreviewThenItsPostIsOneReviewAndOneCost() {
        let r = report([
            ev("previewed", daysAgo: 2, n: 873, cost: 0.38),
            ev("posted", daysAgo: 1, n: 873, cost: 0),       // the person sent it a day later
            ev("posted", daysAgo: 1, n: 874, cost: 0.2),     // a scheduled review: its own
            ev("posted", daysAgo: 0, n: 873, cost: 0.3),     // a later re-review of 873: its own too
        ])
        XCTAssertEqual(r.totalReviews, 3)
        XCTAssertEqual(r.days[11].reviews, 1)
        XCTAssertEqual(r.days[12].reviews, 1)
        XCTAssertEqual(r.days[13].reviews, 1)
        XCTAssertEqual(r.totalCost, 0.88, accuracy: 0.0001)
    }

    func testAPreviewFromBeforeTheWindowStillPairsWithItsPost() {
        let r = report([ev("previewed", daysAgo: 20, n: 5, cost: 1), ev("posted", daysAgo: 0, n: 5)])
        XCTAssertEqual(r.totalReviews, 0, "the review happened 20 days ago; posting it is not a new one")
    }

    func testFailuresAreCountedApart() {
        let r = report([ev("failed", daysAgo: 0, cost: 0.05), ev("posted", daysAgo: 0, n: 2)])
        XCTAssertEqual(r.totalReviews, 1)
        XCTAssertEqual(r.totalFailed, 1)
        XCTAssertEqual(r.models.first?.failed, 1)
        XCTAssertEqual(r.totalCost, 0.05, accuracy: 0.0001)
    }

    func testPerModelDollarsOnlyWhereTheProviderReportsThem() {
        let r = report([
            ev("posted", daysAgo: 0, n: 1, provider: "claude", model: "sonnet", cost: 0.3),
            ev("posted", daysAgo: 1, n: 2, provider: "claude", model: "sonnet", cost: 0.2),
            ev("posted", daysAgo: 1, n: 3, provider: "claude", model: "opus", cost: 1.1),
            ev("posted", daysAgo: 0, n: 4, provider: "codex", model: "gpt-6.1-sol"),
            ev("posted", daysAgo: 0, n: 5, provider: "codex", model: "gpt-6.1-sol"),
            ev("posted", daysAgo: 0, n: 6, provider: "codex", model: "gpt-6.1-sol"),
        ])
        XCTAssertEqual(r.models.map(\.id), ["codex/gpt-6.1-sol", "claude/sonnet", "claude/opus"], "most reviews first")
        let codex = r.models[0], sonnet = r.models[1]
        XCTAssertFalse(codex.costKnown, "a subscription CLI counts reviews, it does not cost $0")
        XCTAssertEqual(codex.reviews, 3)
        XCTAssertTrue(sonnet.costKnown)
        XCTAssertEqual(sonnet.costUsd, 0.5, accuracy: 0.0001)
        XCTAssertEqual(codex.providerName, "Codex")
        XCTAssertTrue(r.anyCostKnown)
    }

    func testOldEventsWithoutProviderAndGarbageLines() {
        let lines = [
            #"{"at":\#(Int(now.timeIntervalSince1970) - 60),"number":1,"status":"posted","costUsd":0.1}"#,
            "not json", #"{"status":"posted"}"#, #"{"at":1,"status":"started"}"#, "",
        ]
        let r = report(lines)
        XCTAssertEqual(r.totalReviews, 1)
        XCTAssertEqual(r.models.first?.providerName, "Unknown")
        XCTAssertEqual(r.models.first?.modelName, "default model")
    }

    func testDollars() {
        XCTAssertEqual(UsageReport.dollars(0), "$0.00")
        XCTAssertEqual(UsageReport.dollars(0.001), "<$0.01")
        XCTAssertEqual(UsageReport.dollars(1.237), "$1.24")
    }
}
