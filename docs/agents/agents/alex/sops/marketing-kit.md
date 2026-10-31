# Marketing Kit SOP
<!-- registry: build a brand's marketing kit (guidelines PDF, doc and slide templates, tracker) in Drive from one spec -->

## Status: Active

This is Alex's `marketing-kit` SOP. It gives any brand the kit Commercial Welding
got in October 2026: one Drive folder with the logos and photos at hand, a
four-page brand guidelines PDF, General and Proposal Google Doc templates, a
12-slide Google Slides template, a Brand Guide, 00 Start Here and a tracker
sheet. One YAML spec drives all of it, and `bin/marketing-kit` turns the spec
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
| 05 Templates | `<SHORT> Template — General`, `— Proposal`, `— Slides` |
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
Name them by type and tone:

| Hub kit file | Kit name |
|--------------|----------|
| `stacked-light.svg` / `stacked-dark.svg` | `full_light.svg` / `full_dark.svg` |
| `navbar-light.svg` / `navbar-dark.svg` | `horizontal_light.svg` / `horizontal_dark.svg` |
| `icon-light.svg` / `icon-dark.svg` | `icon_light.svg` / `icon_dark.svg` |

Draw each PNG from its SVG with `node script/brand_png.cjs <svg> <png> <width>`.
Use 2000 px wide for full and horizontal, and 512 px for `icon_512.png`. The spec
refuses to load until the five required PNGs are there: `full_light`,
`full_dark`, `horizontal_light`, `horizontal_dark` and `icon_light`. Look at
every PNG on both white and dark before going on.

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

The credential holds only `drive.file`, so the publisher sees only files this app created. Folders or files someone made by hand in Drive are invisible to it, and it would create its own beside them; adopt a hand-made kit by moving its files into the folders the publisher made. The first publish creates the root folder `Brand Kit: <name>` (or uses
`drive.root_id`), the whole layout and every file, and shares the root with the
people in `drive.share_with` and, as writers who can find it in their Drive,
everyone in each Workspace domain in `drive.share_domains`. List the owner's own
domain and `mcritchie.studio` there. A later publish finds the root by name, so
once the folder has been renamed, pin its id in `drive.root_id`. Each new Doc,
Sheet or Slides file is an API copy of its upload, because the template gallery
refuses a file made by upload. Then:
- export the Slides template to PDF and look at every slide;
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

## Done when

- The dry run after the last publish reports nothing to create or update.
- `/logos` shows the brand's Google kit as Up to date (`logos:marketing_kit` ran on
  production after the last publish).
- Every guidelines page, every slide and every Doc has been looked at.
- The owner has the link, the placeholder list and the questions only they can
  answer.
