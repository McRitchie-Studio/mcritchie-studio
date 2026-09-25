# Credential Issues — log it, keep building

## Status: Active

When a credential problem turns up in the middle of other work, **record it in one
private place and keep going.** A weekly pass works the list; you do not stop to
rotate. This SOP owns only the intake — where to log, how, and what never to
write. It stands alone: every command is inline.

It exists because mid-work rotations were derailing builds, and because most of
the credentials involved guard shell accounts where a week's delay costs nothing.
It does **not** replace
[`credential-rotation`](../agents/steffon/sops/credential-rotation.md) — it
decides *when* that SOP runs.

---

## 1. Triage first — does this one wait?

Decide before you log. Two outcomes, and the second is the default.

| Outcome | When | What you do |
|---|---|---|
| **ROTATE NOW** | The credential was actually **exposed**, AND it guards real money, customer data, production signing, or the production deploy — or it was exposed in a **public** place and can run up a bill or take an action (bots scrape public repos within minutes) | Stop and run [`credential-rotation`](../agents/steffon/sops/credential-rotation.md) now. Then log it (§3) as **rotated**, so the weekly pass sees it happened |
| **LOG AND DEFER** | Everything else: a shell or placeholder account; a **latent** risk (code or process that *could* expose a credential but has not); a stale value nobody leaked; **hygiene** (a duplicate or misnamed item, a decoy, a credential in the wrong vault, a key holding a seat it should not) | Log it (§3) and go back to your work |

**Unsure?** If money, customer data, or production is anywhere in the picture,
rotate now. Otherwise log it and say so in your hand-back.

"Exposed" means the value reached a reader it should not have: a commit, a
public page, a log line, a chat transcript, an error message, a screenshot. A
credential that *could* leak but has not is a latent risk — defer it.

---

## 2. Where — GitHub Issues in a private repo

**Repo `McRitchie-Studio/mcritchie-industries` (private), label `credential-issue`.**

The location is decided by what is private and what an agent can write:

| Candidate | Why not |
|---|---|
| A file in `mcritchie-studio` | **The repo is PUBLIC** |
| The task board | **The board is public-read.** `TasksController::PUBLIC_ACTIONS` includes `:index` and `:show` and skips authentication, so a task's title, acceptance, context and notes are readable by anyone. This is not hypothetical: `credential-rotation` records a full production config dump written into a task and rendered on the board on 2026-09-09 |
| 1Password | The ambient agent lane is **read-only**; logging there means escalating a mid-work session to the admin lane for a note |
| **GitHub Issues, private repo** | Private; an agent writes one with no PR cycle; open/closed *is* the weekly queue; the whole review is one command |

**Never log a credential issue on the task board or in this repo.** A task that
fixes a credential problem is fine to create, but its public text must describe
the change, not the exposure. Put the exposure in the issue and link it.

### One-time setup — the operator's, once

The agent's GitHub App cannot read or write issues today (measured 2026-09-18:
`gh issue list` answers `Resource not accessible by integration
(repository.issues)`, matching the App's permission table in
[`source-control.md`](source-control.md)). Until this is done, use §4.

1. GitHub → the org's settings → **GitHub Apps** → `mcritchie-agent` →
   **Permissions & events** → Repository permissions → **Issues: Read and
   write** → Save. Then accept the updated permissions on the org's installation
   (GitHub asks the org owner to approve a permission increase).
2. Create the label (any agent, once the grant lands):

   ```bash
   eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"
   gh label create credential-issue -R McRitchie-Studio/mcritchie-industries \
     --color B60205 --description "Credential problem logged for the weekly pass"
   ```

3. Verify — this must exit 0:

   ```bash
   gh issue list -R McRitchie-Studio/mcritchie-industries --label credential-issue --state all
   ```

---

## 3. Log one

```bash
eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"
gh issue create -R McRitchie-Studio/mcritchie-industries --label credential-issue \
  --title "<1Password item>: <what is wrong, in 4-8 words>" \
  --body-file - <<'BODY'
**Item:** <1Password item name> in <vault>
**Class:** exposure | latent risk | stale | hygiene
**Triage:** deferred to the weekly pass | ROTATED NOW on <date>
**What happened:** <how it was exposed, or why it is a risk>
**Known stores:** <every place you know holds this value — app config, Actions secrets, .env files, other vault items>
**Found by:** <session or task slug>, <date>
BODY
```

`Known stores` is the most useful line you can write: it is the start of
`credential-rotation`'s Phase 1 list, and you know it now while it is fresh.

### Never write into the issue

- **The secret value**, or any prefix or suffix of it long enough to be useful.
- **The output of a command that echoed it** — an error message, a log line, a
  failing test's diff. Describe it; do not paste it.
- A screenshot of a vault, a config page, or a terminal holding it.
- **A digest of it.** A sha256 of a live secret is a confirmation oracle for a
  guessed value — `credential-rotation`: "Digests are for the shell, not for the
  record."

The issue is private, but a private issue is still read by every session that
has the grant, rendered in notifications, and kept forever. Identify a value by
its 1Password item and field name, never by its content.

---

## 4. Until the setup is done

Put the issue in your **chat hand-back** to Alex under a
`🔐 Credential issue to log:` line, with the §3 fields. Not on the board, not in a
commit message, not in a task note. Alex holds it: no later session can
read your chat, so the entry reaches the log only when he hands it to a session
after the grant lands.

---

## 5. Working the list — the handoff seam

The weekly pass is the operator's process, not this SOP's. What it can rely on:

```bash
gh issue list -R McRitchie-Studio/mcritchie-industries --label credential-issue --state open
```

is the whole queue. Each deferred issue is fixed by running
[`credential-rotation`](../agents/steffon/sops/credential-rotation.md) for that
one item — or, for hygiene, by the specific repair it names. Close the issue with
a comment saying what was done: the rotation receipt, or the repair.

---

## What this SOP does NOT do

- **It does not rotate anything.** That is `credential-rotation`.
- **It does not define the weekly pass** — the operator owns that process.
- **It does not clean up records already on the public board.** Where a task's
  public text describes a credential problem, move that detail into an issue once
  the private log exists, and cut the task's public text back to the change being
  made.
- **It does not lower the bar for a real exposure of something that matters.**
  §1's first row is the old rule, "rotate first", kept exactly where it belongs.
