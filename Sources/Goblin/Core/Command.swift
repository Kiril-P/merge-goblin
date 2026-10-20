//  Command.swift — the allowlist.
//
//  Everything the app is allowed to ask the CLI for lives in this one file, as a
//  closed enum plus a static table that builds the argv. Nothing else in the app may
//  construct a CLI argument list.
//
//  (It used to also parse messages from a web view. The UI is native now, so a value
//  arrives as a typed Swift enum and the only free-form strings left are the ones
//  validated by `Pattern` below.)
//
//  It imports Foundation and NOTHING ELSE — no AppKit, no WebKit — so unit tests
//  can compile and exercise it headlessly, with no window server and no bundle.
//  If you ever need AppKit here, you have put the wrong thing in this file.
//
//  Why this is stricter than a verb-plus-arity allowlist:
//
//      "config": 3 would permit  `goblin config set <any jq path> <any value>`,
//      which is the whole config plane — including `.providers.claude.bin`,
//      i.e. "run this binary as me, on a timer, forever". A verb+arity check can
//      never close that; only naming the individual settings can. So there is
//      deliberately NO case here that takes a config path, and NO case that can
//      set a provider binary path.
//
//  Hard rules, all failing closed:
//    * no element of a built argv may begin with "-" unless it is one of the
//      literal flags in `Command.allowedFlagLiterals`
//    * every free-form value is validated by a `Pattern` before it is stored in a
//      Command, so an invalid value cannot be represented, only refused

import Foundation

// MARK: - Errors

/// The single failure mode of parsing. `reason` is developer-facing English and
/// safe to show in the panel; it never echoes the offending value.
struct CommandRefusal: Error, Equatable, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}

// MARK: - Closed value types

//
// Every free-form-looking argument is one of these, so "unexpected string" is
// unrepresentable rather than merely unlikely.

enum SnoozeKind: String, CaseIterable {
    case hour, tomorrow, clear
}

enum VerdictMode: String, CaseIterable {
    case comment
    case requestChanges = "request-changes"
    case full
}

enum ProviderId: String, CaseIterable {
    case claude, codex, cursor
}

enum ReviewMode: String, CaseIterable {
    case preview, post
}

enum ReviewFocus: String, CaseIterable {
    case full, security, summary
}

enum AgentAction: String, CaseIterable {
    case install, start, stop, reload
}

/// The boolean settings the panel may flip. Closed on purpose: this is the list
/// that stops `setFlag` from becoming `config set <path>` by another name.
enum FlagKey: String, CaseIterable {
    case incrementalReview
    case postCommitStatus
    case fleetAssignment
    case notifyStarted
    case notifyPosted
    case notifyFailed
    case notifyBudget
    case notifySound
    case skipIfHumanReviewed

    /// The name bash sees. Kebab-case because that is the CLI's convention.
    var cliName: String {
        switch self {
        case .incrementalReview: return "incremental-review"
        case .postCommitStatus:  return "post-commit-status"
        case .fleetAssignment:   return "fleet-assignment"
        case .notifyStarted:     return "notify-started"
        case .notifyPosted:      return "notify-posted"
        case .notifyFailed:      return "notify-failed"
        case .notifyBudget:      return "notify-budget"
        case .notifySound:       return "notify-sound"
        case .skipIfHumanReviewed: return "skip-if-human-reviewed"
        }
    }
}

// MARK: - How long a command may take, and who serialises it

enum TimeoutClass {
    case read           // reads a file or a cached blob
    case mutation       // writes config/state
    case doctor         // probes github + providers + clones
    case discovery      // network listing (repo search, account list)

    var seconds: TimeInterval {
        switch self {
        case .read:      return 10
        case .mutation:  return 30
        case .doctor:    return 60
        case .discovery: return 45
        }
    }
}

/// Things Swift does itself rather than shelling out for. Opening a file or a URL
/// through a subprocess would mean `open(1)` with an attacker-influenced
/// argument; `NSWorkspace` with a path we computed cannot be talked into
/// anything, and needs no allowlist of its own.
enum LocalAction: Equatable {
    case openLog
    case openConfig
    case openURL(String)      // already validated to be https://
    case copyDiagnostics
}

/// The result of parsing: either an argv to hand to the CLI, or something local.
enum Plan: Equatable {
    /// - Parameters:
    ///   - argv: the exact arguments, in order. Never passed through a shell.
    ///   - timeout: which watchdog applies.
    ///   - mutating: true => runs on the `mutations` queue and triggers a state
    ///     reload afterwards. false => runs on the `reads` queue.
    ///   - json: stdout is expected to be a single JSON document.
    case cli(argv: [String], timeout: TimeoutClass, mutating: Bool, json: Bool)
    case local(LocalAction)
}

// MARK: - The commands

