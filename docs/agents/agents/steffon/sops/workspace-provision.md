# Workspace Provision
<!-- registry: client Google Workspace read access -->

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
  send, and a `:mail` token still asks for it because there is no draft-only
  Gmail scope. "Never sends" is held in code
  (`test/lib/no_gmail_send_test.rb`), not by the grant and not by the scope. Do
  not widen to `gmail.send`, `gmail.modify`, or `mail.google.com`.
- **It never edits a file we do not own.** `drive.readonly` plus `drive.file`;
  never plain `drive`. A mail token holds neither.
- **It never creates the 1Password item.** The agent service account is
  READ-ONLY, measured. Alex McRitchie files credentials; see
  [`./credential-filing.md`](./credential-filing.md).
- **It never impersonates a subject that is not on the allow-list.** Delegation
  cannot be narrowed at the grant — it authorizes *any* user in the domain and
  the caller picks — so the boundary is the `workspace_accounts` table (one
  `team@` subject per domain) plus `workspace_mailboxes` (each further address
  we may draft as), not the grant.
- **It does not put client specifics in this repo.** `mcritchie-studio` is
  PUBLIC. Counterparty names, domains, and folder ids are database rows.

## Entry

You need: the client's domain, a `team@<domain>` user existing in their
Workspace, and a named contact who is a **super-admin** of that domain. If any
of the three is missing, stop at the decline path.

```bash
cd /Users/alex/projects/mcritchie-studio
```

Every command in this SOP runs from there.

**And a filed Google credential — which `register` does NOT check.** `check`
guards on it (`lib/tasks/workspace.rake`, the `configured?` gate, warn + exit 1);
`register` has no such guard, so it runs happily without one and prints
`Client ID: (no credential filed)`. Step 2 then tells you to hand that line to
the client's super-admin. It fails loudly — the string says what is wrong — but
only if you read it, and you are about to paste it into an email. Confirm the
credential resolves before you start:

```bash
bin/rails runner 'puts Workspace::Credentials.configured? ? "credential: #{Workspace::Credentials.source}" : "NOT RESOLVING — see below before you conclude it is unfiled"'
```

**A "not resolving" answer has FOUR causes and only one of them is an unfiled
credential.** `configured?` is `ENV || 1Password`, and the `op` read returns
nil — indistinguishably — on a 15-second timeout (the process is KILLed), on a
non-zero `op` exit, on `op` being absent, and on the item genuinely not being
there (`app/services/workspace/credentials.rb`, `shell_read_from_op`). A COLD
BIOMETRIC SESSION is the common one: `op` blocks for unlock, the deadline
fires, and a perfectly well-filed credential reads as missing. So before you
conclude anything, unlock and read the item directly:

```bash
op read "$(bin/rails runner 'print Workspace::Credentials::ITEM')" >/dev/null && echo "op CAN read it — the nil was a cold session, not a missing item"
```

Never print the value. If that succeeds, re-run the check above; if it fails,
the item really is absent and step 1 is where you stop.

