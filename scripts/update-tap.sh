#!/usr/bin/env bash
# scripts/update-tap.sh [version] — copy a published release's cask into the tap.
#
# The release workflow attaches merge-goblin.rb (version and sha256 filled in) to
# every release. This puts that file in Kiril-P/homebrew-tap as Casks/merge-goblin.rb
# and pushes, so `brew upgrade --cask merge-goblin` sees the new version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/brand.sh"
VERSION="${1:-$GOBLIN_VERSION}"
TAP="${GOBLIN_TAP_REPO:-Kiril-P/homebrew-tap}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
gh release download "v$VERSION" --repo Kiril-P/merge-goblin --pattern merge-goblin.rb --dir "$work"
grep -q "version \"$VERSION\"" "$work/merge-goblin.rb" || { echo "cask in v$VERSION does not say version $VERSION" >&2; exit 1; }
grep -qE 'sha256 "[0-9a-f]{64}"' "$work/merge-goblin.rb" || { echo "cask in v$VERSION has no sha256" >&2; exit 1; }

gh repo clone "$TAP" "$work/tap" -- --quiet
mkdir -p "$work/tap/Casks"
cp "$work/merge-goblin.rb" "$work/tap/Casks/merge-goblin.rb"
cd "$work/tap"
if git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ]; then
  echo "tap already has merge-goblin $VERSION"; exit 0
fi
git add Casks/merge-goblin.rb
git commit -qm "merge-goblin $VERSION"
git push -q
echo "tap updated: merge-goblin $VERSION"
