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
    /// Where the keyboard cursor starts. Only the screenshot run sets it.
    var initialCursor: Int? = nil

    var body: some View {
        Group {
            if let job = store.job(jobID) {
                switch job.phase {
                case .ready, .posting: PreviewPane(store: store, job: job, initialCursor: initialCursor)
                case .queued, .fetching, .reading, .reviewing: RunningPane(store: store, job: job)
                case .done: DonePane(store: store, job: job)
                case .failed:
                    // A post that failed leaves the review (and your edits) intact: show them
                    // again with the reason, rather than offering only a brand-new review.
                    if store.preview(for: job.id) != nil { PreviewPane(store: store, job: job, initialCursor: initialCursor) }
                    else { FailedPane(store: store, job: job) }
                case .skipped: SkippedPane(store: store, job: job)
                case .cancelled, .discarded: EndedPane(store: store, job: job)
                }
            } else {
                EmptyState(symbol: "questionmark.folder", title: "That review is gone",
                           subtitle: "Finished reviews are kept for two weeks.")
            }
        }
        .animation(Motion.spring, value: store.job(jobID)?.phase)
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
            Button { store.openURL(job.url) } label: {
                Text(job.displayTitle).font(.system(size: 20, weight: .bold)).lineLimit(3).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).help("Open the pull request on GitHub")
            HStack(spacing: 6) {
                Button { store.openURL(job.url) } label: {
                    Chip(text: job.ref, symbol: "arrow.up.right.square", tint: Theme.accent).modifier(LiftOnHover())
                }.buttonStyle(.plain).help("Open the pull request")
                if !job.author.isEmpty, Pattern.githubLogin.accepts(job.author) {
                    Button { store.openURL("https://github.com/\(job.author)") } label: {
                        Chip(text: "@\(job.author)").modifier(LiftOnHover())
                    }.buttonStyle(.plain).help("Open @\(job.author) on GitHub")
                }
                if !job.provider.isEmpty {
                    Menu {
                        Section("Review again with") {
                            ForEach(ProviderId.allCases, id: \.self) { p in
                                Button(p.rawValue.capitalized) {
                                    guard let ref = PRRef.parse("\(job.repo)#\(job.number)") else { return }
                                    var o = ReviewOptions(); o.provider = p; o.force = true; o.mode = .preview
                                    Task { if let j = await store.startReview(ref, options: o) { WindowManager.shared.showJob(j.id) } }
                                }
                            }
                        }
                    } label: {
                        Chip(text: preview.map { "\($0.provider)/\($0.model)" } ?? job.provider, symbol: "sparkles").modifier(LiftOnHover())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Who wrote this review — click to get a second opinion from another one")
                }
                if job.focus != .full { Chip(text: job.focus.rawValue.capitalized) }
                if let p = preview {
                    Button { store.openURL(job.url + "/files") } label: {
                        Chip(text: "\(p.files) files  +\(p.additions) −\(p.deletions)", symbol: "doc.on.doc").modifier(LiftOnHover())
                    }.buttonStyle(.plain).help("Open the changed files on GitHub")
                }
                if let p = preview, !p.risk.isEmpty {
                    Chip(text: "\(p.risk) risk", symbol: "gauge.with.dots.needle.67percent",
                         tint: p.risk == "high" ? .red : p.risk == "medium" ? .orange : .green)
                        .help(p.blastRadius)
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
                HStack(alignment: .center, spacing: 18) {
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
                Mascot(.reviewing, size: 128).modifier(Bob(active: true))
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

/// Which text control has the keyboard, if any. Every shortcut below stands down while
/// one does: Space and E are typing, and ⌘↩ in the middle of a sentence must not post it.
enum ReviewTextField: Hashable {
    case summary
    case title(String)
    case body(String)
}

private struct PreviewPane: View {
    @Bindable var store: AppStore
    let job: Job
    @State private var editingSummary = false

    private var preview: ReviewPreview? { store.preview(for: job.id) }
    private var edits: ReviewEdits { store.edits[job.id] ?? ReviewEdits() }
    @State private var confirmDiscard = false
    private var posting: Bool { job.phase == .posting || store.postingJobs.contains(job.id) }

    // keyboard
    /// The finding the arrow keys are on, by index into the preview's findings.
    @State private var cursor: Int?
    /// Findings open for editing. Lives here, not in the card, so E can open one.
    @State private var editingFindings: Set<String> = []
    @FocusState private var textField: ReviewTextField?
    @FocusState private var paneFocused: Bool

    init(store: AppStore, job: Job, initialCursor: Int? = nil) {
        self.store = store
        self.job = job
        _cursor = State(initialValue: initialCursor)
    }

    /// True while anything is being edited. ⌘↩ is withheld for all of it, not only while
    /// the caret is in a field: an open editor means the person is not done yet.
    private var editingAnything: Bool { textField != nil || editingSummary || !editingFindings.isEmpty }

    var body: some View {
        if let p = preview {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            JobHeader(job: job, store: store, preview: p).arrive()
                            if job.phase == .failed || !job.error.isEmpty {
                                Text(job.errorDetail.isEmpty ? "The last attempt to post this did not go through. Nothing was lost: your edits are still here."
                                                             : "The last attempt to post this failed: \(job.errorDetail) Your edits are still here.")
                                    .font(.system(size: 12.5)).foregroundStyle(Color(nsColor: .systemOrange))
                            }
                            summaryCard(p).arrive(0.03)
                            if let intent = p.intent { intentCard(intent).arrive(0.06) }
                            findingsSection(p)
                        }
                        .padding(.horizontal, 28).padding(.vertical, 24)
                    }
                    .onChange(of: cursor) { _, new in
                        guard let new, p.findings.indices.contains(new) else { return }
                        withAnimation(Motion.quick) { proxy.scrollTo(p.findings[new].id, anchor: .center) }
                    }
                }
                Divider()
                bar(p)
            }
            // The pane itself takes the keyboard, so the shortcuts work without first
            // clicking into something. `.edit` is what lets a plain view be focused by a
            // click or in code on macOS, without Full Keyboard Access.
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused($paneFocused)
            .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, p) }
            .onAppear { paneFocused = true }
            .onChange(of: textField) { _, new in if new == nil { paneFocused = true } }
        } else {
            EmptyState(symbol: "exclamationmark.triangle", title: "This review can't be read",
                       subtitle: "Its saved files are missing. Run the review again.")
        }
    }

    // MARK: keys

    private func handleKey(_ press: KeyPress, _ p: ReviewPreview) -> KeyPress.Result {
        // Esc first: inside an editor it finishes editing; otherwise it closes the window.
        if press.key == .escape {
            if editingAnything { finishEditing() } else { WindowManager.shared.close("job:\(job.id)") }
            return .handled
        }
        // Typing belongs to the field. ⌘/⌃/⌥ combinations belong to the menus.
        guard textField == nil, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let n = p.findings.count
        switch press.key {
        case .downArrow, "j", "J":
            guard n > 0 else { return .ignored }
            withAnimation(Motion.quick) { cursor = min((cursor ?? -1) + 1, n - 1) }
        case .upArrow, "k", "K":
            guard n > 0 else { return .ignored }
            withAnimation(Motion.quick) { cursor = max((cursor ?? n) - 1, 0) }
        case .space:
            guard let i = cursor, p.findings.indices.contains(i) else { return .ignored }
            let id = p.findings[i].id
            var e = edits
            if e.dropped.contains(id) { e.dropped.remove(id) } else { e.dropped.insert(id) }
            withAnimation(Motion.spring) { store.edits[job.id] = e }
        case "e", "E":
            guard let i = cursor, p.findings.indices.contains(i) else { return .ignored }
            let id = p.findings[i].id
            withAnimation(Motion.quick) { _ = editingFindings.insert(id) }
            // The field exists only from the next frame on; focus it then.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                textField = .title(id)
            }
        default:
            return .ignored
        }
        return .handled
    }

    private func finishEditing() {
        textField = nil
        withAnimation(Motion.quick) {
            editingSummary = false
            editingFindings = []
        }
        paneFocused = true
    }

    // MARK: summary

    private func summaryCard(_ p: ReviewPreview) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Summary")
                    Button(editingSummary ? "Done" : "Edit") {
                        editingSummary.toggle()
                        if editingSummary { textField = .summary } else if textField == .summary { textField = nil }
                    }.buttonStyle(.goblinQuiet)
                        .accessibilityLabel(editingSummary ? "Done editing summary" : "Edit summary")
                }
                if editingSummary {
                    TextEditor(text: Binding(
                        get: { edits.summary ?? p.summary },
                        set: { var e = edits; e.summary = $0; store.edits[job.id] = e }))
                        .font(.system(size: 13)).frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6).background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 8))
                        .focused($textField, equals: .summary)
                        .onKeyPress(.escape) { finishEditing(); return .handled }
                } else {
                    // An emptied summary is not sent (the engine keeps the original), so show
                    // the original rather than a blank that would not match what is posted.
                    Markdown(text: (edits.summary?.isEmpty == false ? edits.summary : nil) ?? p.summary).font(.system(size: 13.5))
                }
                if !p.blastRadius.isEmpty {
                    Text("If it's wrong: \(p.blastRadius)").font(.system(size: 12)).foregroundStyle(.secondary)
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
                ForEach(Array(p.findings.enumerated()), id: \.element.id) { i, f in
                    FindingCard(finding: f, sourceURL: f.sourceURL(repo: p.repo, head: p.head), store: store,
                                edits: Binding(get: { store.edits[job.id] ?? ReviewEdits() },
                                               set: { store.edits[job.id] = $0 }),
                                editing: Binding(get: { editingFindings.contains(f.id) },
                                                 set: { on in if on { editingFindings.insert(f.id) } else { editingFindings.remove(f.id) } }),
                                isCursor: cursor == i,
                                textField: $textField,
                                finishEditing: finishEditing)
                    .id(f.id)
                    // A click puts the keyboard cursor where the pointer is. It does not
                    // take focus from a field being typed in.
                    .simultaneousGesture(TapGesture().onEnded {
                        cursor = i
                        if textField == nil { paneFocused = true }
                    })
                    .arrive(0.08 + Double(min(i, 8)) * 0.05)
                }
            }
        }
    }

    private func included(_ p: ReviewPreview) -> [Finding] { p.findings.filter { !edits.dropped.contains($0.id) } }

    // MARK: bottom bar

    private func bar(_ p: ReviewPreview) -> some View {
        VStack(alignment: .leading, spacing: 9) {
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
                Button("Discard") { confirmDiscard = true }.buttonStyle(.goblin).disabled(posting)
                    .confirmationDialog("Discard this review?", isPresented: $confirmDiscard) {
                        Button("Discard review", role: .destructive) { store.cancel(job) }
                    } message: { Text("Nothing has been posted. Your edits will be lost.") }
                Button {
                    Task { await store.post(job) }
                } label: {
                    HStack(spacing: 6) {
                        if posting { ProgressView().controlSize(.small) }
                        Text(posting ? "Posting…" : "Post to GitHub")
                    }
                }
                .buttonStyle(.goblinPrimary).disabled(posting)
                // Withheld while anything is being edited: ⌘↩ in a text editor is a
                // finger slip far more often than "send this under my name".
                .keyboardShortcut(editingAnything ? nil : KeyboardShortcut(.return, modifiers: .command))
                .help(editingAnything ? "Finish editing (Esc) to post with ⌘↩" : "Post to GitHub (⌘↩)")
            }
            KeyHints(editing: editingAnything, hasFindings: !p.findings.isEmpty)
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

/// The review window's shortcuts, quietly, along the bottom. They change while editing,
/// because then only Esc means anything.
private struct KeyHints: View {
    let editing: Bool
    let hasFindings: Bool

    var body: some View {
        HStack(spacing: 12) {
            if editing {
                hint("esc", "finish editing")
            } else {
                if hasFindings {
                    hint("↑ ↓", "move")
                    hint("space", "include or drop")
                    hint("E", "edit")
                }
                hint("⌘↩", "post")
                hint("esc", "close")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .animation(Motion.quick, value: editing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(editing ? "Press Escape to finish editing"
                                    : "Keyboard: arrow keys or J and K move between findings, Space includes or drops one, E edits it, Command Return posts, Escape closes")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4.5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text(label)
        }
        .transition(.opacity)
    }
}

// MARK: - A finding you can edit

struct FindingCard: View {
    let finding: Finding
    var sourceURL: String? = nil
    var store: AppStore? = nil
    @Binding var edits: ReviewEdits
    @Binding var editing: Bool
    /// The keyboard cursor is on this card.
    var isCursor = false
    var textField: FocusState<ReviewTextField?>.Binding
    var finishEditing: () -> Void = {}

    private var dropped: Bool { edits.dropped.contains(finding.id) }
    private var severity: Severity { edits.edited[finding.id]?.severity ?? finding.severity }
    private var title: String { edits.edited[finding.id]?.title ?? finding.title }
    private var bodyText: String { edits.edited[finding.id]?.body ?? finding.body }

    var body: some View {
        Card(padding: 14, accent: dropped ? Color.secondary.opacity(0.4) : Theme.color(for: severity)) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { !dropped },
                        set: { on in withAnimation(Motion.spring) { if on { edits.dropped.remove(finding.id) } else { edits.dropped.insert(finding.id) } } }))
                        .toggleStyle(.checkbox).labelsHidden().help("Include this finding (Space)")
                        .accessibilityLabel("Include finding: \(title)")
                    Menu {
                        ForEach(Severity.allCases) { s in
                            Button { setEdit { $0.severity = s } } label: { Label(s.label, systemImage: s == severity ? "checkmark" : "") }
                        }
                    } label: { SeverityBadge(severity: severity) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    if let loc = finding.location {
                        if let sourceURL, let store {
                            Button { store.openURL(sourceURL) } label: {
                                Text(loc).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).hoverRow()
                            .help("Open these lines on GitHub, at the commit that was reviewed")
                        } else {
                            Text(loc).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if !finding.anchored {
                        Chip(text: "goes in the summary", symbol: "text.append", tint: Color(nsColor: .systemOrange))
                            .help("GitHub can't pin this to a line of the diff, so it is posted inside the review body.")
                    }
                    Spacer()
                    Button(editing ? "Done" : "Edit") {
                        let mine: Set<ReviewTextField> = [.title(finding.id), .body(finding.id)]
                        if editing, let f = textField.wrappedValue, mine.contains(f) { textField.wrappedValue = nil }
                        withAnimation(Motion.quick) { editing.toggle() }
                        if editing { textField.wrappedValue = .title(finding.id) }
                    }.buttonStyle(.goblinQuiet)
                        .help(editing ? "Done (Esc)" : "Edit (E)")
                        .accessibilityLabel(editing ? "Done editing finding" : "Edit finding: \(title)")
                }
                if editing {
                    TextField("Title", text: Binding(get: { title }, set: { v in setEdit { $0.title = v } }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 13.5, weight: .semibold))
                        .focused(textField, equals: .title(finding.id))
                        .onKeyPress(.escape) { finishEditing(); return .handled }
                    TextEditor(text: Binding(get: { bodyText }, set: { v in setEdit { $0.body = v } }))
                        .font(.system(size: 12.5)).frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6).background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 8))
                        .focused(textField, equals: .body(finding.id))
                        .onKeyPress(.escape) { finishEditing(); return .handled }
                } else {
                    Markdown(text: title).font(.system(size: 13.5, weight: .semibold))
                        .strikethrough(dropped, color: .secondary)
                    if !dropped {
                        Markdown(text: bodyText).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if let s = finding.suggestion, !s.isEmpty {
                    Text(s).font(.system(size: 11.5, design: .monospaced))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .opacity(dropped ? 0.5 : 1)
        }
        // The keyboard cursor: a ring in the accent, just outside the card's own hairline.
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .padding(-3)
                .opacity(isCursor ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(Motion.spring, value: dropped)
        .animation(Motion.quick, value: editing)
        .animation(Motion.quick, value: isCursor)
        .accessibilityAddTraits(isCursor ? .isSelected : [])
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
        Text(Self.attributed(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ text: String) -> AttributedString {
        guard var a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        // Finding text is model output derived from somebody else's pull request. A link
        // in it must not be able to open smb://, file:// or another app's URL scheme.
        for run in a.runs {
            if let l = run.link, !Command.isHTTPS(l.absoluteString) { a[run.range].link = nil }
        }
        return a
    }
}

// MARK: - Terminal states

private struct DonePane: View {
    let store: AppStore
    let job: Job
    @State private var celebrate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            JobHeader(job: job, store: store)
            Card(padding: 20, accent: Theme.accent) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolEffect(.bounce, options: .nonRepeating, value: celebrate)
                            Text("Posted to GitHub")
                        }
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                        if !job.counts.isEmpty { SeverityCounts(text: job.counts, size: 13) }
                        HStack {
                            if !job.reviewURL.isEmpty {
                                Button("Open the review on GitHub") { store.openURL(job.reviewURL) }.buttonStyle(.goblinPrimary)
                            }
                            Button("Open the pull request") { store.openURL(job.url) }.buttonStyle(.goblin)
                        }
                    }
                    Spacer(minLength: 0)
                    Mascot(.idleWave, size: 112)
                        .scaleEffect(celebrate || Motion.reduced ? 1 : 0.6)
                        .opacity(celebrate || Motion.reduced ? 1 : 0)
                }
            }
            .arrive()
            .onAppear { withAnimation(Motion.reduced ? nil : .spring(duration: 0.55, bounce: 0.45).delay(0.1)) { celebrate = true } }
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
                HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("The review didn't finish", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(nsColor: .systemRed))
                    Text(job.failureMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack {
                        Button("Try again") { retry() }.buttonStyle(.goblinPrimary)
                        Button("Open the log") { store.openLog() }.buttonStyle(.goblin)
                    }
                }
                Spacer(minLength: 0)
                Mascot(.alert, size: 112)
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