```bash
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
match — but a rotation cannot change it, and a code change can.

**When SCOPES moves, `check` is a WEAKER signal than it looks, in both
directions.** What it compares is `account.scopes` — the DB column stamped at
register — against the constant. That is row-versus-code drift; it never
inspects the Google-side grant, which is the thing this doc means by "grant".
So a row re-registered after the change reads clean while its actual grant is
still the old one. And the comparison sits AFTER the `next account` that a
failed probe takes, so:

| SCOPES change | Probe | What you see |
|---|---|---|
| NARROWED — the old grant still covers it | passes | the drift warning prints; nothing is actually broken |
| WIDENED — the old grant no longer covers it | FAILS | `NOT AUTHORIZED (unauthorized_client)`, and the drift warning is **unreachable** |

The widening case is the one that breaks, and it is the one `check` cannot
name: the verdict table below will send you to "wrong Workspace" for what is
really a scope change of our own. If you have just widened SCOPES, re-grant
every domain before you trust a single refusal.

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
| `NOT AUTHORIZED … (<anything else>)` | Not a propagation delay. The parenthesis carries an OAuth slug when Google refused, and otherwise a sentence the probe wrote itself — e.g. `subject was not applied to the credential`, or `credential is in self-signed-JWT mode, which ignores the subject entirely` | Read it before re-running; a sentence means OUR bug, not their grant |
| `SKIPPED — revoked` | Deliberately switched off | Switching one back on, below |
| `CHECK FAILED` **after** the probe passed | **The row is already `active`.** Re-run before you walk away | Below |

The rows above key on the line the task actually prints —
`<domain>: NOT AUTHORIZED as <subject> (<slug>)` — not on the bare slug. The
slug sits in parentheses at the end, so a reader scanning for `unauthorized_client`
finds nothing at the start of any line and can read that as "no refusal for this
domain". The label is what you see first.

**The slug does NOT tell the first two rows apart** — they carry the same
`unauthorized_client`, and the warning above says why: nothing in the error
distinguishes a grant in the wrong Workspace from one that has not propagated.
Only the AGE of the grant separates them, which is why you confirm the domain
with the admin rather than re-reading the line. The slug's job is the third
row: it is what tells `unauthorized_client` apart from every other refusal.

**`CHECK FAILED` AFTER THE PROBE PASSED does not mean `pending`** — and the
qualifier is the whole sentence. The `rescue` spans the entire block, so a
failure BEFORE `mark_verified!` also prints `CHECK FAILED`, with the row
correctly left AS IT WAS — `pending` on a first check, still `active` on a
re-check of a proven row. It is only the post-flip failure that disagrees with
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

## 7. Drafting mailboxes — optional

Drafting is how an agent writes an email *as* someone in the workspace — a
reply or a first message — and leaves it in that person's Gmail **Drafts** for
them to read and send. Nothing in this lane sends.

Each address we may draft as is its own allow-list row, proven with its own
token. The workspace's `team@` subject is not enough to draft as `alex@`.

**What a mailbox row opens: that address's MAIL, never its Drive.** Drafting as
`alex@`, and reading the one thread a draft answers, run with purpose `:mail`,
which admits a mailbox row. Drive walks run with purpose `:workspace`, which
admits only the workspace's own subject — so `Workspace::Credentials.authorizer_for`
refuses to build a Drive authorizer for `alex@` even though the Google grant
itself would allow it. The grant is domain-wide; the purpose is the boundary.

The purpose is now the boundary **at the token as well as at the caller**. A
`:mail` authorizer asks for `gmail.readonly` and `gmail.compose` only
(`Credentials::MAIL_SCOPES`); `:workspace` asks for all four. What that is
measured to mean, and what it is not:

- **Measured:** the credential a Gmail caller receives names those two scopes
  and no Drive scope. The suite reads it off a real `googleauth` object.
- **Not measured:** what Google returns for a Drive call made with that token.
  It should be an insufficient-scope refusal, and nobody has made the call — it
  needs a live token against a live workspace. Do not write it down as proven.

Two things it does NOT buy at all, so do not write that it does:

- **Not "can draft, cannot send".** There is no draft-only Gmail scope;
  `gmail.compose` covers drafts and send. "Never sends" is still a property of
  our code, asserted by `test/lib/no_gmail_send_test.rb`.
- **Not per-mailbox narrowing.** No scope says "this address only". The
  `workspace_mailboxes` allow-list holds that, in Ruby.

The cache is keyed on `[address, purpose]`. It was keyed on the address alone,
which meant the first caller to ask for an address decided what every later
caller got — `check_mailbox` probes `alex@` against the whole grant, and the
`GmailClient` read two lines later was handed that same four-scope object.

```bash
bin/rails 'workspace:add_mailbox[<address>]'           # SIGNATURE='markdown' optional
bin/rails 'workspace:check_mailbox[<address>]'         # proves it; flips a pending workspace active too
bin/rails workspace:mailboxes                          # who is draftable, with draft counts
bin/rails 'workspace:revoke_mailbox[<address>,<why>]'  # stop drafting as one address
```

`check_mailbox` succeeding also proves the workspace's grant (delegation is
domain-wide), so a domain whose `team@` does not exist can still be brought
active through the mailbox it is really for.

Drafting itself, run from the operator's chat session:

```bash
# Read the ONE thread being answered. A query matching several threads is
# refused before any of them is opened — narrow it and retry.
MAILBOX=alex@<domain> QUERY='from:vendor.example subject:"payment failed" newer_than:14d' \
  bin/rails workspace:thread

# Write the draft. BODY is a markdown file: **[text](url)** is a bold link.
MAILBOX=alex@<domain> BY=<who asked> BODY=draft.md \
  REPLY_QUERY='<the same query>' bin/rails workspace:draft          # a reply, threaded
MAILBOX=alex@<domain> BY=<who asked> BODY=draft.md \
  TO=a@x.example SUBJECT='…' bin/rails workspace:draft              # a new message
```

It prints `Open: https://mail.google.com/mail/u/<mailbox>/#drafts?compose=…`.
Every draft is logged in `mailbox_drafts` — who asked, which mailbox, which
thread — but the body is never stored; it lives only in Gmail.

Traps in this lane, each one silent:

