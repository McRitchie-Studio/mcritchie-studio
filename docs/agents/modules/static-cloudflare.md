# Static apps on Cloudflare R2

**Purpose.** Serve a database-free app as plain files from Cloudflare R2, with no
Heroku dyno, and ship it through the release like any other app.

**Why.** The seven showcase apps share Heroku's 1,000h Eco pool. It was overdrawn by
75h on 2026-10-24, so all seven answered 503 for the last week of every month. Alex,
2026-10-25: the unpaid apps serve from Cloudflare. The lifecycle that will downgrade
any unpaid app after its 30-day trial is epic `hosting-trial-lifecycle`
(`/Users/alex/projects/.agents/epics/hosting-trial-lifecycle.md`); this page is its
first piece.

**Who.** The ship runs the strategy (`production-deploy`). Steffon's lane runs a
downgrade (`bin/static-downgrade`), because it uses the admin Cloudflare token.

## How a request is answered

| Piece | What it is |
|---|---|
| Bucket | One R2 bucket per app, `<heroku app>-static` (rantly: `mcr-rantly-static`), holding one object per file of the static build |
| Host | An **R2 custom domain** on the app's existing host (`rantly.mcritchie.studio`). It replaces the old CNAME to Heroku, and Cloudflare manages its proxied record and certificate |
| Index documents | R2 has none, so a zone **URL rewrite** (Transform Rules, phase `http_request_transform`) maps the path before R2 sees it. The address bar keeps the clean URL |
| Release marker | `static-release.json`, written last on every deploy: `{sha, repo, built_at, objects}`, `Cache-Control: no-store` |

The rewrite is two rules per host, using only functions every plan has (no regex):

| Path | Key |
|---|---|
| ends in `/` (`/`, `/rants/x/`) | `<path>index.html` |
| no `.` anywhere (`/rants/x`, `/@rantly`, `/up`) | `<path>/index.html` |
| anything else (`/assets/app-1a2b.css`, `/404.html`) | as it is |

`StaticCloudflare::Rewrite.key_for` is the same mapping in Ruby; the tests' stub hosts
serve through it. **The one limit:** a page path that contains a dot is not rewritten.
The static build writes pages only at extension-free paths. An unknown path gets R2's
own 404, not the app's `404.html`.

**Cache.** A page is `no-cache` (a ship shows at once), a digested asset a year
`immutable`, anything else five minutes: the client-app host's policy
([`../system/client-app-host.md`](../system/client-app-host.md)).

## What an app must be

- No database, no add-ons, and only GET routes whose pages depend on nothing but the
  checked-in code (the showcase apps read YAML under `data/`).
- **`bin/static-build`** in the repo: writes the whole site into `$OUT` for host
  `$HOST`, including `index.html` and `up/index.html` (the smoke reads `/up`). Rantly's
  renders every route through the real Rack app in production mode and crawls every
  internal link, so the bundle is what the dynamic app serves (`lib/static_site.rb`).
- **No link with a query string.** A static host ignores it, so the build refuses one.
  Rantly's sorted feed moved from `/?sort=discussed` to `/discussed` for this.

## The ship: `static_cloudflare`

`config/release_repos.yml`, on the `standalone-static` profile
(`config/app_profiles.yml`):

```yaml
rantly:
  profile: standalone-static
  ladder: three-rung
  prod_deploy:
    strategy: static_cloudflare
    bucket: mcr-rantly-static
    heroku_app: mcr-rantly        # parked at 0; no remote, so no ship pushes to it
    smoke_url: https://rantly.mcritchie.studio
  test_cmd: bin/rails test
  qa_evidence: exempt
```

Optional keys: `build_command` (default `bin/static-build`), `build_dir` (default
`tmp/static/site`), `credential` (default `r2.static-sites`).

`bin/release ship` (`deploy_app`, `when :static_cloudflare`):

1. Refuses an adapter with no `bucket` or `smoke_url` before `main` moves.
2. Pins the **ship workspace** at the frozen SHA (`<repo>/.worktrees/_ship`), checks its
   bundle under the suite ruby, and runs `bin/static-build` there in production mode.
   No test database: the gate's `RAILS_ENV=test` and `DATABASE_URL` are stripped.
3. Uploads every object with `aws s3api put-object` (assets first, then pages), with the
   keys of `credential` in the child's environment only.
4. Writes `static-release.json` last.
5. Smokes `<smoke_url>/up` **and** the marker: both must answer, and the marker must
   name the frozen SHA. `/up` alone proves nothing, because the old Heroku dyno answers
   it too. It retries for a minute.
6. Records the G4 `deploy:<repo>` SOP and aborts on any failure, naming the key.

A failed upload leaves the previous release serving every key not yet written, and no
page names an asset it lacks (assets go first, and digested names never collide).
`finalize` confirms the deploy by the marker naming the SHA. `bin/release rollback`
rebuilds the previous SHA the same way.

**The registry is read from the hub primary.** A change to `release_repos.yml` takes
effect only once the hub change carrying it has shipped.

## The downgrade: one unit, any app

`StaticCloudflare::Downgrade` (`bin/lib/static_cloudflare.rb`) is the one-time move
off Heroku. The hosting-trial daily job will call it for an app past its trial;
`bin/static-downgrade <repo>` is its command line. **It plans by default and writes
only with `--execute`.** The order is the safety:

| # | Step | Write |
|---|---|---|
| 1 | Create the bucket, if absent | `POST /accounts/<id>/r2/buckets` |
| 2 | Build `origin/main` in a private worktree, upload it, write the marker | `aws s3api put-object` per file |
| 3 | Delete the host's old record (the CNAME to Heroku), unless the custom domain is already attached | `DELETE /zones/<z>/dns_records/<id>` |
| 4 | Attach the R2 custom domain | `POST /accounts/<id>/r2/buckets/<b>/domains/custom` |
| 5 | Put the URL rewrite, carrying the zone's other rewrite rules | `PUT /zones/<z>/rulesets/phases/http_request_transform/entrypoint` |
| 6 | Smoke `/up` and the marker at the SHA | reads |
| 7 | Only after a green smoke: scale the web dyno to 0 (`--keep-dyno` skips it) | `PATCH /apps/<app>/formation/web {quantity: 0}` |

The Heroku app is **kept, never deleted**, until Alex rules on removing it. The plan
prints the old record so step 3 can be undone. A failed upload stops before any DNS
write; a failed smoke stops before the scale, with the dyno still up. Steps 3 to 5
are the only window in which the host may not answer.

After an `--execute`, move the app's `release_repos.yml` entry to
`profile: standalone-static` in the same pass, or the next ship would push to a dyno
nobody serves. Update the app's README `## Deploy` section too.

**Credentials,** read from 1Password and never printed:

| Item | Lane | For |
|---|---|---|
| `cloudflare.studio.provision` | admin (`studio-agents-admin`) | the zone, DNS, R2 bucket and custom domain, Transform Rules. It holds R2, Transform Rules and DNS grants; it has no Workers Scripts or Pages scope, which is why this design uses neither |
| `r2.static-sites` | agent (`studio-agents`) | the upload: an R2 S3 key pair (`access-key-id`, `secret-access-key`, `endpoint`) scoped to the `*-static` buckets. **Not yet minted:** Steffon's `bucket-provision` mints it with the provision token's Account API Tokens grant before the first downgrade |
| `heroku.studio.agents` | agent | the scale to 0 (or `HEROKU_API_KEY`) |

## Rantly first

Built and tested; **nothing live has changed.** In order, after the hub change ships:

1. Mint `r2.static-sites` (`bucket-provision`).
2. `bin/static-downgrade rantly` and read the plan.
3. `bin/static-downgrade rantly --execute`. It builds rantly's `origin/main`, so the
   rantly change carrying `bin/static-build` must have shipped first.
4. Check `https://rantly.mcritchie.studio/`, a rant, a profile and `/discussed` in a
   browser; then the next rantly ship runs through `static_cloudflare`.

## How the other six move

**One fold, run by the daily job's first run** (the epic's third piece), not six cards:
each app is one `bin/static-downgrade <repo> --execute` plus its registry line. Each
repo first needs its own `bin/static-build` (Rantly's `lib/static_site.rb` and
`lib/tasks/static.rake` copy across almost verbatim; only the seed list of routes is
the app's own) and a link audit for query strings.

| App | Heroku app | Host today | Before it can move |
|---|---|---|---|
| dads-app | `dads-app` | `greigmcritchie.com` | the zone must be on Cloudflare in this account (an R2 custom domain needs it); check with `domain-dns` |
| 10and5 | `mcr-10and5` | the herokuapp host | a `10and5.mcritchie.studio` host first: the herokuapp host cannot point at R2. Its nested visits routes are GET-only |
| portfolio | `mcr-portfolio` | `portfolio.mcritchie.studio` | `bin/static-build` |
| prisoners-dilemma | `mcr-prisoners-dilemma` | `prisoners-dilemma.mcritchie.studio` | `bin/static-build`; any client-side game logic stays in JS files |
| search-position | `mcr-search-position` | the herokuapp host | a `search-position.mcritchie.studio` host first |
| weekly-lock | `mcr-weekly-lock` | `weekly-lock.mcritchie.studio` | `bin/static-build` |

`StaticCloudflare.downgrade_target` derives each one's bucket (`<heroku app>-static`)
from its current `git_push_heroku` adapter, so the daily job needs no per-app config.
In `test/models/release/repos_test.rb`, each app moves from `SHOWCASE_APPS`'s Heroku
test to `STATIC_SHOWCASE_APPS` in the PR that flips its registry line.

## Code and tests

| File | What |
|---|---|
| `bin/lib/static_cloudflare.rb` | `Target`, `Rewrite`, `Bundle`, `S3Uploader`, `Deploy`, `Downgrade` |
| `bin/release.rb` | `deploy_app` `when :static_cloudflare`, `static_release_sha` (finalize), `rollback_app` |
| `bin/static-downgrade` | the downgrade's command line |
| `test/lib/static_cloudflare_test.rb` | [unit] keys, headers, rewrite, upload argv, build, upload, smoke, abort on a failed upload, downgrade order |
| `test/lib/release_cli_deploy_app_test.rb` | [integration] a ship of a fixture app through the strategy against a stub bucket; a failed upload; the dry run |
