import XCTest
@testable import Goblin

final class FleetStatusTests: XCTestCase {
    /// The shape `goblin fleet status --json` prints (see tests/fleet_test.sh).
    private let sample = #"""
    {"ok":true,"at":1792526110,"me":"me","intervalSeconds":300,"activeWindowSecs":660,"reposRead":1,"reposFailed":0,
     "members":[
      {"login":"alice","me":false,"lastSeen":1792526050,"status":"active","reviewing":[{"repo":"acme/widgets","pr":12,"at":1792526050}],"recent":[{"repo":"acme/widgets","pr":10,"at":1792519110}]},
      {"login":"bob","me":false,"lastSeen":1792439710,"status":"seen","reviewing":[],"recent":[{"repo":"acme/widgets","pr":9,"at":1792439710}]},
      {"login":"carol","me":false,"lastSeen":null,"status":"unknown","reviewing":[],"recent":[]},
      {"login":"me","me":true,"lastSeen":1792526080,"status":"active","reviewing":[],"recent":[]},
      {"login":"bad login!","me":false,"status":"active"}]}
    """#

    func testDecodesMembers() throws {
        let s = try XCTUnwrap(FleetStatus(json: JSON.parse(sample)))
        XCTAssertEqual(s.members.map(\.login), ["alice", "bob", "carol", "me"], "a login GitHub could not have is dropped")
        XCTAssertFalse(s.stale)
        let alice = try XCTUnwrap(s.member("ALICE"))
        XCTAssertEqual(alice.presence, .active)
        XCTAssertEqual(alice.reviewing.map(\.shortRef), ["widgets#12"])
        XCTAssertEqual(alice.recent.first?.pr, 10)
        XCTAssertEqual(s.member("bob")?.presence, .seen)
        XCTAssertNil(s.member("carol")?.lastSeen)
        XCTAssertEqual(s.member("carol")?.presence, .unknown)
        XCTAssertEqual(s.member("me")?.isMe, true)
    }

    func testFailuresAndStaleness() throws {
        XCTAssertNil(FleetStatus(json: JSON.parse(#"{"ok":false,"error":"unreachable","message":"Could not reach GitHub."}"#)))
        XCTAssertEqual(FleetStatus.failure(JSON.parse(#"{"ok":false,"error":"unreachable","message":"Could not reach GitHub."}"#)),
                       "Could not reach GitHub.")
        XCTAssertNil(FleetStatus.failure(JSON.parse(sample)))
        XCTAssertNil(FleetStatus(json: JSON.parse("garbage")))
        let stale = try XCTUnwrap(FleetStatus(json: JSON.parse(#"{"ok":true,"stale":true,"at":1,"members":[]}"#)))
        XCTAssertTrue(stale.stale)
        XCTAssertTrue(stale.members.isEmpty)
    }

    func testCommand() throws {
        guard case .cli(let a, let t, let mutating, let json) = try Command.fleetStatus(refresh: false).validatedPlan() else {
            return XCTFail("not a CLI plan")
        }
        XCTAssertEqual(a, ["fleet", "status", "--json"])
        XCTAssertFalse(mutating, "reading the team's status changes nothing")
        XCTAssertTrue(json)
        XCTAssertEqual(t, .doctor)
        guard case .cli(let b, _, _, _) = try Command.fleetStatus(refresh: true).validatedPlan() else { return XCTFail() }
        XCTAssertEqual(b.last, "--refresh")
    }
}

final class NotificationRouteTests: XCTestCase {
    private let job = "j1792526000-12345"
    private var info: [AnyHashable: Any] { NotificationRoute.userInfo(kind: "ready", job: job) }

    func testOnlyAReadyBannerWithAJobGetsButtons() {
        XCTAssertEqual(NotificationRoute.category(kind: "ready", job: job), NotificationRoute.readyCategory)
        XCTAssertNil(NotificationRoute.category(kind: "posted", job: job))
        XCTAssertNil(NotificationRoute.category(kind: "ready", job: nil))
        XCTAssertNil(NotificationRoute.category(kind: "ready", job: "../../etc"))
        XCTAssertNil(NotificationRoute.userInfo(kind: "ready", job: "j1; rm")["jobId"])
    }

    func testPostOnlyWhileStillReady() {
        XCTAssertEqual(NotificationRoute.decide(action: NotificationRoute.postAction, userInfo: info, phase: .ready), .post(job: job))
        for phase in [JobPhase.done, .posting, .discarded, .failed, .reviewing] {
            XCTAssertEqual(NotificationRoute.decide(action: NotificationRoute.postAction, userInfo: info, phase: phase), .open(job: job),
                           "\(phase): a stale banner opens the review, it never posts")
        }
        XCTAssertEqual(NotificationRoute.decide(action: NotificationRoute.postAction, userInfo: info, phase: nil), .open(job: job))
    }

    func testClickAndOpenOpenThatJob() {
        XCTAssertEqual(NotificationRoute.decide(action: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info, phase: .ready),
                       .open(job: job))
        XCTAssertEqual(NotificationRoute.decide(action: NotificationRoute.openAction, userInfo: info, phase: .done), .open(job: job))
        XCTAssertEqual(NotificationRoute.decide(action: NotificationRoute.dismissAction, userInfo: info, phase: .ready), .none)
    }

    func testABannerWithoutAJobDoesNothing() {
        XCTAssertEqual(NotificationRoute.decide(action: NotificationRoute.postAction, userInfo: ["kind": "posted"], phase: .ready), .none)
        XCTAssertEqual(NotificationRoute.decide(action: "x", userInfo: ["jobId": "not-a-job"], phase: .ready), .none)
        XCTAssertEqual(NotificationRoute.decide(action: "x", userInfo: ["jobId": 42], phase: .ready), .none)
    }
}
