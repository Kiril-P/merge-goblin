//  ReviewWindow.swift — one review, full size: watch it run, read it, change it, send it.
//
//  The preview is the point of the whole manual flow. Nothing here has reached GitHub.
//  What you edit is written to the job's own edits.json and the engine re-validates it
//  and rebuilds the review through the same renderer an unattended review uses, so the
//  label, the footer and the verdict policy cannot differ between the two paths.

import SwiftUI

struct ReviewWindowView: View {
    @Bindable var store: AppStore
    let jobID: String

    var body: some View {
        Group {
            if let job = store.job(jobID) {
                switch job.phase {
                case .ready, .posting: PreviewPane(store: store, job: job)
                case .queued, .fetching, .reading, .reviewing: RunningPane(store: store, job: job)
                case .done: DonePane(store: store, job: job)
                case .failed: FailedPane(store: store, job: job)
                case .skipped: SkippedPane(store: store, job: job)
                case .cancelled, .discarded: EndedPane(store: store, job: job)
                }
            } else {
                EmptyState(symbol: "questionmark.folder", title: "That review is gone",
                           subtitle: "Finished reviews are kept for two weeks.")
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(.background)
        .toasts(store)
    }
}

// MARK: - Shared header

private struct JobHeader: View {
    let job: Job
    let store: AppStore
    var preview: ReviewPreview? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.displayTitle).font(.system(size: 20, weight: .bold)).lineLimit(3)
            HStack(spacing: 6) {
                Button { store.openURL(job.url) } label: {
                    Chip(text: job.ref, symbol: "arrow.up.right.square", tint: Theme.accent)
                }.buttonStyle(.plain)
                if !job.author.isEmpty { Chip(text: "@\(job.author)") }
                if !job.provider.isEmpty {
                    Chip(text: preview.map { "\($0.provider)/\($0.model)" } ?? job.provider, symbol: "sparkles")
                }
                if job.focus != .full { Chip(text: job.focus.rawValue.capitalized) }
                if let p = preview {
                    Chip(text: "\(p.files) files  +\(p.additions) −\(p.deletions)", symbol: "doc.on.doc")
                }
                if let p = preview, p.costUsd > 0 { Chip(text: String(format: "$%.2f", p.costUsd)) }
            }
        }
    }
}

// MARK: - Running

