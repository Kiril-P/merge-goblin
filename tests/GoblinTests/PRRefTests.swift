import XCTest
@testable import Goblin

/// The same table as test_ref_parse in tests/run.sh. If one changes, change both.
final class PRRefTests: XCTestCase {
    func testAccepted() {
        let cases: [(String, String?, Int)] = [
            ("2456", nil, 2456),
            ("#2456", nil, 2456),
            ("  2456 ", nil, 2456),
            ("acme/widgets#2456", "acme/widgets", 2456),
            ("https://github.com/acme/widgets/pull/2456", "acme/widgets", 2456),
            ("https://github.com/acme/widgets/pull/2456/files?x=1#y", "acme/widgets", 2456),
        ]
        for (input, slug, number) in cases {
            let ref = PRRef.parse(input)
            XCTAssertEqual(ref?.slug, slug, input)
            XCTAssertEqual(ref?.number, number, input)
        }
    }

    func testRefused() {
        for input in ["", "abc", "0", "-5", "123456789", "a b/c#1",
                      "acme/widgets#1; rm -rf /",
                      "https://github.com/acme/widgets/issues/5"] {
            XCTAssertNil(PRRef.parse(input), input)
        }
    }

    func testCanonicalNeverLooksLikeAFlag() {
        XCTAssertEqual(PRRef.parse("#7")?.canonical, "7")
        XCTAssertEqual(PRRef.parse("a/b#7")?.canonical, "a/b#7")
        XCTAssertNil(PRRef.parse("-x/y#7"), "a slug starting with - would become a flag")
    }

    func testClipboardFindsALinkButNotABareNumber() {
        XCTAssertEqual(PRRef.firstLink(in: "look: https://github.com/acme/widgets/pull/9 thanks")?.number, 9)
        XCTAssertEqual(PRRef.firstLink(in: "(see https://github.com/acme/widgets/pull/9)")?.slug, "acme/widgets")
        XCTAssertNil(PRRef.firstLink(in: "2456"))
        XCTAssertNil(PRRef.firstLink(in: "https://github.com/acme/widgets/issues/9"))
    }
}
