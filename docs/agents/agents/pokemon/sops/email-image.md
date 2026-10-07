# Email Image

## Status: Active

The Pokémon's `email-image` SOP: make the header image for one transactional
email, in a Claude Code session, with Alex. You show him what the brand's headers
are made from, take his direction and his copy, generate candidates through the
hub, show them to him inline, iterate on his notes, and approve only when he
says so. Then you export the image and wire it into the app's mailer.

Alex asked for it this way on 2026-10-06: "The actual generation of the image
should come through a Claude Code SOP. That way you can show me the base list of
assets and I can tell you the changes and copy to put on the email." The hub's
`/email_images` page stays as the record and review page; its Generate button
is a fallback.

The builder of a new email runs it. Mason has a veto on the headline wording,
Shannon is the visual light on the PR, and Alex approves the image.

Plan and background: `/Users/alex/projects/.agents/epics/email-image-builder.md`
(piece 6).

## The split: read this before running anything

**You run the conversation and judge the art. The hub does everything else.**

| Deterministic: the hub | Agentic: you |
|---|---|
| The brand kit: references, palette, style, the "never" list (`config/email_brand_kits.yml`) | What the email is for, and which brand |
| The generator call, the crop to 1200x600, the byte budget, our copy on R2 | The headline and subtext, from Alex's copy |
| The round cap, the claim, the cost record | Each round's direction, in a sentence the model can use |
| Approve, retire, export, the catalog snippet | Judging candidates for brand fit before Alex sees them |
| | Asking Alex; recording his word |

**You never approve on your own judgment.** `approve` takes `--by <who>` and
stores it as the approver. Pass `--by alex` only after Alex has said, in this
conversation, which candidate he wants.

## Scope

One brief (one email, one variant) per run of the loop. This SOP buys images on
the hub's OpenAI key, writes `email_image_briefs` and `artifacts` rows, and
writes one image file into the app's desk. It never merges, deploys, or touches
`release` or `main`; the image ships inside the email's own task.

## Entry: pick where the CLI runs

Every step below is `bin/email-image <subcommand>`. Run `bin/email-image --help`
for the reference; it is safe anywhere on the line and starts nothing.

**(a) On the production hub. Recommended.** The OpenAI key and the R2 bucket live
there, and the approval lands on the record Alex's page reads.

```bash
heroku run --no-tty --exit-code -a mcritchie-studio -- bin/email-image <subcommand> …
```

`--` keeps the CLI's own flags (`--notes`, `--no-download`) away from the
Heroku CLI, `--exit-code` passes the CLI's status back (0 done, 1 refused or the
round failed, 2 usage), and `--no-tty` keeps it non-interactive: every subcommand
takes its input from flags, prints, and exits. The one-off dyno's disk vanishes when the command
ends, so the files it writes are useless to you. Read the `url=` field instead
and fetch each image into your scratch directory, then open it with Read:

```bash
dir=tmp/email-image/<brief-slug>   # or your session scratchpad
mkdir -p "$dir" && curl -sSfo "$dir/<artifact>.jpg" "<url>"
```

Pass `--no-download` on the dyno to skip the pointless copy. Reference images
print hub URLs (`https://mcritchie.studio/…`); candidates and approved headers
print `https://assets.mcritchie.studio/…`.

**(b) Locally, in a hub desk, with `OPENAI_API_KEY` set** (the 1Password row
`openai.studio.applications`; never print it). Images land under
`tmp/email-image/` (or `--out <dir>`) and you Read them directly. The records
land in the desk's development database, not production, so an approval made
here is not on Alex's page. Use it for a dry run, or when the hub is down.

## Preconditions

1. **The email exists and has a task.** You are building the email (or its
   header) under `bin/task begin`; the image rides that task's PR. No task, stop
   and open one.
2. **The brand has a kit.** `bin/email-image assets <kit>` lists it; the kits are
   `turf-monster`, `mcritchie-studio`, `mcritchie-industries`. A new brand is a
   change to `config/email_brand_kits.yml` (its own task), not an improvisation.
