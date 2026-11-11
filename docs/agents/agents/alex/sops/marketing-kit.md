# Marketing Kit SOP
<!-- registry: build a brand's marketing kit (guidelines PDF, doc and slide templates, tracker) in Drive from one spec -->

## Status: Active

This is Alex's `marketing-kit` SOP. It gives any brand the kit Commercial Welding
got in October 2026: one Drive folder with the logos and photos at hand, a
four-page brand guidelines PDF, General and Proposal Google Doc templates, a
12-slide Google Slides template, a branded Google Sheets template, a Brand
Guide, 00 Start Here and a tracker sheet. One YAML spec drives all of it, and `bin/marketing-kit` turns the spec
into files and puts them in Drive.

The guidelines are a reference, not a rulebook. Alex McRitchie, 2026-10-26: "No
need to be militant about everything. I mainly want easy access to the
information and ideas." Write every brand's kit in that spirit.

`brand-kit-rollout` takes a saved logo kit into the apps. This SOP takes the
same logos, with the brand's colours, words and photos, into a kit people use
to make things.

## The kit's shape

Every kit has the same layout (`lib/marketing_kit/layout.rb`), so someone who
knows one kit can find their way round any other:

| Where | What |
|-------|------|
| Top level | 00 Start Here · Marketing Kit Tracker · `<SHORT> Brand Guidelines.pdf` · quick-grab copies of the five most-used logos and the favourite photos |
| 01 Brand | Brand Guide · Logos (SVG for print and web, PNG for Office and social) · Kit source (the spec and its doc fragments) |
| 02 Photography | Every approved photo, named `<SHORT>_photo_<name>.jpg` |
| 03 Messaging · 04 Sales Collateral | Docs the brand writes itself (`docs:` in the spec) |
| 05 Templates | `<SHORT> Template — General`, `— Proposal`, `— Slides`, `— Sheet` |
| 06 Archive | Superseded files: move, never delete |

## Rules that hold for every brand

- **A brand's spec never goes in a repo.** `mcritchie-studio` is public. The spec
  holds the owner's name, contact details and sometimes pre-close or unproven
  claims. It lives in the kit's `01 Brand/Kit source`, with the working copy in
  your scratchpad. The only spec in the repo is the made-up example,
  `script/marketing_kit/kit.example.yml`.
- **Nothing confidential goes in a kit.** No deal, loan, financial, employee,
  customer-pricing or legal-strategy material. A kit is meant to be shared. For a
  business still being bought, keep the buyer's name out of anything
  customer-facing until close.
- **Flag claims rather than repeating them.** A certification, a "25+ years" or a
  named customer goes in `tracker.claims` with what needs checking, and is
  marked in the doc that uses it.
- **Use the brand's real work.** Use the brand's own photos, never stock. Use
  the live site's words where they are good; otherwise ask the owner.

## Procedure

**1. Gather the sources.** You need:
- the brand's saved logo kit on the hub (`/logos/<brand>`);
- its live site or existing material, for words and photos;
- the owner's name;
- the Workspace account that will own the kit (`team@mcritchie.studio` for
  McRitchie brands).

Note anything the owner must supply, such as a tagline, a value or a claim to
confirm, so you can ask in the hand-back rather than guessing.

**2. Start a spec** in a private working folder:

```bash
bin/marketing-kit init <scratchpad>/<brand>-kit
```

This writes `kit.yml` (the worked example, every field explained) and empty
`logos/png`, `logos/svg`, `photos` and `docs` folders.

**3. Put the logos in.** Export the saved kit and install its SVGs with
`brand-kit-rollout` steps 3 and 4, setting `DEST=<working folder>/logos/svg`.
`logos:install` reads the local database, which must have the `brand_kits`
table. If the development database lacks it, load the schema into a scratch
database (`createdb <name>`, then `DATABASE_URL=postgres:///<name> bin/rails
db:schema:load`), run the install against it, and drop it after. Name the SVGs
by type and tone:

| Hub kit file | Kit name |
|--------------|----------|
| `stacked-light.svg` / `stacked-dark.svg` | `full_light.svg` / `full_dark.svg` |
| `navbar-light.svg` / `navbar-dark.svg` | `horizontal_light.svg` / `horizontal_dark.svg` |
| `icon-light.svg` / `icon-dark.svg` | `icon_light.svg` / `icon_dark.svg` |

