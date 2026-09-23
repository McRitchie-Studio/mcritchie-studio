# Form Fill — complete an application on Mr. McRitchie's behalf

## Status: Active

Mr. McRitchie forwards an application: insurance, benefits, a bank or vendor
form. The agent **fills in everything the records can answer**. It asks only the
questions the records cannot answer, then hands back a draft for him to review,
edit, and sign. The agent drafts; Mr. McRitchie attests.

This SOP stands alone. Every command is inline. It composes with one registered
SOP, [`knowledge-capture`](knowledge-capture.md): a forwarded email arrives
through that SOP's desk queue, and any new fact is filed through it.

> **Public repo.** This file describes the process only. A filled value (an
> EIN, an address, a headcount) never appears here, on the task board (it is
> public-read), in a PR body, or in an Artifact. Values live in the private
> `mcritchie-industries` repo and knowledge layer, and in the filled PDF on his
> machine.

---

## 1. Get the form

| He sent it by | Where it is |
|---|---|
| A file path or a download | Read it where it is. **Never edit the original.** |
| Email to `team@mcritchie.studio` | The newest `DeskCaptureItem` (below). A form attached to a quarantined item stays sealed. Report it; don't open it |

```bash
cd /Users/alex/projects/mcritchie-studio
heroku run -a mcritchie-studio --no-tty -- bin/rails runner \
  'DeskCaptureItem.order(created_at: :desc).limit(6).each { |i| puts [i.id, i.source, i.status, i.from_addr, i.subject].join(" | ") }'
```

Then read the **whole** form, every page, before filling anything. Check whether
it is fillable, and map each field's name to its printed label:

```bash
python3 -c "
import pypdf,sys
r=pypdf.PdfReader(sys.argv[1])
for i,p in enumerate(r.pages):
  for a in p.get('/Annots') or []:
    a=a.get_object(); par=a.get('/Parent'); t=a.get('/T') or (par and par.get_object().get('/T'))
    print(i+1, t, a.get('/TU'), [round(x) for x in a['/Rect']])
" <form.pdf>
```

A form with no fields (a scan) gets a filled **answer sheet** instead: a list
of every field with the value to write in. Don't try to draw text over a scan.

## 2. Pin the applicant before any value

Settle **who is applying** first: the entity, not the business in general.
Everything else follows from that answer. An acquisition is the usual trap:
the business being bought, the entity buying it, and the holding company each
have their own name, EIN, formation date, and address. So one form can mix
facts from all three, and the seller's EIN must never appear on a buyer-side
form.

If the forwarded email or the form doesn't make the applicant clear, this is
the **first** question to ask.

## 3. Answer from the records, in this order

1. **The quick reference.** `business-data/FACTS.md` in the private
   `mcritchie-industries` repo. Every row cites its source and keeps its
   history. Read the row's **History & notes** before using the value. A
   conflict recorded there is a question for him, not a value to copy.
2. **The knowledge layer.** `Studio::KnowledgeDoc` rows on the
   `mcritchie-industries` app. Search the `source_note` and `body_text`:

   ```bash
   cd /Users/alex/projects/mcritchie-industries
   heroku run -a mcritchie-industries --no-tty -- bin/rails runner \
     'Studio::KnowledgeDoc.find_each { |d| t = [d.title, d.source_note].join(" "); puts "##{d.id} #{d.title}" if t =~ /PATTERN/i }'
   ```

   Keep `$` out of runner strings. The shell expands it and silently mangles
   the text.
3. **Filed originals.** `business-data/` (data room, returns, entity papers),
   plus IRS or state letters in his Downloads.
4. **Public facts from a primary source.** A company phone number or website
   comes from the company's own page, fetched raw. A search-engine summary is
   a lead, not a source; they have been caught with a wrong digit.
5. **Him.** Anything left over goes to §4.

For every value, note **where it came from**. Section §6 hands that list back.

## 4. Ask only what the records can't answer

You are acting **for** him, so ask for context, not for data entry. Batch the
questions into one message, and put each one in a form he can answer in a word:

