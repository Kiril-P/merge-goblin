import XCTest
@testable import Goblin

final class HardeningTests: XCTestCase {

    func testFindingTextCannotCarryANonHTTPSLink() {
        let a = Markdown.attributed("[ok](https://github.com/a/b) [bad](smb://evil/x) [file](file:///Applications/X.app)")
        let links = a.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://github.com/a/b"])
        XCTAssertEqual(String(a.characters), "ok bad file")   // the words stay, only the link goes
    }

    func testPostingGetsMoreThanTheDiscoveryTimeout() throws {
        guard case .cli(_, let timeout, _, _) = try Command.postReview(job: "j1792509161-39526").validatedPlan() else {
            return XCTFail("not a CLI plan")
        }
        XCTAssertGreaterThanOrEqual(timeout.seconds, 120)
    }

    func testTailReadsOnlyTheEndAndDropsTheCutLine() throws {
        let file = NSTemporaryDirectory() + "tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: file) }
        let lines = (1...500).map { "{\"n\":\($0)}" }.joined(separator: "\n") + "\n"
        try lines.write(toFile: file, atomically: true, encoding: .utf8)
        let t = try XCTUnwrap(AppStore.tail(file, bytes: 200))
        XCTAssertTrue(t.hasSuffix("{\"n\":500}\n"))
        XCTAssertTrue(t.split(separator: "\n").allSatisfy { $0.hasPrefix("{") && $0.hasSuffix("}") })
        XCTAssertNil(AppStore.tail("/nonexistent/file", bytes: 10))
    }

    func testASnapshotThatOnlyChangedAReleaseIsNotEqual() {
        var a = Snapshot(), b = Snapshot()
        a.updateLatest = "0.5.0"; b.updateLatest = "0.6.0"
        XCTAssertNotEqual(a, b)
        a = Snapshot(); b = Snapshot(); b.version = "9"
        XCTAssertNotEqual(a, b)
    }

    func testSeverityCountsReadTheEnginesLine() throws {
        let c = try XCTUnwrap(SeverityCounts.parse("🔴 1 blocker · 🟡 2 risk"))
        XCTAssertEqual(c.map(\.0), [.blocker, .risk])
        XCTAssertEqual(c.map(\.1), [1, 2])
        XCTAssertNil(SeverityCounts.parse("no findings"))   // shown as plain text instead
    }
}