private struct RunningPane: View {
    let store: AppStore
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            JobHeader(job: job, store: store)
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(job.phase.label).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Ago.elapsed(job.createdAt, now: ctx.date)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    PhaseTrack(phase: job.phase, labels: true)
                    Text(blurb).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel review") { store.cancel(job) }.buttonStyle(.goblinDestructive)
            }
            Spacer()
        }
        .padding(28)
    }

    private var blurb: String {
        switch job.phase {
        case .queued: return "Another review is using the slot. This one starts as soon as it is free."
        case .fetching: return "Getting the changed files from GitHub."
        case .reading: return "Checking out the branch so the reviewer can read the code around the change, and finding the repo's own review rules."
        default: return "The reviewer is reading the diff against your repo's rules. This usually takes a minute or two. Nothing is posted — you'll read it first."
        }
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    @Bindable var store: AppStore
    let job: Job
    @State private var editingSummary = false
    @State private var showDropped = true

    private var preview: ReviewPreview? { store.preview(for: job.id) }
    private var edits: ReviewEdits { store.edits[job.id] ?? ReviewEdits() }
    private var posting: Bool { job.phase == .posting }

    var body: some View {
        if let p = preview {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        JobHeader(job: job, store: store, preview: p)
                        summaryCard(p)
                        if let intent = p.intent { intentCard(intent) }
                        findingsSection(p)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 24)
                }
                Divider()
                bar(p)
            }
        } else {
            EmptyState(symbol: "exclamationmark.triangle", title: "This review can't be read",
                       subtitle: "Its saved files are missing. Run the review again.")
        }
    }

    // MARK: summary

    private func summaryCard(_ p: ReviewPreview) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Summary")
                    Button(editingSummary ? "Done" : "Edit") { editingSummary.toggle() }.buttonStyle(.goblinQuiet)
                }
                if editingSummary {
                    TextEditor(text: Binding(
                        get: { edits.summary ?? p.summary },
                        set: { var e = edits; e.summary = $0; store.edits[job.id] = e }))
                        .font(.system(size: 13)).frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6).background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Markdown(text: edits.summary ?? p.summary).font(.system(size: 13.5))
                }
            }
        }
    }

    private func intentCard(_ n: IntentNote) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Does it do what the issue asked?", trailing: n.issue.isEmpty ? nil : n.issue)
                Text(n.headline).font(.system(size: 13.5, weight: .semibold))
                Markdown(text: n.body).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: findings

    private func findingsSection(_ p: ReviewPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Findings", trailing: p.findings.isEmpty ? nil : "\(included(p).count) of \(p.findings.count) will be posted")
            if p.findings.isEmpty {
                Card { EmptyState(symbol: "checkmark.seal", title: "Suspiciously clean", subtitle: "The reviewer found nothing to flag. The summary is still posted.") }
            } else {
                ForEach(p.findings) { f in
                    FindingCard(finding: f, edits: Binding(
                        get: { store.edits[job.id] ?? ReviewEdits() },
                        set: { store.edits[job.id] = $0 }))
                }
            }
        }
    }

    private func included(_ p: ReviewPreview) -> [Finding] { p.findings.filter { !edits.dropped.contains($0.id) } }

    // MARK: bottom bar

    private func bar(_ p: ReviewPreview) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verdictLine(p)).font(.system(size: 12.5, weight: .semibold))
                Text(store.snapshot.settings.verdictMode == "comment"
                     ? "Posted from @\(store.snapshot.login) as a comment. Never approves, never blocks."
                     : "Posted from @\(store.snapshot.login). See Settings for the verdict policy.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if job.headChanged {
                    Text("The PR has new commits since this review. It will be posted against the commit that was reviewed.")
                        .font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
            Spacer()
            if !edits.isEmpty { Button("Reset edits") { store.edits[job.id] = nil }.buttonStyle(.goblinQuiet) }
            Button("Discard") { store.cancel(job) }.buttonStyle(.goblin).disabled(posting)
            Button {
                Task { await store.post(job) }
            } label: {
                HStack(spacing: 6) {
                    if posting { ProgressView().controlSize(.small) }
                    Text(posting ? "Posting…" : "Post to GitHub")
                }
            }
            .buttonStyle(.goblinPrimary).disabled(posting)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
    }

    private func verdictLine(_ p: ReviewPreview) -> String {
        let live = included(p)
        if live.isEmpty { return "Posting the summary only" }
        let blockers = live.filter { $0.severity == .blocker }.count
        return blockers > 0 ? "\(live.count) finding\(live.count == 1 ? "" : "s"), \(blockers) blocker\(blockers == 1 ? "" : "s")"
                            : "\(live.count) finding\(live.count == 1 ? "" : "s")"
    }
}

// MARK: - A finding you can edit

struct FindingCard: View {
    let finding: Finding
    @Binding var edits: ReviewEdits
    @State private var editing = false

