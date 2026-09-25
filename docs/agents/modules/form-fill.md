# Form Fill — complete an application on Alex's behalf

## Status: Active

Alex forwards an application: insurance, benefits, a bank or vendor
form. The agent **fills in everything the records can answer**. It asks only the
questions the records cannot answer, then hands back a draft for him to review,
edit, and sign. The agent drafts; Alex attests.

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
    a=a.get_object(); par=a.get('/Parent'); fld=par.get_object() if par is not None else a
    t=a.get('/T') or fld.get('/T')
    on=[k for k in (a.get('/AP',{}).get('/N') or {}) if k!='/Off']
    print(i+1, t, fld.get('/FT'), on or '', a.get('/TU'), [round(x) for x in a['/Rect']])
" <form.pdf>
```

Each row is page, field name, type, **on-states**, tooltip, rectangle. Read the
on-states column before writing any checkbox into the map: it is that field's
own legal "on", and §5 depends on it. A `/Btn` row whose name came from a parent
rather than from the widget is the parent/kid shape §5 handles.

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
   `mcritchie-industries` app. Search the `title`, `source_note` and `tags`:

   ```bash
   cd /Users/alex/projects/mcritchie-industries
   heroku run -a mcritchie-industries --no-tty -- bin/rails runner \
     'Studio::KnowledgeDoc.find_each { |d| t = [d.title, d.source_note, d.tags].join(" "); puts "##{d.id} #{d.title}" if t =~ /PATTERN/i }'
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

### A checkbox has no universal "on" value — read it, never assume it

Three shapes turn up on real forms, and only the first survives a guess:

| Shape | Where the name is | Turning it on |
|---|---|---|
| On-state `/Yes` | on the widget itself | `/V` and `/AS` both `/Yes` |
| On-state `/On`, `/1`, `/X` … | on the widget itself | `/V` and `/AS` both **that** state |
| Parent field + unnamed kid widget | on the **parent** | `/V` on the parent, `/AS` on the kid |

Each field declares its own legal on-state in its `/AP /N` dictionary: it is the
key that is not `/Off`. Writing `/Yes` into a field whose only on-state is `/On`
stores a value outside that field's legal set. The third shape — the name on a
parent, the appearance on a kid widget carrying no `/T` — is what most IRS and
insurance forms use; set only the parent's `/V` and the box renders off whatever
the value says. So the loop below reads the on-state off each widget.

```python
import pypdf
from pypdf.generic import NameObject
src, dst = "<original.pdf>", "<Name>-FILLED.pdf"
text   = {"<field>": "<value>"}           # text fields
radios = {"<group>": "/<export value>"}   # radio groups
checks = ["<checkbox field>"]             # checkboxes to turn ON

def widgets(page):
    """(name, widget, field) per widget. `field` is the parent when there is
    one — that is where /V belongs. /AS always belongs on the widget."""
    for x in page.get("/Annots") or []:
        a = x.get_object()
        par = a.get("/Parent")
        fld = par.get_object() if par is not None else a
        yield (a.get("/T") or fld.get("/T")), a, fld

def on_states(widget):
    """This widget's own legal on-states: the /AP /N keys that are not /Off."""
    return [s for s in (widget.get("/AP", {}).get("/N") or {}) if s != "/Off"]

w = pypdf.PdfWriter(clone_from=pypdf.PdfReader(src))
for pg in w.pages:
    w.update_page_form_field_values(pg, text, auto_regenerate=False)
    for name, a, fld in widgets(pg):
        if name in radios:                      # one kid widget per export value
            want = radios[name]
            a[NameObject("/AS")] = NameObject(want if want in on_states(a) else "/Off")
            fld[NameObject("/V")] = NameObject(want)
        if name in checks:
            legal = on_states(a)
            if len(legal) != 1:
                raise SystemExit(f"{name}: expected one on-state, found {legal}")
            fld[NameObject("/V")] = NameObject(legal[0])   # value on the field
            a[NameObject("/AS")] = NameObject(legal[0])    # appearance on the widget
w.set_need_appearances_writer(True)
w.write(dst)
```

