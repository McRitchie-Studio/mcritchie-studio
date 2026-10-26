# Credential Filing SOP (Steffon)
<!-- registry: naming, logos, vault lanes -->

## Status: Active

Every credential that enters the ecosystem — an API key, an OAuth lane, a
service-account token, a wallet — is filed the same way: named by one
convention, wearing the service's logo, carrying its permission matrix in the
notes, and verified by read-back. This SOP is the whole procedure; run it
top to bottom.

## 1. Choose the vault — the consumer decides

| Who consumes it | Vault |
|-----------------|-------|
| Agent sessions, day to day (deploy keys, service APIs) | `<entity>-agents` (`studio-agents`, `industries-agents`, `family-agents`) |
| Provisioning and break-glass acts (transfers, access grants, deployer identities) | `studio-agents-admin` |
| Application runtime and CI (config vars, Actions secrets) | `studio-applications` |

## 2. Name it `<service>.<entity>.<lane>`

Lowercase, dot-separated, three parts:

- **service** — the provider: `heroku`, `aws`, `github`, `resend`, `discord`.
- **entity** — `studio`, `industries`, `family`; an app slug when the
  credential is app-scoped rather than entity-wide.
- **lane** — the vault family it lives in: `agents`, `admin`, `applications`.

Live examples: `heroku.studio.agents` · `heroku.studio.admin` ·
`heroku.studio.applications`. Existing items that predate the convention
(`mcritchie-industries.aws`, `agent.gmail`) are grandfathered — rename one
only when you next touch it, and fix every reference (inventory, docs,
scripts) in the same pass.

## 3. Create the item — logo and permission notes are MANDATORY

```bash
# VALUE carries the secret, and this SOP must assign it before it expands it.
# Read it silently: -s keeps it off the screen, -r keeps a backslash in the
# token intact.
read -rs VALUE
[ -n "$VALUE" ] || { echo "VALUE is unset or empty — refusing to file an empty credential"; exit 1; }

# The secret goes to `op` as a one-field JSON template on stdin (the `-`), never
# as an assignment argument: `ps` shows arguments to every local process, and
# op's own help says so. Only public values ride on the command line.
printf '%s' "$VALUE" |
  ruby -rjson -e 'print JSON.generate("fields" => [{ "id" => "credential", "label" => "credential",
                                                     "type" => "CONCEALED", "value" => STDIN.read }])' |
op item create --category "API Credential" --vault <vault> \
  --title "<service>.<entity>.<lane>" \
  --url "https://<the service's dashboard>" \
  - \
  "username[text]=<account email>" \
  "authorization-id[text]=<lane/key id, if the provider has one>" \
  "used-by[text]=<one line: which sessions/apps consume it, via which env var>" \
  "notesPlain=scope: <the provider-enforced scope>
CAN: <the acts the scope permits, one line>
CANNOT: <the acts the scope refuses, one line>
<any SOP-only prohibition the platform cannot enforce, stated as such>"
```

If `op` rejects the one-field template, start from `op item template get "API Credential"`
(it holds no secret), set its `credential` field the same way, and pipe that. Never fall back
to `credential[concealed]=…` on the command line.

**The pipe is honoured; NO pipe is the trap.** Rehearsed with `op item create --dry-run`
on op 2.34.0 (2026-10-24, fake values): this exact command files the title, the category
and the concealed `credential` from the piped template, and an empty or failed pipe is
refused (`invalid JSON in piped input`), never filed. What makes an empty
"Untitled SecureNote" is `op` getting no pipe at all (stdin a terminal or `/dev/null`):
it then builds the item from the flags alone. So a template piped with `-` and a
`--template <file>` (what [`secrets-rotation.md`](../../../system/secrets-rotation.md)
step 2 uses) are equally right, a template that names its own category must not also get
`--category` (op refuses the pair), and section 6's read-back is what proves the secret
landed. Never `--dry-run` with the real secret: its preview prints the concealed value.

- **`read -rs VALUE` is one way in, not the only one.** When the agent
  generated the credential itself, assign `VALUE` from the command that
  produced it and keep the refusal below it. When Alex McRitchie holds the
  secret, he runs section 5 in HIS terminal and the variable is `$T` — the
  agent never holds that one at all.
