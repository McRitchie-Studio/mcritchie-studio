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
message holding the whole PEM body. Measured on json 2.21.1: a 1,889-character
message carrying all 25 lines of a 1,588-character private key.

**The rule: rescue it, and report POSITION ONLY.**

```ruby
rescue JSON::ParserError => e
  raise Malformed, "#{ITEM} is not valid JSON " \
                   "(#{e.message[/at line \d+ column \d+/] || 'position unreported'})"
end
```

Two details in that one line are load-bearing, and both were learned by leaking.

**ANCHOR the slice.** `e.message[/\d+/]` looks like "the position" and is not:
it takes the message's FIRST digit run, and on the most likely failure that run
is key material. Measured under `bundle exec` on **json 2.20.0 — the version
`Gemfile.lock` pins and a dyno actually loads** — against a key pasted with a
literal line break inside `private_key`, the cause these rescues exist for:

```text
message                              invalid ASCII control character in string:
                                     \nMIIEvQIBADANBgkqhkiG987654…
e.message[/\d+/]                  => "987654321"            ← key bytes
e.message[/at line \d+ column \d+/] => "at line 2 column 0"
```

The anchored pattern needs the literal words `at line` and `column`, which key
material does not contain (base64 has no space character, so a key body cannot
form that phrase). A bare `\d+` "reports the position" on a well-formed test
fixture and leaks on the real accident.

**Measure under the runtime the command LOADS, not the one your shell reaches
for.** The first run of this was taken with bare `ruby`, which used the laptop's
default gem (3.0.2) while the documented command was `heroku run bin/rails
runner` — the bundled 2.20.0. The leak reproduces on both, so the conclusion
survived; it survived for a reason that run had not established. `bundle exec`,
or the dyno.

**FALL BACK to a fixed string**, never to the raw message. A message that does
not match the pattern must degrade to `position unreported`, so a change to the
exception's wording degrades instead of silently reopening the leak.

**Why it is worse than a noisy log.** `ErrorLog.capture!` (studio-engine
`app/models/error_log.rb`) stores `message: exception.message` verbatim into
Postgres and forwards it to Sentry, and the same method builds its `inspect`
column as `exception.message.to_s[0, 1000]`. The engine already refuses to store
`exception.inspect` **because ivar dumps carry secrets** — and leaves `message`
wholly undefended. That asymmetry is the sharpest way to see the gap: 1,000
characters of a 1,592-character PEM is still the usable part of a private key,
and `error_logs/show` renders that column in the admin UI. The leak is
persistent, published, and visible.

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
