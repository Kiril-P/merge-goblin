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

    func testInstallUpdateIsOneFixedArgvOnTheLongestWatchdog() throws {
        guard case .cli(let argv, let timeout, let mutating, let json) = try Command.installUpdate.validatedPlan() else {
            return XCTFail("installUpdate must run the CLI")
        }
        // No value travels with it: the engine alone picks the release, the asset and
        // the destination, so nothing in the UI can redirect the download.
        XCTAssertEqual(argv, ["update", "install", "--json", "--relaunch"])
        XCTAssertEqual(timeout, .update)
        XCTAssertTrue(mutating, "serialised with other writes, and followed by a state reload")
        XCTAssertTrue(json)
        // A download on a slow line must outlast every other watchdog, including a post.
        let others: [TimeoutClass] = [.read, .mutation, .doctor, .discovery, .post]
        for other in others { XCTAssertGreaterThan(timeout.seconds, other.seconds) }
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
            .power(on: true), .pause, .resume, .dismissFailures, .snooze(kind: .hour), .reviewNow, .dryRun,
            .setMaxReviewsPerDay(5), .setMaxConcurrentJobs(2), .setManualReviewMode(.preview),
            .setVerdictMode(.comment), .setAllowApprove(false), .setProvider(.claude),
            .setProviderModel(provider: .claude, model: "sonnet"),
            .repoAdd(slug: "a/b"), .repoRemove(slug: "a/b"), .repoEnable(slug: "a/b", on: true),
            .setRepoProvider(slug: "a/b", provider: .cursor, model: "x"),
            .setRepoProvider(slug: "a/b", provider: nil, model: ""),
            .setIdentity(login: "someone"), .doctor(fix: true), .accounts, .providers(refresh: true),
            .stats(days: 30, refresh: true), .fleetStatus(refresh: true), .fleetStatus(refresh: false),
            .repoSearch(query: "wid", limit: 20), .wizardState, .githubLoginStart, .loginItem(on: true),
            .installUpdate,
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

    func testRepoProviderGoesThroughThePanelAndIsValidated() throws {
        XCTAssertEqual(try argv(.setRepoProvider(slug: "acme/widgets", provider: .codex, model: "gpt-5")),
                       ["panel", "set", "repo-provider", "acme/widgets", "codex", "gpt-5"])
        // back to the global provider: the model goes with it
        XCTAssertEqual(try argv(.setRepoProvider(slug: "acme/widgets", provider: nil, model: "gpt-5")),
                       ["panel", "set", "repo-provider", "acme/widgets", "default", ""])
        XCTAssertThrowsError(try Command.setRepoProvider(slug: "-x/y", provider: .claude, model: "").validatedPlan())
        XCTAssertThrowsError(try Command.setRepoProvider(slug: "a/b", provider: .claude, model: "--help").validatedPlan())
        XCTAssertThrowsError(try Command.setRepoProvider(slug: "a/b", provider: .claude, model: "x y").validatedPlan())
    }

    func testSkipFlagsUseTheCLINames() throws {
        XCTAssertEqual(try argv(.setFlag(key: .skipBots, on: false)), ["panel", "set", "flag", "skip-bots", "off"])
        XCTAssertEqual(try argv(.setFlag(key: .skipDocsOnly, on: true)), ["panel", "set", "flag", "skip-docs-only", "on"])
        XCTAssertEqual(try argv(.setProviderFallback(.codex)), ["panel", "set", "provider-fallback", "codex"])
        XCTAssertEqual(try argv(.setProviderFallback(nil)), ["panel", "set", "provider-fallback", "none"])
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
