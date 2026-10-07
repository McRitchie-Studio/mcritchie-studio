# Backend Discipline

This module captures cross-repo backend rules that showed up repeatedly in prior agent memory. Keep app-specific implementation details in the owning repo.

## Error Visibility

If a Rails app has `ErrorLog`, expected recoverable backend failures should be logged there with enough context to debug the user, provider, record, and external request.

Prefer the local helper pattern when present:

```ruby
rescue_and_log(target:, parent:)
```

Do not swallow provider failures silently. If a user-facing flow fails, make the failure visible to support and future agents.

`rescue_and_log` is a **controller** concern (studio-engine
`app/controllers/concerns/studio/error_handling.rb`) and it **re-raises**. Inside a
bulk loop it ends the run at the first bad row. Outside a controller use
`ErrorLog.capture!`; in a tight loop, where that pages Sentry per row, write the
`ErrorLog` directly and swallow a failure of the log write itself.

A guard that strips secrets from an error must keep a bounded fault token, shaped
(leading letter, word characters, a length cap) rather than matched by a character
class: a PEM header is only letters, hyphens and spaces. Test both directions: the
secret is gone, and the vendor's fault token survives.

### Never interpolate an exception message that quotes its input

Some exceptions carry the thing that failed to parse. `JSON::ParserError` is the
one that keeps biting: its message echoes the input **from the failure point to
the end of the stream**. So a service-account key pasted with literal newlines
inside `private_key` does not produce "bad JSON at line 4" — it produces a
message holding the whole PEM body.

**Measured here, on this repo's own stack** — `bundle exec`, json 2.20.0, the
version `Gemfile.lock` pins and a dyno loads — against ten freshly generated
RSA-2048 keys, each broken the documented way (the PEM's own newlines left
literal):

```text
key body (base64, unwrapped)          1,624 chars
ParserError message                   1,782-1,786 chars
how much of the body it carries       ALL of it
longest CONTIGUOUS run of body chars  64  (one PEM line)
```

The body arrives WRAPPED, because a real PEM is: 25 lines of 64 characters and
one of 24, whose breaks the message echoes too. No single 1,624-character run
appears, and none needs to — every character of the key is in there, and
stripping 25 newlines is not a defence.

**The rule: rescue it, and report POSITION ONLY.**

```ruby
rescue JSON::ParserError => e
  raise Malformed, "#{ITEM} is not valid JSON " \
                   "(#{e.message[/at line \d+ column \d+/] || 'position unreported'})"
end
```

Two details in that one line are load-bearing.

**ANCHOR the slice — because `e.message[/\d+/]` is not a position at all.** It
reads like one and is not: it returns whatever digit run happens to sit at the
failure point. Measured on the same stack, 40 freshly generated RSA-2048 bodies:

```text
break right after the BEGIN armor
  e.message[/\d+/]                  => "9"                  ← key material, 1 char
  e.message[/at line \d+ column \d+/] => "at line 2 column 0"

digit runs present in real key bodies   mostly 1-2 chars; the tail is a SAMPLE
```

**"Longest seen" is a sample, not a limit**, and two censuses disagree: 40 bodies
measured here gave a maximum run of 5 (`80456`), and 40 measured by a reviewer
gave 6 (`277951`). Neither is wrong. A base64 body draws from a 64-character
alphabet of which 10 are digits, so a run of length *k* appears with probability
≈ (10/64)^k — geometric, with no upper bound. Quote the distribution's shape, not
its maximum; the maximum is whatever your sample happened to contain.

