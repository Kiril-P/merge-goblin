import Foundation

/// What each teammate's Goblin left on GitHub lately (`goblin fleet status --json`).
///
/// A Goblin with nothing to review leaves no trace, so this can say "active" or "last
/// seen" but never "offline": `unknown` means no sign, not dead.
struct FleetStatus: Equatable {
    enum Presence: String { case active, seen, unknown }

    struct Activity: Equatable, Identifiable {
        let repo: String
        let pr: Int
        let at: Date
        var id: String { "\(repo)#\(pr)" }
        var shortRef: String { "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(pr)" }
    }

    struct Member: Equatable, Identifiable {
        let login: String
        let isMe: Bool
        let presence: Presence
        let lastSeen: Date?
        let reviewing: [Activity]
        let recent: [Activity]
        var id: String { login }
    }

    let at: Date
    /// The engine could not reach GitHub and answered from its last good read.
    let stale: Bool
    let activeWindowSecs: Int
    let reposRead: Int
    let reposFailed: Int
    let members: [Member]

    init?(json: JSON) {
        guard json["ok"].bool(false) else { return nil }
        at = Date(timeIntervalSince1970: json["at"].double(0))
        stale = json["stale"].bool(false)
        activeWindowSecs = json["activeWindowSecs"].int(0)
        reposRead = json["reposRead"].int(0)
        reposFailed = json["reposFailed"].int(0)
        members = json["members"].array.compactMap { m in
            guard let login = m["login"].string, Pattern.githubLogin.accepts(login) else { return nil }
            func activity(_ a: JSON) -> Activity? {
                guard let repo = a["repo"].string, let pr = a["pr"].int, let at = a["at"].double else { return nil }
                return Activity(repo: repo, pr: pr, at: Date(timeIntervalSince1970: at))
            }
            let seen = m["lastSeen"].double
            return Member(login: login, isMe: m["me"].bool(false),
                          presence: Presence(rawValue: m["status"].string("")) ?? (seen == nil ? .unknown : .seen),
                          lastSeen: seen.map { Date(timeIntervalSince1970: $0) },
                          reviewing: m["reviewing"].array.compactMap(activity),
                          recent: m["recent"].array.compactMap(activity))
        }
    }

    init(at: Date, stale: Bool = false, activeWindowSecs: Int = 660, reposRead: Int = 1, reposFailed: Int = 0, members: [Member]) {
        self.at = at; self.stale = stale; self.activeWindowSecs = activeWindowSecs
        self.reposRead = reposRead; self.reposFailed = reposFailed; self.members = members
    }

    /// The engine's reason, when it answered with `ok: false`; nil for anything else.
    static func failure(_ json: JSON) -> String? {
        guard json.exists, !json["ok"].bool(false) else { return nil }
        return json["message"].string("Could not see what the team is doing.")
    }

    func member(_ login: String) -> Member? {
        members.first { $0.login.caseInsensitiveCompare(login) == .orderedSame }
    }
}