- **The refusal is not ceremony.** An unset `VALUE` does not abort the
  command — the shell hands `op` the literal `credential[concealed]=`, a
  well-formed assignment carrying zero bytes, so nothing downstream ever sees a
  missing argument. Whether `op` then files the empty item or rejects it has
  NOT been measured here, because measuring it means writing a throwaway item
  into a real credential vault; the refusal removes the question rather than
  betting on the answer. Guard on the variable being non-empty — `[ -n
  "$VALUE" ]`, or `${VALUE:+set}`, which substitutes the word `set` and never
  the value. Never reach for a DEFAULT: `${VALUE:-absent}` expands the secret
  itself whenever the variable is set, which is every time it matters. Same
  defect and same remedy as `$KEYFILE` in `workspace-provision.md`, fixed at
  `ec8a814b`.
- **`--url` is required.** It is what makes 1Password render the brand
  logo, and the logo is what makes a vault legible at a glance. No generic
  `</>` icons. The exception: a **Secure Note has no URL field**, so drop
  `--url` when the category is `Secure Note` (met minting
  `solana.turf.governance.v2` on 2026-10-14).
- **Notes are a permission matrix, not prose.** `scope`, `CAN`, `CANNOT`,
  plus a line for any SOP-only rule (e.g. Heroku cannot separate app-delete
  from write, so "never delete" is policy — say so in the note).
- **The value rides the command's argv** (`credential[concealed]=$VALUE`), so
  it is readable via `ps` by same-user processes for the life of the call.
  Acceptable on this single-operator machine; stated so the recipe is not
  mistaken for airtight.
- Scope claims must be **measured, not assumed**: probe with a throwaway
  token/act where the provider's docs are vague, and put what you measured
  in the note. (2026-09-02: a Heroku `write-protected` probe created AND
  destroyed an app — that finding is why the note format exists.)

## 4. Activate the writing lane

Filing is **admin work**: the writing lane below is one you are expected to hold,
so an admin token that is absent or refused here is a setup gap on THIS MACHINE,
not a lane closed to you. `source ~/.zprofile.admin` when the file is on disk but
missing from this shell; `bin/setup-1pass-token --admin`, once, when the machine
has no such file at all — only that second one is Alex McRitchie's. Source it
**without a pipe**: a pipeline runs `source` in a subshell, so the token lands in
a child that exits and the lane reads ABSENT while fully present.

`op` reads exactly ONE variable — `OP_SERVICE_ACCOUNT_TOKEN`. Sourcing
`~/.zprofile.admin` puts the lane tokens in the environment under OTHER names,
so a lane does nothing until you ASSIGN it into that one variable.

