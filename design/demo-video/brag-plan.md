# Merge Goblin — brag plan (v2: the real app, on a real-looking Mac)

## What changed from v1
v1 rebuilt the app in HTML on a dark, neon-green backdrop with glowing AI art. It read as "AI made this".
v2 shows the product doing its job, the way an edited screen recording does:

- Every app screen is the real SwiftUI view, rendered by the app's own `--snapshot` mode from the
  demo sandbox (`scripts/demo-home.sh`), in each state: idle, fetching, reading, reviewing, ready to read.
  The ⌥⌘G quick panel is the real `ReviewField` as it is typed into.
- The GitHub scene is a screenshot of a real public review: Merge Goblin on Kiril-P/merge-goblin#1.
- Light mode on a plain Mac desktop: an original wallpaper (generated once, calm colour fields, no glow),
  a light menu bar drawn with real SF Symbols, and a macOS notification using the engine's real wording.
- Camera push-ins on whatever is in use, plain white captions, the mascot only as the app icon.

## Privacy
PRs and people are the demo sandbox's invented ones (acme/*, grace, linus, margaret). The only real
review shown is public, on this repo.

## Storyboard (22.0 s, 1920×1080, 30 fps; the Mac is 1280×720 pt drawn at 1.5×)
| t | On screen | Caption |
|---|---|---|
| 0.0–1.9 | Popover open, pushed in: Waiting for you 3 | Three pull requests want your review. |
| 1.9–6.5 | Popover closes; ⌥⌘G keystroke; quick panel; 8, 7, 3 typed; it resolves to the PR; Review | Press ⌥⌘G and type its number. |
| 6.5–12.0 | Cursor clicks the menu bar goblin; popover shows the review: fetching → reading → reviewing → ready; notification "The Merge Goblin finished 👺" | He reads the diff, your repo's rules and the ticket. |
| 12.0–16.5 | Review window: summary, intent check, findings, Discard / Post to GitHub | You read it first. Drop what you disagree with. |
| 16.5–19.8 | The real review on GitHub, scrolling to the suggested change | Then it's one review on GitHub, clearly labelled as his. |
| 19.8–22.0 | App icon, Merge Goblin, the brew line | Code review on the AI subscription you already pay for. |
