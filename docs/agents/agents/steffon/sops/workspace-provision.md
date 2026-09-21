# Workspace Provision

## Status: Active

This is Steffon's `workspace-provision` SOP. It gives the agents **read access
to one client's Google Workspace** — their Drive and their mail — so the
knowledge layer can index what that client already has, without anyone
forwarding files by hand.

Run it when a new client arrives, or when an existing client opens a second
domain. The conventions it applies live in
[`../../../modules/credential-inventory.md`](../../../modules/credential-inventory.md)
and [`../../../modules/knowledge-capture.md`](../../../modules/knowledge-capture.md);
this file is the act.

**The shape of the work, in one sentence:** one service account serves every
workspace we are ever given, and the only per-client step is that client's own
super-admin granting it delegation in their own admin console — which Google
offers no API for, and which is therefore the one manual seam this SOP cannot
remove.

## What this act is NOT

- **It never sends mail.** The grant includes `gmail.compose`, which *can*
  send. "Never sends" is held in code (`test/lib/no_gmail_send_test.rb`), not
  by the grant. Do not widen to `gmail.send`, `gmail.modify`, or
  `mail.google.com`.
- **It never edits a file we do not own.** `drive.readonly` plus `drive.file`;
  never plain `drive`.
- **It never creates the 1Password item.** The agent service account is
  READ-ONLY, measured. Mr. McRitchie files credentials; see
  [`./credential-filing.md`](./credential-filing.md).
- **It never impersonates a subject that is not on the allow-list.** Delegation
  cannot be narrowed at the grant — it authorizes *any* user in the domain and
  the caller picks — so the boundary is the `workspace_accounts` table, not the
  grant.
- **It does not put client specifics in this repo.** `mcritchie-studio` is
  PUBLIC. Counterparty names, domains, and folder ids are database rows.

## Entry

You need: the client's domain, a `team@<domain>` user existing in their
Workspace, and a named contact who is a **super-admin** of that domain. If any
of the three is missing, stop at the decline path.

**And a filed Google credential — which `register` does NOT check.** `check`
guards on it (`lib/tasks/workspace.rake`, the `configured?` gate, warn + exit 1);
`register` has no such guard, so it runs happily without one and prints
`Client ID: (no credential filed)`. Step 2 then tells you to hand that line to
the client's super-admin. It fails loudly — the string says what is wrong — but
only if you read it, and you are about to paste it into an email. Confirm the
credential resolves before you start:

```bash
bin/rails runner 'puts Workspace::Credentials.configured? ? "credential: #{Workspace::Credentials.source}" : "NO CREDENTIAL FILED — stop here"'
```

```bash
cd /Users/alex/projects/mcritchie-studio
bin/rails workspace:accounts          # who is reachable today
```

## 1. Register the workspace

```bash
bin/rails 'workspace:register[<domain>,<Display Name>,<entity-slug>]'
```

The row lands as **`pending`** — registered is not authorized. The subject
defaults to `team@<domain>` and is validated to belong to that row's own
domain, so a row for one client can never be pointed at another's mailbox.

`register` prints the two values the client's admin needs: the **Client ID** and
the **exact scope list**. Read them from that output rather than from any doc —
but for different reasons, and the difference matters when a key rotates. The
Client ID is read from the filed credential, so it does stay correct across a
rotation. The scope list is NOT: it is printed from
`Workspace::Credentials::SCOPES`, a frozen constant in the code, so it tracks
what the CODE asks for. That is the right source — it is what a grant has to
match — but a rotation cannot change it, and a code change can. When SCOPES
moves, every existing grant is stale and `check` says so.

## 2. Hand the grant to the client's super-admin

Send the printed Client ID and scopes with these instructions. They must be run
by a super-admin **of the client's own domain**:

> admin.google.com → Security → Access and data control → API controls →
> Manage domain wide delegation → **Add new** → paste the Client ID → paste the
> scopes as one comma-separated line → Authorize.

**⚠ THE FAILURE THAT COSTS AN EVENING.** A grant added in the *wrong* Workspace
looks identical to a grant that has not propagated yet: both answer
`unauthorized_client`, forever versus for a few minutes. Nothing in the error
distinguishes them. That is why step 3 names the domain it proved, and why you
confirm with the admin **which domain they were signed into** before you wait on
propagation. Measured 2026-09-19.

## 3. Prove the delegation

```bash
bin/rails 'workspace:check[<domain>]'
```

Green flips the row to **`active`** and prints the mailbox and a first page of
Drive. A refusal at the PROBE is recorded on the row and leaves it `pending`.

