# Artwork

AI-generated raster art (image generation, 2026-10-20) of one character: a hooded goblin with
a glowing git-merge mark. `prompts.json` has the prompts, so anything here can be redone in the
same style. Nothing is hand-drawn except `goblin-bar.svg`, the code-drawn fallback glyph.

| file | size | used for |
|---|---|---|
| `app-icon.png` | 1024, alpha | the app icon (`goblin.icns`) and the popover avatar |
| `menu-bar-glyph.png` | 1024, alpha | the menu bar silhouette (a template image: macOS tints it) |
| `mascot/*.png` | 512, alpha | idle-wave, sleeping, reviewing, alert, empty: in-app illustrations |
| `hero.png` | 1600×600 | top of the README |
| `social-preview.png` | 1280×640 | GitHub → Settings → Social preview (upload by hand) |
| `dmg-background.png` | 1320×800 | the installer window, shown at 660×400 |
| `alternates/` | | the two icon styles and glyph that were not chosen |

Regenerate the app's copies after changing any of the above:

```bash
swift scripts/make-icons.swift
```

The menu bar glyph is all `(0,0,0)` with transparent eyes and grin. If it is replaced,
keep it that way: no colour, no gradients, no thin lines, or it will not survive at 18pt.
