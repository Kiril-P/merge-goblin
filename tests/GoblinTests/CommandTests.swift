import XCTest
@testable import Goblin

final class CommandTests: XCTestCase {
    private func argv(_ c: Command) throws -> [String] {
        guard case .cli(let argv, _, _, _) = try c.validatedPlan() else { XCTFail("not a CLI plan"); return [] }
        return argv
    }

    func testReviewByNumberIsDetachedAndPreviewFirst() throws {
        let ref = try XCTUnwrap(PRRef.parse("2456"))
        let a = try argv(.review(ref: ref, repo: "acme/widgets", mode: .preview, focus: .full,
                                 provider: nil, model: nil, force: false))
        XCTAssertEqual(a.prefix(3), ["review", "2456", "--detach"])
        XCTAssertTrue(a.contains("--preview"))
        XCTAssertFalse(a.contains("--post"))
        XCTAssertEqual(a.firstIndex(of: "--repo").map { a[$0 + 1] }, "acme/widgets")
    }

    func testARefsOwnRepoBeatsTheRepoArgument() throws {
        let ref = try XCTUnwrap(PRRef.parse("acme/widgets#5"))
        let a = try argv(.review(ref: ref, repo: "other/repo", mode: .post, focus: .security,
                                 provider: .codex, model: "gpt-5", force: true))
        XCTAssertEqual(a[1], "acme/widgets#5")
        XCTAssertFalse(a.contains("--repo"))
        XCTAssertTrue(a.contains("--post") && a.contains("--force"))
    }

    func testHostileValuesAreRefused() {
        let ref = PRRef.parse("1")!
        XCTAssertThrowsError(try Command.review(ref: ref, repo: "-x/y", mode: .preview, focus: .full,
                                                provider: nil, model: nil, force: false).validatedPlan())
        XCTAssertThrowsError(try Command.review(ref: ref, repo: nil, mode: .preview, focus: .full,
                                                provider: nil, model: "a b; rm", force: false).validatedPlan())
        XCTAssertThrowsError(try Command.postReview(job: "../etc").validatedPlan())
        XCTAssertThrowsError(try Command.repoAdd(slug: "no-slash").validatedPlan())
        XCTAssertThrowsError(try Command.repoAdd(slug: "--help/x").validatedPlan())
        XCTAssertThrowsError(try Command.repoSearch(query: "--help", limit: 5).validatedPlan())
        XCTAssertThrowsError(try Command.repoSearch(query: "ok", limit: 0).validatedPlan())
        XCTAssertThrowsError(try Command.setIdentity(login: "a;b").validatedPlan())
        XCTAssertThrowsError(try Command.openURL("file:///etc/passwd").validatedPlan())
        XCTAssertThrowsError(try Command.openURL("javascript:alert(1)").validatedPlan())
        XCTAssertNoThrow(try Command.openURL("https://github.com/acme/widgets/pull/1").validatedPlan())
    }

    func testEveryCaseBuildsAnArgvWithNoStrayFlags() throws {
        var all: [Command] = [
            .power(on: true), .pause, .resume, .snooze(kind: .hour), .reviewNow, .dryRun,
            .setMaxReviewsPerDay(5), .setMaxConcurrentJobs(2), .setManualReviewMode(.preview),
            .setVerdictMode(.comment), .setAllowApprove(false), .setProvider(.claude),
            .setProviderModel(provider: .claude, model: "sonnet"),
            .repoAdd(slug: "a/b"), .repoRemove(slug: "a/b"), .repoEnable(slug: "a/b", on: true),
            .setIdentity(login: "someone"), .doctor(fix: true), .accounts, .providers(refresh: true),
            .repoSearch(query: "wid", limit: 20), .wizardState, .githubLoginStart, .loginItem(on: true),
        ]
        all += FlagKey.allCases.map { .setFlag(key: $0, on: true) }
        for c in all {
            for element in try argv(c) where element.hasPrefix("-") {
                XCTAssertTrue(Command.allowedFlagLiterals.contains(element), "\(c): \(element)")
            }
        }
    }

    func testNoCaseCanSetAProviderBinaryOrAConfigPath() {
        // The reason this enum is closed: `config set .providers.claude.bin <x>` was
        // arbitrary code execution from the old panel.
        for key in FlagKey.allCases {
            XCTAssertFalse(key.cliName.contains("."), key.cliName)
            XCTAssertFalse(key.cliName.lowercased().contains("bin"), key.cliName)
        }
    }

    func testPatterns() {
        XCTAssertTrue(Pattern.jobId.accepts("j1700000000-1234"))
        XCTAssertFalse(Pattern.jobId.accepts("j170000000-1"))
        XCTAssertFalse(Pattern.jobId.accepts("j1700000000-"))
        XCTAssertTrue(Pattern.repoSlug.accepts("acme/widgets.js"))
        XCTAssertFalse(Pattern.repoSlug.accepts("acme/widgets/extra"))
        XCTAssertFalse(Pattern.githubLogin.accepts(String(repeating: "a", count: 40)))
        XCTAssertTrue(Pattern.model.accepts(""))
    }
}
