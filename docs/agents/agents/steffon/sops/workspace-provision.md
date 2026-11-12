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
  not widen to `gmail.send`, `gmail.modify`, or `mail.google.com`. The one
  sanctioned send is a print order to the FedEx store, on Alex McRitchie's ask
  in the current chat, from a scratchpad script: see the Pokémon's
  `print-order` SOP.
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
of the three is missing, stop at the decline path. You also need the **folder
user**: the person new Drive folders are shared with. If you do not have that name,
ask, but do not stop; see step 1.

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
bin/rails 'workspace:register[<domain>,<Display Name>,<entity-slug>,<folder user email>]'
```

The **folder user** is the person who runs this Workspace for the client. Every
Drive folder an agent creates through `Workspace::DriveClient` is shared with them
as Editor, with no email, so they can find it under **Shared with me**. Without a
folder user, the folder is still created, but only `team@` can see it and the
command warns. To set or change it on a registered Workspace, do not re-run
`register`, which re-stamps the scopes. Run:

```bash
bin/rails 'workspace:folder_user[<domain>,<email>]'
```

This changes the database of the environment it runs in, so a bare run on a Mac
changes only the local row. For production, run:

```bash
heroku run --app mcritchie-studio --no-tty --exit-code -- \
  bin/rails 'workspace:folder_user[<domain>,<email>]'