Read the verdict this way:

| What you see | What it means | Next |
|---|---|---|
| `ACTIVE as team@<domain>` | Proven. The grant is in the right place. | Step 4 |
| `NOT AUTHORIZED as team@<domain> (unauthorized_client)`, minutes old | Normal propagation | Wait, re-run |
| `NOT AUTHORIZED as team@<domain> (unauthorized_client)`, hours old | Wrong Workspace, or wrong Client ID | Back to step 2 — confirm the domain they signed into |
| `NOT AUTHORIZED … (<any other slug>)` | Not a propagation delay — the slug names the refusal | Read the slug before re-running |
| `SKIPPED — revoked` | Deliberately switched off | Switching one back on, below |
| `CHECK FAILED` **after** the probe passed | **The row is already `active`.** Re-run before you walk away | Below |

The rows above key on the line the task actually prints —
`<domain>: NOT AUTHORIZED as <subject> (<slug>)` — not on the bare slug. The
slug sits in parentheses at the end, so a reader scanning for `unauthorized_client`
finds nothing at the start of any line and can read that as "no refusal for this
domain". The label is what you see first; the slug is what tells the two
`NOT AUTHORIZED` rows apart.

**`CHECK FAILED` AFTER THE PROBE PASSED does not mean `pending`** — and the
qualifier is the whole sentence. The `rescue` spans the entire block, so a
failure BEFORE `mark_verified!` also prints `CHECK FAILED`, with the row
correctly left `pending`. It is only the post-flip failure that disagrees with
the screen. `lib/tasks/workspace.rake` calls
`account.mark_verified!` BEFORE the Drive and Gmail smoke reads — deliberately,
because `authorizer_for` refuses a subject that is not ACTIVE, so the reads
cannot come first. `mark_verified!` sets `status: "active"` and clears
`last_check_error`, and the `rescue StandardError` below only warns. So a smoke
read that fails leaves the row **active with no recorded error** while your
terminal says `CHECK FAILED` — the one state where the screen and the row
disagree. Re-run `workspace:check[<domain>]`: a real grant passes the reads the
second time, and a row that keeps failing them is `workspace:revoke`'s job, not
something to leave sitting.

A `pending` row is refused everywhere, so a workspace that never got past the
probe is safe to leave sitting. One that reached `CHECK FAILED` is not, per the
paragraph above. Do not hand-edit `status` to `active` to move things along; the
flip exists to record that a real token was issued.

## 4. Attach the folders

```bash
bin/rails 'workspace:add_source[<domain>,<Source Name>,<drive folder id>,<entity-slug>]'
```

The folder id is the last path segment of the Drive URL. Attach the narrowest
folder that covers the need — the grant reaches the whole domain, so the source
row is what actually scopes what we read.

## 5. First walk

```bash
bin/rails 'workspace:walk[<source id>]'
```

This records **metadata only** — title, type, owner, link, version, modified
date. It never downloads a document: the client's Drive stays the source of
truth and we keep an index, not a copy. The walker has no download path at all,
and a test asserts it.

A document is marked `missing` only after a walk that COMPLETED. A failed walk
records the error and infers nothing, so a network blip mid-tree never
tombstones the half it did not reach.

## 6. Record

- Note the new workspace and its sources in the client's own private repo — not
  here.
- If a credential changed hands, file it per
  [`./credential-filing.md`](./credential-filing.md).

## Switching a workspace off — and back on

```bash
bin/rails 'workspace:revoke[<domain>,<why>]'      # impersonation refused from the next call
bin/rails 'workspace:reinstate[<domain>]'         # returns to PENDING, never to active
```

`revoked` is terminal to every automatic path: no sweep, and no successful
delegation check, reactivates it. `reinstate` returns the row only to `pending`,
so coming back always costs two deliberate acts — a human naming the domain, and
then a real token through `workspace:check`.

**Revoking here does not withdraw the Google-side grant.** It closes our door,
not theirs. Ending the grant itself is the client's super-admin removing our
Client ID from their delegation page — ask for it explicitly when a relationship
ends, and record the date you asked.

## Handling the credential — the rule that leaked a key

When a service-account key is set anywhere, **suppress both streams and verify
by identifier, never by value**:

