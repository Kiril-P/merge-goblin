import XCTest
@testable import Goblin

final class StatsTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)").path
    }

    private func argv(_ c: Command) throws -> [String] {
        guard case .cli(let argv, _, _, _) = try c.validatedPlan() else { XCTFail("not a CLI plan"); return [] }
        return argv
    }

    /// real-stats.json is what `goblin stats --json` printed for the bash test's threads.
    func testRealStatsDecode() throws {
        let s = try XCTUnwrap(ReviewStats(json: JSON.read(path: fixture("real-stats.json"))))
        XCTAssertEqual(s.days, 30)
        XCTAssertEqual(s.prs, 2)
        XCTAssertEqual(s.total, .init(n: 8, addressed: 4, discussed: 2, silent: 2))
        XCTAssertEqual(s.addressedRate, 0.5)
        XCTAssertEqual(ReviewStats.percent(s.addressedRate), "50%")
        XCTAssertEqual(s.bySeverity.map(\.name), ["blocker", "risk", "convention", "nit"], "worst first")
        XCTAssertEqual(s.bySeverity.reduce(0) { $0 + $1.tally.n }, s.total.n)
        XCTAssertFalse(s.isEmpty)
    }

    func testNoFindingsIsNotAZeroPercentRate() throws {
        let s = try XCTUnwrap(ReviewStats(json: JSON.parse(
            #"{"days":30,"prs":0,"looked":0,"skipped":0,"findings":0,"addressed":0,"discussed":0,"silent":0,"addressedRate":null,"bySeverity":{},"perPr":[]}"#)))
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.addressedRate)
        XCTAssertNil(ReviewStats.percent(s.addressedRate))
        XCTAssertEqual(StatsCopy.headline(s), "Last 30 days · 0 findings on 0 PRs")
    }

    func testAnErrorOrGarbageIsNotAReport() {
        XCTAssertNil(ReviewStats(json: JSON.parse(#"{"error":"not authenticated"}"#)))
        XCTAssertNil(ReviewStats(json: JSON.parse("not json")))
    }

    func testUnknownSeverityStillShowsAfterTheKnownOnes() throws {
        let s = try XCTUnwrap(ReviewStats(json: JSON.parse(
            #"{"days":7,"prs":1,"findings":2,"addressed":1,"discussed":0,"silent":1,"bySeverity":{"zzz":{"n":1,"addressed":0,"discussed":0,"silent":1},"nit":{"n":1,"addressed":1,"discussed":0,"silent":0}}}"#)))
        XCTAssertEqual(s.bySeverity.map(\.name), ["nit", "zzz"])
    }

    func testStatsCommandArgvAndBounds() throws {
        XCTAssertEqual(try argv(.stats(days: 30, refresh: false)), ["stats", "--json", "--days", "30"])
        XCTAssertEqual(try argv(.stats(days: 7, refresh: true)), ["stats", "--json", "--days", "7", "--refresh"])
        XCTAssertThrowsError(try Command.stats(days: 0, refresh: false).validatedPlan())
        XCTAssertThrowsError(try Command.stats(days: 366, refresh: false).validatedPlan())
    }
}