    private var dropped: Bool { edits.dropped.contains(finding.id) }
    private var severity: Severity { edits.edited[finding.id]?.severity ?? finding.severity }
    private var title: String { edits.edited[finding.id]?.title ?? finding.title }
    private var bodyText: String { edits.edited[finding.id]?.body ?? finding.body }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { !dropped },
                        set: { on in if on { edits.dropped.remove(finding.id) } else { edits.dropped.insert(finding.id) } }))
                        .toggleStyle(.checkbox).labelsHidden().help("Include this finding")
                    Menu {
                        ForEach(Severity.allCases) { s in
                            Button { setEdit { $0.severity = s } } label: { Label(s.label, systemImage: s == severity ? "checkmark" : "") }
                        }
                    } label: { SeverityBadge(severity: severity) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    if let loc = finding.location {
                        Text(loc).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !finding.anchored {
                        Chip(text: "goes in the summary", symbol: "text.append", tint: Color(nsColor: .systemOrange))
                            .help("GitHub can't pin this to a line of the diff, so it is posted inside the review body.")
                    }
                    Spacer()
                    Button(editing ? "Done" : "Edit") { editing.toggle() }.buttonStyle(.goblinQuiet)
                }
                if editing {
                    TextField("Title", text: Binding(get: { title }, set: { v in setEdit { $0.title = v } }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 13.5, weight: .semibold))
                    TextEditor(text: Binding(get: { bodyText }, set: { v in setEdit { $0.body = v } }))
                        .font(.system(size: 12.5)).frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6).background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Markdown(text: title).font(.system(size: 13.5, weight: .semibold))
                    Markdown(text: bodyText).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                if let s = finding.suggestion, !s.isEmpty {
                    Text(s).font(.system(size: 11.5, design: .monospaced))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .opacity(dropped ? 0.4 : 1)
        }
    }

    private func setEdit(_ f: (inout FindingEdit) -> Void) {
        var e = edits
        var fe = e.edited[finding.id] ?? FindingEdit()
        f(&fe)
        e.edited[finding.id] = fe
        edits = e
    }
}

/// Inline markdown, preserving the author's line breaks. Not a full renderer on
/// purpose: findings are short prose, and anything fancier is read on GitHub.
struct Markdown: View {
    let text: String
    var body: some View {
        if let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(a).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Terminal states

private struct DonePane: View {
    let store: AppStore
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            JobHeader(job: job, store: store)
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Posted to GitHub", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                    if !job.counts.isEmpty { Text(job.counts).font(.system(size: 13)) }
                    HStack {
                        if !job.reviewURL.isEmpty {
                            Button("Open the review on GitHub") { store.openURL(job.reviewURL) }.buttonStyle(.goblinPrimary)
                        }
                        Button("Open the pull request") { store.openURL(job.url) }.buttonStyle(.goblin)
                    }
                }
            }
            Spacer()
        }.padding(28)
    }
}

private struct FailedPane: View {
    let store: AppStore
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            JobHeader(job: job, store: store)
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("The review didn't finish", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(nsColor: .systemRed))
                    Text(job.failureMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack {
                        Button("Try again") { retry() }.buttonStyle(.goblinPrimary)
                        Button("Open the log") { store.openLog() }.buttonStyle(.goblin)
                    }
                }
            }
            Spacer()
        }.padding(28)
    }
    private func retry() {
        guard let ref = PRRef.parse("\(job.repo)#\(job.number)") else { return }
        var o = ReviewOptions(); o.focus = job.focus; o.mode = job.mode; o.force = true
        Task { if let j = await store.startReview(ref, options: o) { WindowManager.shared.showJob(j.id) } }
    }
}

private struct SkippedPane: View {
    let store: AppStore
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            JobHeader(job: job, store: store)
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Nothing to do", systemImage: "forward.circle").font(.system(size: 16, weight: .semibold))
                    Text(job.skipMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack {
                        Button("Review anyway") { go() }.buttonStyle(.goblinPrimary)
                        Button("Open the pull request") { store.openURL(job.url) }.buttonStyle(.goblin)
                    }
                }
            }
            Spacer()
        }.padding(28)
    }
    private func go() {
        guard let ref = PRRef.parse("\(job.repo)#\(job.number)") else { return }
        var o = ReviewOptions(); o.focus = job.focus; o.mode = job.mode; o.force = true
        Task { if let j = await store.startReview(ref, options: o) { WindowManager.shared.showJob(j.id) } }
    }
}

private struct EndedPane: View {
    let store: AppStore
    let job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            JobHeader(job: job, store: store)
            Card(padding: 20) {
                Label(job.phase == .discarded ? "Discarded — nothing was posted" : "Cancelled — nothing was posted",
                      systemImage: Theme.symbol(for: job.phase)).font(.system(size: 15, weight: .semibold))
            }
            Spacer()
        }.padding(28)
    }
}
