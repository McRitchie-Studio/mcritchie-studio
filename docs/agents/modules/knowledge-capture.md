# Knowledge Capture — one front door, every source

## Status: Active

The standing procedure for getting knowledge INTO the McRitchie knowledge
layer: documents, transcripts, spreadsheets, brain-dumps — from any source,
for any entity — through ONE central funnel in McRitchie Studio, then filed by
one protocol. Mr. McRitchie approved the design 2026-09-02; the first 61
documents (the Commercial Welding data room + LOI) were filed with it.

It stands alone — every command inline. The knowledge layer's storage rules
live in [`object-storage.md`](object-storage.md); this module owns the FLOW.

## The four mouths, one funnel

| Source | How it arrives |
|---|---|
| **Email** | forward to **`desk@mcritchie.studio`** (Google alias → `desk@in.mcritchie.studio` → SES → the private `mcritchie-studio-desk` bucket → hub poller → `/admin/desk`) |
| **File drop** | `mcritchie-industries/business-data/_inbox/` — folders, zips, anything; do not pre-sort |
| **Chat** | hand a path or paste content to a session and say what it is |
| **UI upload** | the entity app's `/admin/knowledge` intake form |

Everything converges on the same protocol below. Email specifics:

- **Allowlist or quarantine.** Only Mr. McRitchie's addresses
  (`DESK_ALLOWED_SENDERS`) are parsed. Anything else lands `quarantined` —
  raw kept sealed in `incoming/`, attachments never extracted. The desk
  address is guessable; treat unexpected mail as untrusted input, always.
- **Entity routing hints:** a `[welding]` / `[industries]` subject tag, or a
  plus-address (`desk+welding@…`). A hint is advice for the sweep — never
  trusted blindly.
- The arrivals queue is `/admin/desk` on the hub; the model is
  `DeskCaptureItem` (`awaiting_sweep` scope).

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
6. **Flag urgency:** a decision-changing fact (a moved date, a changed number)
   jumps the queue — surface it to Mr. McRitchie immediately rather than
   waiting for distillation.

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
# the queue: /admin/desk, or
heroku run -a mcritchie-studio --no-tty rails runner \
  'DeskCaptureItem.awaiting_sweep.each { |i| puts "#{i.id} | #{i.from_addr} | #{i.subject} | hint=#{i.entity_hint}" }'
```

For each awaiting item: run the intake protocol on its body and attachments
(raw + parsed parts live in the `mcritchie-studio-desk` bucket, us-east-1),
then stamp the outcome — `status` to `filed` (or `ignored`) and one line in
`filed_note` saying what was done and where it went. Quarantined items are
REPORTED to Mr. McRitchie, never processed, never deleted.

## Boundaries

- Everything here is confidential by default: private buckets, private repos,
  presigned links only — never an artifact, never a public store.
- Capture never merges, deploys, or touches the release ladder; it writes
  knowledge stores and board notes only.
- A filed document must not wait on CI — data commits ride
  `business-data/` directly, per that store's README.
