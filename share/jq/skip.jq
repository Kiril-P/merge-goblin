# skip.jq — should this pull request be left alone before any model runs?
#
# Input: {author: "<login>", files: ["path", …]}   (files may be [] when not fetched)
# Named arg (via $ARGS so the file compiles on its own): rules =
#   {bots, botLogins, docsOnly, docsPaths, paths}   — the merged global + per-repo `skip`
#
# Output: {skip: true, reason, detail} or {skip: false}
#   reason  bot_author | skip_paths | docs_only
#
# Globs (gitignore-flavoured, deliberately small):
#   *      any run of characters except "/"        **/  any number of directories
#   **     anything, "/" included                   ?    one character except "/"
#   a pattern WITHOUT a "/" matches the file name in any directory (yarn.lock, *.min.js);
#   a pattern WITH one matches the whole path from the repo root (dist/**, **/__snapshots__/**).
# A file list that is empty never skips: "no files" is the engine's error to report.

($ARGS.named.rules // {}) as $r
| def glob_re:
    ltrimstr("/")
    | gsub("(?<c>[.+^${}()\\[\\]|\\\\])"; "\\\(.c)")
    | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
    | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
    | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")
    | "^" + . + "$";
  def matches_any($globs):
    . as $p
    | any($globs[]?; . as $g
        | if ($g | contains("/")) then ($p | test($g | glob_re))
          else ($p | split("/") | last | test($g | glob_re)) end);
  def botname: ascii_downcase | ltrimstr("app/") | sub("\\[bot\\]$"; "");
  (.files // []) as $files
| (.author // "") as $author
| ($r.paths // []) as $noise
| ($r.docsPaths // ["*.md", "*.mdx", "*.markdown", "*.rst", "docs/**"]) as $docs
| if ($r.bots == true) and ($author != "")
     and ([($r.botLogins // [])[] | botname] | index($author | botname)) != null then
    { skip: true, reason: "bot_author",
      detail: "opened by \($author), a dependency bot (skip.bots)" }
  elif ($files | length) == 0 then
    { skip: false }
  elif ($noise | length) > 0 and all($files[]; matches_any($noise)) then
    { skip: true, reason: "skip_paths",
      detail: "only lockfiles or generated files changed (\($files | length) file\(if ($files | length) == 1 then "" else "s" end), all match skip.paths)" }
  elif ($r.docsOnly == true) and all($files[]; matches_any($docs) or matches_any($noise))
       and any($files[]; matches_any($docs)) then
    { skip: true, reason: "docs_only",
      detail: "only documentation changed (skip.docsOnly)" }
  else { skip: false } end
