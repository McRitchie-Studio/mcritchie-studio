# Build a Sheet: one branded Google Sheet from a recipe, in its company's Records folder
<!-- registry: build or change a branded Google Sheet (a roster, register or tracker) from a recipe with bin/sheet -->

## Status: Active

Alex McRitchie asked for it on 2026-11-10: a branded working sheet (a card roster,
a register, a tracker) should take minutes, not an evening. A **recipe** says what
the sheet is; `bin/sheet` draws it in the company's brand and puts it in Drive.
It works for every company with a marketing kit (MI, MS, CW, TM): the kit gives
the brand, the recipe's `drive` block gives the home.

## Rules

- **Name the company first.** The brand is the kit of the company the sheet is
  for; the home is that company's Workspace and its `<Company> Records` folder.
- **Private rows never go in a repo.** A recipe with real data (cards, people,
  money) lives in Drive beside its sheet (e.g. `McRitchie Studio Records/Card Hub
  source/<sheet>/`). Only a data-free example may go in the repo.
- **Last four digits only** for any card or account number. Cut longer numbers in
  notes to their last four.
- **Never overwrite a person's edits.** `bin/sheet publish` refuses a sheet whose
  last editor is a person. Export it, carry their changes into the recipe, then
  publish with `--force`. Once a person has restructured a sheet by hand, it is
  theirs: stop publishing it from the recipe.
- **Everything is shared** with the company's admin (`alex@<domain>`) and
  alex@mcritchie.studio, by name. The publisher does it for a folder or sheet it
  creates.

## The recipe

A YAML file; `lib/marketing_kit/sheet_recipe.rb` has the full reference. The
layout is the [Sheet Template's](../../alex/sops/marketing-kit.md#the-sheet-template):
icon in A2, title in B2, Last Updated in B3, variables from row 4 (the headline,
`emphasis: true`, under the title), the three-section head in rows 7-8, data from
row 9, the item column in B and the freeze at C9.

```yaml
kit: ../ms-kit/kit.yml                 # the brand: a marketing-kit spec
title: McRitchie Studio Cards
sheet_title: Cards
sections: [Card, Terms, Rewards]
columns:                               # the first is the item (kind: item)
  - { key: card, head: Card, kind: item, width: 28, section: 0 }
  - { key: limit, head: Limit, kind: money, format: '"$"#,##0', width: 12, section: 1 }
  - { key: used, head: Used, kind: stamp, target: Last Used, width: 8, section: 1 }
  - { key: last_used, head: Last Used, kind: date, format: m/yy, width: 11, section: 1,
      age_bands: { months: [4, 10, 16], fresh: ["💳"] } }
  - { key: archived, head: Archived, kind: archive, width: 11, section: 2 }
variables:
  - { label: Total credit, kind: money, format: '"$"#,##0', emphasis: true,
      value: '=SUMIFS({col:limit}{first}:{col:limit}{last},{col:archived}{first}:{col:archived}{last},"<>Archived")' }
rows: rows.json                        # row arrays, in column order
drive: { subject: team@mcritchie.studio, folder: McRitchie Studio Records, name: McRitchie Studio Cards }
```

Column kinds: `item`, `text`, `date`, `money`, `percent`, `status`, `formula`,
`archive` (an Archived dropdown: the row greys out and totals skip it), `stamp` (a
tick-box column for the date named in `target`). Any column may carry `choices`
(a dropdown) and `format`. A date column may carry `age_bands`: within
`months[0]` (or a `fresh` marker) the row is green, within `months[1]` white,
within `months[2]` yellow, older red, and the date cell itself turns amber, then
deep red. In a value or formula, `{col:key}` is a column's letter, `{var:Label}` a
variable's cell, and `{first}`/`{last}` the data rows. A workbook with several
tables lists them under `tabs:`. A live pull from another sheet is an
`IMPORTRANGE` formula; find its columns by header name (`MATCH` on row 8) so a
moved column never breaks it, and tell the owner to click **Allow access** once
per source.

## Procedure

Work in your scratchpad, from a checkout whose development database holds the
Drive credential (the hub primary, or a desk with `ALLOW_SHARED_DEV_DB=1` and
`DATABASE_URL` set to it).

1. **Fetch the kit** for the company (the [marketing-kit SOP](../../alex/sops/marketing-kit.md),
   "Changing a kit later"), into a folder the recipe's `kit:` path reaches.
2. **Write the recipe** and its `rows.json`. For an existing sheet, start from its
   recipe in Drive.
3. **Build and look:** `bin/sheet build <recipe>`. Upload is not needed to look:
   open the `.xlsx`, or publish to a scratch copy.
4. **Dry-run, then publish:** `bin/sheet publish <recipe> --dry-run`, then without
   `--dry-run`. It creates or replaces the sheet, shares it, and makes `stamp`
   columns real checkboxes through the Sheets API. If it reports `skipped
   checkboxes`, the Sheets API is still off on the credential's project; the
   message names the console page.
5. **Read it back** (`files_export`), look at it, and store the recipe beside the
   sheet in Drive.
6. **Hand back** the link. Name what the owner must do in the sheet itself (an
   Allow access click, the Studio add-on's tick-box switch).

## The tick-box needs a script

A checkbox only ticks. What writes the date is a script: the **Studio** add-on
(task `studio-sheets-addon`) once it is installed, or, until then, the
`markUsedThisMonth`/`onEdit` script pasted into the sheet by its owner
(Extensions → Apps Script). Agents cannot install scripts: the credential holds no
Apps Script access.
