# Merge Goblin — brag plan

## Answers
- **What is it:** a Mac menu bar app that reviews GitHub pull requests with the AI CLI you already pay for (Claude, Codex or Cursor) and posts one labelled review with line comments.
- **For whom:** developers who get asked to review PRs; teams that already have AI seats and don't want a per-seat review bot.
- **What sets it apart:** runs on your Mac and your subscription; reads the repo's own review rules; preview before it posts; never approves or blocks; one review, not twenty notifications.
- **Funniest true claim:** its verdict lines. "The Goblin refuses the merge." / "Suspiciously clean. Proceed."
- **Visual hook:** the hero art. The goblin is leaning on an empty glowing button. We put "Merge pull request" on it, then the goblin's answer.
- **Real UI to show:** the popover (rebuilt in HTML from PopoverView.swift / Theme.swift, dark mode), ⌥⌘G review field, job phases (real strings from Models.swift), the posted review (verdict header from lib/brand.sh, the real inline-review screenshot from docs/media).
- **Tone:** default, leaning polished. Dark, green glow, playful copy, clean motion.
- **Share caption:** a goblin now guards my merge button.

## Privacy
The live popover shows private work PRs. All PRs in the video are fictional (`acme/widgets`, invented titles). The inline review is the public screenshot from this repo (reviewer avatar already blurred).

## Identity
- Background #07110b → #0b1f13, green glow #5cd185 (Theme.accent dark), purple hood #6b2a8f, system blue #0a84ff for "reviewing", orange #ff9f0a.
- Type: SF Pro (system-ui), SF Mono for code. Popover 400×580 scaled 1.6×.

## Storyboard (20.0 s, 1920×1080, 30 fps)
| # | t | Scene | On screen | Sound |
|---|---|---|---|---|
| 1 | 0.0–3.4 | Hook | Hero art. "Merge pull request" types onto the glowing button, a cursor moves to click it, the button flips red: "👺 Not so fast." | music in; soft click; low thunk on flip |
| 2 | 3.4–7.4 | Reveal | Mac menu bar slides down, goblin glyph, popover drops open (on duty, Waiting for you: 3 PRs). Left title: "Merge Goblin" / "An AI code reviewer in your menu bar." | whoosh, pop |
| 3 | 7.4–12.0 | Review any PR | "⌥⌘G" keycap, "2456" typed, Review pressed; job row steps Fetching the diff → Reading the code → Reviewing → Ready to read. Left: "Type a PR number." / chips claude · codex · cursor "on the AI you already pay for". | key ticks, chime on Ready |
| 4 | 12.0–16.6 | The review | GitHub review card: badge, "The Goblin refuses the merge.", meta line, 🔴 1 blocker · 🟠 2 convention; inline comment slides in (real screenshot). Left: "One review. Line by line. By your repo's own rules." | swell |
| 5 | 16.6–20.0 | Outro | Idle-wave goblin, "Merge Goblin", `brew install --cask Kiril-P/tap/merge-goblin`, github.com/Kiril-P/merge-goblin · free & open source · macOS 14+ | resolve chord |

Sum: 3.4 + 4.0 + 4.6 + 4.6 + 3.4 = 20.0 s.