Setting a radio group's or a checkbox's `/V` alone leaves the box **visibly
unchecked**. The widget's `/AS` must name the same state, as the loop does.

### Verify — the read-back is the gate

Append this to the same script. It reopens the written file and asserts against
each field's **own** `/AP /N`, so it judges what landed on disk rather than what
the fill loop meant to do. It names every wrong field and exits non-zero.

```python
r = pypdf.PdfReader(dst)
f = r.get_fields()
bad = [f"{k}: want {v!r}, got {f.get(k, {}).get('/V')!r}"
       for k, v in {**text, **radios}.items() if f.get(k, {}).get("/V") != v]
seen = set()
for pg in r.pages:
    for name, a, fld in widgets(pg):
        if name not in checks:
            continue
        seen.add(name)
        legal, v, drawn = on_states(a), fld.get("/V"), a.get("/AS")
        if v not in legal:
            bad.append(f"{name}: value {v!r} is not an on-state of this field {legal}")
        elif drawn != v:
            bad.append(f"{name}: value {v!r} but widget draws {drawn!r} - renders OFF")
bad += [f"{n}: no widget carries this name - nothing was set" for n in checks if n not in seen]
if bad:
    raise SystemExit("FORM FILL FAILED:\n  " + "\n  ".join(bad))
print(f"verified: {len(text)} text, {len(radios)} radio, {len(checks)} checkbox - all match")
```

It reds on four distinct faults:

- a text or radio value that did not land — the one check this step always had;
- a checkbox value outside that field's legal on-states (`/Yes` written into an
  `/On` field);
- a checkbox whose value is legal but whose widget still draws something else,
  so the box renders off;
- a name in `checks` that matches no widget on the form — a typo, or the
  parent/kid shape when a fill loop never reached it.

The three checkbox faults are the new ones, and the Background section below
reproduces each on a fixture you can rebuild.

**The read-back is the gate; the render is not.** Render the pages as well, but
know what each check can see. Measured: a box wrongly set to `/Yes` when its
only on-state was `/On` still rasterised as a **tick**, because `pdftoppm` falls
back to redrawing from `/MK` instead of failing on the unresolvable state. The
render caught one of the two corrupt boxes; the read-back caught both. Use the
render for the fault it does catch — a value that reads back correctly and still
fails to draw.

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

---

## Background — not needed to execute

### The checkbox fixture, and what it proved

§5 reads each checkbox's on-state instead of assuming `/Yes` because assuming it
was wrong on two of the three shapes. This rebuilds the three-shape form those
claims were measured on, so any later change to §5 can be re-checked rather
than trusted. Run it in a scratch directory; it writes `form-fill-fixture.pdf`.

