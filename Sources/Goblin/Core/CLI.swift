//  CLI.swift — the only place this app starts a process.
//
//  Rules that are not negotiable:
//
//    * executableURL comes from the Info.plist key GBLCLIPath, written at install
//      time. A GUI-launched app inherits PATH=/usr/bin:/bin:/usr/sbin:/sbin, so
//      "goblin" is not on it. Searching for the CLI would mean picking up
//      whatever is first on some path we do not control — the plist pins it.
//    * no shell. Ever. No `bash -c`, no string interpolation, no `sh -lc`.
//      Process + argv array, and the argv only ever comes from Command.swift.
//    * `environment` is an explicit fixed dictionary. Inheriting
//      ProcessInfo.processInfo.environment would hand the CLI whatever the
//      launching context happened to have (a stale GOBLIN_HOME from a shell, a
//      GIT_* override, a poisoned PATH from a login item).
//    * two serial queues. `goblin status --json` is itself a read-modify-write of
//      uistate.json, so two "reads" in flight can lose one of them; reads
//      serialise for correctness, not just politeness.
//    * long reviews are not our children. `run-now` detaches inside bash, so
//      quitting the app cannot take a fifteen-minute review with it.

import Foundation
import os

final class CLI {

    static let shared = CLI()

    enum Failure: Error, LocalizedError {
        case notFound(String)
        case timeout
        case cliError(message: String, exit: Int32)

