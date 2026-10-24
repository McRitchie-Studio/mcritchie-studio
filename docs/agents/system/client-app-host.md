# The shared client-app host

Every app built through `/build` gets its first version as a **static bundle**. One
shared host serves all of them at `<sub>.<preview domain>`, which is `mcritchie.app` in
production. The plan and its decisions are in `.agents/epics/client-app-zero-to-one.md`.
An app moves to its own repo and Heroku app only when it needs server code.

The preview domain is a separate registrable domain. That way the hub's
`.mcritchie.studio` session cookie (`config/initializers/session_store.rb`) never reaches
code a model wrote.

## How a request is answered

`ClientAppHost` (`lib/middleware/client_app_host.rb`) is mounted after host authorization
and before `CanonicalHost`. A request whose host is under the preview domain is answered
there, by `ClientApps::Host`. It never reaches the cookie jar, the session, flash, the
CSP middleware, Rack::Attack, OmniAuth, or any hub route. So no `Set-Cookie` can be
written on a preview host, and the hub's own report-only Content-Security-Policy
never reaches a preview response, which carries the bundle policy below.

| Host | Answer |
|------|--------|
| `<sub>.<domain>`, any path under `/_studio/kit/` (an app with a bundle, or one being built) | The shared Studio kit ([The Studio template](#the-studio-template)) |
| `<sub>.<domain>`, the app has a live bundle | The file the path names, from `App#preview_version`; an HTML page is wrapped in the Studio template. `/` and a directory serve their `index.html`; `/about` also tries `about/index.html` and `about.html`. An unknown path **without** an extension gets `index.html` (the SPA fallback). An unknown file (`/x.js`) gets a 404 |
| `<sub>.<domain>`, a client app (an App with an `AppCto`) or a held `/build` request, no bundle yet | The "being built" page: the app's name, its CTO's name and portrait, and its palette in light and dark mode. It answers on **every** path (`/x.js` included) until a bundle exists |
| Anything else: an unknown sub, a reserved name or one of our own apps, the apex, a nested name | A bare 404 that names nothing of the hub's |
| A method other than GET or HEAD | 405 |

**Headers on every preview response:** `X-Content-Type-Options: nosniff`,
`Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy` and
`Cross-Origin-Resource-Policy: same-origin`, and a `Permissions-Policy` that denies camera,
microphone, geolocation, payment and USB.

**The bundle's CSP:**

```text
default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';
img-src 'self' data:; font-src 'self' data:; connect-src 'self'; media-src 'self';
object-src 'none'; base-uri 'none'; form-action 'self'; frame-src 'none';
frame-ancestors 'none'; worker-src 'self'; manifest-src 'self'
```

`'self'` is the app's own sub only. A bundle cannot call the hub, load a third-party
script, or run **inline script**: its JavaScript must live in `.js` files. Inline styles
are allowed. The host's own pages (being built, 404, error) carry `default-src 'none'`
and no script.

**Caching.** HTML gets `no-cache`, so a new publish shows at once; the ETag (the file's
sha256) makes a revalidation a 304. A file whose name carries a content hash
(`app-3f9a2c1b.css`) gets a year, `immutable`. Any other asset gets five minutes.

## The Studio template

Every app on the host wears the same frame: the **Studio navbar** (the app's name, split
as the engine's navbar splits it, with its CTO's portrait as the mark, a dark-mode toggle
and a menu) and the engine's **site footer** ("Built with McRitchie Studio", back to
`https://mcritchie.studio`), in the app's own palette, light and dark. Alex, 2026-10-20:
"We want to build all the apps to a standard and that should start with a template and
have a continuity." So the frame is never copied into a bundle, where it would freeze
and drift. The host owns it, in `ClientApps::StudioKit`
(`app/services/client_apps/studio_kit.rb`), and applies it **at serve time**: a change
to the engine or to the template reaches every app on its next request, with no rebuild.

**The contract a bundle keeps.**

- Every `.html` page puts its content in exactly one `<main data-studio-content>`.
  The app's own navigation (tabs, a section menu) goes inside it.
- Nothing before or after that region is page chrome: no `<header>`, `<footer>` or
  `<nav>` there (a `<script src>` is fine).
- No copy of the shell: no `data-studio-navbar`, `data-studio-footer`,
  `data-studio-menu`, `data-studio-kit`, `data-studio-theme` or `data-site-footer`.
- No reference to `/_studio/`, and no file under `_studio/`: that path is the host's.
- Style on the theme variables (below). Dark mode is the root's `dark` class, which the
  navbar's toggle sets, so a dark-only rule is `html.dark .thing`, never
  `@media (prefers-color-scheme)`.
- The engine primitives may be used in the content: `btn` with `btn-primary`,
  `btn-secondary`, `btn-outline` or `btn-neutral` (and `btn-sm`, `btn-lg`), `card`,
  `card-hover`, `badge`, `input-field`, `label-upper`, `empty-state`. No other Tailwind
  utility is in the kit.

`ClientAppBundle.template_errors` holds the contract (pure Ruby, so the CLI, the launcher
and the hub all run it), and publish refuses a page that breaks it. Bundles
published before the rule (team-notes, table-ready) keep serving and are wrapped too.
Their own hand-written `footer[data-site-footer]` stays in the page and the kit's CSS
hides it, so only the Studio footer shows.

**Where the host puts it.** `StudioKit::Wrap` never re-serialises the page, because
that would rewrite model-written markup. It inserts at three tag boundaries, found by
`ClientAppMarkup` (below), and leaves every other byte as written:

| Where | What |
|-------|------|
| Right after `<head>` | The kit's `<link>`, the app's theme (`<style data-studio-theme>`), the kit's `<script>`, first, so the bundle's own CSS has the last word and the theme is set before the first paint |
| `<body>` | Gains `data-studio-kit`, and the navbar goes right after it |
| The last `</body>` | The footer goes right before it |

A page missing a tag still gets the whole shell: the head goes after `<html>` or the
doctype; with no `<body>` tag the host opens one after the head; with no `</body>` the
footer goes before `</html>`, or last. The rendered shell is cached in process per kit
version and app identity (name, portrait, palette), and each page's insertion points per
its bytes, so a page view renders and scans nothing. The page's ETag covers its bytes and
the digest of the RENDERED shell (head, navbar and footer), so any template, footer fact,
menu, theme or kit change is a new ETag and a returning visitor never keeps an old shell.

**The one shared kit.** `GET /_studio/kit/<version>/studio-kit.css` and `studio-kit.js`,
on every app host that answers (a live bundle or a "being built" app):

- Same origin, so the bundle CSP's `'self'` covers it; no other origin, no inline
  script, no cookie, no hub route.
- `<version>` is the first 12 hex characters of the digest of both files, so the current
  version is cached for a year, `immutable`. A path naming an older version (a page
  rendered just before a deploy) gets the current files with the five-minute cache.
- There is no unversioned alias on purpose. Pages are `no-cache` and always name the
  current version, so an alias would only add a URL that can never be cached.

**Engine-derived, never hand-copied.**

| Piece | Source |
|-------|--------|
| CSS | The engine's `engine.css` (the `btn`/`card` utilities and the navbar's `nav-shell` band table) and its theme (`tailwind/studio.tailwind.config.js`, class-based dark mode), compiled by the hub's Tailwind (`tailwindcss-ruby`) against only the kit's templates, with no preflight; then `app/assets/studio_kit/shell.css` (the frame, the menu, the toggle's icon swap); then the footer's scoped CSS, lifted from the engine's `studio/site_footer/_assets`. About 25 KB |
| Navbar | `app/views/client_apps/kit/_navbar.html.erb`: the engine navbar's markup contract (`nav-shell`, `nav-row`, `nav-logo`, `nav-title`), drawn statically, never sticky, so an app's own sticky bar or fixed tabs sit under it with no stacking fight |
| Toggle | The engine's `components/_theme_toggle` partial, with its Alpine bindings rewritten to the kit's data hooks (`StudioKit.kit_toggle`). A binding the rewrite does not know raises `StudioKit::Drift`, so an engine change fails the test suite instead of shipping a dead button |
| Footer | The engine's `studio/site_footer/_footer` partial, with facts for the app (`Studio::SiteFooter.resolve`), rendered with no booking popup |
| Theme | `Studio::ThemeResolver`'s full token set, once per side of the app's palette, under `html:not(.dark)` and `html.dark`, plus the palette's own `--primary`, `--accent`, `--surface` and `--text`. Those selectors outrank a bundle's `:root`, so even an older bundle's colours follow the toggle |
| Script | `app/assets/studio_kit/studio-kit.js`: the theme (a saved choice, else the device's setting) and the menu (its button, Escape, a click outside). Storage failures are caught |

**Built at deploy, or on first use.** `bin/rails studio_kit:build` is a prerequisite of
`assets:precompile`, which the Heroku Ruby buildpack runs, so the slug carries
`app/assets/builds/studio_kit/<digest>.css` and no dyno compiles. The digest is of content
only (the engine and Tailwind versions, and each input's bytes under its path relative to
its root), so the build directory (`/tmp/build_<hash>`) and the running slug (`/app`) name
the same file. A process that finds no file for the current digest compiles it once, in
about a second: a mutex serialises its threads, a file lock serialises processes, and the
output is renamed into place from a unique temporary name.

**A broken kit never takes an app down.** If the kit cannot be built or rendered (a
Tailwind failure, an engine partial the kit no longer understands), every page is served
exactly as its bundle wrote it, with no shell, and the failure is recorded once
(`ErrorLog`, Sentry). Nothing retries the build for five minutes
(`StudioKit::FAILURE_BACKOFF`); then one request tries again.

**Where the host finds the tags.** `ClientAppMarkup` (`lib/client_app_markup.rb`, pure
Ruby) reads a page as a browser's tokenizer does: a `<body>` inside a comment, a quoted
attribute, or a `title`, `script`, `style` or `textarea` is text, not a tag. The wrap and
the publish check both use it, so a page publish accepts is a page the host wraps
correctly. Publish also refuses a page whose `<body>` tag comes after its content region.
A portrait that follows the colour scheme is drawn once per theme in the navbar, so the
mark follows the kit's toggle, not the device.

**Not covered yet.** The "being built" page does not wear the template.

## The domain

| Where | `CLIENT_APP_PREVIEW_DOMAIN` unset | URL |
|-------|-----------------------------------|-----|
| Production | `mcritchie.app` (also listed in `config.hosts` as `.mcritchie.app`) | `https://<sub>.mcritchie.app` |
| QA | off: a QA app never claims production's domain | none |
| Development, test | `localhost` | `http://<sub>.localhost:<desk port>` |

Browsers, Playwright and curl (7.85 and later) resolve `*.localhost` to loopback with no
`/etc/hosts` edit. Setting the variable picks another domain, and `off` turns the host off.

**The domain guard.** A set `CLIENT_APP_PREVIEW_DOMAIN` loses a trailing dot. Boot then
refuses it (an `ArgumentError`) when it sits at, under or above the hub's cookie domain
or any `production_url` or `qa_url` host in `config/apps.yml` or `config/satellites.yml`.
So `studio`, `mcritchie.studio.`, `media` and `x.turfmonster.media` are all refused.
It also refuses a value of one label (`app`, `.app`, `app.`): a top-level domain on
its own, not a registrable one. Only `localhost` may be one label.

**Forged hosts.** A request whose `X-Forwarded-Host` or `Forwarded` header names a preview
host is answered by the door, never the hub. `Forwarded` is read both by Rack's own
parser (what `request.host` believes: spaces around `=`, escaped quoted values) and by a
plain scan, because Rack answers nil for a header it cannot parse. A trailing dot on any
host is the same host.

**Live since 2026-10-19, 23:45 MDT.** Alex chose `mcritchie.app` on 2026-10-19 (it
replaced `mcritchie.si`). It is bought on Cloudflare Registrar, so the zone sits in our
Cloudflare account with no nameserver move. The whole `.app` TLD is on the browsers' HSTS
preload list, so a preview is reachable over https only (a browser upgrades every http
request to it before sending), and the certificate in step 2 is what lets anyone see a
page. What is in place:

- a proxied wildcard CNAME `*.mcritchie.app` on the Cloudflare zone;
- the Heroku SNI endpoint `gigantoraptor-93447`, carrying a Cloudflare origin certificate
  for `*.mcritchie.app` and `mcritchie.app` (expires 2041-10-16);
- zone SSL mode **Full (strict)**;
- the edge rate-limiting rule (step 4).

`EDGE_SECRET` is still **unset** on the hub, so the origin stays open (step 3).

How it was wired, in order (the runbook for a second preview domain):

1. Put the zone on Cloudflare, with a proxied wildcard `*.mcritchie.app` record.
2. Add `*.mcritchie.app` as a Heroku custom domain. Heroku's ACM does not issue wildcard
   certificates, so use a **Cloudflare origin certificate**. Minting one through the Origin
   CA API needs the token grant **Zone > SSL and Certificates > Edit**; the Account-level
   SSL and Certificates group is the wrong one and answers error 1016. **Adding a manual
   SNI certificate turns Heroku ACM off for the whole app** ("you cannot do both on a
   single app"), so on `mcritchie-studio` this step stopped the hub's own certificates
   renewing; see [`deployment.md`](../modules/deployment.md#certificates-and-the-edge)
   before doing it on any app that relies on ACM. Without a TTY, `heroku certs:add`
   cannot ask which domain the endpoint serves, so attach it afterwards with
   `heroku domains:update "*.mcritchie.app" --cert <endpoint>`.
3. **Edge secret before the rate rule.** If `EDGE_SECRET` is armed (or is armed later), add
   the same edge-secret transform rule to the new zone *first*. EdgeGuard sits in front of
   every host, so without the rule every preview request is refused. Without `EDGE_SECRET`
   armed at all, the origin stays open: a direct request to the Heroku dyno with
   `Host: x.mcritchie.app` reaches the door and never meets the edge's throttle, so the
   rate rule in step 4 is only a real limit once the edge secret is in force.
4. Add a Cloudflare **rate-limiting rule** on the zone: preview hosts sit in front of
   Rack::Attack, so the edge is their only throttle. Match
   `ends_with(http.host, ".mcritchie.app") or http.host eq "mcritchie.app"`, count by
   client IP, and block past a ceiling well above one visitor's page load. The Free plan
   allows only a **10-second period**, so start near **50 requests per 10 seconds** per IP
   and tune from the zone's analytics.
5. **Set `CLIENT_APP_PREVIEW_DOMAIN` on QA first** (`mcritchie-studio-qa`), and watch it
   boot. The domain guard raises at boot on a bad value, so a typo crash-loops the whole
   hub, not just the preview host. Production needs no value (the default is
   `mcritchie.app`); set one there only after the same value booted on QA.

Each step is a DNS or credential change for Steffon's `domain-dns` act.

## Storage

Each file is one object, never an Active Storage blob row:

```text
client-apps/<sub>/<version>/<path>
```

`version` is `YYYYMMDDTHHMMSSZ-<8 hex>`. A version's objects are written once and never
changed. The service is `CLIENT_APP_BUNDLE_SERVICE`, else:

- **Production and QA:** `chat_private`, the private R2 bucket pair
  (`mcritchie-studio-chat-production` and `-dev`). It has no public domain. Bundles
  **never** go in the hub bucket (`amazon`), because `assets.mcritchie.studio` serves any
  key in it to anyone. That would put model-written HTML on a `mcritchie.studio` origin,
  inside the session cookie's reach. No new bucket was added. If its keys
  (`CHAT_R2_ACCESS_KEY_ID`, `CHAT_R2_SECRET_ACCESS_KEY`) are unset, a publish answers 503
  `STORAGE_NOT_READY`.
- **Development:** `local` (Disk, `storage/`).
- **Test:** `test` (Disk, `tmp/storage`).

The host reads an object only when its path is in the version's manifest. It checks the
bytes against the manifest's sha256 and caches them in process (64 MB, least recently
used).

## The model

- **`apps.preview_version`** names the live bundle. Publishing is the only thing that
  flips it.
- **`app_preview_versions`** is the history, one row per publish: `version`,
  `published_by` (the session's soul and slug), `file_count`, `byte_size`, the
  `manifest` (`path => size, sha256, content_type`) and `published_at`. Rows are never
  changed. `App#current_preview` is the live row.

## Publishing

The publish contract: the CLI, the API, the storage path and the event.

```bash
bin/client-bundle check <dir>                     # validate only; sends nothing
bin/client-bundle publish <sub> <dir>             # through the hub API (https://mcritchie.studio)
bin/client-bundle publish <sub> <dir> --api URL   # through another hub, such as a desk server
bin/client-bundle publish <sub> <dir> --local     # this checkout's development database and Disk; refused in production
```

**The bundle rules** live in `ClientAppBundle` (`lib/client_app_bundle.rb`, plain Ruby).
The CLI runs them before it sends anything, and the hub runs them again.

- `index.html` at the root.
- At most 200 files and 5 MB in all, and 3 MB for one file.
- These extensions only: html, css, js, json, svg, png, jpg/jpeg, webp, woff2, ico, txt.
  There is no server code.
- Relative paths of `[A-Za-z0-9_.-]` segments: no dot-files, no `..`, no absolute path,
  no backslash, at most 6 levels deep.
- Read from disk: regular files only, no symlinks.
- The Studio template: one `<main data-studio-content>` per page, no page chrome or shell
  hook of its own, nothing under or naming `_studio/` ([The Studio template](#the-studio-template)).

**The API.** `POST /api/v1/client_bundles/:sub` takes
`{ "files": [ { "path", "content_base64" } ] }` and answers 201 with
`{ data: { app_slug, version, previous_version, url, file_count, byte_size, event } }`.
A refused bundle answers 422 `BUNDLE_INVALID` with every reason in `errors`.

**Only client apps publish.** `ClientApps::Publish.publishable_reason` allows an app only
when a `/build` request (`AppRequest`, queued, building or live) holds its name: the claim
`AppLaunch` and `AppRequest#queue!` make. The reserved names and `config/apps.yml` stay as
a second guard. Any other App row is refused ("has no client origin").

The bearer must be an **agent session**. The shared token answers 401, and a client or
harness session 403. An admin session publishes any client app. A studio session
publishes only the app whose **build task** it holds: the task of the `/build` request
that holds the sub. The CLI sends `CLIENT_BUNDLE_SESSION_TOKEN`, else
`AGENT_ADMIN_SESSION_TOKEN`, else the desk's own studio session. It holds no storage
credential; the hub writes R2.

**In process.** `ClientApps::Publish.new(app:, files: { path => bytes }, by:).call` runs
three steps:

1. **Validate** the bundle.
2. **Upload** every file under the new version. Nothing reads a version until step 3
   names it, so a failed upload leaves the live preview unchanged.
3. **Flip** in one transaction under the app's row lock: the history row,
   `apps.preview_version`, and the event. A reader sees the old version or the new one,
   never a mix.

**The event.** A `TaskEvent` **checkpoint** named `preview_ready` (status `ok`) on the
app's build task, with metadata `app_slug`, `version`, `url`, `file_count` and
`byte_size`. The status card (`app-card-stage-labels`) and the CTO read it. An app with
no build task records none.

## Not covered yet

- **No rollback command.** Re-publishing an older bundle makes a new version.
- **No in-app throttle.** Preview hosts sit in front of Rack::Attack, so the hub does not
  throttle them; the in-process cache keeps a repeat read off R2, and the go-live
  Cloudflare rate rule (step 4 above) is their throttle. The reserved-name list a preview
  request checks is read once per process, never from disk per request.
- **AppRequest stays where it is.** Publishing does not move a `/build` request to
  `live`; the launcher moves the task.
