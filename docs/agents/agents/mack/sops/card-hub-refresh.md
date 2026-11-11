# Card Hub Refresh: keep the credit card hub and its sources right
<!-- registry: check or change McRitchie Studio Cards, the live total-credit hub over the MS, MI and personal card rosters -->

## Status: Active

Alex McRitchie asked for it on 2026-11-10: one credit card hub that totals the
credit across McRitchie Studio, McRitchie Industries and his personal roster. The
hub is **McRitchie Studio Cards**, a Google Sheet in `team@mcritchie.studio`'s
`McRitchie Studio Records` folder. It is **live**: its numbers update by
themselves as the source rosters change. This SOP is for reading it back, and for
the changes that do need an agent: a new source, a moved source, or a new layout.

It is Mack's, the CFO. Any agent may run it when Alex McRitchie asks about the
cards or the total credit.

## What the hub holds

| Tab | What it shows | Where the numbers come from |
|-----|---------------|-----------------------------|
| Overview | Total Credit (the headline), open cards, one row per source | McRitchie Studio: its own Cards tab. McRitchie Industries: **McRitchie Industries Cards** (MI Workspace, `McRitchie Industries Records`). Personal: **Personal Credit Card Roster** (`McRitchie Studio Records`) |
| Cards | The McRitchie Studio card roster | Typed into the sheet |

The MI and Personal rows are `IMPORTRANGE` formulas that find their columns by
the header names in row 8 (`Card` or `Company`, `Credit Limit` or `Limit`,
`Archived`, `Last Four`), so moving a column in a source never breaks them. The
first viewer clicks **Allow access** once per source; until then the row reads
`#REF!`.

## Rules

- **Last four digits only.** Never a full card number, CVV, PIN or login.
- **Recipes never go in a repo.** The hub and McRitchie Industries Cards are
  built from recipes (the [build-a-sheet SOP](../../pokemon/sops/build-a-sheet.md))
  stored in `McRitchie Studio Records/Card Hub source/ms` and `/mi`. Change them
  there, never in git.
- **Open cards only.** A card marked **Archived** is left out of every total. A
  card counts under one source only: a Studio card listed in both rosters sits on
  the Cards tab, so the Personal row leaves it out by its last four.
- **The Personal Credit Card Roster is Alex McRitchie's hand-kept master.** He
  restructured it and bound a script to it; never republish it from a recipe.
- **Total Credit is credit limit on open cards**, not credit available. It becomes
  available credit once balances are tracked (a Plaid connection, not built yet).

## Procedure

**Read it back** (the common case). Export the hub with cached values
(`files_export` as `team@mcritchie.studio`, then `openpyxl` with `data_only=True`)
and report the Overview: Total Credit, open cards, and each source row. A row
reading `#REF!` means a source needs **Allow access** (ask Alex McRitchie to click
it) or has been moved or unshared.

**Change the hub or McRitchie Industries Cards** (a new source, a new column, a
card moving between companies):

1. Download the recipe folder (`Card Hub source/ms` or `/mi`) and the brand kit
   it names (`pull_kit.rb` in `Card Hub source`) into your scratchpad, keeping
   the recipe's relative `kit:` path.
2. Read the live sheet first: if Alex McRitchie edited it, carry his edits into
   the recipe and its rows file.
3. Edit the recipe, then `bin/sheet publish <recipe> --dry-run` and
   `bin/sheet publish <recipe>`. The publisher refuses a sheet a person edited
   last; `--force` only after step 2.
4. Read it back, store the changed recipe files over the old ones in Drive, and
   tell Alex McRitchie what changed. A new `IMPORTRANGE` source needs his Allow
   access click.

## Done when

- The Overview reads numbers on every source row (no `#REF!`), and the totals
  match the sources read back.
- Any recipe you changed is stored back in `Card Hub source`.