        /// Safe to show a person: no argv, no paths beyond what the CLI itself said.
        var errorDescription: String? {
            switch self {
            case .notFound(let m): return m
            case .timeout: return "That took too long and was stopped."
            case .cliError(let m, _): return m.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    struct Output {
        let stdout: String
        let stderr: String
    }

    /// Kill the process rather than buffer more than this. A wedged provider
    /// printing progress forever would otherwise grow the app's heap without
    /// bound and never trip the timeout, because it is making progress.
    static let outputCap = 1024 * 1024

    private let mutations = DispatchQueue(label: "goblin.cli.mutations")
    private let reads = DispatchQueue(label: "goblin.cli.reads")
    private let watchdogQueue = DispatchQueue(label: "goblin.cli.watchdog", attributes: .concurrent)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "goblin", category: "cli")

    /// Absolute path to bin/goblin, from Info.plist. nil means the bundle was
    /// built by hand or the installer changed shape — every call fails closed.
    let executable: URL?
    /// GOBLIN_HOME, from Info.plist, falling back to the documented default.
    let home: String
    /// GOBLIN_APP: the installed copy of bin/ lib/ share/ templates/, which is
    /// two levels above bin/goblin.
    let appRoot: String

    /// Where the engine came from, for the About screen and for diagnosing "which
    /// copy of the CLI is this app actually driving".
    enum EngineSource: String { case bundled, installed, none }
    let engineSource: EngineSource

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let plistHome = (info["GBLHome"] as? String) ?? ""

        // GOBLIN_HOME in the app's own environment wins: that is how a demo or a test
        // points the app at a sandbox. A normal launch (Finder, login item) has none.
        if let h = env["GOBLIN_HOME"], h.hasPrefix("/") {
            home = h
        } else if !plistHome.isEmpty {
            home = plistHome
        } else {
            home = (NSHomeDirectory() as NSString).appendingPathComponent(".goblin")
        }

        // The engine travels INSIDE the app (Contents/Resources/engine), so the app and
        // the scripts it drives are always the same version. A source install pins an
        // absolute path in Info.plist instead; that is the fallback.
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("engine/bin/goblin").path ?? ""
        let pinned = (info["GBLCLIPath"] as? String) ?? ""
        let fm = FileManager.default

        if let override = env["GOBLIN_CLI"], override.hasPrefix("/"), fm.isExecutableFile(atPath: override) {
            executable = URL(fileURLWithPath: override)
            engineSource = .installed
        } else if fm.isExecutableFile(atPath: bundled) {
            executable = URL(fileURLWithPath: bundled)
            engineSource = .bundled
        } else if pinned.hasPrefix("/"), fm.isExecutableFile(atPath: pinned) {
            executable = URL(fileURLWithPath: pinned)
            engineSource = .installed
        } else {
            executable = nil
            engineSource = .none
        }
        if let exe = executable {
            appRoot = ((exe.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        } else {
            appRoot = (home as NSString).appendingPathComponent("app")
        }
    }

    /// Deliberately fixed, but NOT minimal. See the file header.
    ///
    /// The point of pinning this is to avoid inheriting a POISONED value — a stale
    /// GOBLIN_HOME from a shell, a GIT_* override, a rewritten PATH. It was never to
    /// prove how few variables a process can survive on, and stripping the basic
    /// identity variables broke provider detection in a way that looked like a login
    /// problem:
    ///
    ///     `claude auth status` reports `loggedIn: false` when USER is unset.
    ///
    /// So the panel said claude was not signed in while the identical command in a
    /// terminal said it was, and the only difference was this dictionary. codex and
    /// cursor read a file on disk and were unaffected, which made it look like a
    /// Claude-specific auth bug rather than a missing variable.
    ///
    /// USER/LOGNAME/SHELL/TMPDIR are identity and scratch space, not configuration,
    /// and a CLI is entitled to expect them.
    private var environment: [String: String] {
        let h = NSHomeDirectory()
        let inherited = ProcessInfo.processInfo.environment
        let user = inherited["USER"] ?? NSUserName()
        var env = [
            "HOME": h,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(h)/.local/bin",
            "GOBLIN_HOME": home,
            "GOBLIN_APP": appRoot,
            "LANG": "en_US.UTF-8",
            // The engine's own scheduler and the app must agree on where state lives.
            "USER": user,
            "LOGNAME": inherited["LOGNAME"] ?? user,
        ]
        // Passed through only when the launching context actually had them: a
        // fabricated TMPDIR would be worse than no TMPDIR.
        if let t = inherited["TMPDIR"] { env["TMPDIR"] = t }
        if let s = inherited["SHELL"] { env["SHELL"] = s }
        return env
    }

    var isConfigured: Bool { executable != nil }

    var jobsPath: String { (home as NSString).appendingPathComponent("jobs") }
    var logPath: String { (home as NSString).appendingPathComponent("goblin.log") }
    var configPath: String { (home as NSString).appendingPathComponent("config.json") }
    var uiStatePath: String { (home as NSString).appendingPathComponent("uistate.json") }
    var inboxPath: String { (home as NSString).appendingPathComponent("inbox.json") }
    var eventsPath: String { (home as NSString).appendingPathComponent("events.jsonl") }

    // MARK: - Running

    /// Runs a validated plan. `completion` is always called, always on the main
    /// queue, exactly once.
    func run(argv: [String],
             timeout: TimeoutClass,
             mutating: Bool,
             completion: @escaping (Result<Output, Failure>) -> Void) {
        let queue = mutating ? mutations : reads
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.exec(argv: argv, timeout: timeout.seconds)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The same thing, awaitable. Throws `Failure`.
    func run(_ command: Command) async throws -> Output {
        let plan: Plan
        do { plan = try command.validatedPlan() } catch { throw Failure.cliError(message: "\(error)", exit: 2) }
        guard case .cli(let argv, let timeout, let mutating, _) = plan else {
            throw Failure.cliError(message: "not a CLI command", exit: 2)
        }
        return try await withCheckedThrowingContinuation { cont in
            run(argv: argv, timeout: timeout, mutating: mutating) { result in
                cont.resume(with: result)
            }
        }
    }

    // MARK: - The actual subprocess

    private func exec(argv: [String], timeout: TimeInterval) -> Result<Output, Failure> {
        guard let exe = executable else {
            return .failure(.notFound("the Merge Goblin CLI path is missing from the app bundle"))
        }

        let process = Process()
        process.executableURL = exe
        process.arguments = argv
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        // No inherited stdin: a CLI that decides to prompt must see EOF, not the
        // app's terminal (or worse, a pipe nobody is writing to).
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let flags = Flags()
        let outSink = Sink(cap: CLI.outputCap)
        let errSink = Sink(cap: CLI.outputCap)
        let onOverflow: () -> Void = { [weak process] in
            flags.setOverflowed()
            if let process, process.isRunning { process.terminate() }
        }
        outSink.attach(outPipe.fileHandleForReading, onOverflow: onOverflow)
        errSink.attach(errPipe.fileHandleForReading, onOverflow: onOverflow)

        do {
            try process.run()
        } catch {
            outSink.detach()
            errSink.detach()
            return .failure(.notFound("could not start \(exe.path)"))
        }

        // SIGTERM, two seconds of grace, then SIGKILL. The grace matters: the CLI
        // traps TERM to release its lock directory, and a lock left behind blocks
        // every later run until the three-hour stale sweep.
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process else { return }
            flags.setTimedOut()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        watchdogQueue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        outSink.waitForEOF(seconds: 2)
        errSink.waitForEOF(seconds: 2)

        let stdout = outSink.text
        let stderr = errSink.text
        let status = process.terminationStatus

        if flags.timedOut {
            log.error("cli timed out: \(argv.first ?? "?", privacy: .public)")
            return .failure(.timeout)
        }
        if flags.overflowed {
            return .failure(.cliError(message: "the CLI produced more than 1 MB of output", exit: status))
        }
        if status != 0 {
            let message = stderr.isEmpty ? (stdout.isEmpty ? "exited \(status)" : stdout) : stderr
            return .failure(.cliError(message: String(message.prefix(2000)), exit: status))
        }
        return .success(Output(stdout: stdout, stderr: stderr))
    }
}

// MARK: - Small helpers

/// Two booleans that are written from a watchdog thread and read from the caller.
private final class Flags {
    private let lock = NSLock()
    private var _timedOut = false
    private var _overflowed = false

    func setTimedOut() { lock.lock(); _timedOut = true; lock.unlock() }
    func setOverflowed() { lock.lock(); _overflowed = true; lock.unlock() }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return _overflowed }
}

/// Drains a pipe with a readabilityHandler and a hard cap.
///
/// readDataToEndOfFile would be simpler and unbounded, which is the bug: the cap
/// has to be enforced while the bytes arrive, not after.
private final class Sink {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let cap: Int
    private let eof = DispatchSemaphore(value: 0)
    private weak var handle: FileHandle?

    init(cap: Int) { self.cap = cap }

    func attach(_ handle: FileHandle, onOverflow: @escaping () -> Void) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let chunk = fh.availableData
            if chunk.isEmpty {
                self.finish(fh)
                return
            }
            self.lock.lock()
            var over = false
            if self.buffer.count + chunk.count > self.cap {
                over = true
            } else {
                self.buffer.append(chunk)
            }
            self.lock.unlock()
            if over {
                self.finish(fh)
                onOverflow()
            }
        }
    }

    private func finish(_ fh: FileHandle) {
        lock.lock()
        let alreadyDone = finished
        finished = true
        lock.unlock()
        guard !alreadyDone else { return }
        fh.readabilityHandler = nil
        eof.signal()
    }

    func detach() {
        handle?.readabilityHandler = nil
    }

    func waitForEOF(seconds: TimeInterval) {
        _ = eof.wait(timeout: .now() + seconds)
        detach()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? String(decoding: buffer, as: UTF8.self)
    }
}
