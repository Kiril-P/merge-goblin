# Changelog

## 0.5.0

The Goblin is now a native Mac app, and you can hand it any PR yourself.

### Review any PR by number

- Type `2456`, `owner/repo#2456` or paste a PR link (popover, or ⌥⌘G anywhere) and
  the Goblin reviews it on demand. The CLI equivalent is `goblin review <ref>`.
- By default a review stops at a **preview**: read it, edit or drop findings, then
  post. `goblin post <job>` / `goblin cancel <job>` from the terminal.
- A ready review can be posted straight from its card in the popover.
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
  typing a name.
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

### Fixes from an audit

- Engine: the repo lock is keyed by repo, not PR number; transient claim failures
  are retried instead of remembered as "taken"; hidden markers are only trusted from
  you and your fleet; ticket keys are no longer guessed from prose; quoted PR text
  cannot break out of its prompt fence; an option missing its value no longer hangs.
- App: a failed post keeps the preview and your edits; posting cannot be started
  twice; Discard asks first; non-https links in findings are inert; `goblin://`
  links ask before starting a review.
- The installer no longer leaves the machine without a scheduler when re-run.
