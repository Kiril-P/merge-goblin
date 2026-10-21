import XCTest
@testable import Goblin

final class ModelCatalogTests: XCTestCase {
    private func opts(_ pairs: [(String, String)]) -> [ModelOption] { pairs.map { ModelOption(id: $0.0, label: $0.1) } }

    func testVendors() {
        XCTAssertEqual(ModelCatalog.vendor(of: "claude-opus-5-thinking-high"), "Claude")
        XCTAssertEqual(ModelCatalog.vendor(of: "sonnet"), "Claude")
        XCTAssertEqual(ModelCatalog.vendor(of: "gpt-5.6-sol-high"), "GPT")
        XCTAssertEqual(ModelCatalog.vendor(of: "cursor-grok-4.5-high"), "Grok")
        XCTAssertEqual(ModelCatalog.vendor(of: "composer-2.5"), "Cursor")
        XCTAssertEqual(ModelCatalog.vendor(of: "something-new"), "Other")
    }

    func testVariantsCollapseIntoOneFamily() {
        XCTAssertEqual(ModelCatalog.familyKey(of: "claude-opus-5-thinking-high-fast"), "claude-opus-5")
        XCTAssertEqual(ModelCatalog.familyKey(of: "gpt-5.3-codex-xhigh-fast"), "gpt-5.3-codex")
        XCTAssertEqual(ModelCatalog.familyKey(of: "gpt-5.3-codex"), "gpt-5.3-codex")
        XCTAssertEqual(ModelCatalog.familyKey(of: "auto"), "auto")
        XCTAssertEqual(ModelCatalog.familyKey(of: "high"), "high", "never strips an id down to nothing")
    }

    func testGroupingKeepsEveryModelOnce() {
        let all = opts([
            ("claude-opus-5-thinking-high", "Claude Opus 5 1M Thinking"),
            ("claude-opus-5-thinking-high-fast", "Claude Opus 5 1M Thinking Fast"),
            ("claude-sonnet-5-thinking-high", "Claude Sonnet 5 1M Thinking"),
            ("gpt-5.6-sol-high", "GPT-5.6 Sol 1M High"),
            ("auto", "Auto"),
        ])
        let groups = ModelCatalog.grouped(all)
        XCTAssertEqual(groups.map(\.vendor), ["Claude", "GPT", "Cursor"])
        XCTAssertEqual(groups[0].families.map(\.title), ["Claude Opus 5", "Claude Sonnet 5"])
        XCTAssertEqual(groups[0].families[0].options.count, 2)
        XCTAssertEqual(groups.flatMap(\.families).flatMap(\.options).count, all.count)
    }

    func testParseDropsUnsafeAndDuplicateIds() {
        let json = JSON.parse(#"[{"id":"a","label":"A"},{"id":"a","label":"again"},{"id":"--help","label":"x"},{"id":"b c","label":"y"},{"label":"no id"}]"#)
        XCTAssertEqual(ModelCatalog.parse(json).map(\.id), ["a"])
    }

    func testLabelFallsBackToTheRawId() {
        let o = opts([("sonnet", "Sonnet (latest)")])
        XCTAssertEqual(ModelCatalog.label(for: "sonnet", in: o), "Sonnet (latest)")
        XCTAssertEqual(ModelCatalog.label(for: "", in: o), "Provider default")
        XCTAssertEqual(ModelCatalog.label(for: "hand-edited", in: o), "hand-edited")
    }
}