3. **A generator is configured.** If `generate` answers "set OPENAI_API_KEY",
   stop and say so; it spent nothing.

## The loop: one brief

### 1. Brief

Ask Alex, or read from the email's task: which app and email key, which variant,
the headline, the subtext, and the text mode.

```bash
bin/email-image brief --app turf-monster --email drop_signup_confirmation \
  --variant new_player --brand turf-monster \
  --headline "You're In!" --subtext "Picks open Friday" --text-mode baked
```

- `--text-mode baked` draws the headline into the art (the house look of every
  Turf banner today); `none` leaves the art wordless for the engine's layered
  banner to set the headline as live text. `composited` is not built yet.
- The headline is the alt text unless `--alt` says better. Keep it short: the
  model spelled a three-word headline right; longer is unmeasured.
- `--notes` holds standing direction for every round of this brief.
- It prints `created <slug>` with the page path. A brief already open for that
  email answers "has already been taken"; use `bin/email-image list` and edit
  it with `bin/email-image brief <slug> --headline …`.

### 2. Show Alex the base assets

```bash
bin/email-image assets turf-monster
```

It prints the kit, its palette, each reference (`reference mascot …`,
`reference style …`), a palette swatch, the style and never-lists, and every
header already approved for that brand (`approved …`). Open each `file=` (or
fetch each `url=` in mode (a)) with Read so Alex sees them in the conversation,
then summarise in two lines what the model will be handed: the mascot or mark,
the style anchor, the colours.

### 3. Take his direction and copy

Ask Alex what to change from the base look and confirm the exact words. Put
copy changes on the brief (`brief <slug> --headline …`), and turn his visual
direction into one or two plain sentences for the round. Concrete beats
adjectival: "the gator holds a golden ticket, stadium lights behind" works;
"make it pop" does not.

### 4. Generate a round

```bash
bin/email-image generate <slug> --notes "the gator holds a golden ticket"
```

It runs the round in the foreground and waits: two candidates, each about
**45 to 60 seconds** (measured 2026-10-06: 43.3 s and 58.7 s, about 100 s for the
round with crop and upload). **Do not run it twice at once**; a second call while
one runs is refused and spends nothing. Each image costs **5,000 to 7,000 tokens**
(measured 5,251 and 6,889); no dollar rate is declared, so cost prints as
`unpriced`, which means unknown, never free.

The output is one `round` line (round `1/4`, state, units, seconds, your notes)
and one `candidate` line per image with its slug, `file=` and `url=`. The notes
are recorded on each candidate's stored prompt, so `show` can say later which
direction produced which image.

### 5. Judge, then show the candidates inline

Open every candidate yourself first. Retire the plain misses before Alex sees
them (`bin/email-image retire <slug> <artifact>`), and tell him you did:

- a misspelled or extra word in a `baked` headline, or any lettering in `none`;
- the wrong mascot or mark, or off-palette colours;
- **anything that looks like a real person, a real athlete, a team crest or a
  jersey.** Never show it as a candidate; retire it and say so.

Then Read the rest into the conversation, side by side, each with its slug.

### 6. Iterate on his notes

Each new direction is a new round on the same brief:

```bash
bin/email-image generate <slug> --notes "<his note, in one sentence>"
bin/email-image show <slug>        # every candidate, oldest round first, with its notes
```

A brief has **four rounds** (two candidates each). `round 3/4` means one left;
say so before you spend it. **Ask Alex before raising the cap**; with his yes:

```bash
bin/email-image brief <slug> --max-rounds 6
```

Four rounds with nothing he likes means the brief is wrong, not the count:
change the headline, the text mode or the notes, and say which.

### 7. Approve, only on his word

When Alex names a candidate ("the second one", "approve artifact-…"), confirm
the slug back to him and record it:

```bash
bin/email-image approve <slug> <artifact-slug> --by alex
```

