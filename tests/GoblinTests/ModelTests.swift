import XCTest
@testable import Goblin

final class ModelTests: XCTestCase {
    private func job(_ extra: String = "") -> Job {
        let json = JSON.parse("""
        {"id":"j1700000000-1","repo":"acme/widgets","number":7,"phase":"reviewing",
         "createdAt":1700000000 \(extra)}
        """)
        return Job(json: json)!
    }

    func testJobNeedsAValidId() {
        XCTAssertNil(Job(json: JSON.parse(#"{"id":"../x","repo":"a/b","number":1}"#)))
        XCTAssertNil(Job(json: JSON.parse(#"{"id":"j1700000000-1","repo":"a/b"}"#)))
    }

    func testDeadWorkerIsInterruptedNotSpinning() {
        var j = job(#","pid":99999999"#)
        j.reconcile()
        XCTAssertEqual(j.phase, .failed)
        XCTAssertEqual(j.error, "interrupted")
    }

    func testLiveWorkerKeepsRunning() {
        var j = job(#","pid":\#(getpid())"#)
        j.reconcile()
        XCTAssertEqual(j.phase, .reviewing)
    }

    func testNoPidGetsAGraceWindow() {
        var young = job(); young.createdAt = Date(); young.reconcile()
        XCTAssertEqual(young.phase, .reviewing)
        var old = job(); old.reconcile(now: Date())
        XCTAssertEqual(old.phase, .failed)
    }

    func testFinishedJobsAreLeftAlone() {
        var j = job(#","pid":99999999"#); j.phase = .done; j.reconcile()
        XCTAssertEqual(j.phase, .done)
    }

    func testSkippedJobsSayWhy() {
        var j = job(#","reason":"skip_paths","reasonDetail":"only lockfiles or generated files changed (2 files, all match skip.paths)""#)
        j.phase = .skipped
        XCTAssertTrue(j.skipMessage.hasPrefix("Only lockfiles or generated files changed."))
        XCTAssertTrue(j.skipMessage.contains("2 files"))
        XCTAssertTrue(job(#","reason":"bot_author""#).skipMessage.contains("dependency bot"))
        XCTAssertEqual(job(#","reason":"docs_only""#).skipMessage, "Only documentation changed, and docs-only PRs are skipped.")
        XCTAssertEqual(job(#","reason":"mystery","reasonDetail":"why not""#).skipMessage, "Skipped: why not.")
        XCTAssertEqual(job(#","reason":"mystery""#).skipMessage, "Skipped.")
    }

    func testSnapshotCarriesRepoProvidersAndSkipSettings() {
        let ui = JSON.parse("""
        {"repos":[{"slug":"a/b","enabled":true,"provider":"codex","model":"gpt-5"},{"slug":"c/d","enabled":false}],
         "settings":{"skip":{"bots":false,"docsOnly":true}}}
        """)
        let s = Snapshot(json: ui, config: JSON.parse("{}"))
        XCTAssertEqual(s.repos, [Snapshot.WatchedRepo(slug: "a/b", enabled: true, provider: "codex", model: "gpt-5"),
                                 Snapshot.WatchedRepo(slug: "c/d", enabled: false)])
        XCTAssertFalse(s.settings.skipBots)
        XCTAssertTrue(s.settings.skipDocsOnly)
        // an engine that predates the keys: the safe defaults
        let old = Snapshot(json: JSON.parse(#"{"repos":[{"slug":"a/b"}]}"#), config: JSON.parse("{}"))
        XCTAssertTrue(old.settings.skipBots)
        XCTAssertFalse(old.settings.skipDocsOnly)
        XCTAssertEqual(old.repos.first?.provider, "")
    }

    func testEditsSerialiseOnlyWhatChanged() throws {
        var e = ReviewEdits()
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(String(data: e.jsonData(), encoding: .utf8), "{}")

        e.dropped = ["f1"]
        e.edited["f1"] = FindingEdit(severity: .nit, title: nil, body: nil)   // dropped wins
        e.edited["f2"] = FindingEdit(severity: .blocker, title: "T", body: nil)
        e.summary = "hello"
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: e.jsonData()) as? [String: Any])
        XCTAssertEqual(obj["drop"] as? [String], ["f1"])
        let edit = try XCTUnwrap(obj["edit"] as? [String: [String: String]])
        XCTAssertNil(edit["f1"])
        XCTAssertEqual(edit["f2"], ["severity": "blocker", "title": "T"])
        XCTAssertEqual(obj["summary"] as? String, "hello")
    }
}
