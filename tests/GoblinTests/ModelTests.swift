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
