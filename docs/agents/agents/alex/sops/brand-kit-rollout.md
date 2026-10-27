# Brand Kit Rollout SOP
<!-- registry: apply a saved brand kit to one or more apps and record it applied -->

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](../../../modules/token-session.md)).

## Status: Active

This is Alex's `brand-kit-rollout` SOP. A brand kit is saved on the hub's
`/logos/<brand>` page; an app draws its logo from the kit's files committed under
its own `public/brand/`. This SOP takes one or more saved kits into one or more
apps, through the normal pipeline, and ends by recording each app as **Applied**
on the hub. The /logos brand column and each app's page (`/applications/<slug>`)
show every link as **Applied**, **Kit changed** (amber: the kit was saved after
the app last applied it) or **Not applied**. Design and status rules:
`docs/topics/logos.md` § Which apps have the kit.

## Preconditions

- **The kit is saved on production.** Its Icon, Navbar and Stacked choices are
  what Alex McRitchie wants (the Kit card on `/logos/<brand>` shows them). The
  kit's version is its `saved_at`; a later save turns every app's link to Kit
  changed.
- **The link exists, or the rollout will create it.** `/logos` lists the apps a
  kit feeds. A new kit-to-app pairing is created by step 6.

## Procedure

**1. Pick the kits and the apps.** Read `/logos` on production: each row's app
lines say which apps are behind (Kit changed, Not applied). An app may take
several kits (Commercial Welding v1 and v2 both feed `commercial-welding`);
name which one the app draws, and where each goes.

**2. Open one task naming every repo it touches.** Run
[`building-sop`](../../../modules/building-sop.md) with one `task begin` whose
`--repo` names each target app (and `mcritchie-studio` when the hub itself is a
target). Kind `chore`, shape `ui-only`; Alex McRitchie will recognize a new logo
on sight, so it earns a local review. One task, not one per app.

**3. Export the kit from production.** Read the kit's manifest, read-only, on
the hub's production app:

```bash
heroku run -a mcritchie-studio --no-tty --exit-code -- bin/rails runner \
  'puts JSON.generate(BrandKitInstall.manifest_for(BrandKit.for("<brand>")))' > <scratchpad>/kit-<brand>.json
```

Check that the file is one JSON line naming the brand and a `saved_at` (not
`null`: a kit never saved has no version to apply). The files themselves are
drawn from it, byte-equal to what production's `/logos/<brand>/kit/<file>` and
`/logos/<brand>/kit.zip` serve; there is no need to download them.

**4. Install into each app's desk.** From the hub desk (any hub checkout runs
the rake task; the files land where `DEST` points):

```bash
bin/rails logos:install BRAND=<brand> FROM=<scratchpad>/kit-<brand>.json \
  DEST=/Users/alex/projects/<app>/.worktrees/<task-slug>/public/brand
```

It writes the nine SVGs and `kit.json` (the brand, the three choices and the
kit's `saved_at`). A second kit for the same app goes in its own folder
(`public/brand/<brand>/`) so the two `kit.json` files never overwrite each
other. Then make the app draw the files as they are: the navbar and footer
read `navbar-*.svg` and `stacked-*.svg` by tone; never hand-edit a copy.

**5. Regenerate the raster icons** the app serves, exactly as
`docs/topics/logos.md` § Installing a kit into an app describes for the hub:
the favicon's small-size mark (`logos:favicon_mark`, then `node
script/brand_png.cjs <mark.svg> <app>/public/favicon.png 256`), `icon.png`
from `icon-dark.svg` (`… icon.png 512 '<background>' 0.16` where the manifest
serves it as maskable), and `og.png` from `stacked-dark.svg` with the
ImageMagick line there (keep its `+size`). Look at each result.

**6. Submit, review, ship.** Boot each desk, open the pages that draw the logo
in light and dark, and hand Alex McRitchie the local review (building-sop
Step 4). Then `submit-wait`, the reviewer's [`pr-review`](../../carl/sops/pr-review.md),
Avi's [`qa-release`](../../avi/sops/qa-release.md) and Steffon's
[`production-deploy`](../../steffon/sops/production-deploy.md). This SOP never
merges or deploys on its own.

**7. Verify the live kit and record it.** Once each app is in production, read
its live manifest and compare its `saved_at` with the one exported in step 3:

```bash
curl -sS https://<app host>/brand/kit.json      # public/brand/<brand>/kit.json for a second kit
```

Only when they match, record it on the hub's production database:

```bash
heroku run -a mcritchie-studio --no-tty --exit-code -- bin/rails logos:applied \
  BRAND=<brand> APP=<app slug> BY="<your soul>" SAVED_AT=<the live kit.json saved_at>
```

It prints `<brand> → <app>: Applied (…)`; `/logos` and the app's page now say
Applied. A mismatch is a stale deploy or a kit saved since step 3: do not
record it; find which and go again. Nothing polls an app's `kit.json` yet, so
this read is the only check.

## Done when

- Every target app's live `/brand/kit.json` names the kit's `saved_at`.
- `logos:applied` recorded each link on production, and `/logos` shows each
  target app as **Applied**.
- The task shipped through `production-deploy`, with the local review offered.