enum Command: Equatable {
    // power / scheduling
    case power(on: Bool)
    case pause
    case resume
    case snooze(kind: SnoozeKind)

    // reviewing
    case reviewNow
    case dryRun

    // review one PR on demand (see lib/review.sh)
    case review(ref: PRRef, repo: String?, mode: ReviewMode, focus: ReviewFocus,
                provider: ProviderId?, model: String?, force: Bool)
    case resolve(ref: PRRef, repo: String?)
    case postReview(job: String)         // publishes jobs/<id>/edits.json over the preview
    case cancelJob(job: String)          // stops a running job, or discards a waiting review
    case pruneJobs

    // budgets and limits
    case setMaxReviewsPerDay(Int)      // 0...500   (0 = no cap)
    case setMaxReviewsPerRun(Int)      // 1...50
    case setMaxFindings(Int)           // 1...200
    case setIntervalMinutes(Int)       // 1...1440
    case setMaxConcurrentJobs(Int)     // 1...8
    case setManualReviewMode(ReviewMode)

    // review behaviour
    case setVerdictMode(VerdictMode)
    case setAllowApprove(Bool)
    case setFlag(key: FlagKey, on: Bool)

    // provider
    case setProvider(ProviderId)
    case setProviderModel(provider: ProviderId, model: String)   // ^[A-Za-z0-9._:-]{0,64}$

    // repos
    case repoAdd(slug: String)
    case repoRemove(slug: String)
    case repoEnable(slug: String, on: Bool)

    // teammates who also run the Goblin
    case fleetAdd(login: String)
    case fleetRemove(login: String)

    // identity
    case setIdentity(login: String)    // ^[A-Za-z0-9-]{1,39}$
    case fixAccount

    // diagnostics / plumbing
    case doctor(fix: Bool)
    case agent(AgentAction)

    // reads
    case state
    case inbox(refresh: Bool)
    case accounts
    case providers(refresh: Bool)
    case providerModels(ProviderId, refresh: Bool)
    case repoSearch(query: String, limit: Int)   // query ^[A-Za-z0-9 ._/-]{0,80}$, limit 1...200

    // first-run wizard
    case wizardState
    case wizardComplete
    case githubLoginStart
    case githubLoginStatus

    // the app itself
    case loginItem(on: Bool)
    case openLog
    case openConfig
    case openURL(String)
    case copyDiagnostics

    /// The only argv elements allowed to start with "-". Anything else that does
    /// is a refusal, which is what stops a validated-but-hostile value (a repo
    /// slug of "-x/y", a search query of "--help") from turning into a flag.
    static let allowedFlagLiterals: Set<String> = [
        "--json", "--fix", "--refresh", "--limit", "--query",
        "--detach", "--post", "--preview", "--force", "--repo", "--focus", "--provider", "--model", "--saved-edits",
    ]

    // MARK: - argv