```bash
# ASSIGN THE PATH FIRST, and refuse to continue without it. `>/dev/null 2>&1`
# suppresses the key, but it also suppresses `cat`'s complaint — so an unset or
# mistyped path sets the production credential to the EMPTY STRING, silently,
# and Heroku stores it. Guard on the file, not on the variable being non-blank:
# a path that is set but wrong fails the same way.
KEYFILE=<absolute path to the downloaded key .json>
[ -s "$KEYFILE" ] || { echo "KEYFILE is unset or empty — refusing to set the credential"; exit 1; }

# The value is multi-line. A filter that matches only the first line lets the
# REST of a private key through, which is exactly how one reached a transcript
# on 2026-09-19.
heroku config:set GOOGLE_SERVICE_ACCOUNT_JSON="$(cat "$KEYFILE")" \
  --app <app> >/dev/null 2>&1

# VERIFY ON THE DYNO, and verify the ENV VAR — not the resolved credential.
# A bare `bin/rails` runs on your desk, not on the app you just wrote to. And
# `Workspace::Credentials.credential` resolves `ENV[...].presence || 1Password`
# (app/services/workspace/credentials.rb), so a wiped `""` falls through to the
# vault and prints a perfectly healthy fingerprint over the value you just
# destroyed. Read the var itself, by length and fingerprint, never by value:
heroku run --app <app> --no-tty --exit-code -- \
  bin/rails runner 'v = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"].to_s;
                    abort("EMPTY — the config:set wrote nothing") if v.strip.empty?;
                    begin; k = JSON.parse(v);
                    rescue JSON::ParserError => e;
                      abort("UNPARSEABLE #{e.message[/at line \d+ column \d+/] || "position unreported"}"); end;
                    puts "bytes=#{v.bytesize} private_key_id=#{k["private_key_id"]}"'
```

Two things make this a check rather than a printout. `abort` exits non-zero
under `--exit-code`, so a wiped credential stops the SOP instead of scrolling
past as a blank line. And the parse is RESCUED to a POSITION: a bare
`JSON.parse` on a truncated key raises `JSON::ParserError`, whose message
echoes its input to end of stream — printing the key bytes into the transcript,
which is the exact leak the rest of this section exists to prevent.
`Workspace::Credentials` already handles this internally; a hand-written runner
does not inherit that, so it has to say so itself.

**Slice the message with the ANCHORED pattern — `at line \d+ column \d+` —
never a bare `\d+`.** The bare form takes the message's FIRST digit run, and on
this credential's most likely failure that run is key material, not a position.
Measured under `bundle exec` on **json 2.20.0** — the version `Gemfile.lock`
pins and the `heroku run bin/rails runner` above actually loads, not the
laptop's default gem — against a key pasted with a literal line break inside
`private_key`:

```text
message         invalid ASCII control character in string: \nMIIEvQIBADANBgkqhkiG987654…
e.message[/\d+/]                      => "987654321"   ← key bytes
e.message[/at line \d+ column \d+/]   => "at line 2 column 0"
```

The anchored pattern needs the literal words `at line` and `column`, which key
material does not contain. It is the same slice `Gmail::Credentials`,
`Workspace::Credentials` and Industries' `Google::Credentials` already use — and
like them it falls back to a fixed string rather than to the raw message, so a
future change to the exception's wording degrades to `position unreported`
instead of reopening the leak.

Never `echo`, `cat`, or interpolate the key into a message, a commit, or an
error. `Workspace::Credentials` already refuses to put key bytes in an exception
— a `JSON::ParserError` echoes its input to end of stream, so the parse failure
reports **position only**.

## Decline path

Stop, and say so plainly, when:

- The contact is not a super-admin of that domain. Nobody else can grant this.
- There is no `team@` user. Ask them to create one; do not substitute a person's
  mailbox, which would put one employee's mail behind an agent's read.
- The client wants us to send or edit rather than read. That is a different
  grant and a different decision, and it is Mr. McRitchie's to make.

## Background — not needed to execute

`gcloud` (585.0.0, installed 2026-09-20) covers the Google-side half that *is*
scriptable: creating and rotating the service-account key, and listing which
keys exist. The delegation grant itself stays manual because Google publishes no
API for it — verified across every Google source, which documents it as a
console action only. So the ceiling on automating this act is one click, taken
by someone who does not work for us.

Architecture of the allow-list, and why a compile-time constant became a table:
`app/services/workspace/credentials.rb` carries it at the `SCOPES`/allow-list
comments, and `app/models/workspace_account.rb` carries the allow-list rationale
and the three-state lifecycle. Both are on disk. (The `workspace-accounts-registry`
task record held the original write-up and is ARCHIVED, so it is history rather
than a place to read.)