Then draw every PNG from its SVG:

```bash
bin/marketing-kit pngs <working folder>
```

It draws full and horizontal logos 2000 px wide at their own height, icons at
512 px square, and `icon_512.png` from `icon_light.svg`. An SVG still under
its hub name, or a watermark, gets no PNG; the command lists it as skipped, so
rename the six logos first. Do not use
`script/brand_png.cjs` here: it draws squares only (app favicons), so a
horizontal logo comes out padded into a square. The spec refuses to load until
the five required PNGs are there: `full_light`, `full_dark`,
`horizontal_light`, `horizontal_dark` and `icon_light`. Look at every PNG on
both white and dark before going on.

**4. Put the photos in** `photos/`: web-sized (about 2000 px, JPEG). List each one
in `photos.items` with what it shows. Pick:
- 2 or 3 `favourites` for the top level;
- up to 6 photos for the guidelines' photo page;
- a photo for each `slot` (cover, slides, templates, proposal). Any slot left
  out uses the cover.

**5. Write the spec.** Fill in:
- the colours: `primary`, `accent` and `dark`, with the hexes from the hub kit.
  `primary` draws bars, bands and table heads; `accent` draws buttons, kickers
  and the tagline. Titles (page, document and slide titles) take `primary`
  unless a swatch carries the optional `title` key. A key may be a list, so a
  brand that wants accent-coloured titles and buttons over dark bars writes
  `key: [accent, title]` on its accent swatch, and that swatch shows once;
- the words: tagline, lines, one sentence, pitch, voice and contact;
- the ideas;
- whatever the proposal and slides should say beyond the generic placeholders.

Docs the brand writes itself, such as Messaging and Boilerplate or a
Capabilities Statement, are HTML fragments in `docs/`, listed under `docs:`. Use
plain tags (`h1`, `h2`, `h3`, `p`, `ul`, `li`, `table`, `b`) and the styler
brands them. Put the brand's own terms of service in
`proposal.terms_of_service`, word for word, and only if the owner gave them to
you.

