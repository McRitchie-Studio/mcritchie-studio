# Studio: the Google Sheets add-on

Studio is a Google Sheets **Editor add-on** (Apps Script). It is named after the
`studio-engine` gem. It gives every Sheet in our Workspaces an **Extensions >
Studio** menu and a tick-box behaviour for sheets built on our Sheet Template
layout: the table header is row 8 and data starts on row 9.

**This repo is public.** The add-on holds no private data: no spreadsheet IDs, no
card data, no script ID, no email address. Keep it that way.

The SOP for changing and redeploying it is
[`docs/agents/agents/steffon/sops/sheets-addon.md`](../../docs/agents/agents/steffon/sops/sheets-addon.md).

## What it does

Every function finds its columns by the **header names in row 8**, never by
column letter. A moved column never breaks a function.

| Menu item | What it does |
|-----------|--------------|
| Mark used this month | On each selected row (any selection, several ranges included), sets `Last Used` to the 1st of this month, number format `m/yy`. It skips rows above 9 and rows whose column B is empty. A toast says `N card(s) marked used Nov 2026`. |
| Archive row | Sets `Archived` to the text `Archived` on the selected rows. Our sheets grey these rows and skip them in totals by that exact value. |
| Un-archive row | Clears `Archived` on the selected rows. |
| Stamp Last Updated | Finds the cell in B1:B6 that starts with `Last Updated:` and rewrites it for today, for example `Last Updated: Nov 10th, 2026`, in the script's time zone (`America/Denver`). |
| Turn on Used tick-boxes | Installs the tick-box trigger for this spreadsheet. A second click does nothing: there is never more than one trigger. |
| Turn off Used tick-boxes | Removes that trigger. |

**The tick-box.** When the trigger is on, a tick in a column headed `Used` on row 9
or below writes the 1st of this month into `Last Used` on that row, and clears
the tick. A pasted block of ticks stamps each ticked row.

Simple `onEdit` triggers never run for an editor add-on, so the tick-box needs an
installable trigger. Each person who wants it turns it on once per spreadsheet.
The trigger runs as that person, and it fires on edits by anyone in the sheet.

## The files

| Path | What |
|------|------|
| `src/Logic.js` | The pure functions: header lookup, first of month, the ordinal date, row selection and filtering. They take plain arrays and dates. |
| `src/Studio.js` | The thin Apps Script layer: the menu, the actions, the trigger. It reads and writes through `SpreadsheetApp` only. |
| `src/appsscript.json` | The manifest. |
| `.clasp.json.example` | The clasp config, with a placeholder script ID. Copy it to `.clasp.json` (git ignores it). |
| `test/javascript/studio_sheets_logic_test.js` | `[unit]` tests of `Logic.js`. |
| `test/javascript/studio_sheets_addon_test.js` | `[integration]` tests of `Studio.js` against an in-memory `SpreadsheetApp`, `ScriptApp`, `Session` and `Utilities`, plus the manifest and the menu wiring. |

Apps Script shares one global scope across a project's files, so the source uses
plain function declarations, not modules. The tests load the files into a Node
`vm` context the same way (`test/javascript/support/studio_sheets_addon.mjs`).

Run the tests from the hub root:

```bash
bin/test-js test/javascript/studio_sheets_logic_test.js test/javascript/studio_sheets_addon_test.js
```

CI runs them in the `javascript` lane with every other `test/javascript/*_test.js`.

## Scopes

The manifest asks for two scopes, and no others:

| Scope | Why |
|-------|-----|
| `https://www.googleapis.com/auth/spreadsheets.currentonly` | Read and write the spreadsheet the add-on is open in, and show a toast. It gives no access to any other file. |
| `https://www.googleapis.com/auth/script.scriptapp` | Create, list and delete the installable onEdit trigger (`ScriptApp.newTrigger`, `getUserTriggers`, `deleteTrigger`). Without it the tick-box cannot work in an add-on. |

The menu itself needs no scope. The add-on shows no dialog or sidebar, so it does
not ask for `script.container.ui`. Do not add a scope without a row here.

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
   npx @google/clasp login              # browser sign-in, once per machine
   npx @google/clasp push --force       # uploads src/ and replaces the default manifest
   ```

   `.clasp.json` and `.clasprc.json` are git-ignored. The script ID is not a
   secret, but it stays out of this public repo all the same.

### 2. Link a Google Cloud project

The default Cloud project that Apps Script makes cannot publish to the
Marketplace. Use a standard one.

1. In <https://console.cloud.google.com>, create a project (for example
   `studio-sheets-addon`) in the owning organisation. Note its **project number**.
2. **APIs & Services > OAuth consent screen**: user type **External** (four
   Workspaces cannot share an Internal app). App name **Studio**. Add the two
   scopes above. Use the support links from step 3. Set the publishing status to
   **In production**: a Testing app expires its grants after seven days.
3. **APIs & Services > Library**: enable the **Google Workspace Marketplace SDK**.
4. Back in the Apps Script project: **Project Settings > Google Cloud Platform
   (GCP) Project > Change project**, and enter the project number.

### 3. Make a version and configure the Marketplace SDK

1. Make a version:

   ```bash
   npx @google/clasp version "Studio 1"   # prints the version number
   ```

   Or, in the editor: **Deploy > Manage deployments > New version**.
2. Cloud console > **Google Workspace Marketplace SDK > App Configuration**:
   - **App visibility**: Public, with **Unlisted** ticked. Unlisted means anyone
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
spreadsheet, and **Execute**.

### 4. Install it in each Workspace

Repeat for each of the four Workspaces: mcritchie.studio, mcritchie.industries,
commercialwelding.llc and the Turf Monster / Studio Workspace.

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
tick-boxes**. Once per spreadsheet, per person.

## Ship a change

Code changes go through the normal task cycle (a PR into `accepted`). After the
PR merges, push and version from the hub's primary checkout, then raise the
version number in the Marketplace SDK **App Configuration** and save. Users get the
new version without a reinstall. A new scope is different: it needs the manifest,
the scope table above, the Marketplace SDK scope list and a fresh admin consent in
every Workspace. The SOP has the steps.

## Not built yet

The task also names **Apply brand style** (the kit layout from the owning
company) and **age colours**. Both wait on the brand-style payload from the
`sheets-in-place-edits` task, which shares its layout rules with this add-on.