So the bare slice is a *small* leak — but that is not the argument for anchoring,
and an earlier revision of this file overstated it into a nine-digit one that no
real key produces. **That figure was not confined to this file.** The same
fabricated `"987654321"` was published in
[`agents/steffon/sops/workspace-provision.md`](../agents/steffon/sops/workspace-provision.md),
labelled "Measured", and is retracted there too — with the reason the real run is
one character: PKCS#8 wraps every RSA key in an AlgorithmIdentifier carrying the
rsaEncryption OID, which base64s to the fixed run `BgkqhkiG9w0BAQEF`, so a body's
FIRST digit is always the `9` of `9w0`, at index 20. Measured 10/10 there. A
retraction scoped to one file leaves the other asserting the opposite, which is
worse than either alone. The argument is that **the bare form is not the thing you
asked for.** It yields a position only by coincidence, and it yields key bytes
the rest of the time; the anchored form is a position or it is nothing. It needs
the literal words `at line` and `column`, which a base64 body cannot form
(base64 has no space character).

**FALL BACK to a fixed string**, never to the raw message. A message that does
not match the pattern must degrade to `position unreported`, so a change to the
exception's wording degrades instead of silently reopening the leak.

**Measure under the runtime the command LOADS, not the one your shell reaches
for**, and measure the REAL input. Both halves of that were learned here: an
early run used bare `ruby` (the laptop's default gem) while the documented
command was `heroku run bin/rails runner` (the bundled 2.20.0), and a later one
used a hand-built fixture whose digits were typed rather than generated — which
is how the nine-digit figure got in. A synthetic input measures your fixture.

**Why it is worse than a noisy log — it reaches a screen, further than you would
guess.** `ErrorLog.capture!` (studio-engine `app/models/error_log.rb`) stores
`message: exception.message` verbatim into an uncapped `text` column and
forwards it to Sentry. The engine already refuses to store `exception.inspect`
**because ivar dumps carry secrets**, and leaves `message` wholly undefended.
That asymmetry is the sharpest way to see the gap. Then it renders, three ways:

| Where | What it shows |
|---|---|
| `error_logs/show.html.erb` | the message **unbounded**, in an `h2` |
| `error_logs/index.html.erb` | the message under Tailwind `truncate` — CSS ellipsis only, so the **full bytes sit in the DOM** for up to 100 rows, without opening a single log |
| `error_logs_controller.rb` | `message ILIKE :q` — the leaked bytes are **queryable** |

Persistent, published, visible, and searchable.

**It is not only parser errors.** The shape is *any* raise or log that
interpolates a value the caller did not choose. A near-miss found in review:
`mcritchie-industries` `app/services/indexes/fred_client.rb` interpolates the
request URL into three raises that `indexes/sync.rb` hands to
`ErrorLog.capture!` and prints in a `Result#error`. It is safe today only
because FRED's `fredgraph.csv` endpoint is keyless. Repoint it at the keyed
`api.stlouisfed.org`, whose key rides an `api_key=` query param, and those three
lines become a live credential leak into Postgres on the first transport error.

**A SECOND LIVE INSTANCE OF THAT SHAPE, IN THIS REPO, WITH THE SAME SOLE
DEFENCE.** `app/services/espn/scrape_depth_charts.rb` and
`app/services/espn/player_profile.rb` both interpolate the request URL into the
`SourceUnavailable` they raise from `fetch_json`, and `espn-services-error-logs`
(2026-09-27) is what made those exceptions reach `ErrorLog.capture!` — before it,
nothing in `app/services/espn/` filed a row at all, so the URL never became durable.
It is safe for FRED's exact reason and no other: every ESPN endpoint the app reads is
public and takes no key, which `app/services/espn/api.rb` measures and records for all
three hosts. Because "safe today, by a property of the vendor" is not a guarantee, a
test in `test/services/espn/scrape_depth_charts_test.rb` refuses `ENV[`,
`Rails.application.credentials`, `api_key`, `access_token` and a bearer token back into
that directory — flattened after whole-line comments are dropped, so a read split over
two lines cannot slip past a line regex. The lesson generalises: the moment a rescue
starts FILING an exception whose message carries a URL, the endpoint's keylessness
stops being a detail and becomes a load-bearing invariant that needs a guard.

**Where the rule already lives in code** — three sites, which is why it belongs
in prose:

| Repo | Service | Leak test |
|------|---------|-----------|
| `mcritchie-studio` | `app/services/gmail/credentials.rb#parse` | `test/services/gmail/credentials_test.rb` |
| `mcritchie-studio` | `app/services/workspace/credentials.rb#parse` | `test/services/workspace/credentials_test.rb` |
| `mcritchie-industries` | `app/services/google/credentials.rb` | |

Each in-repo site carries a behavioural leak test that feeds a secret-bearing
broken payload and refutes the secret in the raised message, so the rule is
pinned where it runs, not in a copy of this table.

A hand-written `bin/rails runner` does **not** inherit any of them. When you
write one that parses a credential — in a rake task, in an SOP, in a one-off —
it needs its own rescue.

**Writing the test is its own trap: a leak test must not print the leak.**
minitest's `message()` prepends your custom message and still **appends** the
default one, so `assert_match`, `assert_includes` and `refute_includes` dump
their haystack even when you pass a message of your own. Only plain `assert` and
`refute` suppress it. Assert on a body prefix plus a length bound, and keep the
failure message to lengths.

**Plain is only half the rule: the refute must also run FIRST.** minitest stops
a test at its first failed assertion, so ORDER decides which assertion gets to
print. An `assert_equal` on the redacted value is a fine SHAPE check and belongs
in the test — but its haystack is the same string the refute is guarding, so if
it runs ahead of the refute a broken guard fails THERE, dumps the bytes, and the
refute never runs at all. Measured on
`test/services/workspace/error_slug_test.rb` under a broken-guard mutant: 9
failures, **5 of them printing guarded content**, one carrying the whole PEM
private-key header and the key-body prefix behind it. Moving every plain
`refute` ahead of the first `assert_equal` left the same 9 failures printing
nothing. So: **plain `refute` first, shape checks behind it.** The exemption is
the **haystack, not the method**: any assertion whose haystack is an INTEGER is
exempt by construction, because an integer cannot hold the secret. That covers
an `assert_operator` on a length and an `assert_equal` on one alike — a length
assertion running first is fine.

That header is described above rather than quoted, deliberately:
`test/lib/app_id_recorded_claims_test.rb` refuses private-key material anywhere
under `docs/`, so illustrating this rule with a real one reddens CI.

Ordering is invisible on review and silent when it regresses, so that file
asserts it rather than describing it: a guard parses its own source and flags
any test naming a `GUARDED_FIXTURES` string that reaches an `assert_equal`
before a plain `refute`. **Before adding a string to that list, ask what the
suite already asserts about it.** `team@x.test` is deliberately absent, and the
reason is documentary rather than mechanical: registering it would change no
verdict at all, because the only test naming it already names `team@secret.test`
and is already selected. It is absent because the list registers strings whose
appearance is a LEAK, and that one appears BY DESIGN — it rides inside an
AUTHORED error message that `Workspace::ErrorSlug` passes through and the test
beside it asserts must SURVIVE. Listing it would state the opposite of the
assertion directly above it. A fixture earns a place there only when the
property under test is that it must NOT survive.

## Irreversible Effects

Validate everything before irreversible side effects:

- Payments and refunds.
- Emails or broadcasts.
- Solana transactions.
- Provider account mutations.
- Deployments or production data repair.

Persist external IDs, transaction signatures, payment intent IDs, and webhook event IDs as soon as they are known. Add a reconciler when an external system can succeed while the local process fails.

- **When reviewed code exists for a fix, run that code, never a hand-retyped
  equivalent**, against production. An ad-hoc copy has had no review and no tests.
  Before any bulk write, check one row's full result, not just "it succeeded".
- **Before dropping a table, paste every external identifier that exists nowhere
  else** (an on-chain address, an S3 key) into the migration comment. The external
  object outlives the table; the pointer to it does not.
- **A flag stamped in the same transaction as a send is not proof of the send.**
  Verify an outbox per row (`sent`, `sent_at`, `error`): a send that neither raises
  nor sends strands with nothing to retry it.
- **A kill switch must gate every door.** Grep every opener of the feature it hides;
  an ungated one becomes a dead button when the flag is off.
- **A registered cron is not a running one.** Check its last enqueue time.

## Lookups, Predicates And Writers

- **Filter inside the query in a fallback chain** (`pin || newest_open ||
  newest_any`). A post-filter drops the excluded winner to the next RUNG and skips
  the rest of its own candidates.
- **Enumerate every shape the producer returns** before writing an absence test:
  nil, empty, malformed, and tombstoned (a released row that keeps its record).
  If a sibling function already draws the line, match it.
- **Before changing what a predicate matches, grep every call site** and ask what
  each uses it for. One that gates both a label and a mutation (retire, delete,
  notify) should split, with the mutation pinned to the old population.
- **A second writer to a table copies the first writer's guards**, the create/adopt
  fallback above all. A fix for a weak shared primitive belongs in the primitive,
  not at one call site.
- **Key lookups on a field that does not churn** (email, an external id) and raise
  rather than fall back to an arbitrary row. For a rename, sweep the old value,
  every value derived from it (slugs, cache keys, URLs) and, in a swap, both sides.
- **Swapping unique values between two rows** defeats row-at-a-time writers: park
  (null) the rows first, then assign. Test it from the pre-swap state.
- **An importer that dedupes by name** must test two namesakes with different
  external ids and assert both survive.
- **A model callback is not a reconciler.** Production rows change only when saved,
  so a roster or default change that must reach production needs a data migration.
- **Rename a string consumers assert on in two steps:** let consumers accept both
  names, then tighten after the engine ships.
- **Before rerouting a URL**, list what the old page did on load (replayed a cart,
  read params, consumed a one-shot) and who returns through it: auth callbacks,
  purchase hand-offs.

## Rails Traps

- **A `before_save` that rewrites a field voids a write at HTTP 200.** Read back the
  field you wrote. If the rule is intended, raise at the write path's front door and
  keep the callback as the silent backstop.
- **Adding a keyword argument rebinds a brace-less trailing hash** (`m(a, "k" => v)`
  becomes keywords and raises). A trailing optional positional is immune.
- **A JSON endpoint never `redirect_to`s.** `fetch` follows the redirect, the error
  names another action, and `rescue_from StandardError` turns its `UnknownFormat`
  into a 500.
- **Reading a CSP directive by its method clears it**: `policy.frame_src` with no
  arguments deletes the directive. Read `policy.directives["frame-src"]`.
- **Rendering outside a request emits `example.org` URLs** unless
  `Rails.application.routes.default_url_options` is set. Set that, not
  `ActionController::Base.default_url_options`, which overrides the live host.
- **`defined?(Rails)` is true for a namespace-only module** some gems define; gate gem
  code on `Rails.respond_to?(:env)`.
- **`Time.zone.parse` returns midnight for garbage.** Parse a guard boundary with
  `Time.zone.iso8601`, which raises.
- **`Net::HTTP` sends `User-Agent: Ruby` when none is set.** Echo the request from a
  header-printing service before recording what a server saw.
- **Rack 3 trusts a client-sent `Forwarded:` header over `X-Forwarded-For`.** Behind
  the Heroku router set `Rack::Request.forwarded_priority = [:x_forwarded]` (the hub:
  `config/initializers/forwarded_headers.rb`), after confirming no proxy hop sits in front.
- **Tests run the async cable adapter.** After shipping a cable feature, probe
  production with `ActionCable.server.pubsub.broadcast`; a 101 on `/cable` proves only
  the route.

## Data Modeling

- Prefer slug or stable-key foreign keys when records are copied across environments or seeded repeatedly.
- Store money as integer cents.
- Put state transitions behind named methods instead of scattered status assignment.
- Keep jobs and seeds idempotent.

## Verification

Backend changes should include the narrowest meaningful automated test. For provider workflows, also verify the local callback path or document the exact external dependency blocking verification.