    var plan: Plan {
        switch self {
        case .power(let on):
            return .cli(argv: [on ? "on" : "off"], timeout: .mutation, mutating: true, json: false)
        case .pause:
            return .cli(argv: ["pause"], timeout: .mutation, mutating: true, json: false)
        case .resume:
            return .cli(argv: ["resume"], timeout: .mutation, mutating: true, json: false)
        case .snooze(let kind):
            let verb: String
            switch kind {
            case .hour:     verb = "snooze1h"
            case .tomorrow: verb = "snoozetomorrow"
            case .clear:    verb = "clearsnooze"
            }
            return .cli(argv: [verb], timeout: .mutation, mutating: true, json: false)

        case .reviewNow:
            // run-now detaches in bash. The app must never be the parent of a
            // fifteen-minute review: quitting the app would take the review with it.
            return .cli(argv: ["run-now"], timeout: .mutation, mutating: true, json: false)
        case .dryRun:
            return .cli(argv: ["panel", "dry-run"], timeout: .mutation, mutating: true, json: false)

        case .review(let ref, let repo, let mode, let focus, let provider, let model, let force):
            // --detach: the app must never be the parent of a review. Quitting the app
            // would take it with it, and a review is minutes long.
            var argv = ["review", ref.canonical, "--detach", "--json",
                        mode == .post ? "--post" : "--preview", "--focus", focus.rawValue]
            if let repo, ref.slug == nil { argv += ["--repo", repo] }
            if let provider { argv += ["--provider", provider.rawValue] }
            if let model, !model.isEmpty { argv += ["--model", model] }
            if force { argv.append("--force") }
            return .cli(argv: argv, timeout: .mutation, mutating: true, json: true)
        case .resolve(let ref, let repo):
            var argv = ["resolve", ref.canonical, "--json"]
            if let repo, ref.slug == nil { argv += ["--repo", repo] }
            return .cli(argv: argv, timeout: .discovery, mutating: false, json: true)
        case .postReview(let job):
            return .cli(argv: ["post", job, "--saved-edits", "--json"],
                        timeout: .discovery, mutating: true, json: true)
        case .cancelJob(let job):
            return .cli(argv: ["cancel", job], timeout: .mutation, mutating: true, json: false)
        case .pruneJobs:
            return .cli(argv: ["jobs", "prune"], timeout: .mutation, mutating: true, json: false)

        case .setMaxReviewsPerDay(let n):
            return Command.panelSet("max-per-day", String(n))
        case .setMaxReviewsPerRun(let n):
            return Command.panelSet("max-per-run", String(n))
        case .setMaxFindings(let n):
            return Command.panelSet("max-findings", String(n))
        case .setIntervalMinutes(let n):
            return Command.panelSet("interval-minutes", String(n))

        case .setMaxConcurrentJobs(let n):
            return Command.panelSet("max-jobs", String(n))
        case .setManualReviewMode(let mode):
            return Command.panelSet("manual-mode", mode.rawValue)

        case .setVerdictMode(let mode):
            return Command.panelSet("verdict-mode", mode.rawValue)
        case .setAllowApprove(let on):
            return Command.panelSet("allow-approve", on ? "on" : "off")
        case .setFlag(let key, let on):
            return Command.panelSet("flag", key.cliName, on ? "on" : "off")

        case .setProvider(let id):
            return .cli(argv: ["provider", "use", id.rawValue], timeout: .discovery, mutating: true, json: false)
        case .setProviderModel(let provider, let model):
            return Command.panelSet("provider-model", provider.rawValue, model)

        case .repoAdd(let slug):
            return .cli(argv: ["repos", "add", slug], timeout: .mutation, mutating: true, json: false)
        case .repoRemove(let slug):
            return .cli(argv: ["repos", "rm", slug], timeout: .mutation, mutating: true, json: false)
        case .repoEnable(let slug, let on):
            return .cli(argv: ["repos", on ? "enable" : "disable", slug],
                        timeout: .mutation, mutating: true, json: false)

        case .fleetAdd(let login):
            return .cli(argv: ["fleet", "add", login], timeout: .mutation, mutating: true, json: false)
        case .fleetRemove(let login):
            return .cli(argv: ["fleet", "rm", login], timeout: .mutation, mutating: true, json: false)

        case .setIdentity(let login):
            return Command.panelSet("identity", login)
        case .fixAccount:
            return .cli(argv: ["fix-account"], timeout: .mutation, mutating: true, json: false)

        case .doctor(let fix):
            return .cli(argv: fix ? ["doctor", "--fix", "--json"] : ["doctor", "--json"],
                        timeout: .doctor, mutating: fix, json: true)
        case .agent(let action):
            return .cli(argv: ["agent", action.rawValue], timeout: .mutation, mutating: true, json: false)

        case .state:
            return .cli(argv: ["status", "--json"], timeout: .read, mutating: false, json: true)
        case .inbox(let refresh):
            return .cli(argv: refresh ? ["inbox", "--refresh", "--json"] : ["inbox", "--json"],
                        timeout: refresh ? .discovery : .read, mutating: false, json: true)
        case .accounts:
            return .cli(argv: ["accounts", "--json"], timeout: .discovery, mutating: false, json: true)
        case .providers(let refresh):
            return .cli(argv: refresh ? ["provider", "list", "--refresh", "--json"]
                                      : ["provider", "list", "--json"],
                        timeout: .discovery, mutating: false, json: true)
        case .providerModels(let provider, let refresh):
            return .cli(argv: ["provider", "models", provider.rawValue] + (refresh ? ["--refresh"] : []),
                        timeout: .discovery, mutating: false, json: true)
        case .repoSearch(let query, let limit):
            return .cli(argv: ["repo-search", "--json", "--limit", String(limit), "--query", query],
                        timeout: .discovery, mutating: false, json: true)

        case .wizardState:
            return .cli(argv: ["wizard", "state", "--json"], timeout: .read, mutating: false, json: true)
        case .wizardComplete:
            return .cli(argv: ["panel", "set", "setup-complete", "on"], timeout: .mutation, mutating: true, json: false)
        case .githubLoginStart:
            return .cli(argv: ["github-login", "start"], timeout: .mutation, mutating: true, json: true)
        case .githubLoginStatus:
            return .cli(argv: ["github-login", "status"], timeout: .read, mutating: false, json: true)

        case .loginItem(let on):
            return .cli(argv: ["app", "login-item", on ? "on" : "off"],
                        timeout: .mutation, mutating: true, json: false)

        case .openLog:         return .local(.openLog)
        case .openConfig:      return .local(.openConfig)
        case .openURL(let u):  return .local(.openURL(u))
        case .copyDiagnostics: return .local(.copyDiagnostics)
        }
    }

