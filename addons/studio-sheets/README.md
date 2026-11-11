# Studio: the Google Sheets add-on

Studio is a Google Sheets **Editor add-on** (Apps Script). It is named after the
`studio-engine` gem. It gives every Sheet in our Workspaces an **Extensions >
Studio** menu, a tick-box behaviour, the brand style and age colours for sheets
built on our Sheet Template layout: the table header is row 8 and data starts on
row 9.

**This repo is public.** The add-on holds no private data: no spreadsheet IDs, no
card data, no script ID, no email address. Keep it that way.

The SOP for changing and redeploying it is
[`docs/agents/agents/steffon/sops/sheets-addon.md`](../../docs/agents/agents/steffon/sops/sheets-addon.md).

## What it does

Every function finds its columns by the **header names in row 8**, never by
column letter. A moved column never breaks a function.

| Menu item | What it does |
|-----------|--------------|
| Mark used this month | On each selected row (any selection, several ranges included), sets `Last Used` to the 1st of this month in the spreadsheet's time zone, number format `m/yy`. It skips rows above 9 and rows whose column B is empty. A toast says `N card(s) marked used Nov 2026`. |
| Archive row | Sets `Archived` to the text `Archived` on the selected rows. Our sheets grey these rows and skip them in totals by that exact value. |
| Un-archive row | Clears `Archived` on the selected rows. |
| Stamp Last Updated | Finds the cell in B1:B6 that starts with `Last Updated:` and rewrites it for today, for example `Last Updated: Nov 10th, 2026`, in the spreadsheet's time zone (**File > Settings**). |
| Apply brand style > *company* | Styles the active tab to the Sheet Template, as far as the tab has the layout. See **Apply brand style** below. |
| Add age colours to this column | Colours the table by the age of the dates in the selected column. See **Age colours** below. |
| Turn on Used tick-boxes | Installs the tick-box trigger for this spreadsheet. A second click does nothing: there is never more than one trigger. |
| Turn off Used tick-boxes | Removes that trigger. |

**The tick-box.** When the trigger is on, a tick in a column headed `Used` on row 9
or below writes the 1st of this month into `Last Used` on that row, and clears
the tick. A pasted block of ticks stamps each ticked row.

Simple `onEdit` triggers never run for an editor add-on, so the tick-box needs an
installable trigger. The trigger runs as the person who turned it on, and it fires
on edits by anyone in the sheet. **Turn it on once per spreadsheet, normally as
the sheet's owner, and by one person only.** Each person's trigger fires on every
edit, so two triggers race on the same tick and one of them fails without a word.

## Apply brand style

**Extensions > Studio > Apply brand style** lists the four companies: McRitchie
Industries, McRitchie Studio, Commercial Welding and Turf Monster. You pick the
company. The add-on never reads who you are, so it needs no `userinfo` scope.

It styles the active tab to the kit's Sheet Template, as far as the tab already
has the layout:

- the font family (Montserrat) on the whole tab;
- the title in B2: the brand's dark title colour, 16 pt bold, and the kit's title
  alignment (MI sits on the bottom, the others in the middle);
- the headline in B4:B5, if B5 has a value: the brand's headline colour, 16 pt bold;
- the two head rows in the brand's three section colours: row 7 the darker top
  fill, white bold 10 pt; row 8 the lighter low fill, white bold 9 pt. A section
  runs from a labelled row-7 cell to the cell before the next label. With no
  row-7 labels, the headed columns split into three, the first ones widest;
- the freeze at C9 (rows 1-8, columns A-B) and gridlines off.

It sets formats only. It never writes a value and never merges a cell, so running
it twice changes nothing.

## Age colours

Select any cell in a date column (for example `Last Used`) and run **Extensions >
Studio > Add age colours to this column**. The column needs a header in row 8. It
adds the drawer's `age_bands` rules, with months `[4, 10, 16]` and the fresh
markers 💳 and 🔄:

| Age of the date | The row | The date cell |
|-----------------|---------|---------------|
| 4 months or less, or a fresh marker | green `#D9EAD3` | green |
| 10 months or less | white | - |
| 16 months or less | yellow `#FFF2CC` | amber `#F1C232`, bold |
| Older | red `#F4CCCC` | deep red `#CC0000`, white bold |

The date column is cut out of the row rules' ranges, so the row rules never
overlap the cell rules (Google ranks an overlapping row rule above a cell rule).
An `Archived` rule ranks first, so an archived row stays grey: the add-on keeps
the one the sheet has, or adds one (grey italic text on a light fill) when there
is an `Archived` column and no rule for it. Other rules stay, ranked after the age
colours. Run it again and it replaces the age rules it made before; it never
stacks them.

## How the add-on shares the drawer's rules

The Sheet Template drawer (`script/marketing_kit/office.py`, `def sheet`) builds
a sheet from a kit. The add-on restyles a sheet that already exists. They share
the same rules in two ways:

- **The brand table is generated.** The kit specs live in Drive, private, so the
  add-on cannot read them. `src/Brands.js` holds the public part of each spec:
  the three section colours (top, low), the title colour, the headline colour,
  the title alignment and the font. `MarketingKit::AddonBrands` computes them
  with `MarketingKit::SheetTemplate`, the drawer's own maths. Never edit
  `Brands.js` by hand. After a kit's colours change, fetch the four specs (the
  marketing-kit SOP) and regenerate it from the hub root:

  ```bash
  bin/rails runner script/marketing_kit/addon_brands.rb mi/kit.yml ms/kit.yml cw/kit.yml tm/kit.yml
  ```

  Pass all four specs each time: it rewrites the table whole. Then ship the
  change like any other.
- **The age bands are the same spec.** `STUDIO_AGE_BANDS` in `src/Style.js` is
  the drawer's `age_bands`, colour for colour. A unit test reads `office.py` and
  fails if the two drift.

## The files

| Path | What |
|------|------|
| `src/Logic.js` | The pure functions: header lookup, the ordinal date, row selection and filtering. They take plain arrays and numbers. |
| `src/Style.js` | The pure style rules: head section spans, the title alignment, and the age colours' rules as plain data. |
| `src/Brands.js` | The generated brand table (see above). |
| `src/Studio.js` | The thin Apps Script layer: the menu, the actions, the trigger. It reads and writes through `SpreadsheetApp` only. |
| `src/appsscript.json` | The manifest. |
| `.clasp.json.example` | The clasp config, with a placeholder script ID. Copy it to `.clasp.json` (git ignores it). |
| `test/javascript/studio_sheets_logic_test.js` | `[unit]` tests of `Logic.js`. |
| `test/javascript/studio_sheets_style_test.js` | `[unit]` tests of `Style.js` and `Brands.js`, and the drift check against the drawer's age bands. |
| `test/javascript/studio_sheets_addon_test.js` | `[integration]` tests of `Studio.js` against an in-memory `SpreadsheetApp`, `ScriptApp` and `Utilities`, plus the manifest and the menu wiring. |
| `test/lib/marketing_kit_addon_brands_test.rb` | `[unit]` tests of the brand table generator. |

Apps Script shares one global scope across a project's files, so the source uses
plain function declarations, not modules. The tests load the files into a Node
`vm` context the same way (`test/javascript/support/studio_sheets_addon.mjs`).

Run the tests from the hub root:

```bash
bin/test-js test/javascript/studio_sheets_logic_test.js test/javascript/studio_sheets_style_test.js \
  test/javascript/studio_sheets_addon_test.js
bin/rails test test/lib/marketing_kit_addon_brands_test.rb
```

CI runs them in the `javascript` lane with every other `test/javascript/*_test.js`.

## Scopes

The manifest asks for two scopes, and no others:

| Scope | Why |
|-------|-----|
| `https://www.googleapis.com/auth/spreadsheets.currentonly` | Read and write the spreadsheet the add-on is open in, and show a toast. It gives no access to any other file. |
| `https://www.googleapis.com/auth/script.scriptapp` | Create, list and delete the installable onEdit trigger (`ScriptApp.newTrigger`, `getUserTriggers`, `deleteTrigger`). Without it the tick-box cannot work in an add-on. |

The menu itself needs no scope. The add-on shows no dialog or sidebar, so it does
not ask for `script.container.ui`. Apply brand style and the age colours change
formats in the open spreadsheet, so `spreadsheets.currentonly` covers them. The
brand table ships inside the add-on, so it fetches nothing and needs no
`script.external_request`. Do not add a scope without a row here.

## Deploy it (Alex McRitchie's clicks)

An agent never signs in to Google for this. Each step below is a click or a
sign-in that Alex McRitchie does, from an admin account in the Workspace that will
own the add-on. Agents keep the code, the tests and this page.

### 1. Push the code with clasp

1. Turn on the Apps Script API for the owning account:
   <https://script.google.com/home/usersettings>.
2. Create the project: <https://script.google.com> > **New project**. Name it
   **Studio**. Open **Project Settings** and copy the **Script ID**.
3. From the hub checkout:

   ```bash
   cd addons/studio-sheets
   cp .clasp.json.example .clasp.json   # paste the Script ID into scriptId
   npx @google/clasp@3.4.1 login         # browser sign-in
   npx @google/clasp@3.4.1 push --force  # uploads src/ and replaces the default manifest
   npx @google/clasp@3.4.1 logout        # removes the refresh token from ~/.clasprc.json
   ```

   Always use the pinned version, `@google/clasp@3.4.1`. Always run `clasp
   logout` when you finish, so no long-lived refresh token stays in
   `~/.clasprc.json`. `.clasp.json` and `.clasprc.json` are git-ignored. The
   script ID is not a secret, but it stays out of this public repo all the same.

