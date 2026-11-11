# Sheets Add-on SOP (Steffon)
<!-- registry: change, test and redeploy the Studio Google Sheets editor add-on (addons/studio-sheets) -->

## Status: Active

Studio is our Google Sheets editor add-on. It gives every Sheet in our four
Workspaces an **Extensions > Studio** menu: the `Used` tick-box, archive, Last
Updated, **Apply brand style** and **age colours**. The
code, the manifest and the full deploy guide live in
`addons/studio-sheets/README.md`. This SOP
is how an agent changes it and gets the change to users.

**This repo is public.** Never commit a script ID, a spreadsheet ID, card data or
an email address. `.clasp.json` is git-ignored; keep it that way.

**Agents never sign in to Google for this.** The clasp login, the Cloud console,
the Marketplace SDK and every admin install are Alex McRitchie's clicks. An agent
builds, tests and hands him the exact steps.

## Act 1: Change the code

1. Start a task (`bin/task begin`, repo `mcritchie-studio`, shape `backend`) and
   work in its desk.
2. Put decisions in `src/Logic.js` (rows and dates) or `src/Style.js` (brand
   style and age colours) as pure functions that take plain arrays and numbers.
   Keep `src/Studio.js` a thin layer that reads and writes through
   `SpreadsheetApp`. Never edit `src/Brands.js` by hand: it is generated (Act 5).
3. Find every column by its row-8 header name with `studioColumnIndex`. Never use
   a column letter.
4. A function a menu item or a trigger calls must be public (no trailing `_`).
   Add a new item to `onOpen` and to the menu test.
5. Test both tiers:

   ```bash
   bin/test-js test/javascript/studio_sheets_logic_test.js test/javascript/studio_sheets_style_test.js \
     test/javascript/studio_sheets_addon_test.js
   ```

   - `[unit]` `studio_sheets_logic_test.js` and `studio_sheets_style_test.js`:
     each pure function, and the drift check against the drawer's age bands.
   - `[integration]` `studio_sheets_addon_test.js`: the Apps Script layer against
     the in-memory fakes. Extend the fake there when you call a new
     `SpreadsheetApp` method; an unfaked method fails the test.
6. Submit with `bin/submit-wait`. The PR goes through review into `accepted` like
   any other.

## Act 2: Change a scope

A new scope is the expensive change: every Workspace admin must consent again.
Prefer the narrowest scope that works, and say why in the PR.

1. Edit `oauthScopes` in `src/appsscript.json`.
2. Update the scope test in `studio_sheets_addon_test.js` and the **Scopes** table
   in the README, with one line of reason.
3. After the change ships to `main`, Alex McRitchie adds the scope by hand to the
   Cloud OAuth consent screen (**Manually add scopes**) and to the Marketplace SDK
   **App Configuration**, then re-runs the admin install in each Workspace
   (README step 4). A new sensitive scope can also need the consent screen
   verified again.

## Act 3: Redeploy after the merge

Hand Alex McRitchie these steps. They run from the hub primary checkout once the
change is on `main`, with his clasp login:

```bash
cd addons/studio-sheets
npx @google/clasp@3.4.1 login
npx @google/clasp@3.4.1 push --force
npx @google/clasp@3.4.1 version "<task-slug>"   # prints the new version number
npx @google/clasp@3.4.1 logout                  # no refresh token left in ~/.clasprc.json
```

Keep clasp pinned to `3.4.1`, and always end with `clasp logout`.

Then: Cloud console > **Google Workspace Marketplace SDK > App Configuration** >
set the **Sheets add-on** script version to the new number > **Save**. Users get
it on their next sheet load; no reinstall. A listing change (name, icons,
description) goes back through Google's review; a version change does not.

To try a change before release, use **Deploy > Test deployments** in the Apps
Script editor on a scratch spreadsheet. Never test on a live roster. A test
deployment proves the menu items only: editor add-on test deployments do not
support installable triggers, so the `Used` tick-box is proved only after a real
install.

## Act 4: Check it works

1. Open a sheet built on the Sheet Template in each Workspace. **Extensions >
   Studio** shows the eight items, with the four companies under **Apply brand
   style**.
2. Select two rows, run **Mark used this month**: `Last Used` reads `11/26` style
   and a toast counts the rows.
3. **Turn on Used tick-boxes** (once per spreadsheet, as the owner; two
   people's triggers race), tick a `Used` box: `Last Used` updates and the box
   clears.
4. On a scratch copy, **Apply brand style** for its company: the title and the
   head rows take the brand colours, the freeze sits at C9, and no value changes.
5. Select a `Last Used` cell, **Add age colours to this column**, run it twice:
   **Format > Conditional formatting** lists the Archived rule first and one set
   of age rules.

If the menu is missing in one Workspace, check **Admin console > Apps > Google
Workspace Marketplace apps > Apps list** there. The install may cover only some
organisational units.

## Act 5: Regenerate the brand table

`src/Brands.js` holds each brand's head section colours, title and headline
colours, title alignment and font, computed by `MarketingKit::SheetTemplate`, the
drawer's own maths. Regenerate it when a kit's colours or `sheet:` options change:

1. Fetch the four kit specs (MI, MS, CW, TM) into your scratchpad, as the
   [marketing-kit SOP](../../alex/sops/marketing-kit.md) does.
2. From the desk:

   ```bash
   bin/rails runner script/marketing_kit/addon_brands.rb <mi>/kit.yml <ms>/kit.yml <cw>/kit.yml <tm>/kit.yml
   bin/rails test test/lib/marketing_kit_addon_brands_test.rb
   ```

   Pass all four specs: the table is rewritten whole. It carries colours, the
   font and the alignment only, never a spec's contact details.
3. Commit `src/Brands.js` and ship it like any change (Act 3 after `main`).

A new brand also needs its own menu function in `src/Studio.js`
(`studioBrandStyle<SHORT>`) and a row in `STUDIO_BRAND_MENU`; the menu test fails
until it has them.
