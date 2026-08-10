# Kickoff — Standard transactional emails as an engine primitive

Paste everything below the line into a fresh session started from
`/Users/alex/projects`.

---

Work from `/Users/alex/projects`. Build the **standard transactional-email
primitive** in `studio-engine`, then adopt it in the host apps.

## The goal

Every Studio app should ship working, branded transactional emails the moment it
boots — no setup — and every app should be able to grow its own email workflows
and swap in its own artwork. Two halves:

- **Works from the jump.** The engine ships the email infrastructure and the
  default banner images. A brand-new app inherits the McRitchie Studio artwork
  and sends good-looking email on day one.
- **Expandable.** Each app registers its own email workflows and can upload its
  own image per email. On upload the asset belongs to that app.

## Build this

**1. A standard `/admin/emails` page,** modelled on the Design System page
(`/admin/style`) — one shared engine page every app gets, linked from the admin
sidebar. It replaces today's `/admin/email_images`.

- **Table view: name + image on every row**, so an email is identifiable at a
  glance. This is the primary view.
- Each row shows which image is live and whether it is the inherited default or
  an app-owned override.
- Uploading uses the **standard image-upload + crop modal**, not a bare
  `file_field_tag`.

**2. An email registry the host declares,** following the
`Studio::ModelPage.register` precedent already in the engine. An email record is
**mostly symbolic of the workflow** — the only real asset is the image.

- **Engine + McRitchie Studio ship exactly two:** `magic_link` and
  `email_change_confirmation`. Mr. McRitchie will supply the artwork later; build
  against placeholders.
- **Every app inherits those two** — MS, Turf Monster, moms-app, McRitchie
  Industries.
- **Turf Monster registers its additional workflows** on top: `wallet_export`,
  `winnings`, `friend_joined_contest`, `email_verification`,
  `email_change_notification`, `welcome`. This is where TM's email assets get
  organized.

**3. Inheritance with per-app override.** An app renders the engine default
until someone uploads a replacement on that app's `/admin/emails`; from then on
the asset belongs to that app. Example: McRitchie Industries inherits the MS
magic-link banner, and MI's admin page can replace it with MI-branded artwork.

## Read this before designing — five things I verified today

**The infrastructure mostly exists. Do not rebuild it.**

| Piece | Where | State |
|---|---|---|
| Registry + S3 store | `studio-engine/app/services/studio/email_image.rb` | Works; `VARIANTS` has **1** entry (`magic_link`) |
| Admin page | `studio-engine/app/controllers/studio/email_images_controller.rb` + `app/views/studio/email_images/index.html.erb` | Works; bare file input, no crop modal |
| Routes | `studio-engine/lib/studio.rb:468-469` | `/admin/email_images` GET + PATCH |
| Image records | `ImageCache` (`owner` polymorphic optional / `purpose` / `variant` / `s3_key`) | Owner-less rows already used for email banners |
| S3 | `studio-engine/lib/studio/s3.rb` | Bucket = `"#{Studio.s3_bucket_prefix}-#{dev\|production}"` |
| Crop + upload modals | `studio/modals/_crop_photo.html.erb`, `_image_upload.html.erb`, `studio/_cropper_assets.html.erb` | Factories: `cropPhotoModal()`, `imageUploadHost()`, `submitFormWithProgress()` |
| Sidebar API | `Studio.sidebar_sections` — `lib/studio/sidebar_sections.rb` | Array or callable; `admin: true` gates a section |
| Email shell | `studio-engine/app/views/layouts/branded_mailer.html.erb` | 600px card, full-bleed banner from `@banner_url` |
| Delivery tracking | `Studio::EmailDelivery` → `studio_email_deliveries` | Already recording sends |
| Dev inbox | `/_studio/local_emails` | Already working |

**Only one external caller** reads the registry today —
`turf-monster/app/mailers/user_mailer.rb:30` calls
`Studio::EmailImage.url(:magic_link)`. So `VARIANTS` can change shape freely.

### Decision to confirm before you build

**Each app has its own S3 bucket AND its own `image_caches` table**
(`mcritchie-studio-dev`, `turf-monster-dev`, …). So McRitchie Industries cannot
read a row McRitchie Studio wrote — inheritance has to come from somewhere both
apps can see.

**Recommendation: ship the defaults as engine gem assets.** Put the default
artwork in `studio-engine/app/assets/images/emails/`, and resolve in this order:

```
app's own ImageCache row (its S3 bucket)  →  engine default asset  →  nil
```

Uploading writes to the app's own bucket and creates its own `ImageCache` row —
which is exactly "the asset now belongs to the app." This is the only option
that makes a brand-new app with an empty bucket work on day one, and it needs no
cross-account S3 permissions. Note the nuance against the brief: *overrides* live
in S3, *defaults* ride the gem. Confirm before building.

The alternative — a shared `studio-defaults` bucket every app reads — is also
viable but adds a bucket, cross-app read permissions, and a new failure mode on
first boot.

### Blocker — three apps cannot upload anything yet

`Studio::S3` raises `NotConfigured` unless the host sets `s3_bucket_prefix`:

| App | `config.s3_bucket_prefix` |
|---|---|
| mcritchie-studio | `"mcritchie-studio"` ✅ |
| turf-monster | `"turf-monster"` ✅ |
| **mcritchie-industries** | **not set** |
| **moms-app** | **not set** |
| **acquisition-studio** | **not set** |

Setting the prefix is a one-line initializer change, but the `<prefix>-dev` and
`<prefix>-production` buckets must also exist. Confirm with Mr. McRitchie whether
to create them or point the satellites at an existing bucket under a per-app key
prefix. Until this is resolved, MI can render an inherited default but cannot
accept an upload — so the page must degrade honestly rather than 500.

### Fix these two bugs in the same pass

1. **The page misreports the live state.** It reads only the S3 override, so it
   shows *"No image yet — emails send without a banner until you upload one"* for
   an email that is currently sending **with** a banner from a committed repo
   asset. Once the registry knows its defaults, `current_url` must reflect what
   actually ships, and the copy must distinguish "inherited default" from "no
   image at all."

2. **`turf-monster/app/views/layouts/branded_mailer.html.erb` is a redundant
   fork.** It differs from the engine's copy only by a comment and a hardcoded
   `'Turf Monster'` where the engine uses `Studio.app_name`. Delete it.

### Also true, decide whether it is in scope

TM's seven PNG banners in `app/assets/images/emails/` are **1774×887 at
~1.7 MB each** and render at `width="600"`. The magic-link banner is already
1200×600 JPEG at 144 KB — the correct treatment. Re-cutting the other seven takes
11.7 MB down to about 1 MB. Since this work reorganizes exactly those assets, it
is the natural moment; if it widens the task too far, file it as a follow-up
rather than silently dropping it.

## Sequencing and DevOps routing

Order matters, because studio-engine is a published gem:

1. **studio-engine first** — registry, resolution order, `/admin/emails` page,
   crop-modal upload, sidebar link, default assets. Keep it additive.
2. **Publish the gem** (engine is at `0.32.3`; hosts pin `~> 0.30` / `~> 0.31`,
   so a `0.33` minor satisfies them).
3. **Hosts adopt** — MS registers its two; TM registers its full set and drops
   its `branded_mailer` fork and its local `email_banner_url` calls; MI and
   moms-app register the inherited two.

Operational notes for the gem repo, which behaves differently from an app:

- **The fast lane does not work for gem repos.** `bin/task begin` / `bin/ship`
  assume an app checkout. Use plain worktrees and the long-form commands.
- **Gem-repo PRs ride the two-rung ladder** — retarget to `release`, not
  `accepted`.
- **Consumer CI reads the consumers' `main`.** Anything that would break a host
  needs the host made forward-compatible first. This change should be additive,
  so verify that rather than assume it.
- Certify from the same root you built in.

Suggested split: one engine task, then one adoption task per app. Do not create
one task spanning both repos.

## Definition of done

- `/admin/emails` renders in all four apps, linked from the admin sidebar.
- The table shows name + live image per row, and says whether it is inherited or
  app-owned.
- Uploading goes through the standard crop modal and results in an app-owned
  asset.
- MS and the engine register `magic_link` and `email_change_confirmation`; TM
  registers its full workflow set; MI and moms-app inherit and render.
- MI's page shows the inherited MS artwork and can replace it (or explains
  clearly why it cannot yet, if the S3 blocker is still open).
- `/_studio/local_emails` still shows every email sending with the right banner.
- No app forks `branded_mailer.html.erb`.

Read `mcritchie-studio/docs/agents/modules/building-sop.md` before writing code,
and mark the local review with `bin/task update <task> --local-url … --approval
waiting` so Mr. McRitchie can look at the page before the PR.
