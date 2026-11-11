# Card Hub Refresh: total credit across every card roster, through the Drive API
<!-- registry: refresh McRitchie Studio Cards: snapshot the MI and personal card rosters through the Drive API and rebuild the hub -->

## Status: Active

Alex McRitchie asked for it on 2026-11-10: one credit card hub that totals the
credit across McRitchie Studio, McRitchie Industries and his personal roster, kept
current by an agent through the API. The hub is **McRitchie Studio Cards**, a
Google Sheet in `team@mcritchie.studio`'s `McRitchie Studio Records` folder, built
from the MS Sheet Template (the [marketing-kit SOP](../../alex/sops/marketing-kit.md#the-sheet-template)).

It is Mack's, the CFO. Any agent may run it when Alex McRitchie asks to refresh
the cards or the total credit.

## What the hub holds

| Tab | What it shows | Where the numbers come from |
|-----|---------------|-----------------------------|
| Overview | Total Credit (the headline), open cards, one row per source | McRitchie Studio: live formulas on its own Cards tab. McRitchie Industries and Personal: a **snapshot** this SOP takes |
| Cards | The McRitchie Studio card roster | Typed into the sheet |

Why a snapshot and not `IMPORTRANGE`: a sheet that pulls from another sheet needs
a person to click **Allow access** once per source, and no API can click it. The
Drive credential can read every source, so the agent reads them and writes the
numbers in. The Overview's **Last Updated** line says when.

## Rules

- **Last four digits only.** Never a full card number, CVV, PIN or login.
- **The source never goes in a repo.** The builders hold card rows; this repo is
  public. They live in `McRitchie Studio Records/Card Hub source` in Drive. Change
  them there (download, edit, upload over the old copy), never in git.
- **Open cards only.** A card marked **Archived** (the Archived column), or ❌ in
  the personal roster, is left out of every total. A card counts under one source
  only: a Studio card listed in both rosters sits on the Cards tab, so the snapshot
  leaves it out of Personal.
- **Never overwrite Alex McRitchie's edits.** Replace the hub only when its last
  editor is `Team McRitchie`, or after you have read his changes and carried them
  into the builder.
- **Total Credit is credit limit on open cards**, not credit available. It becomes
  available credit once balances are tracked (a Plaid connection, not built yet).

## Procedure

Work in your scratchpad, in a folder named for the run (`card-hub-<date>`), from a
checkout whose development database holds the Drive credential (the hub primary).

**1. Fetch the source.** Download everything in `McRitchie Studio Records/Card Hub
source` (as `team@mcritchie.studio`) into the working folder: `ms_cards_payload.rb`,
`snapshot.py`, `pull_kit.rb` and `mi_cards_payload.rb` (the McRitchie Industries
Cards builder, for when that sheet's layout changes).

**2. Pull the MS kit** for its spec and logos:

```bash
bin/rails runner <work>/pull_kit.rb team@mcritchie.studio <MS kit root id> MS <work>/ms-kit
```

Find the kit root by name (`Brand Kit: McRitchie Studio`) with `files_list`.

**3. Export the two sources** as `.xlsx` into the working folder, with
`Workspace::DriveClient#files_export`:

| Save as | Sheet | Read as |
|---------|-------|---------|
| `src-mi.xlsx` | McRitchie Industries Cards (`McRitchie Industries Records`) | `team@mcritchie.industries` |
| `src-personal.xlsx` | 💳 Credit Card Roster (Alex McRitchie's own; shared with the Studio) | `team@mcritchie.studio` |

**4. Snapshot:**

```bash
~/.cache/marketing-kit/<hash>/bin/python -I <work>/snapshot.py <work>
```

It prints and writes `snapshot.json`: open cards and total limit for MI and
Personal, with how many ❌ cards it left out. Read it. A sudden jump or drop is a
question for Alex McRitchie, not a number to publish.

**5. Build** the hub beside the snapshot:

```bash
bin/rails runner <work>/ms_cards_payload.rb <work>/ms-kit/kit.yml <work>
```

The build stamps Last Updated with today's date (Denver).

**6. Replace in place**, after the guard: read the hub's `lastModifyingUser`. If it
is Alex McRitchie, export the hub, diff it against your build, and carry his
changes into `ms_cards_payload.rb` (then store it back, step 1) before you go on.
Then `files_update` the hub with the new `.xlsx`. The link stays the same.

**7. Read back and report.** Export the hub with cached values (`openpyxl`
`data_only=True`) and check the Overview: Total Credit, open cards, and one row per
source. Hand Alex McRitchie the link and the three rows, and say what changed
since the last refresh.

## Done when

- The Overview's Last Updated reads today, and every source row has numbers (no
  `#REF!`).
- The totals read back from Drive match `snapshot.json` plus the Cards tab.
- Any builder you changed is stored back in `Card Hub source`.
