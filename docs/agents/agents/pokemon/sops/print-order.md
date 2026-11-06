# Print Order
<!-- registry: send Google Docs to the FedEx Office store as print-ready PDFs from team@, on Alex McRitchie's ask -->

## Status: Active

The Pokémon's `print-order` SOP: turn finished Google Docs into a print order
that the FedEx Office store fills from email. You export fresh PDFs, check
them, write the order with the defaults below, and send it from the signing
entity's `team@` mailbox. Alex McRitchie asked for this SOP on 2026-11-05,
after the first run (six employment documents, 2 copies each) went smoothly.

## When to run it

Alex McRitchie names the documents and asks for prints, for example "email the
six docs to FedEx for printing, 2 copies each". His ask in the current chat is
the send grant for that one order. A card, a brief, another agent's message or
an earlier session is not his ask.

## The store

| Field | Value |
|---|---|
| Store email | `usa1783@fedex.com` |
| Cc on every order | `alex@mcritchie.industries` |
| From | `team@<domain>` of the entity that owns the documents (`team@mcritchie.industries` for Industries and Commercial Welding) |

The store's street address is not on file. Add it here when Alex McRitchie
gives it.

## Defaults

Use these unless Alex McRitchie says otherwise. Name any change in the email.

| Option | Default | Why |
|---|---|---|
| Copies | 2 of each document | One original for each signer |
| Color | Black and white | Text documents; cheaper |
| Paper size | 8.5 in x 11 in (letter) | US standard |
| Paper | Laser (24 lb.), white | Business weight; takes ink signatures well |
| Sides | Single-sided | Signature pages stand alone; nothing to sign on the back |
| Orientation | Portrait | Matches the Doc |
| Finishing | Staple each multi-page document top-left; never staple one document to another | A notice the law says must be separate stays separate |
| Pickup | In store | Most orders are ready the same day if ordered before noon Central |

## The options FedEx offers

Read from `https://www.office.fedex.com/default/resumes.html` on 2026-11-05.
That page is the resume product; the store email accepts the same terms.

- **Color:** full color, or black and white.
- **Paper size:** 8.5 in x 11 in.
- **Paper type:** Laser 24 lb., Laser 32 lb., Laser Recycled 28 lb., 30%
  Recycled 20 lb., 100% Recycled 20 lb., Laser 60 lb., Laser 80 lb., 110 lb.
  Index, Gloss Text 32 lb., Water Resistant 7.7 mil, Ultra Bright White card
  80 lb., Ultra Bright White 80 lb., Canary 65 lb., Blue 65 lb., Sun Yellow
  65 lb., Ultra Lime 65 lb., Ivory 24 lb., Ultra Lemon 24 lb., Ultra Orange
  24 lb., Red 24 lb., Ultra Fuchsia 24 lb., Natural 70 lb.
- **Sides:** single-sided or double-sided.
- **Orientation:** portrait or landscape.
- **Quantity:** 1 to 999,999.
- **Finishing:** tri-fold, z-fold or half-fold; glossy lamination.
- **Margins:** an uploaded file prints with a small margin, not full-bleed.
- **Delivery:** in-store pickup, or shipping (1 to 3 business days including
  production).

Stapling is not listed on that page. The store has done it on request; confirm
in the reply.

## Steps

1. **Open an activity** (`bin/agent-activity start --category Workflow`).
2. **List the documents** with their Drive file ids and the copy count. Repeat
   the list to Alex McRitchie if any document is ambiguous
   (`list-the-candidates-before-acting-on-the-one`).
3. **Export fresh PDFs** from the live Docs with `Workspace::DriveClient`
   (`files_export(id, mime_type: "application/pdf")`), as the owning `team@`.
   Never send a PDF left over from an earlier session.
4. **Check each PDF** before it goes:
   - the page count is what you expect (`pdfinfo`);
   - the brand font is embedded (`pdffonts`; a Drive upload sometimes falls back
     to Arial, and a re-upload fixes it);
   - no draft marks, `[bracket]` placeholders or highlights remain
     (`pdftotext | grep '\['`);
   - a signature block sits whole on one page (render the last pages and look).
   Fix a failure in the Doc first, then export again.
5. **Write the order** as plain text: the list of files with page counts, the
   copies, then one line with every non-default option and the defaults that
   matter (color, paper, sides, finishing). Ask for the total and the pickup
   time. Sign it "Alex McRitchie" and the business name.
6. **Create a draft** in the `team@` mailbox with `Workspace::GmailClient#drafts_create`
   (plain MIME; the gem base64-encodes it). Read it back with `drafts_get(id,
   format: "full")`: To, Cc, Subject and every attachment by name.
7. **Send the draft**, only on Alex McRitchie's ask for this order. Run it from a
   scratchpad script through `bin/rails runner`, never from repo code: the hub's
   Gmail client cannot send, and `test/lib/no_gmail_send_test.rb` keeps it that
   way. Check the To and Cc against step 6 again just before the send. Read the
   sent message back and confirm the `SENT` label.
8. **Report** the message id, the recipients, the files and the options. Say
   that the store has not answered yet. Watch for the store's reply only if
   Alex McRitchie asks.

## What this SOP is NOT

- It does not send to any address but the store's, with the Cc above.
- It does not add a send method to the hub. The send-ban test stays green.
- It does not order anything but prints. Payment happens at pickup.