- **The printed link can 404 for Alex McRitchie.** The `/u/<mailbox>/` form
  (`Workspace::GmailClient.draft_url`) picks the account when several are signed
  in, and can still land on "account temporarily unavailable". Do not change it
  without testing in his browser. The fallback is the macOS clipboard carrying
  BOTH `public.html` and `public.utf8-plain-text` (set through `NSPasteboard`
  with `osascript -l JavaScript`), so the reply pastes formatted.
- **The drafter cannot attach files**, and re-creating a draft leaves the old one
  in the thread; only Alex McRitchie can discard it.
- **Hand the Gmail gem plain MIME.** It base64-encodes `raw` itself; encoding
  first sends gibberish, and no service double catches it.
- **`make_creds(sub:)` is dropped with only a stderr line.** Assign `creds.sub`
  after building the credential (`Workspace::Credentials` does); without it the
  call authenticates as the service account, which has no mailbox.

These run where the key is: on production (`heroku run`), or on a desk that can
read the 1Password item. A mailbox must be proven on the SAME database the
draft runs against.

## 8. Calendar, Gmail and Drive by sign-in — the `sign_in` connection method

Calendar, Gmail and Drive do **not** ride the delegation above: the service
account holds none of their read scopes, and widening `SCOPES` breaks every
client domain until each re-grants (step 1's table). Each is read through a
person's own Google sign-in instead: one click, one person, and it may ask
again (revoked, or unused for six months). This is the `sign_in` method in
`config/integrations.yml`; the admin grant is `admin_grant`.

One sign-in, three abilities (`GoogleConnection::ABILITIES`), read only, asked
for all at once with **Connect Google** (`?ability=all`) or each on its own:

| Ability | Scope | Proof on the standing page |
|---------|-------|----------------------------|
| `calendar` | `calendar.events.readonly` | the next week's events |
| `gmail` | `gmail.readonly` | the five newest subjects (headers only) |
| `drive` | `drive.readonly` | the five most recently changed files |

Every sign-in also asks for `openid` and `email`, with
`include_granted_scopes=true`, so connecting one ability adds it to what the
account already granted. One `GoogleConnection` row per Google account holds the
encrypted refresh token and the granted `scope`; until 2026-10-14 it was
`GoogleCalendarConnection`, and the rename kept the connected row.

**The row keeps only what a sign-in asked for and Google granted.** Because of
`include_granted_scopes`, Google echoes every scope the account ever granted, so
the callback adds only the scopes of the abilities THAT sign-in requested to the
ones the row already had. An ability disconnected here stays off when another
connects. Connect Google's consent screen lists each scope with a checkbox: a
partial grant stores the ticked ones and says which were left unticked; only a
grant of none stores nothing.

**Every connection has an owner** (`google_connections.user_id`, the user who
signed it in; /tasks/every-user-connects-google). An admin's connections are the
**household's**, and **agents read the household's**:
`GoogleConnection.for`, `.current` and every agent-side lookup start from
`GoogleConnection.household` (admin-owned rows). The one exception: the agent
answering a client app's owner on their own app's CTO chat reads that owner's
own rows (`GoogleConnection.owned_by`, through `GoogleConnect::OwnerContext`;
`docs/agents/system/agent-message-loop.md`, "The Google layer"). No agent reads
one user's connection for anyone else. A promoted user's rows join the
household; a demoted admin's leave it. An account another user already connected is refused ("That Google
account is already connected by another user"), never taken over; the same
user signing in again keeps incremental consent.

The household page is **`/admin/google`** (admin only; `/admin/google_calendar`
redirects there): a section per ability with its account, its live read or
Google's error said plainly (a disabled API reads "Gmail answered 403: Gmail API
has not been used in project … or it is disabled"), and one button, with Connect
Google at the top (Connect the rest while some are connected; the account once
all three are). Its Disconnect reaches household rows only.

The same buttons sit on `/integrations` for **any signed-in user**: Connect
Google above the Google section's cards, and Connect or Disconnect on the Google
Calendar, Gmail and Drive cards, which then drop their contact-form Connect. An
admin's buttons go through `/admin/google` and show the household's accounts; a
non-admin's go through `/integrations/google/connect` and
`/integrations/google/connection` (`Integrations::GoogleController`) and show
and disconnect only their own. A signed-out visitor sees the cards and their
normal contact-form CTA only. Both doors share one flow (`GoogleSignIn`) and
**one callback**, `/admin/google_calendar/callback`, which admits any signed-in
user carrying the OAuth state their Connect set, so the console owes no new
redirect URI. `?return_to=` is honoured only for `/integrations` and (for an
admin) `/admin/google`. A single-ability callback whose grant lacks its scope
(unticked on Google's screen) stores nothing.

**Disconnect is per ability.** Google cannot revoke a single scope, so an
account keeping other abilities only forgets this one here; disconnecting its
last ability revokes the token at Google and deletes the row. A TLS or network
failure on the revoke still deletes the row and says Google did not confirm.

**Each API must be enabled** in the OAuth client's Google Cloud project
(APIs & Services → Library: Google Calendar API, Gmail API, Google Drive API),
or its read answers 403 on the standing page.

**Its own OAuth client, never the hub's sign-in client.** Alex McRitchie creates it once in
Google Cloud Console (APIs & Services → Credentials → Create OAuth client ID →
Web application), with the redirect URI the standing page prints while the client is unset
(`https://mcritchie.studio/admin/google_calendar/callback` in production: the
callback keeps the path first registered), and sets the consent screen's
publishing status to **In production**: a Testing app's refresh tokens die after
7 days. Gmail and Drive read scopes are restricted: until Google verifies the
app, the sign-in shows an "unverified app" warning that the person clicks
through, and Google may refuse an outside (non-workspace) account outright or
cap the unverified app's user count. Now that any signed-in user can connect,
expect that warning or refusal for viewers until the app is verified. File the pair under the admin writing lane
([`credential-filing`](credential-filing.md)) and set it on the app:

```bash
op item get <item> --vault <vault> --format json |
  ruby -rjson -e 'f = JSON.parse(STDIN.read)["fields"].to_h { |x| [x["label"], x["value"]] }
    print JSON.generate("GOOGLE_CONNECT_CLIENT_ID" => f.fetch("client-id"),
                        "GOOGLE_CONNECT_CLIENT_SECRET" => f.fetch("client-secret"))' |
  /Users/alex/projects/mcritchie-studio/bin/heroku-secret-set mcritchie-studio --json
```

The pair travels on stdin from the filed item, never as arguments
([`credentials.md`](../../../modules/credentials.md)).

Locally, `GOOGLE_CALENDAR_STAND_IN=1` walks the whole flow against a stand-in
(`config/initializers/google_connect_stand_in.rb`) that grants whichever scopes
each Connect asked for and echoes past grants as Google does; nothing reaches
Google.

## 9. Fathom by sign-in — meeting notes and transcripts

The same `sign_in` method for Fathom (`FathomConnection`, `Fathom::OAuthClient`,
`Fathom::Reader`): one sign-in, one ability (read meetings, their transcripts and
their summaries; Fathom's only OAuth scope is `public_api`). The hub dogfoods it
at **`/admin/fathom`** (admin only): the account, a live read (the first page of
meetings and whether there are more, the newest meeting's title and date, its
transcript's lines and speakers, its summary's length) or Fathom's error said
plainly, and one button. The Fathom card in the Meeting notes section of
`/integrations` carries the same Connect or Disconnect for an admin;
`?return_to=` is honoured only for `/integrations` and `/admin/fathom`.

**Refresh tokens are single-use.** Every refresh answers a new refresh token and
spends the old one, so `Fathom::OAuthClient.access_token` refreshes only under
the row's lock and stores the new token before the access token is used. A
refresh that loses its answer (a timeout after Fathom rotated) leaves a spent
token: the standing page then says Fathom no longer accepts the connection, and
the fix is Disconnect, then Connect.

**No revoke.** Fathom documents no revoke endpoint, so Disconnect deletes the
stored token here and says so; removing the app's access is done in Fathom.

**The OAuth apps.** Two Fathom OAuth apps, each with its one redirect URI:
production (`https://mcritchie.studio/admin/fathom/callback`) and development
(`https://qa.mcritchie.studio/admin/fathom/callback`). Their pairs are set as
`FATHOM_CLIENT_ID` and `FATHOM_CLIENT_SECRET` on production and on QA; file a
rotated pair through [`credential-filing`](credential-filing.md). Locally,
`FATHOM_STAND_IN=1` walks the whole flow against a stand-in
(`config/initializers/fathom_connect_stand_in.rb`) whose token endpoint honours
only the last refresh token it issued; nothing reaches Fathom.

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

## Severing — ending a relationship for good

`severed` is the acquisition / departure state, and unlike `revoked` it is
**final**: nothing reinstates it. Because it cannot be taken back, the record
says `severed` only after Google agrees the grant is gone. The order:

1. **Revoke now** if drafting must stop before the client acts:
   `bin/rails 'workspace:revoke[<domain>,<why>]'`.
2. **Hand over their records** (Phase 4 adds `workspace:export`; until then,
   export their `workspace_mailboxes` and `mailbox_drafts` rows by address).
3. **The client's super-admin deletes our Client ID** from their delegation page.
4. **Prove the cut:** `bin/rails 'workspace:check_severed[<domain>]'` must print
   `CUT`. Only `unauthorized_client` counts; any other failure is
   `INCONCLUSIVE`, because it says nothing about their console.
5. **Sever:** `bin/rails 'workspace:sever[<domain>,<why>]'`. It re-runs the same
   probe and refuses unless Google refuses us. Every mailbox in the workspace
   is shut with it.

Our service-account key is **not** rotated for a severance: the client never
held it, so their deleting our Client ID is the whole revocation.

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
# The key goes on stdin, never as an argument; the script prints only the HTTP status.
/Users/alex/projects/mcritchie-studio/bin/heroku-secret-set <app> GOOGLE_SERVICE_ACCOUNT_JSON < "$KEYFILE"

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
this credential's most likely failure that run is key material rather than a
position.

**RETRACTION — an earlier revision of this section printed `=> "987654321"`
here, and that figure was FABRICATED.** It was not measured; digits were typed
over a real PKCS#8 prefix (`MIIEvQIBADANBgkqhkiG9w0BAQ` became
`MIIEvQIBADANBgkqhkiG987654`) and the result was labelled "Measured". The same
figure was retracted from
[`modules/backend-discipline.md`](../../../modules/backend-discipline.md),
§ *Never interpolate an exception message that quotes its input*, which is the
house rule this paragraph applies; the two now agree.

Re-measured here, `bundle exec` on **json 2.20.0** — the version `Gemfile.lock`
pins and the `heroku run bin/rails runner` above actually loads, not the
laptop's default gem. The construction, stated so it can be rebuilt: a
2048-bit RSA key from `OpenSSL::PKey::RSA.new(2048).private_to_pem`, embedded
in a service-account JSON with its PEM **line breaks left literal** — i.e. the
newlines were never escaped as `\n`, which is what a paste does. Ten keys:

```text
message         invalid ASCII control character in string: \nMIIEvQIBADANBgkqhkiG9w0…
e.message[/\d+/]                      => "9"                 ← key bytes, 10/10
e.message[/at line \d+ column \d+/]   => "at line 2 column 0" ← 10/10
```

**No message LENGTH is quoted here, deliberately.** `JSON::ParserError` quotes
from the failure point to END OF DOCUMENT, so the length is a property of the
fields that FOLLOW `private_key`, not of the key. Measured over 20 keys: a
document that ends at `private_key` gives 1,741 (±4 for the DER length byte),
and a real Google credential with its seven trailing fields gives 1,907 — same
key, same failure. An earlier revision of this section printed one of those
numbers under "the construction, stated so it can be rebuilt", which it could
not be. What matters is unbounded, and that is already the claim.

**One character, and it is not a sample — it is structural.** PKCS#8 wraps the
key in an AlgorithmIdentifier carrying the rsaEncryption OID, which base64s to
the literal run `BgkqhkiG9w0BAQEF` in every RSA key. So the body's first digit
is always the `9` of `9w0`, at index 20, and the run stops there. Measured: all
ten bodies contain `9w0BAQEF`, and the first digit sits at index 20 in all ten.

So the case against the bare form is NOT that it leaks a lot — it leaks one
character. **The case is that it is not a position at all.** It returns key
material that merely looks like a number, and it would do so silently, every
time, in a line whose whole purpose is to report where the parse failed. The
anchored form is a position or nothing: it needs the literal words `at line` and
`column`, and the SPACE between them is the part base64 cannot produce. (The
letters are not — `c`, `o`, `l`, `u`, `m` and `n` are all in the base64
alphabet, and an earlier revision of this line claimed otherwise. The rule was
safe; the reason given for it was not.) It is the same slice `Gmail::Credentials`,
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
  grant and a different decision, and it is Alex McRitchie's to make.

## Background — not needed to execute

`gcloud` (585.0.0, installed 2026-09-20) covers the Google-side half that *is*
scriptable: creating and rotating the service-account key, and listing which
keys exist. The delegation grant itself stays manual because Google publishes no
API for it — verified across every Google source, which documents it as a
console action only. So the ceiling on automating this act is one click, taken
by someone who does not work for us.

Architecture of the allow-list, and why a compile-time constant became a table:
`app/services/workspace/credentials.rb` carries it at the allow-list comments, and `app/models/workspace_account.rb` carries the allow-list rationale
and the three-state lifecycle. Both are on disk. (The `workspace-accounts-registry`
task record held the original write-up and is ARCHIVED, so it is history rather
than a place to read.)
