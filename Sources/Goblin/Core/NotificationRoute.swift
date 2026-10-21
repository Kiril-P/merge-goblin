import Foundation

/// What a banner carries, and what a click or a button on it does.
///
/// Plain Foundation on purpose (no UserNotifications) so the decision is unit-tested:
/// the app only translates between this and UNNotification. The ids are the engine's
/// (`notify_payload` in lib/core.sh) and are validated again here, because notify.jsonl
/// is a file anything running as the user can append to.
enum NotificationRoute {
    static let readyCategory = "goblin.ready"
    static let postAction = "goblin.post"
    static let openAction = "goblin.open"
    /// UNNotificationDismissActionIdentifier, spelled out to keep this file Foundation-only.
    static let dismissAction = "com.apple.UNNotificationDismissActionIdentifier"

    enum Action: Equatable {
        case post(job: String)
        case open(job: String)
        case none
    }

    /// The category that puts Post / Open on a banner: only a finished preview with a
    /// job behind it. Everything else is a plain banner.
    static func category(kind: String, job: String?) -> String? {
        guard kind == "ready", let job, Pattern.jobId.accepts(job) else { return nil }
        return readyCategory
    }

    static func userInfo(kind: String, job: String?) -> [String: String] {
        var info = ["kind": kind]
        if let job, Pattern.jobId.accepts(job) { info["jobId"] = job }
        return info
    }

    /// - Parameter phase: the job's phase NOW, or nil if it is not on disk. A banner can
    ///   sit in Notification Center for hours; "Post" on one whose review was since
    ///   posted, discarded or re-run must not post, it only opens what is there.
    static func decide(action: String, userInfo: [AnyHashable: Any], phase: JobPhase?) -> Action {
        guard let job = userInfo["jobId"] as? String, Pattern.jobId.accepts(job) else { return .none }
        switch action {
        case dismissAction: return .none
        case postAction: return phase == .ready ? .post(job: job) : .open(job: job)
        default: return .open(job: job)     // a click on the banner, or "Open"
        }
    }
}
