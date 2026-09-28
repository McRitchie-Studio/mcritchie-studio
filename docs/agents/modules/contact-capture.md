# Contact Capture — offer a contact from a forwarded email's signature

## Status: Active

Alex keeps his iPhone contacts current by forwarding an email to
**`team@mcritchie.studio`**. The forward carries everything a card needs:
the sender's name, title, company, phones, email, address and, often, a
headshot. This SOP turns that signature into a created or corrected card in his
Apple Contacts, which iCloud syncs to his phone.

It is a step in the [`knowledge-capture`](knowledge-capture.md) sweep, run per
item at arrival, and it stands alone: every command is inline here. Approved
2026-09-28.

**The one rule: never write a card Alex has not approved.** A signature
is an *offer*, not an instruction. Not every signature should become a contact,
so the agent asks, and Alex decides.

---

## When it fires

For each desk item in the sweep, offer a contact when **all** of these hold:

1. **`source` is `resend`** (the team@ door) and the item is not
   `quarantined`. That means Alex forwarded it himself. A `gmail` pull item
   is deal correspondence matched by a query, and there are too many of those
   to prompt on. Offer from one only if Alex asks.
2. **The message carries a signature**: a block that gives a name plus at
   least one of title, company, phone or address. **Search the whole thread,
   not just the newest message.** Quick replies are often signed with a first
   name only, and the full block may appear only in the person's oldest
   message, at the bottom of the forward.
3. **The signature belongs to someone other than Alex.** Skip his own signatures
   and those of anyone at his addresses (`DESK_ALLOWED_SENDERS`). In a forwarded
   thread, the candidate is the **original sender** of the forwarded message.
   Each other distinct person who signs in the thread is a separate candidate.

The same steps apply when Alex hands a session a screenshot of a signature
directly in chat.

### When a forward does not arrive

- **Forward from an allowlisted address.** Mail from any address not in
  `DESK_ALLOWED_SENDERS` lands `quarantined`, and a quarantined item is
  reported, never processed. Adding an address is a production config change
  that only Alex can approve.
- **Type a line of text above the forward.** A blank re-forward of a thread
  that had already gone to team@ never reached Resend. Measured 2026-09-28: a
  12:30 PM forward arrived, a blank 1:02 PM re-forward of the same thread never
  did, and a 1:19 PM forward with one line of text arrived within a minute. The
  likely cause is the team@ Google group dropping a near-duplicate; that was
  not confirmed.
- **Check Resend before the hub.** If no desk item appears within a few
  minutes, list Resend's received mail (`GET /emails/receiving` with the hub's
  `RESEND_API_KEY`, from a dyno). If the message is not there, it stopped
  before our pipeline, and nothing in the hub will show it.

## What the agent asks

Run `find` first (below), then act on what it says:

| `find` reports | Ask Alex? | The question |
|---|---|---|
| No matching card | **Yes** | "Create a contact for *Name, Title at Company*?" Show the fields you read |
| A match whose diff has any `add` or `change` row | **Yes** | "Update *Name*?" Show a table of each `add`/`change` row: field, card value, signature value |
| A match whose rows are all `same` or `keep` | **No** | Report "*Name* is already current" in one line |
| Two or more matches | **Yes** | Name each match and its `reasons`, and ask which card it is, or whether this person needs a new card |

Ask with one question per person, offering **Create / Update**, **Skip** and,
when a headshot was found, **with photo** as a separate choice. Alex may accept
some fields and not others; each field he declines becomes a `--skip`. A skip
covers the whole field: `--skip phones` declines every new phone. To take one
new number and not another, drop the unwanted one from the card JSON instead. **Skip is a
real answer.** Record it in the item's `filed_note` and do not ask again for the
same email.

If Alex is not in the session (for example, an unattended sweep), do not write.
Stamp the item `contact pending: <Name>` in `filed_note`, and ask at the next
hand-back.

---

## Step 1 — Read the signature

Read the **raw `.eml`** from the private `mcritchie-studio-desk` bucket, not
`body_text`. The parser strips HTML, and the signature's layout (which line is
the title, which number is direct) and its images live in the HTML part.

Write the card as JSON in your scratchpad, named by the task or item
(`contact-<item-id>.json`). **Fill only what the signature says**, and never
guess a field:

```json
{
  "first_name": "", "last_name": "", "organization": "", "job_title": "",
  "phones":    [{ "label": "direct", "value": "" }, { "label": "work", "value": "" }],
  "emails":    [{ "label": "work", "value": "" }],
  "urls":      [{ "label": "work", "value": "" }],
  "addresses": [{ "label": "work", "street": "", "city": "", "state": "", "zip": "", "country": "" }],
  "note":      ""
}
```