The Sheet template's head colours come from the palette too: `primary`,
`accent`, then the first other swatch that carries white text. A brand whose
palette gives a poor third (two near-identical greys, say) names its three in
`sheet.sections`, by swatch name or key. See [The Sheet template](#the-sheet-template).

**6. Build and look.**

```bash
bin/marketing-kit build <working folder>/kit.yml --out <working folder>/out
```

The build needs Google Chrome for the PDF, and python3 for the slides and
tracker; the first run makes a venv under `~/.cache/marketing-kit`. Open every
page of `out/guidelines/<SHORT> Brand Guidelines.pdf`, render it with `pdftoppm`
if need be, and fix what reads wrong: a wrapping line, a logo too small, a
photo that crops badly. Change the spec, not the output. Run the build again
after each change.

**7. Publish.** Run the publish from a checkout with a development database, as
the Drive credential reads its workspace account there; a primary checkout
works. Dry-run it first:

```bash
bin/marketing-kit publish <working folder>/kit.yml --out <working folder>/out --dry-run
bin/marketing-kit publish <working folder>/kit.yml --out <working folder>/out
```

The credential holds `drive.readonly` and `drive.file`, so the publisher can read what its subject can see and write only to files this app created. A hand-made folder the subject can see is found by name, and the publish cannot count on writing into it: with Editor, a shortcut landed in one ([Shortcuts](#shortcuts)), and ordinary files are not tested. One it cannot see is invisible, and the publisher creates its own beside it. Adopt a hand-made kit by moving its files into the folders the publisher made. The first publish creates the root folder `Brand Kit: <name>` (or uses
`drive.root_id`), the whole layout and every file, and shares the root with the
people in `drive.share_with` and, as writers who can find it in their Drive,
everyone in each Workspace domain in `drive.share_domains`. List the owner's own
domain and `mcritchie.studio` there. A later publish finds the root by name, so
once the folder has been renamed, pin its id in `drive.root_id`. A kit first
published under the old default name, `<name> — Marketing Kit`, needs
`drive.root_id` (or `drive.root_name`) before it is published again, or the
publish builds a second kit beside it. Each new Doc,
Sheet or Slides file is an API copy of its upload, because the template gallery
refuses a file made by upload. Then:
- export the Slides template to PDF and look at every slide;
- export the Sheet template to PDF and look at it (`files_export` with
  `application/pdf`);
- open each Doc.

Fix anything through the spec, then publish again with `--replace "<file name>"`
for the Google file you changed.

**Record it on `/logos`.** Give the spec its `/logos` brand key (`brand:`, for
example `welding_v2`). A real publish then prints the command that records the
kit on the hub's production database. Run it as printed, with your name in `BY`:

```bash
heroku run -a mcritchie-studio --no-tty --exit-code -- bin/rails logos:marketing_kit \
  BRAND=<brand> URL=https://drive.google.com/drive/folders/<root id> OWNER=<team@domain> BY=<you>
```

`/logos` then shows the brand's Google kit: the Google Drive mark, the account
that owns it (the spec's `drive.subject`) and an Open link. It reads **Up to
date** until someone saves the brand's logos again, then **Kit changed**, the
same convention as each app's kit line. A brand with no record reads **No
Google kit**. Only the logos are watched: a change to the spec's colours or words
does not flip it, so run the stamp after every real publish, not only the first.

**8. Hand back to the owner.** Lead with the link. Then give a table of what is
where, what is a placeholder (`[brackets]` and orange `[fields]`), which claims
are flagged, and what you need from them. Record the kit in the hub's knowledge
capture if it is a new brand's first.

## Changing a kit later

The kit carries its own source, so any session can change it without this
conversation:
1. Download `01 Brand/Kit source` and the logos and photos into a working
   folder, keeping the layout from step 2.
2. Edit the spec, build, and dry-run.
3. Publish, and record it on `/logos` (step 7).

What a publish does to what is already there:
- An uploaded file (logo, photo, PDF) is replaced in place when its bytes
  change, so its links keep working.
- A Google Doc, Sheet or Slides file is **kept**, because people edit them (the
  tracker's backlog, a tidied template). Overwrite one only on purpose, with
  `--replace NAME` (or `--replace-all`), and only after checking nobody has
  edited it since. Drive's version history can restore it.
- Two files with the same name in one folder are reported and skipped; merge
  them in Drive first.

## The Sheet template

`<SHORT> Template — Sheet` is the kit's standard spreadsheet
(`lib/marketing_kit/sheet_template.rb`, drawn by `script/marketing_kit/office.py`).
Copy it for any working sheet: a roster, a register, a tracker. Its rules make
the sheet easy to work in, so keep them in every copy:

| Part | What it is |
|------|------------|
| Row 1, column A | Thin margins |
| A2 | The brand icon (`icon_light`), in a square cell |
| Row 2 | `[Sheet Title]` in B2, in the `title` colour, alone on its row so a long title runs across |
| Row 3 | `Last Updated: <date>` in B3, which the agent stamps at every build; the variable labels from D3 |
| Row 4 | The variable values, under their labels. Formulas point at them with absolute references. The first is the headline (`emphasis: true`): it draws larger, in the `title` colour and whole dollars, as a card roster shows its total credit limit |
| Rows 6-7 | The table head from column B, in three colour sections: the darker top row names the section, the lower row names the columns |
| Row 8 on | The data. Column B is the row's item (its name), and column C a narrow gutter that parts it from the columns that scroll. A column may carry `choices` (a dropdown) and its own `format` (`"$"#,##0` for whole dollars) |

- **No merged cells.** A section's label sits in its first cell, and the other
  cells share its colour. Every column can move, sort and filter.
- **The freeze is at C8.** The variables, the head rows and the item column stay in
  view, so you always see which row and which column you are on.
- **White text on both head rows, at 4.5:1 or better.** The lower row is the
  brand colour, darkened only as far as white text needs (a near-black colour
  lightens a step instead, so the two rows still differ). The top row is that
  colour 30% of the way to black.
- **A How to use tab** carries these rules for whoever copies it.

Drive keeps the freeze, the hidden gridlines, the logo, the filter, the
dropdown and the formulas when it converts the `.xlsx` (checked 2026-11-10).

## Doc masters

A **doc master** is the editable Google Doc of one document Alex McRitchie asked
for: an agreement, a letter, a policy. Its home is the Workspace of the entity that
signs or owns it, which may not be the brand it concerns. Keep it outside the kit,
because a kit holds nothing confidential and a doc master may. Keep one master.

1. Work out which brand the document serves, for the template. That is the party
   that issues it: a lease carries the landlord's format, not a tenant's. A party
   with no kit uses the plain format of its own documents.
2. Work out which entity signs or owns it, for the home. Use that entity's `team@`
   account as the owner.
3. Start from the brand kit's `<SHORT> Template — General` in `05 Templates`. Find
   it in Drive; a local search does not prove it is missing. Drop the template's
   parts that do not fit, such as a photo on a contract.
4. Put the Google Doc in a folder named for what it holds, such as
   `<Entity> Records/Employment Agreements`, and hand back its Drive link.
5. Share by name. Do not share the folder with a whole domain. Do not move a
   doc master into a kit.
6. If it must also show in another folder, add a shortcut there. Do not copy it.
   See [Shortcuts](#shortcuts).

The Drive credential holds `drive.readonly` and `drive.file`. It can read what
its subject can see, and it edits only what it created. A folder a person made by
hand is invisible until it is shared with the subject. The Google Picker is not a
way round this: the credential acts by
domain-wide delegation and has no Picker step. So let the credential create the
folder for a doc master. A person can then move that folder wherever it belongs;
the credential keeps its access.

No command does this yet. Use `Workspace::DriveClient` with the owning entity's
`team@` account, from a checkout with a development database, as the publish does.
Read the template as the kit's `drive.subject`, because the owning entity's account
may not see the kit:

1. Search with `files_list` for the exact name, the folder mime type and
   `trashed = false`. If one folder matches, use it. Do not create a second one
   beside it. If several match, or Drive refuses a write into the match, stop and
   tell Alex McRitchie.
2. If it does not exist, create it with `files_create`.
3. `files_create` shares a new folder with the Workspace's folder user. Share it
   with anyone else with `permissions_create`, by name. Ask Alex McRitchie first.
4. Create the Doc with `files_create`, sending HTML built from the template's
   export, so the Doc is a native Google Doc.

### Shortcuts

A shortcut shows a master folder or file in another folder, and it opens the one
master. To add one, the account needs Editor on the destination folder and must be
able to see the target. Run this as the account that owns the destination or has
Editor on it:

```ruby
Workspace::DriveClient.new(subject: "team@<domain>")
                      .shortcut_create(name: "Employment Agreements", parent: destination_folder_id, target_id: master_id)
```

- **It is one master.** On 2026-11-04, across two Workspaces, an edit made by the
  owner read back through the other account.
- **It grants no access.** Anyone not on the master folder reaches the access screen.
  Add each person to the master by name as well. Ask Alex McRitchie first.
- **Hand-made folders can work.** On 2026-11-04, with Editor on a folder a person
  made, this credential added a shortcut. Ordinary files in such a folder are not
  tested; the [rule above](#doc-masters) to let the credential create the folder
  still stands for them.
- **Removing one from a hand-made folder:** on 2026-11-04, Drive refused this
  credential's trash call on shortcuts it had added to such a folder. The folder's
  owner removes them by hand.
- **View-only destination:** a person with edit access adds the shortcut by hand:
  right-click the master, then **Organize > Add shortcut**.
- **The knowledge layer does not follow it.** The walker records a shortcut and its
  target, and never reads the target. A master reaches the index when the folder that
  holds it, such as `<Entity> Records`, is a source. Never register a drive root. Run
  `workspace:add_source` with the signing entity's domain, which must be an active
  Workspace, then `workspace:walk`. The task `workspace:shortcuts` lists each walked
  shortcut and whether a source indexes its target. A new source starts with no
  access for any agent.

## Done when

- The dry run after the last publish reports nothing to create or update.
- `/logos` shows the brand's Google kit as Up to date (`logos:marketing_kit` ran on
  production after the last publish).
- Every guidelines page, every slide and every Doc has been looked at.
- The owner has the link, the placeholder list and the questions only they can
  answer.
