# Post To X

## Status: Active

This is Turf Monster's `post-to-x` SOP. Alex hands over one or more finished
MP4 files, each with a line about what it is. You finish each caption, choose
the hashtags, show him the whole batch, and on his word post every one to
`@turfmonstershow` and report the links.

It is Turf Monster's because picking the tag a fan base actually uses, and
knowing whether a line about a game reads true, is a sports read.

**It is OPERATOR-TRIGGERED.** It runs when Alex hands you videos and never
otherwise. Nothing schedules it, and nothing here finds videos to post.

## The split — read this before running anything

| Alex | You | `bin/x-post` |
|---|---|---|
| Which videos, and the line for each | Tightening the line | Measuring the caption the way X does |
| Approving the batch, once | The hashtags and team handle | Refusing what X would refuse |
| Anything the caption claims as fact | Laying the batch out for approval | Uploading, posting, recording |

**You do not add facts.** A score, a stat, a name: it is in Alex's line or it is
not in the post. Tightening a sentence is yours; deciding what happened in the
game is not.

**A post is public the moment it lands, and this SOP has no undo.** That is why
the order below is fixed: check everything, show everything, then post.

## Scope

This SOP posts video to one X account. It does not render or edit video, does
not reply, quote, delete or schedule, and does not post to TikTok or Instagram.
It holds no release lane.

## Entry

```bash
cd /Users/alex/projects/mcritchie-studio
bin/x-post whoami
```

It must print `@turfmonstershow`. That one line proves three things at once:
the credentials resolve, X accepts them, and they belong to the account this
SOP posts as.

## Preconditions

**1. `whoami` printed `@turfmonstershow`.** Any other handle, stop: you are
holding another account's keys. An HTTP 401 or a 1Password failure is the
`token-session` SOP, not this one. The credentials are the `agent.turf.x` item
in the `studio-agents` vault, and `bin/x-post` reads them itself; never paste a
key into a command.

**2. Every video has a line from Alex.** A video with no line goes back to him
with a question. Do not write one from the filename.

**3. Every video is a file you can read.** A path he gave you that does not
resolve is a question for him, not a search of his disk.

## The loop

### 1. Write each caption to its own file

One directory per video, named for the video, and the whole path written out
at every site. The scratchpad is shared between sibling agents and no shell
variable survives a turn, so `caption.txt` alone is the filename that gets
overwritten.

```bash
mkdir -p "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<video-name>"

cat > "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<video-name>/caption.txt" <<'EOF'
<the finished line>
EOF
```

The caption goes in a file because it carries quotes, `$`, `#` and newlines,
and a shell argument eats all four.

**Finishing the line** means: cut it to one thought, put the hook first, keep
Alex's words where they already work, and fix spelling. It does not mean
rewriting his take into yours. If the line needs more than a trim, show him
both versions in the batch table.

### 2. Choose the hashtags

Tags and handles ride as flags, not in the caption file, so the command can
count and validate them.

- **A team in the video gets that team's own tag.** Read it; do not recall it:

  ```bash
  grep -i "<team name>" db/seeds/data/teams_hashtags.csv
  ```

  The `Hashtag` column is the tag, `HT2` a second one where the team has it,
  and `X` the team's handle where it is filled, stored without its `@`. An
  empty `X` cell means no handle: do not guess one.
- **One or two tags is the target. Three is the ceiling**, and the command
  refuses a fourth. A post that is half tags reads as spam and X ranks it that
  way.
- **Every tag must be about this video.** No trending tag borrowed for reach.
- **No link in the caption** unless Alex put one in his line. X bills a post
  with a link at several times a plain post, and the command says so when it
  sees one.

### 3. Check every post, before asking for anything

```bash
bin/x-post check <video.mp4> \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<video-name>/caption.txt" \
  --tag '#FlyEaglesFly' --handle @Eagles
```

`check` reads no credential and calls nothing. It prints the exact text, its
weight against X's 280, and the video's size, dimensions, frame rate and
length. It exits 1 with a `REFUSED` line for anything X would reject:

| Refusal | What to do |
|---|---|
| `weighs N, over X's 280` | Shorten the line. Emoji weigh 2, so `String#length` lies here |
| `Nfps, over X's 60` | The file needs re-encoding at 30fps. That is Alex's call; report it and leave it out of the batch |
| `ffprobe could not read a video stream` | The file is not a video, or is damaged. Report it |
| `not a hashtag` / `not a handle` | One word, leading `#` or `@`, no spaces |

Quote the tags: an unquoted `#` starts a shell comment and the flag arrives
empty.

### 4. Show Alex the batch, and wait for one word

One table, every post, nothing summarised:

| # | Video | Text exactly as `check` printed it | Weight | Length |
|---|---|---|---|---|

Under it, list anything refused and why, and anything where you changed more
than a trim. Then ask for the go.

**What he approves is the text in that table.** If a caption changes after his
yes, for any reason, re-run `check` and show him that row again. An approval
covers this batch; it does not carry to the next one.

### 5. Post, one at a time

The same command as the check, with `post` and `--yes`:

```bash
bin/x-post post <video.mp4> \
  --caption-file "${CLAUDE_SCRATCHPAD:-/tmp}/x-post/<video-name>/caption.txt" \
  --tag '#FlyEaglesFly' --handle @Eagles --yes
```

It re-runs the check, confirms the account, uploads, waits for X to process
the video, posts, and prints `posted: https://x.com/turfmonstershow/status/…`.
A video takes from a few seconds to a few minutes to process.

Post them in the order Alex gave. Do not run two at once.

**It will not post the same file twice.** Every success is written to a ledger
keyed by the file's sha256, and a second `post` of that file refuses and prints
the first post's link. So a run that was cut short is safe to re-run from the
top: finished posts refuse, unfinished ones go. `--again` overrides it, and
only Alex decides to post a video twice.

```bash
bin/x-post ledger
```

### 6. If X refuses

The command prints X's own words and records nothing. Stop the batch at the
first refusal you cannot explain; five more of the same refusal are five more
billed attempts.

| X says | Meaning | Action |
|---|---|---|
| 401 | The credentials no longer work | `token-session` |
| 403, with "duplicate" | That exact text was posted recently | Change the line; ask Alex |
| 403, otherwise | The X app lost write permission, or the account is restricted | Report to Alex verbatim |
| A message about credits, billing or usage | The developer account has no balance | Alex tops it up; only he holds the billing |
| 429 | Rate limited | Wait for the window X names, then resume |
| `media processing failed` | X could not transcode the file | Report the file; do not retry it unchanged |

## What good looks like

- Every post in the report matches the text Alex approved, character for
  character.
- No caption carries a fact Alex did not give.
- No post has more than three tags, and most have one or two.
- `bin/x-post ledger` lists every post in the report.

## Handoff

Report to Alex with one row per video: the file, the link, the text. Then what
was left out and why. The link comes from the command's `posted:` line or the
ledger, never from memory.

---

## Background — not needed to execute

`bin/x-post` wraps `X::PostMedia`, the uploader the Starter Post X workflow
already uses, described in `mcritchie-studio/docs/topics/content-pipeline.md`
(named rather than linked: the docs route serves from `docs/agents` only). The
upload is X's v2 chunked sequence, initialize, append, finalize and a status
read, signed with OAuth 1.0a. X switched off the v1.1 upload host on
2025-06-09; the uploader was moved to v2 on 2026-10-04, the day this SOP was
written.

X bills the API per call. Third-party price lists read on 2026-10-04 put a
plain post near $0.015 and a post with a link near $0.20; the developer
console is the authority, not this paragraph.
