# Backend Discipline

This module captures cross-repo backend rules that showed up repeatedly in prior agent memory. Keep app-specific implementation details in the owning repo.

## Error Visibility

If a Rails app has `ErrorLog`, expected recoverable backend failures should be logged there with enough context to debug the user, provider, record, and external request.

Prefer the local helper pattern when present:

```ruby
rescue_and_log(target:, parent:)
```

Do not swallow provider failures silently. If a user-facing flow fails, make the failure visible to support and future agents.

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

**Where the rule already lives in code** — three sites, which is why it belongs
in prose:

| Repo | Service |
|------|---------|
| `mcritchie-studio` | `app/services/gmail/credentials.rb` |
| `mcritchie-studio` | `app/services/workspace/credentials.rb` |
| `mcritchie-industries` | `app/services/google/credentials.rb` |

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
under `docs/`, so illustrating this rule with a real one reddens CI. Measured on
the first push of this paragraph — and a docs-ONLY diff maps no test at all in
`bin/fast-check`, so CI was the only thing that said so. Pairing prose with its
guard test under `test/docs/` fixes that half too: a changed `*_test.rb` maps to
itself, so the cert covers the doc rule instead of deferring it to CI.

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

## Data Modeling

- Prefer slug or stable-key foreign keys when records are copied across environments or seeded repeatedly.
- Store money as integer cents.
- Put state transitions behind named methods instead of scattered status assignment.
- Keep jobs and seeds idempotent.

## Verification

Backend changes should include the narrowest meaningful automated test. For provider workflows, also verify the local callback path or document the exact external dependency blocking verification.