`LANES` (`bin/lib/op_vaults.rb`) models two lanes and DOES know one of these
names: `LANES[:deployer][:token_env]` is `OP_ADMIN_SERVICE_ACCOUNT_TOKEN`
(:65), which is how `bin/gh-app-git-credential` reaches the admin vault. The
rest — `OP_APPLICATIONS_`, `OP_INDUSTRIES_`, `OP_FAMILY_` — are plain exports
`LANES` has never heard of. An earlier version of this line said that of ALL of
them, which reads as "nothing here is wired up" and is wrong about the one that
is:

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"        # admin lane
# or: export OP_SERVICE_ACCOUNT_TOKEN="$OP_APPLICATIONS_SERVICE_ACCOUNT_TOKEN"
```

| Lane (assign it as above) | Can write |
|---------------------------|-----------|
| `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` | every vault, `studio-agents-admin` included (read+write since 2026-09-02) — the default writer for this SOP |
| `OP_APPLICATIONS_SERVICE_ACCOUNT_TOKEN` | `studio-applications` |
| `OP_INDUSTRIES_SERVICE_ACCOUNT_TOKEN` | `industries-agents` — mapping INFERRED, see below |
| `OP_FAMILY_SERVICE_ACCOUNT_TOKEN` | `family-agents` — mapping INFERRED, see below |
| ambient `OP_SERVICE_ACCOUNT_TOKEN` (day-to-day agent, `~/.zprofile`) | nothing — read-only lane |

The last two rows are recorded from evidence that costs nothing: `~/.zprofile.admin`
exports both token names, and `op vault list` under the admin lane returns both
`industries-agents` and `family-agents`. What is NOT verified is that each token
opens the vault its NAME suggests — confirming that needs a read per token, and the
1Password daily cap is account-wide and shared by every lane, so a census is not
worth spending it on. If you are about to USE one, spend one read first:

```bash
OP_SERVICE_ACCOUNT_TOKEN="$OP_INDUSTRIES_SERVICE_ACCOUNT_TOKEN" op vault list
```

and correct the row if it disagrees. Rows marked INFERRED are a starting point, not
a fact — which is the distinction this SOP exists to keep.

On a `(101) You do not have permission`, in order: first check the
account-wide 1Password quota — `op service-account ratelimit` — because the
daily cap is shared by EVERY lane and a spent quota refuses exactly like a
missing grant; then confirm the assignment above actually ran (`(101)` under
the ambient agent token is this SOP's most common failure); then switch
lanes. If this machine has no `~/.zprofile.admin` at all, the one-time install
is his — `bin/setup-1pass-token --admin` — but check the file's absence before
saying so. Escalate to Alex McRitchie only when no lane has the grant, naming the
vault and the missing grant.

## 5. Operator-supplied secrets: you make the item, Alex McRitchie pastes only the secret

A secret that starts in Alex McRitchie's hands (a bot token, a fresh service-account
token, a console-only key) must not be pasted into a session transcript:
transcripts are durable. Do not hand him a filing script either (Alex McRitchie,
2026-10-15: "No, just make it lol"). The agent does the filing; Alex McRitchie does only
the one step that needs his hands:

1. **You create the item** with sections 2-4 done (vault, name, logo, notes, the
   admin lane), the secret field present and **empty**, and every non-secret
   field filled (ids, URLs, scopes).
2. **Alex McRitchie pastes only the secret** into that field in the 1Password app and
   saves. Tell him the item title, the vault, the field label, and where in the
   provider's console the value is shown. Nothing else is asked of him.
3. **You verify with the provider** (section 6): read the field and pipe it
   straight into the provider's identity call (a Discord bot token into
   `GET /users/@me` must answer with the bot user id the item records), printing
   only the result's id or status, never the value.

Then apply it where it is used from the item itself
(`op read 'op://<vault>/<item>/<field>' | …`), never from a copy.

**Fallback, only when the app is out of reach** (the value must go straight into
a command on his machine), hand him this two-step for HIS terminal:

```bash
read -rs T       # he pastes the secret, screen stays blank (-r: a backslash
                 # in the token survives; without it read corrupts silently)
# then the apply command, interpolating $T where the value goes
```

Keep `T` set until section 6's read-back has digested it. Transcript and history
then hold the literal `$T`, never the value.

For the reverse direction (a value he must paste into a UI), put it on his
clipboard (`printf '%s' "$VALUE" | pbcopy`) and clear the clipboard after
(`pbcopy < /dev/null`).

## 6. Verify, then record

1. **Read-back, by digest — never by plaintext.** Run by whoever held the
   source value. An agent that filed `$VALUE` from a shell variable compares
   digests without printing either side:

   ```bash
   op item get <title> --vault <vault> --fields label=credential --reveal \
     | tr -d '\n' | shasum -a 256
   printf '%s' "$VALUE" | shasum -a 256    # the two digests must match
   ```

   For an operator-supplied secret the agent never held, there is no second
   side to digest, so the agent verifies it with the provider instead
   (section 5, step 3): the item's field piped into the provider's identity
   call answers with the account or bot id the item records. Only on the
   section 5 fallback does Alex McRitchie run the pair in HIS terminal against the
   variable HE has (`$T`, not the agent's `$VALUE`):

   ```bash
   op item get <title> --vault <vault> --fields label=credential --reveal \
     | tr -d '\n' | shasum -a 256
   printf '%s' "$T" | shasum -a 256        # the two digests must match
   unset T                                 # now — not before this check
   ```

   Or he simply reopens the item in the 1Password UI and eyeballs it.
   `--reveal` piped straight to a digest never lands plaintext in a transcript;
   `--reveal` alone does — that is the line.
2. **Proof by refusal**: where the design says a lane must NOT reach the
   item, run that read and confirm it fails. A wall nobody has probed is a
   hope, not a wall.
3. **Census in the same pass**: add or update the item's row in
   [`credential-inventory.md`](../../../modules/credential-inventory.md)
   (and the rotation recipe in
   [`secrets-rotation.md`](../../../system/secrets-rotation.md) if the
   credential rotates). The inventory is the census; this SOP is the
   procedure — keep both true.