```

`bin/rails workspace:accounts` shows each Workspace's folder user.

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

The walker records a shortcut and never follows it. A shortcut's target is indexed
only when a source walks the folder that holds it, in the Workspace of the entity
that signs it. To list each walked shortcut and whether a source indexes its target,
run:

```bash
bin/rails workspace:shortcuts
```

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

One opt-in WRITE ability (`GoogleConnection::WRITE_ABILITIES`) sits beside them. It is
never part of Connect Google; the person turns it on from the Gmail card's
**Organize** row on `/integrations`:

| Ability | Scopes | What uses it |
|---------|--------|--------------|
| `gmail_organize` | `gmail.modify` + `gmail.settings.basic` (both must be granted) | `GoogleConnect::GmailEditor` through `bin/mail organize\|filter\|unsubscribe\|labels\|filters --mailbox ADDR`: mark read or unread, archive, inbox, spam, not spam, label, unlabel, move, filters, and one-click unsubscribe (RFC 8058 HTTPS POST to one-click senders only, never with a Google token; web-page, email-only and none senders are reported, not touched). Dry unless `--apply`; each run logs a `GmailChange` row. It never sends (Google's grant would allow it; `test/lib/no_gmail_send_test.rb` keeps the source from it), never trashes, never deletes. |

Drive filing needs no write ability of its own (`/tasks/drive-filing`). The `drive`
ability's `drive.file` scope already lets the app create folders and files and see
only those it made, so a Drive connection made before this ships files documents
too. `GoogleConnect::DriveFiler` does it through
`bin/drive mkdir|upload|file-attachment|ls --mailbox ADDR`: make a folder path
(`Insurance/Life Insurance`), upload a local file into it, or file a Gmail
attachment from the same account (needs its Gmail read). Everything it makes
carries an `appProperties` mark (`mcritchieFiler=1`), and every lookup asks for
the mark, so it reuses only its own folders. A file whose md5 already sits in the
folder is skipped. Dry unless `--apply`; each call logs a `DriveFiling` row
(account, folder path, file name, size, md5, Drive id, never the bytes). A local
file's bytes ride the `heroku run` STDIN as base64 with their md5, which the hub
checks; the cap is 25 MB. It never deletes, trashes, shares or changes a file.

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
household; a demoted admin's leave it. Each connection on both pages says who
reads it, from one rule, `GoogleConnection#who_reads`: "Your agents can read
this" for the household's, "Your app's agent can read this when you chat with
it" for a client app owner's own, "Only you can see this" for anyone else's. An
account another user already connected is refused ("That Google account is
already connected by another user"), never taken over; the same user signing in
again keeps incremental consent.

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
normal contact-form CTA only. On `/integrations` the Gmail card's Connect, and
Connect Google or Connect the rest while Gmail is still missing, first open the
Gmail admin-trust modal (`app/views/modals/_gmail_admin.html.erb`): Gmail read is
a restricted scope Google will not verify for us, so the user's Workspace admin
marks the OAuth client (`GOOGLE_CONNECT_CLIENT_ID`, shown with a copy button)
Trusted under Security → API controls → Manage Third-Party App Access. A
personal @gmail.com account has no admin and still connects: Google shows its
"Google hasn't verified this app" screen, and the person clicks Advanced, then
Go to McRitchie Studio (unsafe); the modal says so. Its
Continue goes on to the same connect route. `/admin/google` links straight. Both doors share one flow (`GoogleSignIn`) and
**one callback**, `/admin/google_calendar/callback`, which admits the signed-in
user who pressed Connect, carrying the OAuth state that Connect set, so the
console owes no new redirect URI. `?return_to=` is honoured only for
`/integrations` and (for an admin) `/admin/google`. A single-ability callback
whose grant lacks its scope (unticked on Google's screen) stores nothing.

**What the callback refuses** (/tasks/google-connect-hardening-polish): a
callback reached while someone other than the user who pressed Connect is
signed in on that browser (the state is bound to that user's id); an account
whose email Google does not report as verified (`email_verified` in the
id_token); a grant of none of the asked abilities; an account another user
connected. Each refusal revokes the token Google just issued, **unless a stored
connection already holds that account**: Google's revoke drops the whole grant
(every token the account gave this OAuth client), so revoking then would cut
the connection someone already has. Two simultaneous sign-ins of one new
account end as one row and a plain message, never a 500.

**Disconnect is per ability.** Google cannot revoke a single scope, so an
account keeping other abilities only forgets this one here; disconnecting its
last ability revokes the token at Google and deletes the row. A TLS or network
failure on the revoke still deletes the row and says Google did not confirm.

**Each API must be enabled** in the OAuth client's Google Cloud project
(APIs & Services → Library: Google Calendar API, Gmail API, Google Drive API,
and Google Picker API for Drive),
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

**Drive is files you pick (drive.file).** The Drive ability asks for
`drive.file`, not `drive.readonly`, so the person chooses files in the Google
Picker and the hub reads only those (`GoogleDrivePick`). The Picker needs:
the **Google Picker API** enabled in the same Cloud project, and a browser
**API key** (APIs & Services → Credentials → Create credentials → API key),
restricted to HTTP referrer `https://mcritchie.studio/*` and to the Picker API,
set on the app as `GOOGLE_PICKER_API_KEY`. Its 1Password item already exists:
`google-picker.studio.applications` in vault `studio-applications`, field
`credential` ([`credential-inventory.md`](../../../modules/credential-inventory.md)).
The referrer restriction is production's host ONLY: before the Picker works on
QA (or any other host), an operator adds that host as a referrer on the key, or
files a separate key for it. That is an operator action in the Cloud console,
not code; until then the Picker fails to open there, even though the card shows
Pick files. The Picker's app id is the project
number, read from the digits leading `GOOGLE_CONNECT_CLIENT_ID`
(`GOOGLE_PICKER_APP_ID` overrides it). Without the key the Drive card says
"Drive picking isn't set up yet". A row connected under `drive.readonly`
keeps reading the whole Drive until its owner reconnects Drive. After the
reconnect the hub reads only picked files, but Google keeps the old
`drive.readonly` grant on the token (`include_granted_scopes`) until the person
removes McRitchie Studio at myaccount.google.com/permissions; the hub does not
revoke-and-regrant, since revoking the token would end Calendar and Gmail too. Picking a
folder is not offered: Google documents no grant of its contents under
`drive.file` (the evidence is on `/tasks/drive-files-you-pick`).

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

## 10. Egnyte by sign-in — a document store, one row per domain

The same `sign_in` method for Egnyte (`EgnyteConnection`, `Egnyte::OAuthClient`,
`Egnyte::Reader`), built dark: nothing happens until the developer key is set and
an admin connects a domain. Egnyte's Public API answers on each domain's own host
(`https://<domain>.egnyte.com/pubapi/...`), so the admin types the domain before
Connect, and the hub keeps one row per domain. One scope, `Egnyte.filesystem`
(Egnyte has no read-only variant): browse folders, read file metadata, and upload
one file (`Egnyte::Reader#upload`, the only write). The hub dogfoods it at
**`/admin/egnyte`** (admin only): each domain, who connected it, a live read of
`/Shared` (or the folder `?egnyte_domain=&path=` names), and Disconnect. The
Egnyte card in the Connect group of `/integrations` is dark (`dark: true` in
`config/integrations.yml`): the public page does not list it. An admin's page
does, with the domain field and Connect, rendered disabled until the server holds
the key, and each connected domain with its Disconnect. Offering it to clients is
a config change: drop `dark`, and mind the public page's two rows of four.

**Tokens** (Egnyte's authentication docs, read 2026-11-06). The authorization code
flow on `https://<domain>.egnyte.com/puboauth/token`. The access token lives 30
days; a refresh answers a new access token and a new refresh token. Egnyte asks
callers to cache the access token (its token endpoint allows about 100 requests
an hour), so the row keeps both tokens encrypted with the expiry, and
`Egnyte::OAuthClient.access_token` refreshes only within a day of expiry or after
a 401, under the row's lock. Read limits: about 2 calls a second and 1,000 a day
per access token; a 429 is said on the page. A refused refresh (revoked, or the
user's password changed) shows on the page; the fix is Disconnect, then Connect.

**Revoke.** Disconnect calls `POST /pubapi/v1/tokens/revoke` on the domain, then
deletes the row. When Egnyte does not confirm the revoke, the row still goes and
the notice says to remove the access in Egnyte.

**The bulk import is a follow-up.** `Egnyte::Reader#each_entry` walks one folder a
page at a time; the import job recurses with it, and adds a download read and the
chunked upload (`/fs-content-chunked`, for files over 100 MB).

**The developer key.** Register it at developers.egnyte.com (Alex McRitchie's
turn, in the epic), with the redirect URI `https://mcritchie.studio/admin/egnyte/callback`
for production and `https://qa.mcritchie.studio/admin/egnyte/callback` for QA. Set
its pair as `EGNYTE_CLIENT_ID` (the API key) and `EGNYTE_CLIENT_SECRET` (the
shared secret), and file it as `egnyte.industries.applications` through
[`credential-filing`](credential-filing.md). Locally, `EGNYTE_STAND_IN=1` walks the
whole flow against a stand-in (`config/initializers/egnyte_connect_stand_in.rb`)
that accepts any domain and honours only the last refresh token it issued;
nothing reaches Egnyte.

## 11. QuickBooks Online by sign-in — company info and reports, read only

The same `sign_in` method for QuickBooks Online (`QuickbooksConnection`,
`Quickbooks::OAuthClient`, `Quickbooks::Reader`): an Intuit sign-in per company,
one ability (read the company's info and its reports). Intuit's only scope that
reads a company's books is `com.intuit.quickbooks.accounting`, and it also allows
writes; the hub uses it read only, because `Quickbooks::Reader` holds no write
path (a unit test pins that). The hub dogfoods it at **`/admin/quickbooks`**
(admin only): each connected company, its Intuit environment, and a live read
(the company's name from CompanyInfo, and this year's profit and loss to date:
its period, basis, sections and net income) or Intuit's error said plainly.
Connect adds a company; each company has its own Disconnect. The QuickBooks card
on `/integrations` carries the same buttons for an admin; `?return_to=` is
honoured only for `/integrations` and `/admin/quickbooks`.

**Built dark.** The card is `dark` in `config/integrations.yml`: a visitor and a
client never see it, and an admin sees it with Connect disabled until the Intuit
app is set on the server. When the connector is offered to clients, drop `dark`
and set `status` to `live` in the same change.

**One row per company.** `realm_id` (Intuit's company id, sent on the callback as
`realmId`) is unique, so one owner can connect a new company file and an older
one for history, each its own grant. The realm id is never rendered, and it is
filtered by key (`realmId`) in `config/initializers/filter_parameter_logging.rb`,
so neither the "Started GET" line's URL nor the Parameters line logs it. The
callback's `code` is filtered from the Parameters line only (a controller-scoped
filter, as for the other sign-ins); the URL line still carries it, and it is
single-use and spent by the callback.

**Refresh tokens rotate.** Access tokens last an hour. A refresh may answer a new
refresh token, and Intuit says to keep the one its latest answer gave (the
previous one lapses about a day later). So `Quickbooks::OAuthClient.access_token`
refreshes only under the row's lock and stores the answered token before the
access token is used. The stored token also lapses on its own: the row keeps the
expiry Intuit states (`x_refresh_token_expires_in`), and the page shows it.
Intuit also caps every refresh token at five years. A lapsed or revoked token
reads as "Intuit no longer accepts this connection"; the fix is Disconnect, then
Connect.

**Revoke.** Intuit has a revoke endpoint. Disconnect calls it with the company's
refresh token, then deletes the row either way, and says whether Intuit
confirmed. When it did not, remove the app's access in QuickBooks (Settings,
Manage apps).

**The Intuit app.** One Intuit developer app has two key sets. Its Development
keys reach sandbox companies only: set them on QA (`mcritchie-studio-qa`) as
`INTUIT_CLIENT_ID` and `INTUIT_CLIENT_SECRET`, with `INTUIT_ENVIRONMENT` unset or
`sandbox`, and register `https://qa.mcritchie.studio/admin/quickbooks/callback`
as a Development redirect URI. Its Production keys reach real companies: set them
on production (`mcritchie-studio`) with `INTUIT_ENVIRONMENT=production`, and
register `https://mcritchie.studio/admin/quickbooks/callback` as a Production
redirect URI. Any value of `INTUIT_ENVIRONMENT` other than `production` means the
sandbox, so a typo never points sandbox keys at live books. Each connection
stores the environment it was made in, and its reads go to the matching API
host. The pairs live in `intuit.industries.applications` (`studio-applications`):
the Development pair is filed (2026-11-08); the Production pair waits on Intuit's
production questionnaire. Rotate either through
[`credential-filing`](credential-filing.md). Locally,
`QUICKBOOKS_STAND_IN=1` walks the whole flow against a stand-in
(`config/initializers/quickbooks_connect_stand_in.rb`) whose token endpoint
honours only the last refresh token it issued; nothing reaches Intuit.
## 12. Microsoft 365 by admin approval — users, Teams and SharePoint (dark)

The `admin_grant` method for a Microsoft 365 tenant (`MsgraphConnection`,
`Msgraph::OAuthClient`, `Msgraph::Reader`): app-only Microsoft Graph, read only.
A tenant administrator presses **Connect** on **`/admin/msgraph`** (admin only),
approves the app once on Microsoft's admin-consent page, and the callback stores
one row per tenant: the tenant id encrypted and never rendered, the
organization's name, who connected it and when. The hub's own request log
filters the callback's `tenant` parameter, but Heroku's router log still records
the full callback query, tenant id included. Reads then use the
client-credentials grant; no refresh token exists, and the access token is
cached in process memory only. The page shows each tenant's live read (users,
Teams, the root site and its drives) or Microsoft's error, and a Disconnect per
tenant. The Microsoft 365 card in the Connect group of `/integrations` is
`dark: true`: the public page does not list it. An admin's page lists it as
Coming soon, with the tenants and a Connect that is disabled until the server
can take one. `?return_to=` is honoured only for `/integrations` and
`/admin/msgraph`.

**It ships dark.** Nothing is registered yet. To go live:

1. Check the tenant first: a tenant bought as "Microsoft 365 from GoDaddy" is
   federated to GoDaddy and blocks admin consent until it is defederated.
2. Register one **multi-tenant** app in Microsoft Entra (Accounts in any
   organizational directory). Its web redirect URIs are
   `https://mcritchie.studio/admin/msgraph/callback` and
   `https://qa.mcritchie.studio/admin/msgraph/callback`. Add these Microsoft
   Graph **application** permissions, every one a read:
   `User.Read.All`, `Team.ReadBasic.All`, `Sites.Read.All`, `Files.Read.All`,
   `Organization.Read.All` (`Msgraph::OAuthClient::PERMISSIONS`).
3. Make a client secret. File the app id and secret as
   `microsoft.industries.applications` through
   [`credential-filing`](credential-filing.md), then set `MSGRAPH_CLIENT_ID` and
   `MSGRAPH_CLIENT_SECRET` on the app. These are not the Teams bot's
   `TEAMS_BOT_*` values.
4. A global administrator of the tenant presses Connect and approves.

**No revoke.** Consent is removed in the tenant (Enterprise applications), so
Disconnect deletes the row and the cached token here and says so. Locally,
`MSGRAPH_STAND_IN=1` walks the whole flow against a stand-in
(`config/initializers/msgraph_connect_stand_in.rb`); nothing reaches Microsoft.

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