    /// Every named setting goes through `goblin panel set <name> <value...>`.
    /// One bash entry point, one place to audit, and no jq path in sight.
    private static func panelSet(_ name: String, _ values: String...) -> Plan {
        .cli(argv: ["panel", "set", name] + values, timeout: .mutation, mutating: true, json: false)
    }

    /// The argv after the final safety check. `plan` is the table; this is the
    /// gate. Bridge must call this, never `plan` directly.
    func validatedPlan() throws -> Plan {
        // Structured arguments are checked here, before the argv is built, so that a
        // Command holding a bad repo or job id is refused rather than run.
        switch self {
        case .review(_, let repo, _, _, _, let model, _):
            if let repo, !Pattern.repoSlug.accepts(repo) { throw CommandRefusal("repo is not in the accepted format") }
            if let model, !Pattern.model.accepts(model) { throw CommandRefusal("model is not in the accepted format") }
        case .resolve(_, let repo):
            if let repo, !Pattern.repoSlug.accepts(repo) { throw CommandRefusal("repo is not in the accepted format") }
        case .postReview(let job), .cancelJob(let job):
            if !Pattern.jobId.accepts(job) { throw CommandRefusal("not a job id") }
        case .repoAdd(let slug), .repoRemove(let slug), .repoEnable(let slug, _):
            if !Pattern.repoSlug.accepts(slug) { throw CommandRefusal("repo is not in the accepted format") }
        case .setIdentity(let login), .fleetAdd(let login), .fleetRemove(let login):
            if !Pattern.githubLogin.accepts(login) { throw CommandRefusal("login is not in the accepted format") }
        case .setProviderModel(_, let model):
            if !Pattern.model.accepts(model) { throw CommandRefusal("model is not in the accepted format") }
        case .repoSearch(let q, let limit):
            if !Pattern.searchQuery.accepts(q) || !(1...200).contains(limit) { throw CommandRefusal("bad search") }
        case .openURL(let u):
            guard Command.isHTTPS(u) else { throw CommandRefusal("only https links can be opened") }
        default: break
        }
        let p = plan
        if case .cli(let argv, _, _, _) = p {
            guard !argv.isEmpty else { throw CommandRefusal("empty argv") }
            for element in argv {
                if element.hasPrefix("-") && !Command.allowedFlagLiterals.contains(element) {
                    throw CommandRefusal("argument would be read as a flag")
                }
                guard !element.contains("\0") else { throw CommandRefusal("argument contains NUL") }
            }
        }
        return p
    }
}

extension Command {
    static func isHTTPS(_ raw: String) -> Bool {
        guard raw.count <= 2048, raw.hasPrefix("https://"),
              !raw.contains(where: { $0 == "\0" || $0.isNewline }),
              let comps = URLComponents(string: raw), comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty, host.count <= 253 else { return false }
        return true
    }
}

// MARK: - Patterns
//
// Hand-rolled character scanning rather than NSRegularExpression: the accepted
// sets are tiny, the check is obviously total, and there is no regex engine in
// the path of untrusted input.

enum Pattern {
    case repoSlug       // ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$
    case githubLogin    // ^[A-Za-z0-9-]{1,39}$
    case model          // ^[A-Za-z0-9._:-]{0,64}$
    case searchQuery    // ^[A-Za-z0-9 ._/-]{0,80}$
    case jobId          // ^j[0-9]{10}-[0-9]{1,6}$

    func accepts(_ s: String) -> Bool {
        switch self {
        case .repoSlug:
            let parts = s.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].first?.isLetter == true || parts[0].first?.isASCIIDigit == true,
                  parts[0].first?.isASCII == true else { return false }
            return parts.allSatisfy {
                Pattern.every($0, in: Pattern.slugChars, count: 1...100)
            }
        case .githubLogin:
            return Pattern.every(s[...], in: Pattern.loginChars, count: 1...39)
        case .model:
            return Pattern.every(s[...], in: Pattern.modelChars, count: 0...64)
        case .searchQuery:
            return Pattern.every(s[...], in: Pattern.queryChars, count: 0...80)
        case .jobId:
            guard s.hasPrefix("j"), let dash = s.firstIndex(of: "-") else { return false }
            let stamp = s[s.index(after: s.startIndex)..<dash], tail = s[s.index(after: dash)...]
            return stamp.count == 10 && stamp.allSatisfy(\.isASCIIDigit)
                && (1...6).contains(tail.count) && tail.allSatisfy(\.isASCIIDigit)
        }
    }

    private static let slugChars  = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let loginChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    private static let modelChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    private static let queryChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-")

    private static func every(_ s: Substring, in allowed: Set<Character>, count: ClosedRange<Int>) -> Bool {
        guard count.contains(s.count) else { return false }
        return s.allSatisfy { allowed.contains($0) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