- **Missing facts.** Say what you searched, so he knows it isn't in the
  records.
- **Decisions.** A plan choice, a contribution level, which of two addresses
  becomes the mailing address. Offer a recommended default and the reason
  for it.
- **Conflicts.** Two sources disagree. Show both readings and which one you
  would use.

Before you hand back, fill in everything that doesn't depend on an answer. He
expects to receive a draft, not a questionnaire.

## 5. Fill it — rebuild from the original every time

Keep one value map in a namespaced scratch script
(`scratchpad/form-fill-<slug>.py`). Each pass **re-applies the whole map to the
untouched original** and writes a new copy
(`~/Downloads/<Name>-FILLED.pdf`). Never write onto the previous output.
Preview re-saves an open PDF in a form that `pypdf` then misreads: after
that re-save, one field read back empty and a checkbox showed unchecked.

```python
import pypdf
from pypdf.generic import NameObject
src, dst = "<original.pdf>", "<Name>-FILLED.pdf"
text   = {"<field>": "<value>"}           # text fields
radios = {"<group>": "/<export value>"}   # radio groups
checks = ["<checkbox field>"]             # single checkboxes
w = pypdf.PdfWriter(clone_from=pypdf.PdfReader(src))
for pg in w.pages:
    w.update_page_form_field_values(pg, text, auto_regenerate=False)
    for x in pg.get("/Annots") or []:
        a = x.get_object(); par = a.get("/Parent")
        group = par.get_object() if par else None
        if group is not None and group.get("/T") in radios:
            on = radios[group["/T"]]
            a[NameObject("/AS")] = NameObject(on if on in a["/AP"]["/N"] else "/Off")
            group[NameObject("/V")] = NameObject(on)
        if a.get("/T") in checks:
            a[NameObject("/V")] = a[NameObject("/AS")] = NameObject("/Yes")
w.set_need_appearances_writer(True)
w.write(dst)
f = pypdf.PdfReader(dst).get_fields()
print("mismatched:", [k for k, v in {**text, **radios}.items() if f[k].get("/V") != v])
```

Setting a radio group's `/V` alone leaves the box **visibly unchecked**. Each
widget's `/AS` must name the chosen export value, as the loop above does.

**Verify both halves.** The read-back must print `mismatched: []`. Then render
the pages and look at them. A value can read back correctly and still fail to
draw.

```bash
pdftoppm -f <page> -l <page> -r 90 -png "<Name>-FILLED.pdf" scratchpad/form-fill-<slug>-p
```

**Never fill:** signatures, initials, dates beside a signature, or any
attestation checkbox. Those are his acts.

## 6. Hand back

Lead with the outcome, then a table: **field → value → source**. Flag every
value **you chose** as your choice (a title, "correspond by email", paperless
billing), so he can reverse it at a glance. Then list:

- what is still blank, and why;
- the signatures and initials waiting on him;
- the file path, and "close and reopen it in Preview" if he had it open.

Open the file for him (`open <path>`) when he asks to see it.

## 7. Keep the facts straight: add every new fact to the records

When the session turns up a durable fact (a code, a phone number, a
formation date, an advisor's name), file it **in the same pass**:

1. **The quick reference:** add or update its row in `business-data/FACTS.md`
   with value, as-of date, source, and history. Say **who** asserted it ("the
   seller says", "he chose"). When a fact changes, move the old value into
   History; don't overwrite it. When sources disagree, record both readings
   and which one is in use.
2. **The source:** if the fact came from an email or document not yet in the
   knowledge layer, file it through [`knowledge-capture`](knowledge-capture.md)
   so its `source_note` keeps the full context the quick reference points back
   to.

**Check who said what before you write it down.** In an inline email reply,
the answer sits right under the question it answers. So a list that looks like
part of the question can be the other side's answer. Name the speaker from the
text, not from the layout.

The filled PDF itself is **not** filed by default. It is a draft until he signs.
File the signed copy through `knowledge-capture` when he sends it.
