# The knowledge layer — design

**Status: proposed, awaiting Alex's review.** The final act of the
`platform-audit-refactors` epic. Google Workspace is the knowledge shelf; Egnyte
slots in later as a second source behind the same reader. Section 1 is what
exists; sections 2 to 8 are the design; section 9 lists the build pieces and
section 10 the decisions Alex makes.

**On `accepted`, not live.** Three things this page relies on are merged to
`accepted` and are not in production: private facts (the `Fact` model,
`/api/v1/facts`, `bin/fact`, the person-page panel), the dream bank in two
sequences with relevance loading and the ship-time proposer, and the review-claim
and one-time-code logins. Each is marked **(accepted)** where the page leans on it.

The idea in one paragraph: knowledge sits in five tiers, and it flows downward
only. An original lives in Drive. A fact or a page is derived from it and points
back at it. Nothing private rises into a tier that loads by itself. A Drive
document is untrusted text: it is indexed and pointed at, and it enters a
session's context only when that session asks for it by id.

## 1. Today, read from the code

| Surface | What it does today | Where |
|---|---|---|
| Google identity | One service-account key under domain-wide delegation serves every Workspace. The grant holds four scopes: `drive.readonly`, `drive.file`, `gmail.readonly`, `gmail.compose` | `app/services/workspace/credentials.rb#SCOPES`, `app/services/workspace/credentials.rb#ITEM` |
| Who is impersonated | For Drive, only an `active` `WorkspaceAccount` subject, `team@<domain>` by default. Under the `mail` purpose an active `WorkspaceMailbox` in an active Workspace also passes. Any other address raises before a token is built | `app/services/workspace/credentials.rb#authorizer_for`, `app/models/workspace_account.rb#impersonatable?` |
| Token reach | A token asks for its purpose's scopes. Two purposes exist: `workspace` (all four) and `mail` (the two Gmail scopes). The Drive client asks for `workspace`, so a Drive token also holds the Gmail scopes | `app/services/workspace/credentials.rb#SCOPES_BY_PURPOSE`, `app/services/workspace/drive_client.rb#service` |
| Drive calls | List by query, get, download, export, copy, update, list permissions. No create. A listing with no query is refused | `app/services/workspace/drive_client.rb#files_list` |
| The walker | Walks one folder tree depth-first and records metadata only. It downloads nothing, never follows a shortcut, and marks a document `missing` only after a complete walk | `app/services/workspace/drive_walker.rb#record`, `app/services/workspace/drive_walker.rb#mark_unseen_missing` |
| What runs the walker | The `workspace:walk` task in `lib/tasks/workspace.rake`, by hand. No job and no schedule calls it | `config/recurring.yml` |
| The index | `KnowledgeSource` (kinds `google_drive`, `egnyte`, `transcripts`) and `SourceDocument`: Drive file id, version, title, owner, link, Drive's MD5 for binary files, a per-agent access map, and the version last indexed | `app/models/knowledge_source.rb#KINDS`, `app/models/source_document.rb#needs_indexing?` |
| What the index lacks | A SHA-256, a summary, a category, any document text, and anything that calls `mark_indexed!` | `app/models/source_document.rb#mark_indexed!` |
| Uploaded documents | The engine's `Studio::KnowledgeDoc` holds an upload by `s3_key`, with an access map of `full`, `aware` or `none` per agent. The hub has the table and draws no knowledge routes | `docs/agents/modules/knowledge-capture.md` |
| A second Gmail lane | An OAuth grant for one mailbox, `gmail.readonly` only, feeding the desk queue. It holds no Drive scope | `app/services/gmail/client.rb#SCOPES` |
| Private facts **(accepted)** | One encrypted record per subject, key and value, with a required source: a knowledge doc id or a Drive file id. The source is a string; nothing checks it against the index | `app/models/fact.rb#SOURCE_KINDS` |
| Dreams **(accepted)** | A platform sequence and one per soul, a generated index, and selection by relevance at a claim | `bin/lib/dream_bank.rb#CALL_BUDGET`, `bin/lib/dream_selector.rb#LIMIT` |
| Mirrors | None. Nothing copies Drive to disk, and nothing copies model memory to Drive | — |

## 2. The five tiers

