# Knowledge Capture — one front door, every source

## Status: Active

The standing procedure for getting knowledge INTO the McRitchie knowledge
layer: documents, transcripts, spreadsheets, brain-dumps — from any source,
for any entity — through ONE central funnel in McRitchie Studio, then filed by
one protocol. Alex approved the design 2026-09-02; the first 61
documents (the Commercial Welding data room + LOI) were filed with it.

It stands alone — every command inline. The knowledge layer's storage rules
live in [`object-storage.md`](object-storage.md); this module owns the FLOW.

## The six mouths, one funnel

| Source | How it arrives |
|---|---|
| **Email** | forward to **`team@mcritchie.studio`** — the Google group that is ALSO the fleet's transactional From, so replies to app mail enter the same funnel (group member `team@in.mcritchie.studio` → Resend inbound → svix-signed `email.received` webhook → hub ingest job re-stores the raw in the private `mcritchie-studio-desk` bucket → `/admin/desk`) |
| **File drop** | `mcritchie-industries/business-data/_inbox/` — folders, zips, anything; do not pre-sort |
| **Chat** | hand a path or paste content to a session and say what it is |
| **UI upload** | the entity app's `/admin/knowledge` intake form |
| **Slack** | `bin/rails slack:pull` in the entity app — one JSON archive per channel per calendar month. Connecting, reading and categorizing a channel is its own SOP: [`slack-capture.md`](slack-capture.md) |
| **Gmail** | `bin/rails gmail:pull` on the hub — a READ-ONLY pull of query-matching mail from Alex's own mailbox into this same desk queue, so deal correspondence arrives without a hand-forward. Connecting, reading and revoking it is its own SOP: [`gmail-capture.md`](gmail-capture.md) |

Everything converges on the same protocol below. Email specifics:

- **Allowlist or quarantine.** Only Alex's addresses
  (`DESK_ALLOWED_SENDERS`) are parsed. Anything else lands `quarantined` —
  raw kept sealed in the desk bucket, attachments never extracted. The team
  address is public-facing by design; treat unexpected mail as untrusted input, always.
- **Entity routing hints:** a `[welding]` / `[industries]` subject tag, or a
  plus-address (`team+welding@…`). A hint is advice for the sweep — never
  trusted blindly.
- The arrivals queue is `/admin/desk` on the hub; the model is
  `DeskCaptureItem` (`awaiting_sweep` scope).
- **`source` says which door an item came through, and the allowlist above is
  the PUBLIC door's rule only.** A `gmail` item is trusted by construction —
  it was already in Alex's mailbox and matched a query we control, so
  a counterparty in `From:` is the expected truth there rather than a stranger
  at a guessable address. Read `source` before reading a `received` status as
  an allowlist decision. Trust is keyed on the transport our code passes, never
  on a header in the mail.

## The intake protocol (per item — runs at ARRIVAL, never batched)

For each item, in order:

1. **Read it.** The whole document for anything load-bearing; enough to
   classify honestly for bulk statements. Never file what you have not opened.
2. **Cross-reference** against the current knowledge state. A contradiction
   with a filed fact goes to the discrepancy record with both readings —
   finding these is half the point.
3. **Classify:** entity · folder path · category · **as-of date** (the
   document's own date, not today's) · status (`inbox` if untriaged, `filed`
   if classification is confident).
4. **Set the access map** — per-agent levels `full` / `aware` / `none`.
   `aware` carries the safe `summary` + boundary line (an agent with a hole in
   its context confabulates; one with an awareness entry has something true to
   say and a line to hold). **Unsure defaults to the deal side (Samson-only)**
   — promoting later is one edit; a leak the other way is not.
