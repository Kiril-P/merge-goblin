//  JobViews.swift — a review in flight, as the popover and the review window show it.

import SwiftUI

/// Five steps, filled up to the current one. The step names are the engine's phases,
/// so what you see is what the job file says — there is no invented progress.
struct PhaseTrack: View {
    let phase: JobPhase
    var labels = false
    private let names = ["Queued", "Fetch", "Read", "Review", "Done"]

    var body: some View {
        let current = phase.step
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(i <= current ? Theme.color(for: phase) : Color.primary.opacity(0.12))
                            .frame(width: 9, height: 9)
                        if i == current && phase.isActive {
                            Circle().strokeBorder(Theme.color(for: phase).opacity(0.5), lineWidth: 2)
                                .frame(width: 15, height: 15)
                                .modifier(Pulse())
                        }
                    }
                    .frame(width: 16, height: 16)
                    .overlay(alignment: .top) {
                        if labels {
                            Text(names[i]).font(.system(size: 10.5)).foregroundStyle(i <= current ? .secondary : .tertiary)
                                .fixedSize().offset(y: 19)
                        }
                    }
                    if i < 4 {
                        Rectangle()
                            .fill(i < current ? Theme.color(for: phase) : Color.primary.opacity(0.12))
                            .frame(height: 2)
                    }
                }
            }
        }
        .padding(.bottom, labels ? 20 : 0)
        .accessibilityElement()
        .accessibilityLabel("\(phase.label), step \(current + 1) of 5")
    }
}

private struct Pulse: ViewModifier {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1.25 : 0.9).opacity(on ? 0.2 : 0.9)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct JobRow: View {
    let job: Job
    let store: AppStore
    var open: (Job) -> Void

    var body: some View {
        Card(padding: 11) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Theme.symbol(for: job.phase))
                        .foregroundStyle(Theme.color(for: job.phase))
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        HStack(spacing: 5) {
                            Text(verbatim: "\(job.shortRepo) #\(job.number)").foregroundStyle(.secondary)
                            if job.phase.isActive {
                                Text("·").foregroundStyle(.tertiary)
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    Text(Ago.elapsed(job.createdAt, now: ctx.date)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }.font(.system(size: 11.5))
                    }
                    Spacer(minLength: 0)
                }
                if job.phase.isActive {
                    PhaseTrack(phase: job.phase)
                    HStack {
                        Text(job.phase.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { store.cancel(job) }.buttonStyle(.goblinQuiet)
                    }
                } else if job.phase == .ready {
                    HStack(spacing: 8) {
                        if !job.counts.isEmpty { Text(job.counts).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Button("Discard") { store.cancel(job) }.buttonStyle(.goblinQuiet)
                        // Straight from the card: no need to open the review first. It posts
                        // exactly what the preview holds (no edits), under your name.
                        Button(store.postingJobs.contains(job.id) ? "Posting…" : "Post") {
                            Task { await store.post(job) }
                        }
                        .buttonStyle(.goblinSmall).disabled(store.postingJobs.contains(job.id))
                        .help("Post this review to GitHub as it is")
                        Button("Read review") { open(job) }.buttonStyle(.goblinPrimarySmall)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(job) }
        .accessibilityAction(named: "Open review") { open(job) }
    }
}

/// One finished thing in the Recent list.
struct RecentRow: View {
    let item: RecentItem
    let store: AppStore
    var open: (Job) -> Void

    var body: some View {
        Button(action: act) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 13, weight: .semibold)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Ago.short(item.at)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var title: String { item.job?.displayTitle ?? item.entry?.title ?? "" }

    private var subtitle: String {
        if let j = item.job {
            switch j.phase {
            case .done: return "\(j.shortRepo) #\(j.number) · \(j.counts.isEmpty ? "posted" : j.counts)"
            case .failed: return "\(j.shortRepo) #\(j.number) · \(j.failureMessage)"
            case .skipped: return "\(j.shortRepo) #\(j.number) · \(j.skipMessage)"
            default: return "\(j.shortRepo) #\(j.number) · \(j.phase.label.lowercased())"
            }
        }
        if let e = item.entry {
            return "\(e.shortRepo) #\(e.number) · " + (e.kind == .posted ? "posted" : (e.reason.isEmpty ? "failed" : e.reason))
        }
        return ""
    }

    private var symbol: String {
        if let j = item.job { return Theme.symbol(for: j.phase) }
        return item.entry?.kind == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }
    private var tint: Color {
        if let j = item.job { return Theme.color(for: j.phase) }
        return item.entry?.kind == .failed ? Color(nsColor: .systemRed) : Theme.accent
    }

    private func act() {
        if let j = item.job { open(j) }
        else if let e = item.entry, !e.url.isEmpty { store.openURL(e.url) }
    }
}

struct QueueRow: View {
    let pr: QueuedPR
    let store: AppStore
    var review: (QueuedPR) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).font(.system(size: 13)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                Text(verbatim: "\(pr.shortRepo) #\(pr.number)\(pr.author.isEmpty ? "" : " · @\(pr.author)")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Review") { review(pr) }.buttonStyle(.goblinSmall)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { store.openURL(pr.url) }
        .accessibilityAction(named: "Open the pull request") { store.openURL(pr.url) }
    }
}