- **Labels.** Use the signature's own word when it has one (`direct`, `mobile`,
  `office`, `fax`). Otherwise use `work`.
- **Note.** Put in the note what has no field of its own: license numbers,
  assistant's name, "prefers text". Leave out slogans, disclaimers and fraud
  warnings.
- **Company.** Use the company as the signature spells it ("Example Title of
  Colorado", not "ETC"). If the signature never names the company, you may
  infer it from the website or email domain, but **say that it is inferred**
  when you ask Alex. A footer naming another firm (a parent bank's security
  disclaimer, say) is a clue to mention, not the company.
- **Email.** Use the address as the signature displays it. If its `mailto:`
  link points somewhere else (displayed `pat@example.com`, linked
  `someone.else@example.com`), keep the displayed address and mention the
  mismatch when you ask.
- **Website.** Take the website from the link behind a globe icon. A tracking
  redirect is not the website; if the only URL is a redirect, leave `urls` out.

## Step 2 — The headshot

A signature image is either an **inline part** (a MIME part with a
`Content-ID`, stored with the item's attachments) or a **remote image**
(`<img src="https://…">` in the HTML).

- **Prefer an inline part.** It is already in the bucket.
- **A remote image is a request the sender's server can see.** Fetching it
  can tell them the email was opened. Say so when you offer the photo, and fetch
  it only after Alex says yes.
- **A face, not a logo.** A signature usually carries several images: a company
  logo, social icons and the headshot. Only a photo of the person goes on the
  card. Crop it square around the face, and **show Alex the crop before setting
  it**.
- **Never pull a headshot from a web search.** A search returns namesakes; the
  email's own image is the only source known to be this person.

## Step 3 — Look up, ask, write

The helper is `bin/apple-contact` (hub). Run the fixed-path copy, which no
checkout can move:

```bash
AC=/Users/alex/projects/.agents/bin/apple-contact     # fallback: /Users/alex/projects/mcritchie-studio/bin/apple-contact

$AC find   --file contact-<item-id>.json                     # matches, reasons, and the diff per match
# ...ask Alex (the table above)...
$AC create --file contact-<item-id>.json                     # refuses if any card already matches
$AC update --id "<id from find>" --file contact-<item-id>.json [--skip organization ...]
$AC photo  --id "<id>" --image headshot.png                  # after Alex approved the crop
$AC show   --id "<id>"                                       # read the card back
```

What the helper guarantees, so you do not have to:

- **Values are data, never script.** Signature text is attacker-influenced, and
  AppleScript can run shell commands. The helper hands every value to
  `osascript` as argv data (a JSON payload, or the card id and image path for
  `photo`) and runs only fixed programs. **Do not
  hand-build an AppleScript or JXA string from a signature**, not even for a
  "quick" fix. Use the helper.
- **It never deletes a card or removes a value.** `update` adds missing phones,
  emails, URLs and addresses, replaces a name, company or title only where the
  diff says `change` and Alex agreed, and *appends* to the note.
- **`create` refuses on a match.** Pass `--allow-duplicate` only when Alex has
  said this person needs a separate card from the one `find` offered.
- **A slow Contacts is retried once, at the front.** Contacts can sit on a
  request until the app is activated (measured 2026-09-28: three timeouts, then
  an answer in under a second once activated). The helper retries once with
  Contacts brought forward. A macOS permission refusal names the settings
  pane to fix.

## Step 4 — Verify and record

1. `show --id` and compare it with what Alex approved. **Trust `show`, not
   the Contacts window.** A card written by script can be missing from an open
   window while it is already on the iPhone (measured 2026-09-28). Quitting and
   reopening Contacts refreshes the window.
2. Stamp the desk item's `filed_note` with one line: `contact: created |
   updated (fields) | current | skipped | pending — <Name>`. The desk is
   private; the person's name may go there.
3. Delete the scratch JSON and any image files.

---

## Boundaries

- **Contact details are personal data.** They go to Contacts and the private
  desk only. Never put them in this public repo, a task, a PR body, an
  Artifact, or `business-data/FACTS.md`. A contact is not a business fact.
  Tests use synthetic names.
- **Runs on Alex's Mac only**, in a session he can answer. `osascript` does not
  exist on a dyno, and the prompt needs him.
- **Never merge two cards.** If `find` shows duplicates already in the book,
  tell Alex; fixing them is his call in the Contacts app.
- Capture never merges, deploys, or touches the release ladder.
