import XCTest
@testable import Goblin

/// Decodes files the real engine wrote (a preview-only review of a public PR, run with
/// the real gh and claude), so the app's models are checked against what the CLI
/// actually emits rather than JSON written to match them.
final class RealOutputTests: XCTestCase {
    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)").path
    }

    func testRealReviewDecodes() throws {
        let preview = try XCTUnwrap(ReviewPreview(json: JSON.read(path: fixture("real-review.json"))))
        XCTAssertEqual(preview.repo, "Kiril-P/merge-goblin")
        XCTAssertEqual(preview.number, 4)
        XCTAssertFalse(preview.summary.isEmpty)
        XCTAssertEqual(preview.findings.count, 3)
        XCTAssertEqual(Set(preview.findings.map(\.id)).count, 3, "ids are stable and unique: edits are keyed by them")
        for f in preview.findings {
            XCTAssertNotNil(f.path); XCTAssertNotNil(f.line); XCTAssertFalse(f.title.isEmpty)
            XCTAssertEqual(f.severity, .risk)
        }
        XCTAssertGreaterThan(preview.files, 0)
    }

    func testRealJobDecodes() throws {
        var job = try XCTUnwrap(Job(json: JSON.read(path: fixture("real-job.json"))))
        XCTAssertEqual(job.phase, .ready)
        XCTAssertEqual(job.ref, "Kiril-P/merge-goblin#4")
        XCTAssertEqual(job.findingCount, 3)
        job.reconcile()    // a finished job is never rewritten, whatever its pid says
        XCTAssertEqual(job.phase, .ready)
    }

    func testEditsOverARealReviewMatchTheEngineContract() throws {
        let preview = try XCTUnwrap(ReviewPreview(json: JSON.read(path: fixture("real-review.json"))))
        var edits = ReviewEdits()
        edits.dropped = [preview.findings[0].id]
        edits.edited[preview.findings[1].id] = FindingEdit(severity: .nit, title: "Reworded", body: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: edits.jsonData()) as? [String: Any])
        // review_apply_edits only accepts these keys; anything else and the post is refused
        XCTAssertTrue(Set(obj.keys).isSubset(of: ["drop", "edit", "summary"]))
        XCTAssertEqual(obj["drop"] as? [String], [preview.findings[0].id])
    }
}
