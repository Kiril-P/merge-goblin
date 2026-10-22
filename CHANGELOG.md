# Changelog

## Unreleased

When something goes wrong, the Goblin now says what happened, when it tries again,
and what fixes it.

- **Failures in words.** Most failed reviews used to be filed as `other`: the
  notification read "#123 — other" and the review window showed the AI CLI's raw
  output. Dropped connections, usage limits and sign-outs are now recognised, the
  message says what happened ("Lost the connection to Cursor. The Goblin tries again
  around 14:20."), and the CLI's own words sit behind a "What Cursor said" toggle.
- **The failure screen offers the fix.** Out of quota: review it with another AI
  you're signed in to, or set a backup. Signed out: open Reviewer settings. Wrong
  GitHub account: open account settings. Anything else: try again.
- **Our failures no longer turn a teammate's PR red.** A scheduled review that fails
  leaves its check pending with the time it retries, instead of a red error.
  Fixed: a failed *preview* posted a red "review failed" status on GitHub, although a
  preview is meant to leave GitHub alone.
- **Usage limits.** A provider that hits its limit rests until it resets (the time
  the CLI gives, else an hour) instead of failing every PR in turn and marking each
  one stuck. `providerFallback` now does what the README always said: with a backup
  set (Settings → Reviewer → Backup), the same PR is reviewed by it straight away.
  Without one, the Goblin pauses and says when it resumes.
- **The icon and the panel agree.** When the menu bar icon says something is wrong,
  the panel shows what it is and a button that fixes it, and the pill says "needs
  you", not "on duty".
- **Limits with numbers.** "daily review limit reached · 20 of 20 today · resumes at
  midnight", "daily budget spent · $10 of $10", "snoozed until 15:40", "Claude hit its
  usage limit · trying again at 16:05". `goblin budget` says "daily budget", which is
  what it is.
- **Signs of life.** Waiting for you shows when the Goblin last looked and when it
  looks next.
- **Undo.** Post and Discard wait five seconds with an Undo button (GitHub can't
  unsend a review, so this is the only real undo). After a discard there is a
  **Review again** button, and "Posted to GitHub." links to the review.
- Fixed: reviews made in preview showed "failed" in Recent.

## 0.5.1

- **Pick the repo before you type.** The review field starts with the repo a number
  means ("mobile-app #"); click it to switch between watched and recent repos. Your
  choice sticks for the next number. Before, the repo only showed up after a lookup,
  and switching meant looking up a PR first.
- **Open at login is on by default.** The last setup step shows the switch (on), an
  existing install turns it on once with a notice, and Health flags it when it is off.
  Fixed: from a cask or a dragged DMG (in /Applications) the switch failed, because
  the login item looked for the app in ~/Applications.

## 0.5.0

The Goblin is now a native Mac app, and you can hand it any PR yourself.

### Review any PR by number

- Type `2456`, `owner/repo#2456` or paste a PR link (popover, or ⌥⌘G anywhere) and
  the Goblin reviews it on demand. The CLI equivalent is `goblin review <ref>`.
- By default a review stops at a **preview**: read it, edit or drop findings, then
  post. `goblin post <job>` / `goblin cancel <job>` from the terminal.
- A ready review can be posted straight from its card in the popover, or from the
  notification's **Post** button; clicking a notification opens that exact review.
- **Auto-post policy** for reviews the Goblin does on its own (Settings > Behaviour,
  `autoPost`): post them all, post only when safe (no blocker, not high-risk), or hold
  every one in Ready to read for you to post.
- **Your own pull requests** (Settings > Behaviour, `reviewMine`): the Goblin can review
  every push to PRs you opened, like a review bot. *Keep private* holds each review in
  Ready to read with nothing on GitHub (no comment, no commit status); *Post them* posts
  a comment review. A newer push replaces a review still waiting for an older one. Drafts
  only if you turn on `reviewMineDrafts`. A review of your own PR is always a comment,
  since GitHub refuses approve or request-changes there.
- A preview is refused at post time if a review of the same commit was posted after
  the preview was made, so two people (or two Goblins) do not post the same review.
  `--force` overrides; a deliberate re-review of a newer commit still posts.
- Reviews check out `refs/pull/N/head`, so they work after the branch is deleted.
- Fixed: a bare `run --pr N` no longer fans out across every watched repo, a busy
  scheduler no longer makes it exit silently, and the daily cap no longer blocks a
  review someone explicitly asked for.

### The app

- A SwiftUI menu bar app replaces the old web panel: first-run setup (GitHub
  sign-in, reviewer, repos), a Settings window, and a Health pane with one-click
  fixes. The app carries its own copy of the engine, so an install is one file.
- Pick a model from a menu of what your provider actually offers, instead of
  typing a name — or switch account, provider and model straight from the popover
  header. Right-click any review or PR for its actions; chips, file locations and
  counts are clickable.
- Review window keyboard: ↑/↓ or j/k between findings, Space to include or drop,
  E to edit, ⌘↩ to post (never while you are typing), Esc to close.
- Usage (Settings > About): reviews per day for two weeks and per provider/model,
  with dollars where the provider reports them. Team: whose Goblin is active, from
  `goblin fleet status`.
- New app icon, menu bar glyph and goblin artwork.
- UI overhaul: smoother motion (Reduce Motion is respected), gliding tabs with
  counts, severity dots, hover states, and a header that shows what the Goblin is
  doing.
- Ships as a drag-to-Applications disk image; a Homebrew cask template is included.
- **Install update** (More menu, Settings > About, or `goblin update install`): downloads
  the latest release, refuses it unless its checksum matches, it is newer and final, and
  (for a signed install) it is signed by the same team, then swaps it in and restarts.
  See [Updating](README.md#updating). Releases now publish `SHA256SUMS`.

### A more careful reviewer

- Review rules (AGENTS.md, review guides) are read from the PR's **base branch**, so
  a PR cannot rewrite the rules it is graded by.
- The model reads the PR from a **read-only checkout**: Claude is confined to
  reading files in it, Cursor runs in ask mode, Codex gets a strict output schema.
- **Double-check pass**: before an unattended review posts, a skeptical second look
  can drop or downgrade findings (never add or upgrade them). It fails open and
  notes what it removed. Toggle: `refutePass`.
- **Risk read**: the preview shows the model's assessment of risk and blast radius.
- `goblin stats` reads posted threads back from GitHub and sorts findings into
  likely addressed, discussed or ignored, so you can see whether reviews help. Also
  shown in the popover and Settings > About.

### Found by a real end-to-end run

- "✅ no longer flagged" is replied only on a finding the model checked and says is
  fixed (`fixed_prior`), and only once per thread. Before, every earlier finding the
  new review did not repeat got the reply, including ones still unfixed.
- The commit status no longer carries emoji, which GitHub refuses: a posted review
  now turns the `goblin/review` check green instead of leaving it pending.
- A run that is killed (a reinstall, a crash) no longer blocks the scheduler for
  three hours: the lock records its owner and is cleared as soon as that owner is gone.

### Fixes from an audit

- Engine: the repo lock is keyed by repo, not PR number; transient claim failures
  are retried instead of remembered as "taken"; hidden markers are only trusted from
  you and your fleet; ticket keys are no longer guessed from prose; quoted PR text
  cannot break out of its prompt fence; an option missing its value no longer hangs.
- App: a failed post keeps the preview and your edits; posting cannot be started
  twice; Discard asks first; non-https links in findings are inert; `goblin://`
  links ask before starting a review.
- The installer no longer leaves the machine without a scheduler when re-run.