5. **File it:** original to the entity's PRIVATE production bucket under
   `knowledge/<entity>/<path>/…` + a `Studio::KnowledgeDoc` row; link the
   expectation it fulfills (`expectation_id`) when one exists. Keep the
   repo-side original in `business-data/` per its README, one INDEX row each.
   A durable fact the item establishes (a code, a date, an address, an
   advisor) also gets its row in the quick reference,
   `business-data/FACTS.md` — cited back to this doc, with who asserted it;
   see [the quick reference](#the-quick-reference--when-to-pull-from-facts-when-to-add-to-it).
6. **Flag urgency:** a decision-changing fact (a moved date, a changed number)
   jumps the queue — surface it to Alex immediately rather than
   waiting for distillation.
7. **Offer the contact:** if a team@ item carries someone else's email
   signature, run [`contact-capture`](contact-capture.md). It asks Alex
   whether to create or update that person's Apple Contacts card, and writes
   nothing without his answer.

## Distillation (batched — knowledge is relational)

Filing is per-item; DISTRIBUTION into agent context is batched, because
meaning comes from documents read against each other:

- **When:** end of a feeding session, ~10 items, or before a milestone.
- **What:** read the batch AS A SET against each agent's BRIEF → update
  detailed knowledge files at each agent's access level → **re-weigh the
  BRIEF as a whole** (rewrite, never append) → sweep the discrepancy record
  with cross-document eyes → return substantive questions.
- Until the agents (Samson/Dawn) stand up, filed items simply queue; the
  first distillation batch is the birth event of the agent that reads it.

## The sweep (the email leg's act)

From the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Workflow --reason "knowledge-capture sweep"
bin/mail desk --since 7d            # the queue: id, Denver time, source, status, from, subject, attachments
bin/mail desk <id> --save <dir>     # one item's body; --save writes its raw .eml and every attachment
```

**`bin/mail` is THE way to read an item.** Do not hand-write `heroku run … rails
runner` one-liners: each verb is one read-only `heroku run`, and `--save`
defaults to `$TMPDIR/mail/desk-<id>`. On a quarantined item it prints the
`Authentication-Results` dkim verdict and "report to operator", never the body,
and saves nothing. To read a thread straight from Alex's mailbox, no forward
needed: `bin/mail thread '<gmail query>' --save <dir>`
([`gmail-capture.md`](gmail-capture.md)).

**Check the email leg before trusting an empty queue.** `bin/mail doctor` (the
same check as `bin/rails desk:health`, and the daily `DeskHealthJob`, which files
an `ErrorLog` on failure) requires the `in.mcritchie.studio` MX to point at
`inbound-smtp.us-east-1.amazonaws.com` and every Resend-received email to have a
desk item. Resend's domain page is not a health signal: it showed every record
"verified" through the 2026-09-29 to 10-02 outage, when that MX was missing.

For each awaiting item: run the intake protocol on its body and attachments
(raw + parsed parts live in the private `mcritchie-studio-desk` bucket: S3 us-east-1, or R2 once `DESK_CAPTURE_BACKEND=r2`; raw arrives via the Resend ingest job — Resend's own download URLs are temporary, the bucket copy is the durable one),
then stamp the outcome — `status` to `filed` (or `ignored`) and one line in
`filed_note` saying what was done and where it went. Quarantined items are
REPORTED to Alex, never processed, never deleted.

## The quick reference — when to pull from FACTS, when to add to it

`business-data/FACTS.md`, in the private `mcritchie-industries` repo, holds the
answers sessions keep reaching for. Every row gives the value, an as-of date,
a source (a knowledge doc `KD #n`, a filed path, a public page, or Alex's own
word with its date), **who asserted it**, and a History column. It is the fast
answer; the source it cites holds the context behind it. This rule applies
in **any** session, not only during capture.

**Pull from it first** whenever your work needs a fact about Alex's companies:
an entity's legal name, EIN, formation date, address, industry code,
headcount, advisors, or the deal's key dates. That includes:

- answering Alex's question in chat ("what's our EIN?");
- filling any form or application (the [`form-fill`](form-fill.md) SOP);
- drafting an email, letter, or brief that states a company fact;
- checking a figure in a transcript or document against what is on file.

Before you use a value, read its **History & notes** cell. A conflict recorded
there is a question for Alex, not a value to copy. If the fact is missing,
search the knowledge layer and filed originals, then add the row you had to
dig for.

**Add to it in the same pass** whenever a session learns a durable fact,
however it arrived: capture (email, Slack, Gmail, file drop), a call
transcript, a form-fill, research on a public page, or Alex telling you in chat.
**Durable** means a reference fact someone will ask for again. A figure that
moves weekly (a price, a peg, a balance) stays in its knowledge doc.

- Record **who said it** ("the seller says", "Alex chose"). In an inline
  email reply, name the speaker from the text, not from the layout.
- When a fact changes, update the value and move the old one into History.
  Don't overwrite it.
- When two sources disagree, record both readings, which one is in use, and
  why.
- The source must be on file. If the fact came from an email or document the
  layer doesn't hold yet, file it through this SOP's intake protocol first.

**What never goes in:** privileged deal content (APA terms, negotiating
positions, buyer-side arithmetic). It stays behind its knowledge doc's access
map, because FACTS is readable by anyone with the repo. And **no FACTS value
is ever copied into this public repo**, the task board, a PR body, or an
Artifact.

## Traps

- **Name the item before you file it.** "The last email forwarded" is ambiguous:
  the queue holds several unswept forwards, and Alex's own cc'd replies arrive
  newer than the forward he means. List the `awaiting_sweep` items one line each,
  say which you picked, and read before you file or ship.
- **A quarantined item looks empty, not blocked.** Its body and attachment
  columns are blank; the raw `.eml` is sealed in the desk bucket. Report it.
- **Filing crosses two apps.** The desk queue is on the hub; `Studio::KnowledgeDoc`
  rows live on the entity app. A query for them on the hub returns 0, which reads
  as an empty layer rather than the wrong app.
- **Read a document's metadata before its text.** `file <document>` shows an
  Office or PDF file's title, author, last editor and edit time, which can reveal
  a recycled template the body hides.
- **A returned draft is diffed, not skimmed.** The same filename can be a new
  revision (compare byte sizes), and a redline marks edits against the original,
  not against the last round. Check every decision from the last call landed.
- **Read the prior thread before drafting a reply** (`bin/mail thread` or
  `workspace:thread`): list what was already said and what is still unanswered.
  After Alex sends, file the SENT message, not the draft.

## Boundaries

- Everything here is confidential by default: private buckets, private repos,
  presigned links only — never an artifact, never a public store.
- Capture never merges, deploys, or touches the release ladder; it writes
  knowledge stores and board notes only.
- A filed document must not wait on CI — data commits ride
  `business-data/` directly, per that store's README.
