# The shared client-app host

Every app built through `/build` gets its first version as a **static bundle**. One
shared host serves all of them at `<sub>.<preview domain>`, which is `mcritchie.si` in
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
written on a preview host.

| Host | Answer |
|------|--------|
| `<sub>.<domain>`, the app has a live bundle | The file the path names, from `App#preview_version`. `/` and a directory serve their `index.html`; `/about` also tries `about/index.html` and `about.html`. An unknown path **without** an extension gets `index.html` (the SPA fallback). An unknown file (`/x.js`) gets a 404 |
| `<sub>.<domain>`, a client app (an App with an `AppCto`) or a held `/build` request, no bundle yet | The "being built" page: the app's name, its CTO's name and portrait, and its palette in light and dark mode |
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

## The domain

| Where | `CLIENT_APP_PREVIEW_DOMAIN` unset | URL |
|-------|-----------------------------------|-----|
| Production | `mcritchie.si` (also listed in `config.hosts` as `.mcritchie.si`) | `https://<sub>.mcritchie.si` |
| QA | off: a QA app never claims production's domain | none |
| Development, test | `localhost` | `http://<sub>.localhost:<desk port>` |

Browsers, Playwright and curl (7.85 and later) resolve `*.localhost` to loopback with no
`/etc/hosts` edit. Setting the variable picks another domain, and `off` turns the host off.

**Not live yet.** Alex buys `mcritchie.si` later. Until then, production answers no
preview host. To go live:

1. Put the zone on Cloudflare, with a proxied wildcard `*.mcritchie.si` record.
2. Add `*.mcritchie.si` as a Heroku custom domain. Heroku's ACM does not issue wildcard
   certificates, so use a Cloudflare origin certificate.
3. If `EDGE_SECRET` is ever armed, add the same edge-secret transform rule to the new zone.

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

**The API.** `POST /api/v1/client_bundles/:sub` takes
`{ "files": [ { "path", "content_base64" } ] }` and answers 201 with
`{ data: { app_slug, version, previous_version, url, file_count, byte_size, event } }`.
A refused bundle answers 422 `BUNDLE_INVALID` with every reason in `errors`.

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
- **No throttle.** Preview hosts sit in front of Rack::Attack, so they are not
  throttled; the in-process cache keeps a repeat read off R2.
- **AppRequest stays where it is.** Publishing does not move a `/build` request to
  `live`; the launcher moves the task.
