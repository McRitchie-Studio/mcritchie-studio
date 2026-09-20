# Content Build

## Status: Active

This is Turf Monster's `content-build` SOP. It drains the content board's `idea`
column: for each finished game waiting there, it writes the take, the script and
the scene list, hands the wording to Mason, and leaves the card ready for
rendering.

It is Turf Monster's because the substance of a game recap is a **sports read**.
Whether a 24-17 win was a statement or a survival, whether the story is the
quarterback or the offensive line, whether anyone outside that city cares — those
are judged against knowing the sport, not against knowing the pipeline.

**It is a QUEUE DRAIN, not a schedule.** Ideas accumulate on the board on their
own as games finalise. You run this when there is a queue worth draining —
typically the morning after a slate. There is no cron behind it and there should
not be: one session writing a whole slate is far more coherent than sixteen
scattered ones, because you can see the week's takes next to each other and
avoid writing the same sentence four times.

## The split — read this before running anything

**You decide the words. You decide nothing else.**

| Deterministic — the code | Agentic — you |
|---|---|
| Which games exist, and their scores | Whether a game is worth posting about |
| Creating the idea card | The take — what actually mattered |
| Claiming, leasing, releasing | The script and the scene list |
| Rendering images and video | The caption, before Mason sees it |
| Assembly, music, posting | Whether a card should be skipped |

If you find yourself reasoning about **what the score was**, stop. The score is
recorded, it is in `game_facts`, and it is not yours to decide. Your judgment is
spent on what the game MEANT.

**Never write a scoreline from memory.** Every number in your take comes from
`game_facts` on the card. The API refuses to let you edit those fields for this
exact reason — a video about a game that did not happen is the worst thing this
pipeline can produce.

## Scope

This SOP writes words onto content cards. It does not render, does not assemble,
does not post, and does not spend Higgsfield credits. It never touches
`release`/`main` and holds no deploy lane.

## Entry

```bash
cd /Users/alex/projects/mcritchie-studio
bin/content list --stage idea --workflow game_recap --claimable
```

That is the queue. If it prints `no content`, there is nothing to do and you are
done — say so and stop.

## Preconditions

**1. You can reach the board.** `bin/content list` resolves `AGENT_API_SECRET`
from ENV, then the repo `.env`, then 1Password. If it dies on auth, that is the
`token-session` SOP, not this one.

**2. You have a session.** `bin/content` writes one per desk to
`tmp/content-session` and reuses it, so a claim and its release pair up across
processes. Do not pass a fresh `--session` per command; that is how a release
starts looking like a stranger's.

## The loop — one card at a time

### 1. Claim

```bash
bin/content claim --agent turf-monster --workflow game_recap
```

The SERVER picks which card. It prints the card with its `game_facts`. An empty
claim prints `nothing to claim` and exits 0 — that is a normal end, not a
failure.

**Claim one, finish it, release it, then claim the next.** Do not claim the whole
queue up front: the lease is 30 minutes, and a card you claimed an hour ago has
already been handed to someone else.

### 2. Decide whether it is worth posting

Look at the facts before you write. Some games are not worth a video: a 13-point
blowout of a bad team in week 4 with no story in it is filler, and filler is how
an account teaches people to scroll past it.

If it is not worth posting, release it and say why:

```bash
bin/content release <slug>
```

Skipping is a legitimate outcome of this SOP and you should expect to use it.
**A slate where every single game earned a video is a slate you did not judge.**

### 3. Write the take

One sentence, in your voice, that a fan would repeat. It must be true against
`game_facts` and it must be about what MATTERED, not what happened — "Bills won
24-17" is the card's title, not a take.

Then the script (15-30 seconds spoken) and the scene list. Scenes carry
`number`, `description`, `camera`, `duration` and `characters`.

**Write it to a file rather than a shell argument.** A script has newlines,
quotes and dollar signs in it, and a shell argument eats all three.

```bash
cat > /tmp/take.txt <<'EOF'
<the script>
EOF

cat > /tmp/scenes.json <<'EOF'
[{"number":1,"description":"...","camera":"...","duration":5,"characters":[]}]
EOF
```

### 4. Mason's voice pass — the seam, so it does not get relitigated

**You set whether the take is RIGHT. Mason sets whether the sentence is OURS.**
That is the same seam [`content-sprint`](../../rex/sops/content-sprint.md)
already defines, one level down, and it is not negotiable in either direction:
he does not overrule your read of the game, and you do not overrule his read of
the voice. He can veto a line; if he does, rewrite it rather than argue it.

Hand him the take and the caption. Anything visual goes to Shannon. Anything
claiming what the product DOES gets a check from Avi before it leaves.

### 5. Write it back

```bash
bin/content write <slug> \
  --script-file /tmp/take.txt \
  --scenes-file /tmp/scenes.json \
  --caption "<Mason's line>" \
  --stage script
```

`--stage script` advances the card. Leave the stage off if you want to save work
in progress without moving it.

### 6. Release

```bash
bin/content release <slug>
```

Then claim the next. **Release even when you skip** — an unreleased card sits
invisible for 30 minutes.

## What good looks like

- Every number in every take traces to `game_facts`.
- The takes across one slate do not all have the same shape. Four cards that
  open "You won't believe..." is one card written four times.
- Some cards were skipped, with a reason.
- Nothing is left claimed when you stop.

## When to stop and escalate

- **`game_facts` is empty or disagrees with itself** — do not guess the score.
  Release the card and report it; the deterministic half wrote it and the
  deterministic half is wrong.
- **The queue is full of games from a slate you do not recognise** — check you
  are pointed at production before writing sixteen takes into a dev database.
- **Mason vetoes the same line shape repeatedly** — stop writing that shape and
  ask him for the pattern, rather than producing sixteen he will veto.

## Handoff

Report to Mr. McRitchie with the slug list, how many you wrote, how many you
skipped and why, and the board URL. The cards now sit at `script` waiting on
rendering — which needs Higgsfield credits, and is not this SOP's act.

---

## Background — not needed to execute

Why inference lives here and not in the app: the in-app agents
(`Content::ScriptAgent` and friends) call the Anthropic API directly on a key
production does not have, with prompts frozen as string literals in `.rb` files.
Routing the judgment through a soul means no model key in production, prompts
that improve as prose, inference visible to the learning loop, and a voice veto
that can actually fire. Architecture:
[`content-pipeline.md`](../../../../topics/content-pipeline.md).