Approving a second candidate retires the first; one header ships per email.
The brief page shows the approved one inside the real email shell; give Alex the
link (`https://mcritchie.studio/email_images/<slug>`) if he wants to see it
there.

### 8. Export into the app's desk

In mode (b), from the hub desk:

```bash
bin/email-image export <slug> --into <app-desk>/app/assets/images/emails/
```

It writes `<email>-<variant>-banner.jpg` and prints the
`Studio::EmailCatalog.register` snippet and the resolver line for the app.

In mode (a) the brief lives only in the production database, so a local export
cannot find it (`--image-url` swaps the image source, not the lookup). Run the
export on the dyno for the file name and the snippet, then fetch the approved
`url=` into the app's desk yourself:

```bash
heroku run --no-tty --exit-code -a mcritchie-studio -- bin/email-image export <slug> --into /tmp/
# it prints "wrote /tmp/<file>" and the snippet; then, locally:
curl -sSfo <app-desk>/app/assets/images/emails/<file> "<approved url=>"
```

### 9. Wire it to the mailer

Paste the snippet into the app's `config/initializers/studio_emails.rb`, with the
mailer preview, and set the mailer's image to
`Studio::EmailCatalog.resolved_url("<key>")` with the headline as alt. For the
Turf drop-signup emails this is epic piece 2: `DropSignupMailer.hero_image_resolver`
returns `{ url:, alt: }` per kind and variant.

### 10. Preview the render

Open the mailer preview and `/admin/emails/<key>` in the app's desk. Check: the
image shows at 600 px wide, its `alt` is the headline, the file is under 300 KB
(`ls -l`), and the email still reads with images off (the layout's `bgcolor`
fallback).

### 11. Ship

The image and its registration ride the email's task: `bin/submit-wait <task>
--launch -m "…"` from that desk, per `building-sop`. Shannon reviews the
visual.

## Email constraints the hub already holds

The CLI enforces these; know them so you can explain a refusal.

- JPG or PNG only (no SVG, WebP, AVIF or animation; Outlook shows frame one).
- 1200x600 for a 600 px slot (2x retina), centre-cropped from 1536x1024: keep the
  subject in the middle three quarters of the height.
- Under about 300 KB. A candidate still over after a second squeeze is refused,
  not stored, and the round reports it.
- One header per email; alt text always; absolute `https://` URLs on our own
  bucket, never a vendor CDN link or data URI.

## What good looks like

- Alex saw the base assets and every surviving candidate inline, in the
  conversation, before he chose.
- Every round carries his direction in its notes, and `show` tells the story.
- The approval reads `by alex`, made after his explicit word in the transcript.
- The app's mailer preview renders the header at 600 px with its alt.
- Two rounds or fewer for a clear brief; four is the ceiling, not the target.

## When to stop and escalate

- The generator is unconfigured (`set OPENAI_API_KEY`): report it; nothing was
  spent.
- A candidate shows a real person's likeness, a team crest, or third-party
  logos: retire it, tell Alex, and tighten the notes. Twice in a row, stop.
- The round cap is reached with nothing approvable: change the brief, and ask
  before raising `--max-rounds`.
- A round fails twice with the same error: stop and report the `round N
  failed:` line; the hub logged it against the brief.
- Alex is away: leave the candidates on the brief page, hand him the link, and
  approve nothing.

## Handoff

Report the brief slug and page link, the approved artifact slug, the exported
file path, rounds used and tokens spent, and the email task the image rides.

## Background

- Code: `bin/email-image`, `app/services/email_images/` (the CLI, `Build`,
  `Generate`, `Crop`, `BaseAssets`, `Export`), `config/email_brand_kits.yml`,
  the `openai_image_header` row in `config/image_generators.yml` (its measured
  block holds the latency and token figures quoted here).
- A round's notes are stored in each candidate's `prompt` as the line
  `Round <n> direction: <notes>` (no extra column); `EmailImages::Prompt.round_of`
  reads it back.
