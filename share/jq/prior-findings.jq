# prior-findings.jq — the Goblin's findings already posted on a pull request, and which
# of them the people on the PR declined.
#
# Input: EVERY pull request review comment on the PR, as one array (gh_api_all).
# Named args (read through $ARGS so the file compiles on its own for the hygiene test):
#   who       logins whose markers we trust (this account + the fleet)
#   ns        marker namespace ("goblin"); legacy: the pre-rename one ("bob")
#   resolved  REST ids of the first comment of every RESOLVED review thread
#
# Output: [{…marker fields (id, severity, …), commentId, path, line, title,
#           declined, declinedBy, declinedHow, fixedReplied}]
# fixedReplied: we already told this thread "no longer flagged"; never say it twice.
#
# DECLINED — a heuristic, on purpose kept small and readable:
#   * the thread is resolved, or
#   * somebody replied in the thread with one of the phrases below ("intentional",
#     "won't fix", "by design", "not a bug", "false positive", …), and the same reply
#     does not also say something that means the opposite ("not intentional",
#     "good catch", "will fix", "fixed", "you're right").
# Replies that carry one of our markers, our own "no longer flagged" note, and replies
# from bots are never read as a decline. The Goblin posts as the user, so a reply from
# the same login WITHOUT a marker is that person typing, and counts.
# A declined finding is never raised again on that PR; nothing is ever posted back.

($ARGS.named.who // []) as $who
| ($ARGS.named.ns // "goblin") as $ns
| ($ARGS.named.legacy // "bob") as $legacy
| ($ARGS.named.resolved // []) as $resolved
| def norm: gsub("[‘’ʼ]"; "'") | ascii_downcase;
  def decline_re: "\\b(intentional(ly)?|intended|by design|won'?t fix|wont ?fix|not a bug|false positive|not an issue|deliberate(ly)?|working as intended|expected behaviou?r|won'?t change|wont change|as designed)\\b";
  def accept_re: "\\b(not|isn'?t|wasn'?t|un) ?(intentional|intended|deliberate|by design)|\\b(good|nice|great) catch\\b|\\bwill fix\\b|\\bi'?ll fix\\b|\\bfixed\\b|\\bfixing\\b|\\byou'?re right\\b";
  def declines: norm | test(decline_re) and (test(accept_re) | not);
  def phrase: norm | (match(decline_re).string);
  def ours: test("<!-- (" + $ns + "|" + $legacy + "):");
  def botlike: (((.user.type // "") | ascii_downcase) == "bot") or ((.user.login // "") | test("\\[bot\\]$"));
. as $all
| [ $all[] | select(.in_reply_to_id != null) ] as $replies
| [ $all[]
    | . as $c
    | select(.body != null and ((.user.login // "") as $u | $who | index($u)))
    | (.body | capture("<!-- (?<ns>" + $ns + "|" + $legacy + "):finding (?<j>\\{.*?\\}) -->") // empty) as $mk
    | (try ($mk.j | fromjson) catch empty) as $pf
    | select(($pf | type) == "object")
    | ( [ $replies[]
          | select(.in_reply_to_id == $c.id)
          | select(botlike | not)
          | select(((.body // "") | ours) | not)
          | select(((.body // "") | test("no longer flagged as of")) | not)
          | select((.body // "") | declines) ] | first ) as $d
    | ( any($replies[]; .in_reply_to_id == $c.id
            and ((.body // "") | test("<!-- (" + $ns + "|" + $legacy + "):fixed |no longer flagged as of"))
            and ((.user.login // "") as $u | $who | index($u))) ) as $fx
    | $pf
      + { fixedReplied: $fx }
      + { commentId: $c.id, path: $c.path, line: ($c.line // $c.original_line),
          title: ((($c.body | capture("\\*\\*(?<t>[^*\\n]{1,200})\\*\\*")) | .t) // "") }
      + ( if $d != null then
            { declined: true, declinedBy: ($d.user.login // ""),
              declinedHow: ("replied “" + ($d.body | phrase) + "”") }
          elif ($resolved | index($c.id)) != null then
            { declined: true, declinedBy: "", declinedHow: "resolved the thread" }
          else { declined: false } end ) ]