```python
import pypdf
from pypdf.generic import (ArrayObject, DecodedStreamObject, DictionaryObject,
                           FloatObject, NameObject, NumberObject, TextStringObject)
w = pypdf.PdfWriter(); page = w.add_blank_page(300, 200)

def ap(on):                                    # a drawable on/off appearance
    s = DecodedStreamObject(); s.set_data(b"q 0 0 0 rg 2 2 14 14 re f Q" if on else b"q Q")
    s[NameObject("/Type")] = NameObject("/XObject"); s[NameObject("/Subtype")] = NameObject("/Form")
    s[NameObject("/BBox")] = ArrayObject([NumberObject(0), NumberObject(0),
                                          NumberObject(18), NumberObject(18)])
    s[NameObject("/Resources")] = DictionaryObject(); return w._add_object(s)

def box(y, on_state, named):
    a = DictionaryObject()
    a[NameObject("/Type")] = NameObject("/Annot"); a[NameObject("/Subtype")] = NameObject("/Widget")
    a[NameObject("/Rect")] = ArrayObject([FloatObject(40), FloatObject(y),
                                          FloatObject(58), FloatObject(y + 18)])
    a[NameObject("/F")] = NumberObject(4); a[NameObject("/P")] = page.indirect_reference
    a[NameObject("/AS")] = NameObject("/Off"); a[NameObject("/DA")] = TextStringObject("/ZaDb 0 Tf 0 g")
    mk = DictionaryObject(); mk[NameObject("/CA")] = TextStringObject("4"); a[NameObject("/MK")] = mk
    n = DictionaryObject(); n[NameObject(on_state)] = ap(True); n[NameObject("/Off")] = ap(False)
    d = DictionaryObject(); d[NameObject("/N")] = n; a[NameObject("/AP")] = d
    if named:                                  # shapes 1-2: field and widget are one object
        a[NameObject("/FT")] = NameObject("/Btn"); a[NameObject("/T")] = TextStringObject(named)
        a[NameObject("/V")] = NameObject("/Off")
        r = w._add_object(a); return r, r
    return None, a                             # shape 3: the caller supplies the parent

fields, annots = [], []
for y, st, nm in ((150, "/Yes", "box_yes"), (120, "/On", "box_on")):
    f, _ = box(y, st, nm); fields.append(f); annots.append(f)

parent = DictionaryObject()                    # shape 3: the name on the parent...
parent[NameObject("/FT")] = NameObject("/Btn")
parent[NameObject("/T")] = TextStringObject("box_kid")
parent[NameObject("/V")] = NameObject("/Off"); pref = w._add_object(parent)
_, kid = box(90, "/Yes", None)                 # ...the appearance on an unnamed kid
kid[NameObject("/Parent")] = pref; kref = w._add_object(kid)
parent[NameObject("/Kids")] = ArrayObject([kref]); fields.append(pref); annots.append(kref)

page[NameObject("/Annots")] = ArrayObject(annots)
fonts = DictionaryObject()
for tag, base in (("/Helv", "/Helvetica"), ("/ZaDb", "/ZapfDingbats")):
    fo = DictionaryObject(); fo[NameObject("/Type")] = NameObject("/Font")
    fo[NameObject("/Subtype")] = NameObject("/Type1"); fo[NameObject("/BaseFont")] = NameObject(base)
    fonts[NameObject(tag)] = w._add_object(fo)
dr = DictionaryObject(); dr[NameObject("/Font")] = fonts
acro = DictionaryObject(); acro[NameObject("/Fields")] = ArrayObject(fields)
acro[NameObject("/DR")] = dr; acro[NameObject("/DA")] = TextStringObject("/Helv 10 Tf 0 g")
w._root_object[NameObject("/AcroForm")] = w._add_object(acro)
with open("form-fill-fixture.pdf", "wb") as fh:
    w.write(fh)
```

Point §5's script at it with `checks = ["box_yes", "box_on", "box_kid"]` and
empty `text` and `radios` maps — the fixture carries checkboxes only, so it
exercises the three checkbox faults and not the text/radio one. Measured on
pypdf 6.14.2:

| Field | On-state | Assuming `/Yes` | Reading `/AP /N` |
|---|---|---|---|
| `box_yes` | `/Yes` | `/V` `/AS` = `/Yes` — **correct** | `/V` `/AS` = `/Yes` — correct |
| `box_on` | `/On` | `/V` `/AS` = `/Yes` — not a legal state | `/V` `/AS` = `/On` — correct |
| `box_kid` | `/Yes` (on a kid) | never matched; stayed `/Off` | `/V` on parent, `/AS` on kid — correct |

`box_yes` is the **control**: it fills correctly under both, which is what shows
the fixture is sound and locates the fault in the assumption rather than in the
form. A fixture where everything fails proves only that the fixture is broken.

The old verification — comparing `{**text, **radios}` against `get_fields()` —
printed `mismatched: []` on that corrupt file, because it never looked at a
checkbox. §5's verification reds on it, naming both faults:

```text
FORM FILL FAILED:
  box_on: value '/Yes' is not an on-state of this field ['/On']
  box_kid: value '/Off' is not an on-state of this field ['/Yes']
```

Its other two branches were exercised the same way, by mutating a correct file:
forcing a kid widget's `/AS` back to `/Off` reds with `value '/Yes' but widget
draws '/Off' - renders OFF`, and adding an unknown name to `checks` reds with
`no widget carries this name - nothing was set`.

One trap worth keeping: `get_fields()` reports no `/_States_` for the parent/kid
shape, so the legal on-states cannot be read from it. That is why both the fill
loop and the verification walk `/Annots` and read `/AP /N` off the widget.

