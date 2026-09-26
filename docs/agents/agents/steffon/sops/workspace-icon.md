# Workspace Icon SOP (Steffon)

## Status: Active

Every client workspace wears its own icon on every piece of software we hold a
credential for: that software's logo with the workspace's badge in the
lower-right corner, on a transparent background. The 1Password version is the
icon a client's vault wears in the 1Password app. The whole set is what the
`/credentials` page shows, as a matrix with software down the side and entity
across the top. This SOP renders them, records them, and puts the vault icon
into 1Password.

Records only, throughout. Nothing here reads, stores or shows a secret value.

## The files

| What | Where |
|------|-------|
| Both axes: software logos (rows) and workspace badges (columns) | `config/workspace_icons.yml` |
| The renderer | `bin/workspace-icon`, logic in `bin/lib/workspace_icon.rb` |
| Brand marks (one per software) | `lib/workspace_icons/marks/` |
| Workspace badges | `lib/workspace_icons/badges/` |
| Software tiles (the mark on a white disc) | `app/assets/images/workspace_icons/software/<software>.png` |
| Badged icons | `app/assets/images/workspace_icons/<software>/<workspace>.png` |
| The census the page reads | `credential_vaults` and `credential_records`, seeded from `db/seeds/59_credentials.rb` |
| The pages | `/stack` (clients as rows) and `/credentials` (software by entity), both admin-only |
| Clients, tiers, Google users, Resend mode | `stack_clients`, seeded from `db/seeds/60_stack_clients.rb` |

**This repo is PUBLIC.** A logo, a vault name and an item title belong here, and
all of them are already published in the
[credential inventory](../../../modules/credential-inventory.md). An email
address, an item id or anything secret does not.
`CredentialRecord` refuses the token shapes it knows in every text column, but
that is a tripwire, not a guarantee.

## Prerequisites

| Needs | Check |
|-------|-------|
| ImageMagick (7 on a Mac, `magick`; 6 works too, `convert`) | `magick -version` |
| Ruby 3.x for `bin/workspace-icon` | `ruby -v` |

## Act 1: Add a workspace badge

1. Find the client's square logo. Prefer the icon over the wordmark: the badge is
   drawn at about a third of the icon, and a wordmark is unreadable there.
2. Copy it to `lib/workspace_icons/badges/<workspace>.png`.
3. In `config/workspace_icons.yml`, under `workspaces.<workspace>`, set `badge:`.
   Set `accent:` to the brand's main colour as `#rrggbb`. Leave it out only when
   the logo is one colour: without it, the ring takes the logo's average colour,
   which blends a two-colour logo into mud.
4. Render every software for it, then read one back:

   ```bash
   bin/workspace-icon --all
   bin/workspace-icon --list
   ```

   `--all` writes one icon per software for every workspace that has a badge, at
   256px, and reads each back: the right size, and a transparent corner. A
   render that exits 0 with a flattened background fails here, not in the vault
   list.
5. Open `/credentials` and look at the new column. A workspace with no badge
   shows **No badge**; a cell with no rendered icon falls back to the plain
   software tile.

## Act 2: Add a software row

A credential's `service` must be a software key in the config, or the record is
refused. That is what guarantees every row has an icon.

1. Find the brand mark. In order of preference:
   - **Simple Icons** (CC0): `npm pack simple-icons`, then take
     `package/icons/<slug>.svg`, and its colour from
     `package/data/simple-icons.json`. Bake the colour in:
     `sed 's|<svg |<svg fill="#<hex>" |'`. Brands that asked to be removed
     (AWS, Heroku, Slack) are still in `simple-icons@9`.
   - **The brand's own site icon**: the largest `<link rel="icon">` or
     `apple-touch-icon` on its homepage.
2. Save it as `lib/workspace_icons/marks/<software>.svg` or `.png`.
3. **An SVG must parse in ImageMagick's own renderer**, which rejects compact
   path data (`c-.211.3753`, run-together arc flags) and drops strokes and
   gradients. Render it once and look:

   ```bash
   magick -background none -density 300 lib/workspace_icons/marks/<software>.svg -trim /tmp/check.png
   ```

   An error, or an empty or cropped image, means spell every number in its
   `d=""` out with separators, or use the brand's PNG icon instead.
4. Add `<software>: { name: <Display Name>, mark: lib/workspace_icons/marks/<file> }`
   to `software:`. **The list order is the page's row order**: the headline
   accounts first, then A to Z.
5. Build its tile, then its badged icons:

   ```bash
   bin/workspace-icon --tiles
   bin/workspace-icon --all
   ```

## Act 3: Record a credential

When a credential is filed under
[credential-filing](credential-filing.md), record it here in the same pass.

1. Add its row to `db/seeds/59_credentials.rb`: `vault`, `title`, `service`,
   `category`, `url`, `used_by`, `scope_summary`, and `status` (`filed`,
   `empty`, `retired` or `missing`).
2. Set `entity:` only when the client it serves is not the vault's own. The Turf
   Monster keys live in the Studio agent vault and carry `entity: "turf-monster"`.
3. Load it: `bin/rails runner 'load Rails.root.join("db/seeds/59_credentials.rb")'`.
   In a desk, source `.env.agent-stack` first, or the write lands in the shared
   development database.

**Google is different.** One service-account key, `google.industries.agents`,
acts as `team@<domain>` in every ACTIVE `WorkspaceAccount`. So a new client's
Google access is a delegation grant on their domain (`workspace:register`, then
`workspace:check`), not a new item, and the Google row shows each workspace's
grant from `domain:` in the config.

## Act 4: Put a client on /stack

`/stack` shows one row per client: tier, software, Google users, Resend mode.

1. Add the client to `db/seeds/60_stack_clients.rb`: `slug` (its workspace key in
   `config/workspace_icons.yml`), `name`, `tier` (`launch`, `host`, `workspace`,
   `agentic`, or `internal`), `domain`, and `google_users` / `resend_mode`
   (`ms` or `white_label`) once known. Leave an unknown blank; never guess one.
2. **Do not list its software.** The strip is derived: the software its tier
   provisions (`software:` on each feature in `config/workspace_packages.yml`),
   plus every LIVE credential record serving it, plus `extra_software`.
3. **Hosting is per software.** A logo wears the Studio chest when McRitchie
   Studio runs it on our own account (`hosting: ms` in
   `config/workspace_icons.yml`: Google, Heroku, GitHub, AWS, Resend, 1Password
   and the rest of our infrastructure). Anything else is the client's own account
   and is drawn plain. A white-label client overrides per software in `hosting`,
   such as `{ "heroku" => "own" }`.
4. Load it the way Act 3 loads the census:
   `bin/rails runner 'load Rails.root.join("db/seeds/60_stack_clients.rb")'`.

## Act 5: Put the vault icon into 1Password

`op vault edit --icon` takes only 1Password's built-in icon keywords
(`treasure-chest`, `vault-door`, ...), never an image. A custom vault image is
uploaded in the 1Password app, which makes this step Mr. McRitchie's.

1. Render the full-size icon, which is drawn from the 1Password original rather
   than the 256px asset:

   ```bash
   bin/workspace-icon --workspace <workspace> --size 1024 --out ~/Downloads/<workspace>-vault.png
   ```

2. Hand him the file and the vaults it belongs on (`vaults:` under the
   workspace in the config). In the 1Password app: open the vault, **Edit**,
   click the icon, choose the image.
