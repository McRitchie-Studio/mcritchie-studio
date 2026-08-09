# CDN Rollout — putting the apps behind Cloudflare

**Why this exists.** On 2026-08-09 a distributed scraper swarm took `mcritchie.studio`
down for minutes at a time. It used **2,258 unique IPs, 2,241 of them making exactly one
request**, so the per-IP throttles in `config/initializers/rack_attack.rb` were
structurally blind to it. Production serves **3 concurrent requests** (one Basic dyno,
Puma's default 3 threads, no workers), so three expensive renders is the whole site:
2,293 router timeouts in 2m47s, taking the board, `/api/v1/*`, the GitHub webhook, and
the `/up` health check with them.

An edge in front is the durable answer to that shape of traffic, and it gives Mr.
McRitchie a lever he can pull mid-incident without a deploy.

Roll it out **one domain at a time**, starting with the hub. Each domain is a separate
nameserver migration with its own certificate risk; doing four at once means four ways
to be down with no clean rollback.

---

## The two things that make a CDN real

Skipping either leaves you with a CDN that looks installed and protects nothing.

**1. The origin must stop answering strangers.** The dyno keeps its own hostname.
`mcritchie-studio-039470649719.herokuapp.com` served 200s throughout the outage, and
`APP_HOST_ALIASES` + `DYNO_HOST` allowlist it deliberately. Anyone who learns that name
routes around the edge entirely. `config/environments/production.rb` has warned about
exactly this since the 2026-05-24 prelaunch audit.

**2. The app must still see the real visitor.** Behind a proxy, `REMOTE_ADDR` becomes
the edge's address. Every per-IP defence then measures Cloudflare: the login
brute-force throttles keep reporting healthy while protecting nothing. Cloudflare sends
the truth in `CF-Connecting-IP`, but that header is forgeable by anyone reaching the
origin directly, so it may only be believed on a request proven to come from our edge.

`lib/middleware/edge_guard.rb` handles both, hung off one shared secret — a request
bearing it is admitted *and* believed about who sent it. It is **dark until
`EDGE_SECRET` is set**, which is what makes the ordering below safe.

---

## Order of operations

Ship the code first, cut DNS second, arm the guard last. Any other order either locks
us out of our own origin or leaves a window where the edge is bypassable.

### Step 1 — Ship EdgeGuard unarmed (done for the hub)

`EDGE_SECRET` unset means complete pass-through, so the deploy itself cannot break
anything. Verify after deploy:

```bash
heroku config:get EDGE_SECRET --app mcritchie-studio    # expect empty
curl -s -o /dev/null -w '%{http_code}\n' https://mcritchie.studio/up   # expect 200
```

### Step 2 — Add the zone in Cloudflare

Create the zone for the domain and let Cloudflare import the existing records. **Before
changing nameservers, check the imported set against the live one** — a missed MX or
TXT record is how email and domain verification break.

```bash
dig +short mcritchie.studio        ANY
dig +short mcritchie.studio        MX
dig +short mcritchie.studio        TXT
dig +short www.mcritchie.studio    CNAME
dig +short app.mcritchie.studio    CNAME
```

Cloudflare flattens the apex automatically, so the existing Heroku `ALIAS/ANAME` becomes
a proxied apex record — no change of approach needed.

Set the records that serve the app to **Proxied** (orange cloud). Leave anything used
for domain-ownership or mail delivery **DNS-only** (grey).

### Step 3 — Solve certificates BEFORE cutting over

This is the step that bites weeks later, silently.

All four apps use **Heroku ACM** (Let's Encrypt). ACM revalidates by resolving the
domain to Heroku. Once Cloudflare proxies, it resolves to Cloudflare, **ACM renewal
fails, and the certificate expires ~30-60 days later** — an outage with nothing in the
logs tying it back to the CDN change.

Do this instead:

1. In Cloudflare, create an **Origin Certificate** for the zone (apex + wildcard).
2. Install it on the Heroku app:
   ```bash
   heroku certs:add origin.pem origin.key --type sni --app mcritchie-studio
   ```
3. Set the zone's SSL/TLS mode to **Full (strict)**.
4. Only then disable ACM, so the app is never without a certificate:
   ```bash
   heroku certs:auto:disable --app mcritchie-studio
   ```

An Origin Certificate is trusted by Cloudflare, not by browsers — which is correct here,
because browsers terminate at Cloudflare. It also removes the renewal treadmill.

### Step 4 — Cut the nameservers

Change them at the registrar, then wait for Cloudflare to report the zone active.
Registrars differ per domain — see the inventory below.

Verify the edge is actually in the path:

```bash
dig +short mcritchie.studio                       # expect Cloudflare addresses
curl -sI https://mcritchie.studio/ | grep -i '^server\|^cf-ray'   # expect cloudflare + a cf-ray
```

### Step 5 — Arm the guard

Only once traffic demonstrably flows through Cloudflare.

1. Add a **Transform Rule → Modify Request Header** on the zone: set `X-Edge-Secret` to
   a long random value on every request to the origin.
2. Set the same value on the app and let it restart:
   ```bash
   heroku config:set EDGE_SECRET="<the same value>" --app mcritchie-studio
   ```
3. Prove both halves:
   ```bash
   # through the edge — expect 200
   curl -s -o /dev/null -w '%{http_code}\n' https://mcritchie.studio/tasks
   # direct to origin — expect 403
   curl -s -o /dev/null -w '%{http_code}\n' https://mcritchie-studio-039470649719.herokuapp.com/tasks
   # health check still direct — expect 200
   curl -s -o /dev/null -w '%{http_code}\n' https://mcritchie-studio-039470649719.herokuapp.com/up
   ```

Rollback at any point is `heroku config:unset EDGE_SECRET`, which returns the guard to
pass-through within one restart.

### Step 6 — Let the agents through

**Do this or the agent fleet breaks.** Bot Fight Mode and managed challenges will
challenge non-browser clients, and every `bin/task`, `bin/agent-activity`, and
`bin/release` call is exactly that. Add a **WAF skip rule** for the API and the webhook
before enabling bot protection:

- Skip for `http.request.uri.path starts_with "/api/v1/"`
- Skip for the GitHub webhook path

Then confirm the fleet still writes:

```bash
bin/task list --stage submitted
bin/agent-activity start --category Verify --reason "confirm board writes through edge"
bin/agent-activity end --outcome "board reachable"
```

Also re-point anything configured against the raw dyno hostname — **GitHub webhooks
especially** — at the public domain, or the guard will refuse them.

---

## The lever

Once a zone is proxied, the incident response is a toggle rather than a deploy:

| Lever | Where | Use it when |
|---|---|---|
| **Under Attack Mode** | Zone → Security | A flood is happening now. Challenges every visitor. |
| **WAF custom rule** | Security → WAF | You can describe the bad request (e.g. more than N `sessions=` values). |
| **Rate limiting rule** | Security → WAF | One endpoint is being hammered from many addresses. |
| **Block by ASN/country** | Security → WAF | The flood has a clear origin network. |
| **Bot Fight Mode** | Security → Bots | Baseline, always on, with the `/api/v1/*` skip above. |

Caching is the quiet win: static assets stop touching the dyno at all, which is real
headroom on a 3-thread app.

---

## Domain inventory

Registrar access is Mr. McRitchie's; the nameserver change cannot be done by an agent.

| Domain | DNS host today | Heroku app | Records | Status |
|---|---|---|---|---|
| `mcritchie.studio` | Google Cloud DNS | `mcritchie-studio` | apex + `www` + `app` | **pilot** |
| `turfmonster.media` | name.com | `turf-monster-mainnet` | apex + `app` | after pilot |
| `mcritchie.industries` | Squarespace DNS | `mcritchie-industries` | `www` only | after pilot |
| `karenmcritchie.com` | name.com | `obscure-plains-6405` | apex + `www` | after pilot |

The free plan requires **full nameserver delegation**; Cloudflare's CNAME-only setup is
a Business-plan feature (~$200/mo per zone) and is not worth it here.

**QA apps stay off the edge.** `mcritchie-studio-qa`, `turf-monster-qa`,
`mcritchie-industries-qa`, and `rolio-qa` run on `herokuapp.com` hostnames we do not
control, so they cannot be fronted. That is acceptable — and it is another reason the
origin lockdown in step 5 matters, since a QA hostname is one more way to reach a dyno.

---

## Per-app repeat checklist

For each remaining domain, the same six steps, plus two app-specific pieces:

- [ ] EdgeGuard mounted in that app (it lives in the hub today; satellites need it too,
      or the equivalent from `studio-engine` if it is promoted there)
- [ ] `EDGE_SECRET` generated **per app** — never shared across zones, or one leaked
      secret unlocks every origin
- [ ] Zone added, records verified against live DNS
- [ ] Origin Certificate installed, Full (strict), ACM disabled **in that order**
- [ ] Nameservers cut, `cf-ray` present
- [ ] Guard armed, direct-origin 403 proven
- [ ] WAF skip rules for that app's API/webhook paths
- [ ] Webhooks re-pointed off the dyno hostname

---

## Background — not needed to execute

Full incident detail, the hardening items that came out of it
(`cap-activity-drilldown-actions`, `throttle-expensive-public-endpoints`,
`raise-hub-web-concurrency`), and the reasoning behind the single-switch design live on
the task board and in `lib/middleware/edge_guard.rb`'s header comment.
