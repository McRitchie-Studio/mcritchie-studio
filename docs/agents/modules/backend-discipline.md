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
version `Gemfile.lock` pins and a dyno loads — against a freshly generated
RSA-2048 key broken the documented way:

```text
key body                             1,624 chars
ParserError message                  1,689 chars
verbatim key prefix inside it        1,624 chars   ← the entire body
```

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

digit runs present in real key bodies   1 to 5 chars (longest seen: 92476)
```

So the bare slice is a *small* leak — but that is not the argument for anchoring,
and an earlier revision of this file overstated it into a nine-digit one that no
real key produces. The argument is that **the bare form is not the thing you
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