### 2. Link a Google Cloud project

The default Cloud project that Apps Script makes cannot publish to the
Marketplace. Use a standard one.

1. In <https://console.cloud.google.com>, create a project (for example
   `studio-sheets-addon`) in the owning organisation. Note its **project number**.
2. **APIs & Services > OAuth consent screen**: user type **External** (four
   Workspaces cannot share an Internal app). App name **Studio**. Add the two
   scopes above by hand with **Add or remove scopes > Manually add scopes**:
   `https://www.googleapis.com/auth/spreadsheets.currentonly` and
   `https://www.googleapis.com/auth/script.scriptapp`. Use the support links from
   step 3. Set the publishing status to **In production**: a Testing app expires
   its grants after seven days.
3. **Verify the consent screen.** Under **Authorized domains**, add
   `mcritchie.studio`, and verify it in Google Search Console as the same account
   (the domain is verified through its DNS). Then **Submit for verification**.
   The Marketplace review requires a verified consent screen. Only users in the
   Workspace that owns the Cloud project are exempt, and three of the four
   domains are outside it.
4. **APIs & Services > Library**: enable the **Google Workspace Marketplace SDK**.
5. Back in the Apps Script project: **Project Settings > Google Cloud Platform
   (GCP) Project > Change project**, and enter the project number.

### 3. Make a version and configure the Marketplace SDK

1. Make a version:

   ```bash
   npx @google/clasp@3.4.1 login
   npx @google/clasp@3.4.1 version "Studio 1"   # prints the version number
   npx @google/clasp@3.4.1 logout
   ```

   Use `clasp version`. The editor's **Deploy > Manage deployments** edits an
   existing deployment, and a new project has none.
2. Cloud console > **Google Workspace Marketplace SDK > App Configuration**:
   - **App visibility**: Public, with **Unlisted** ticked. **You cannot change
     the visibility after the first save**, so check it before you save. Unlisted means anyone
     with the link can install it and nobody can find it by search. That is what
     lets four separate Workspaces install one app. (Private works for one
     Workspace only.)
   - **Installation settings**: **Admin Only install**.
   - **App integration**: tick **Editor add-on**, then **Sheets add-on**, and
     enter the **Script ID** and the **version number**. Leave **Google
     Workspace add-on** (the card-based kind) unticked: Studio is an editor
     add-on, because only an editor add-on can add a menu and an edit trigger.
   - **OAuth scopes**: the same two scopes as the manifest.
   - **Developer links**: support `https://mcritchie.studio`, privacy
     `https://mcritchie.studio/privacy`, terms `https://mcritchie.studio/terms`.
3. **Store Listing**: name **Studio**, a short and a long description, the icons
   (32 x 32 and 128 x 128), a card banner (220 x 140) and one screenshot of the
   menu. Then **Publish**. Google reviews a Public app, Unlisted included, before
   the listing goes live. That can take a few days.

Before the review is done, test it on one sheet: in the Apps Script editor,
**Deploy > Test deployments > Install type: Editor add-on > Add test**, pick a
scratch spreadsheet, and **Execute**. A test deployment proves the menu items
only: editor add-on test deployments do not support installable triggers, so the
`Used` tick-box works only after a real install.

### 4. Install it in each Workspace

Repeat for each of the four Workspaces: `mcritchie.studio`,
`mcritchie.industries`, `commercialwelding.llc` and `turfmonster.media`.

1. Sign in as a super admin of that Workspace.
2. Open the Unlisted listing link from the Marketplace SDK **Store Listing** page.
3. Click **Admin install**, choose **Everyone** (or an organisational unit), and
   accept the scopes. The admin's consent covers the whole domain, so nobody sees
   a per-sheet **Allow** prompt.
4. Check it in **Admin console > Apps > Google Workspace Marketplace apps > Apps
   list**: Studio shows as installed for the chosen units.
5. If the domain restricts third-party apps, also mark Studio **Trusted** in
   **Admin console > Security > Access and data control > API controls > Manage
   third-party app access**.

The **Extensions > Studio** menu can take up to 24 hours to appear for users.

### 5. Turn on the tick-box in a sheet

In each spreadsheet that has a `Used` column: **Extensions > Studio > Turn on Used
tick-boxes**. Once per spreadsheet, by one person, normally the sheet's owner (see
**The tick-box** above).

## Ship a change

Code changes go through the normal task cycle (a PR into `accepted`). After the
change ships to `main`, push and version from the hub's primary checkout (log in,
push, version, log out), then raise the
version number in the Marketplace SDK **App Configuration** and save. Users get the
new version without a reinstall. A new scope is different: it needs the manifest,
the scope table above, the Marketplace SDK scope list and a fresh admin consent in
every Workspace. The SOP has the steps.
