# Artwork

AI-generated raster art (image generation, 2026-10-20) of one character: a hooded goblin with
a glowing git-merge mark. `prompts.json` has the prompts, so anything here can be redone in the
same style. Nothing is hand-drawn except `goblin-bar.svg`, the code-drawn fallback glyph.

| file | size | used for |
|---|---|---|
| `app-icon.png` | 1024, alpha | the app icon (`goblin.icns`) and the popover avatar |
| `menu-bar-glyph.png` | 1024, alpha | the menu bar silhouette (a template image: macOS tints it) |
| `mascot/*.png` | 512, alpha | idle-wave, sleeping, reviewing, alert, empty: in-app illustrations |
| `hero.png` | 1600×600 | brand art; it used to top the README, which now opens with the demo video |
| `social-preview.png` | 1280×640 | GitHub → Settings → Social preview (upload by hand) |
| `dmg-background.png` | 1320×800 | the installer window, shown at 660×400 |
| `alternates/` | | the two icon styles and glyph that were not chosen |

Regenerate the app's copies after changing any of the above:

```bash
swift scripts/make-icons.swift
```

The menu bar glyph is all `(0,0,0)` with transparent eyes and grin. If it is replaced,
keep it that way: no colour, no gradients, no thin lines, or it will not survive at 18pt.

## The demo video

`docs/media/merge-goblin-demo.{mp4,gif}` (22 s) shows the real app, not a mockup.

- **App screens:** drawn by the app's own `--snapshot` mode from the demo sandbox (`scripts/demo-home.sh`), so the PRs and people in them are invented.
- **GitHub scene:** a screenshot of the real public review on PR #1.
- **Wallpaper:** `demo-video/wallpaper.jpg` is original, generated once.
- **Composition and storyboard:** `demo-video/index.html` draws each frame as a function of time, and `demo-video/brag-plan.md` is the storyboard.

To re-render:

```bash
./build.sh --dev                                    # the app, into build/
design/demo-video/states.sh design/demo-video       # popover in each state (idle → ready)
git apply design/demo-video/quick-panel-snapshot.patch && ./build.sh --dev
scripts/demo-home.sh /tmp/mgq > /dev/null
GOBLIN_HOME=/tmp/mgq GOBLIN_SNAPSHOT_QUICK=1 "build/Merge Goblin Dev.app/Contents/MacOS/GoblinBar" \
  --snapshot design/demo-video                       # the ⌥⌘G panel as it is typed into
git checkout Sources/Goblin/App/Snapshot.swift
cd design/demo-video
swift sym.swift                                      # SF Symbols for the menu bar (writes ui/; move them up)
# also copy in: ../app-icon.png, ../menu-bar-glyph.png, and a screenshot of the
# review on PR #1 as gh-review.png
npm i playwright && mkdir frames
node capture.mjs frames 30 22 frames                 # 660 PNGs
uv run --with numpy python audio.py                  # music.wav
ffmpeg -framerate 30 -i frames/f%05d.png -i music.wav -c:v libx264 -crf 21 \
  -pix_fmt yuv420p -c:a aac -shortest demo.mp4
```