| Tier | Holds | Lives in | Loads | Never written into it |
|---|---|---|---|---|
| **1 General** | The repo map and the capability pages | This repo, tracked and public | At boot, every session | Anything private: a counterparty, a figure, a contact detail, a key |
| **2 Specialized** | Topic knowledge most sessions never need | Code-bound topics: the owning repo's docs. Business-bound topics: `notes/` in Drive | Only when the task names the topic; the map carries a one-line where-to-look index | Repo half: the tier 1 list. Drive half: identity data and credentials |
| **3 Private facts** **(accepted)** | One thing known about a person, a company or an app | Encrypted `Fact` records on the hub | Never by itself; read by `bin/fact` for a named subject | Identity data (an SSN, a card, an account or routing number, a passport or licence number, a PIN, a password, a person's tax id, a long unformatted number): the key takes a pointer with no value, and the key itself is a name that carries no data. Privileged deal terms never go in an ordinary fact |
| **4 Originals** | Source documents, and a digest row for each | Bytes: Google Drive. Digest row: `SourceDocument` on the hub. Derived text: one private R2 bucket | Never by itself; read by id | In Drive: credentials, keys, tokens and seed phrases. In git: any original's bytes. In R2: an original |
| **5 Dreams** **(accepted)** | Worked decisions, each signed off by Alex | This repo, tracked and public | Platform dreams at session start; a soul's by relevance at a claim | Live data and open security detail ([`dream.md`](../modules/dream.md)) |

Rules that hold across the tiers:

- **Flow is downward only.** An original yields a fact or a page. Nothing derived
  from tier 3 or 4 is copied up into tier 1, tier 2's repo half, or tier 5 except
  by a reviewed pull request that carries no private value.
- **A fact points at its original.** A fact with no source is refused.
- **Model-private memory is a cache.** A durable lesson is promoted into tier 1 or
  2 by a pull request ([`memory.md`](memory.md)); the cache is mirrored to Drive
  as a backup (section 7).
- **Credentials live in 1Password only**, in no tier.

## 3. Who reads what, and how a refusal answers

The trust classes are the session tiers of
[`agent-sessions-design.md`](agent-sessions-design.md): admin, studio and client.
"No session" is a caller holding only the shared token.

| Tier | No session | Client | Studio | Admin |
|---|---|---|---|---|
| 1 and 5 | Reads the files | No repo and no board | Reads | Reads |
| 2, Drive `notes/` | Refused as tier 4 | Refused as tier 4 | As tier 4, by access map | Reads |
| 3 **(accepted)** | `401 SESSION_REQUIRED` | `403 SESSION_FORBIDDEN` | Reads and writes ordinary facts. A sensitive fact is left out of a list with no error; writing one answers `403 SESSION_FORBIDDEN` | Reads and writes both |
| 4 index (proposed) | `401 SESSION_REQUIRED` | `403 SESSION_FORBIDDEN` | Rows whose access map gives its soul `aware` or `full`. A row at `none` is left out of a list, and a read by id answers `404 NOT_FOUND` | Every row |
| 4 text (proposed) | `401 SESSION_REQUIRED` | `403 SESSION_FORBIDDEN` | `full` only. `aware` answers `403 SESSION_FORBIDDEN` with "summary only" and returns the summary | Every document but an original a pointer fact names; that one answers by decision 5 |

Every refusal is a JSON body with `error` (one sentence giving the reason) and
`error_code`, as `app/controllers/concerns/api/agent_session_gate.rb#render_session_refusal`
answers now. Three more tier 3 answers exist **(accepted)**: identity data in
the value, the key, the source or the subject answers `422 IDENTITY_REFUSED`
and names the pointer form; an app with no
encryption keys answers `503 ENCRYPTION_NOT_CONFIGURED`
(`app/controllers/api/v1/facts_controller.rb#require_encryption!`); a fact for a
person the hub does not hold answers `422 VALIDATION_FAILED`. A `none` row answers
404 and not 403 on purpose: 403 would confirm the document exists. A source's
access map defaults to `none` for every agent.

## 4. The Drive tree (tier 4)

One shared drive per Workspace is the shelf. Three of its folders are walked:
`originals/`, `documents/` and `notes/` are each one `KnowledgeSource` row bound
to that Workspace's `WorkspaceAccount`. The drive root is never registered as a
source. Folder ids are database rows and never enter this repo.

```text
<Workspace> Knowledge/         one shared drive per Workspace
  inbox/                       NOT walked: anything, unsorted
  originals/<category>/        walked: the system of record; filed once, not edited
  documents/                   walked: working documents people edit
  notes/                       walked: tier 2, business-bound topic pages
  memory-mirror/               NOT walked: created by the app; the only folder an agent writes
```

`inbox/` and `memory-mirror/` sit outside every walked root, so no row, no text
and no endpoint answer exists for a file in them. The walker reads only under the
root a source names and never follows a shortcut
(`app/services/workspace/drive_walker.rb#walk`). This is held by registration,
not by Google: a `drive_read` token can open both folders, and a source
registered at the drive root would walk them. Piece 4 refuses that registration.

A category is a folder name under `originals/`; the indexer copies it onto the row.

| App | Shelf | Facts | Derived text |
|---|---|---|---|
| McRitchie Studio (hub) | The hub Workspace's shelf drive; it also holds `memory-mirror/` | Hub `Fact` records | `<source id>/` in the knowledge bucket |
| McRitchie Industries | Its Workspace's shelf drive | Hub `Fact` records, subject `company/<slug>` | `<source id>/` in the knowledge bucket |
| Turf Monster | Its shelf drive | Hub `Fact` records, subject `app/<slug>` | `<source id>/` in the knowledge bucket |
| Commercial Welding | Its Workspace's shelf drive, registered last (decision 3) | Hub `Fact` records | `<source id>/` in the knowledge bucket |

The table is the target. Which of these Workspaces is registered and delegated
is a production row this page did not read. The hub owns the walker, the index
and the facts for every app; an entity app keeps its `Studio::KnowledgeDoc`
browser and points a row at a Drive file.

The knowledge bucket is one new private R2 bucket on the hub, with its own
bucket-scoped keys, as the desk bucket has. The hub's and Turf Monster's asset
buckets serve public URLs ([`object-storage.md`](../modules/object-storage.md)),
so no derived text goes there. An object's key is its SHA-256.

## 5. The reading identity

- **One subject per Workspace.** The walker acts as `team@<domain>`, and
  `authorizer_for` refuses any address that is not an active row. The Google-side
  bound is what `team@` can open, so the shelf drive's membership is the boundary
  Alex sets by hand.
- **Two new purposes narrow the token.** `drive_read` asks for `drive.readonly`
  only; the walker and the indexer use it. `drive_mirror` asks for `drive.file`
  only; the memory mirror uses it. Neither holds a Gmail scope. The grant does not
  change, so a delegated Workspace needs no new admin-console tap.
- **`drive.file` keeps writes to files the app made.** The mirror folder is
  created by the app for that reason. No call has been made with a narrowed token:
  the first build measures that a `drive_read` token is refused a write and that a
  `drive_mirror` token can create inside a shared drive.
- **One service account per Workspace domain** (decision 2). A leaked key then
  opens one Workspace, and severing a client retires one key.

## 6. The walker made real

1. **List.** A scheduled job walks every enabled `google_drive` source nightly. A
   failed walk marks nothing missing, as now, and the job files an `ErrorLog`.
2. **Fetch.** For each document where `needs_indexing?` is true, the indexer
   downloads a binary file or exports a Google-native one. An unchanged version
   costs no fetch.
3. **Digest.** It writes a SHA-256 of the fetched bytes, the category, and the
   R2 key of the extracted text onto the `SourceDocument` row, then calls
   `mark_indexed!`. The stable key is the source plus the Drive file id, which the
   table already holds unique.
4. **Screen.** Text that reads as a credential or as identity data marks the row
   `withheld`: its text is served to no studio session, and the row is reported to
   Alex. A credential in Drive is a filing mistake to fix at the source.
5. **Summarize, by hand.** The indexer calls no model. A session writes the
   summary at triage, and it is the only derived text an `aware` reader gets.

The digest row is `SourceDocument`, not `studio_knowledge_docs`: it already holds
the file id, the version, the access map and the freshness rule, and it lives on
the hub beside the facts. `Studio::KnowledgeDoc` gains a Drive file id and link
beside `s3_key`, as a string pointer, because the two tables sit in different apps.

**What a Drive read costs.** A walk is one `files.list` call per folder per page
of 100 files, and it transfers no document. Indexing is one download or export per
changed document. A rate-limit answer is retried up to five times
(`app/services/workspace/api_retry.rb#MAX_RETRIES`).
Google's quota figures are not in this repo and have not been measured.

**No Drive call at request time.** The endpoints of section 3 read the index and
the R2 text. Only the two jobs call Google, which keeps principle 2 of
[`asset-library-plan.md`](asset-library-plan.md).

**Facts trace back.** A fact whose source is a Drive file id must name a row in
the index. When that row's SHA-256 changes, the facts that cite it are listed for
re-review; none is changed automatically.

**Egnyte later.** `egnyte` is already a source kind; its walker fills the same rows.

## 7. The two mirrors

| | Memory mirror | Local convenience copy |
|---|---|---|
| Direction | Laptop to Drive, one way | Drive to laptop, one way |
| What | The provider memory directories ([`memory.md`](memory.md)) | The text of one shelf, by the caller's access |
| Where | `memory-mirror/<machine>/<provider>/` on the hub's shelf | A directory outside every repo (decision 6) |
| When | Nightly, from the laptop: memory files exist only there | On request; optional |
| Token | `drive_mirror` | An admin session through the text endpoint |
| Loads into a session | Never: `memory-mirror/` is outside every walked root (section 4) | Never by itself; a session opens a file by path |

The mirror skips a file that reads as a credential and names it in its output. It
updates a file in place by the Drive id it recorded, so a night adds no duplicates.
Both copies stay out of git.

**The credential screen is not a privacy screen.** A memory file can hold private
business notes: a counterparty, a negotiating position, a figure. The screen does
not catch those. Whatever the mirror sends, every member of the hub's shelf drive
can read (decision 7).

## 8. Untrusted text

A Drive document can be written by anyone a member shares with. Its body, its
title and its file name are data, never instructions.

| Handling | What |
|---|---|
| **Indexed** | Drive's own metadata, the SHA-256, the category folder name. A title is stored and returned as a JSON field, length-capped, never interpolated into a prompt or a command |
| **Loaded into context** | Nothing, automatically. No hook, session start or claim loads Drive-derived text. Only tiers 1 and 5 load by themselves, and both are tracked files that passed review |
| **Read on request** | Document text, by id, by a session whose task names the topic. `bin/knowledge read <id>` prints it inside a labelled block that names the source and says the content is data |
| **Only pointed at** | A `withheld` document, an `aware` document, a binary with no text, and any original a pointer fact names |

- **The server reads the session, not the text.** A document can at most spend the
  capabilities of the session that read it, for that task's life. No text raises a
  tier or widens an access map.
- **The client class gets no tier 3 or tier 4 content**, so an outsider cannot
  draw it out through a client-facing soul.
- **Nothing rises without a person.** A summary is written by a session and read
  at review; a dream is signed off by Alex; the ship-time proposer copies no note
  text into a draft ([`dream.md`](../modules/dream.md)).
- **What this does not stop, studio:** a studio session that read a poisoned
  document recording a wrong ordinary fact inside its own task. The source
  pointer, the supersede history and the re-review list are the guard.
- **What this does not stop, admin:** an admin session that reads a poisoned
  original. An admin session has no task scope, so the text can spend any admin
  capability until the session ends: a sensitive fact, a deploy, a rotation. The
  guards are thin: the read is by id and logged, and each privileged act still
  files its own receipt. An admin session reads document text only when its job
  needs that document.

## 9. Build pieces

Proposed, not filed. Each is a future task title with its repo, in order.

| # | Title | Repo | After |
|---|---|---|---|
| 1 | Drive Tokens Narrow By Purpose | mcritchie-studio | — |
| 2 | Source Documents Gain A Digest | mcritchie-studio | — |
| 3 | Drive Indexer Extracts And Screens | mcritchie-studio | 1, 2, and the knowledge bucket |
| 4 | Knowledge Walk Runs Nightly (and refuses a drive root as a source) | mcritchie-studio | 3 |
| 5 | Source Document Capability Endpoints | mcritchie-studio | 2 |
| 6 | Facts Cite Indexed Originals | mcritchie-studio | 5, and facts live |
| 7 | Knowledge Browser Points At Drive | studio-engine | 5 |
| 8 | Capture Files Originals To Drive | mcritchie-studio | 4, and the owner taps |
| 9 | Memory Mirror Nightly To Drive | mcritchie-studio | 1 |
| 10 | Local Knowledge Copy Command | mcritchie-studio | 5 |
| 11 | Map Carries Specialized Topic Index | mcritchie-studio | — |
| 12 | One Service Account Per Workspace | mcritchie-studio | 4 |
| 13 | Import Facts File Into Records | mcritchie-industries | 6 |
| 14 | Egnyte Walker Behind Same Reader | mcritchie-studio | 4, and an Egnyte credential |

Piece 8 rewrites step 5 of [`knowledge-capture.md`](../modules/knowledge-capture.md),
which files an original to a private bucket and a repo-side copy; the contact step
in [`contact-capture.md`](../modules/contact-capture.md) is unchanged.

**Owner actions.** No agent can do these; the delegation key cannot create a
shared drive or manage its members.

1. In each Workspace, in Google Drive under Shared drives, create one shared drive
   named `<Workspace> Knowledge`.
2. In that drive's Manage members, add `team@<domain>` as Contributor.
3. In the drive, create four folders: `inbox`, `originals`, `documents`, `notes`.
   Do not create `memory-mirror`; the app creates it.
4. Give Steffon the ids of `originals`, `documents` and `notes`, out of band. He
   registers each with `workspace:add_source`.
5. For a Workspace with no delegation yet, a super-admin adds the key's client id
   and the four scopes in the Admin console under Security, API controls,
   Domain-wide delegation ([`workspace-provision`](../agents/steffon/sops/workspace-provision.md)).
6. For facts to go live: approve Steffon setting the three
   `ACTIVE_RECORD_ENCRYPTION_*` values on production and QA
   ([`credentials.md`](../modules/credentials.md)).

Steffon provisions the knowledge bucket with his `bucket-provision` SOP before
piece 3; that needs no tap from Alex.

## 10. Decisions for Alex

1. **A new shelf drive, or the shared drives that exist?** (a) One new dedicated
   drive per Workspace. (b) Register the existing drives as sources.
   **Recommended: (a).** The tree and the membership are set once for agents; an
   existing drive can be added later as a further read-only source.
2. **One key, or one per Workspace?** (a) Keep the one key
   `workspace-provision` describes. (b) One service account per Workspace domain.
   **Recommended: (b)**, built after the nightly walk runs, so nothing waits on it.
3. **Does Commercial Welding go on Drive before its compliance question is
   answered?** [`asset-library-plan.md`](asset-library-plan.md) records that tier
   as open. (a) Register it now. (b) Register it last. **Recommended: (b).** The
   walker is per source, so nothing else waits, and an Egnyte answer makes it an
   `egnyte` source behind the same rows.
4. **May a studio session read document text?** (a) Yes, when the access map gives
   its soul `full`; the default is `none`. (b) Admin only. **Recommended: (a).** A
   builder filling a form needs the text, and the map is set per document.
5. **How does an admin session read an original that holds identity data?**
   (a) Link only: it gets the Drive link and a person opens it. The cost: an agent
   cannot fill a form field that needs the value, so a person types it, and this
   is narrower than "readable by an admin session on request". (b) Text, logged
   as break-glass. The cost: the identity value enters the admin session's
   context and its transcript on disk, and is sent to the model provider. No rule
   can undo that, and the same read is the admin injection path of section 8.
   **Recommended: (a).** A form needs few such values, and a person typing one
   costs less than an identity value in a transcript.
6. **Where does the local copy live?** (a) Under `/Users/alex/projects/.agents/`,
   outside every repo. (b) Inside a repo, gitignored. **Recommended: (a).** A file
   outside a repo cannot be committed by a mistaken `git add`.
7. **Does the memory mirror send every memory file?** (a) Every file, minus any
   that reads as a credential. The cost: private business notes in memory go to
   the shelf drive, and every member of that drive can read them. (b) Only files
   a session marks. The cost: an unmarked file is lost with the laptop, marking
   depends on a session remembering, and a marked file is screened no better.
   **Recommended: (a), on one condition:** the hub's shelf drive has no member but
   Alex and `team@` while it holds the mirror. With more members, choose (b).
8. **Who writes a document's summary?** (a) A session at triage, read at review.
   (b) A model inside the indexer. **Recommended: (a).** A model that reads every
   walked document unattended is the injection path section 8 closes.
