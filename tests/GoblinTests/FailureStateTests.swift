import XCTest
@testable import Goblin

/// The unhappy paths: what a failure is called, what the panel says when the icon
/// says something is wrong, and the undo window's countdown.
final class FailureStateTests: XCTestCase {
    private func job(_ extra: String) -> Job {
        Job(json: JSON.parse("""
        {"id":"j1700000000-1","repo":"acme/widgets","number":7,"phase":"failed",
         "createdAt":1700000000, "providerUsed":"cursor" \(extra)}
        """))!
    }

    func testNothingEverReadsOther() {
        XCTAssertEqual(FailureText.sentence("other", provider: "claude"), "Claude stopped with an error.")
        XCTAssertEqual(FailureText.sentence("transient", provider: "cursor"), "Lost the connection to Cursor.")
        XCTAssertEqual(FailureText.words("quota", provider: ""), "the AI hit its usage limit")
        XCTAssertEqual(FailureText.words("post failed", provider: "x"), "GitHub didn't accept the review")
    }

    func testAnOldJobsRawOutputMovesToTheDetails() {
        // written before errorRaw existed: errorDetail held the CLI's own output
        let j = job(#","error":"other","errorDetail":"Connection lost, reconnecting… Retry attempt 1…""#)
        XCTAssertEqual(j.failureMessage, "Cursor stopped with an error.")
        XCTAssertEqual(j.failureDetails, "Connection lost, reconnecting… Retry attempt 1…")
    }

    func testANewJobSaysItInWordsAndKeepsTheRawApart() {
        let j = job(#","error":"transient","errorDetail":"Lost the connection to Cursor. The Goblin tries again around 14:20.","errorRaw":"Retry attempt 6...","errorProvider":"cursor","retryAt":1700003600"#)
        XCTAssertEqual(j.failureMessage, "Lost the connection to Cursor. The Goblin tries again around 14:20.")
        XCTAssertEqual(j.failureDetails, "Retry attempt 6...")
        XCTAssertEqual(j.retryAt, Date(timeIntervalSince1970: 1700003600))
    }

    func testEngineMessagesForNonProviderKindsAreKept() {
        let j = job(#","error":"auth","errorDetail":"GitHub is not signed in as the configured account.""#)
        XCTAssertEqual(j.failureMessage, "GitHub is not signed in as the configured account.")
        XCTAssertEqual(j.failureDetails, "")
    }

    func testTheIconsProblemReachesThePanel() {
        let ui = JSON.parse("""
        {"setup":{"complete":true},"lastRunFinished":1700000000,"nextRunEstimate":1700000900,
         "bar":{"glyph":"error","tooltip":"1 health check(s) failing",
                "problem":{"kind":"health","title":"A health check is failing","detail":"d","action":"health"}}}
        """)
        let s = Snapshot(json: ui, config: JSON.parse("{}"))
        XCTAssertEqual(s.problem?.title, "A health check is failing")
        XCTAssertEqual(s.problem?.action, .health)
        XCTAssertEqual(s.lastRunFinished, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(s.nextRunEstimate, Date(timeIntervalSince1970: 1700000900))
        // no problem, no banner
        let fine = Snapshot(json: JSON.parse(#"{"setup":{"complete":true},"bar":{"glyph":"idle","problem":null}}"#),
                            config: JSON.parse("{}"))
        XCTAssertNil(fine.problem)
    }

    func testTheUndoWindowCountsDown() {
        let p = PendingSend(kind: .post, at: Date(timeIntervalSince1970: 105))
        XCTAssertEqual(PendingLabel.text(p, now: Date(timeIntervalSince1970: 100)), "Posting in 5s")
        XCTAssertEqual(PendingLabel.text(p, now: Date(timeIntervalSince1970: 104.2)), "Posting in 1s")
        XCTAssertEqual(PendingLabel.text(p, now: Date(timeIntervalSince1970: 200)), "Posting in 1s")
        XCTAssertEqual(PendingLabel.text(PendingSend(kind: .discard, at: Date(timeIntervalSince1970: 103)),
                                         now: Date(timeIntervalSince1970: 100)), "Discarding in 3s")
    }
}
