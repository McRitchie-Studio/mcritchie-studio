# Credential Filing SOP (Steffon)

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
op item create --category "API Credential" --vault <vault> \
  --title "<service>.<entity>.<lane>" \
  --url "https://<the service's dashboard>" \
  "credential[concealed]=$VALUE" \
  "username[text]=<account email>" \
  "authorization-id[text]=<lane/key id, if the provider has one>" \
  "used-by[text]=<one line: which sessions/apps consume it, via which env var>" \
  "notesPlain=scope: <the provider-enforced scope>
CAN: <the acts the scope permits, one line>
CANNOT: <the acts the scope refuses, one line>
<any SOP-only prohibition the platform cannot enforce, stated as such>"
```

- **`--url` is required.** It is what makes 1Password render the brand
  logo, and the logo is what makes a vault legible at a glance. No generic
  `</>` icons.
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

`op` reads exactly ONE variable — `OP_SERVICE_ACCOUNT_TOKEN`
(`bin/lib/op_vaults.rb`; its `LANES` model knows only agent + deployer, and
the lane tokens below are plain exports it has never heard of). Sourcing
`~/.zprofile.admin` puts them in the environment under names `op` never
looks at, so the lane does nothing until you ASSIGN it:

```bash
source ~/.zprofile.admin
export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"        # admin lane
# or: export OP_SERVICE_ACCOUNT_TOKEN="$OP_APPLICATIONS_SERVICE_ACCOUNT_TOKEN"
```

| Lane (assign it as above) | Can write |
|---------------------------|-----------|
| `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` | every vault, `studio-agents-admin` included (read+write since 2026-09-02) — the default writer for this SOP |
| `OP_APPLICATIONS_SERVICE_ACCOUNT_TOKEN` | `studio-applications` |
| ambient `OP_SERVICE_ACCOUNT_TOKEN` (day-to-day agent, `~/.zprofile`) | nothing — read-only lane |

On a `(101) You do not have permission`, in order: first check the
account-wide 1Password quota — `op service-account ratelimit` — because the
daily cap is shared by EVERY lane and a spent quota refuses exactly like a
missing grant; then confirm the assignment above actually ran (`(101)` under
the ambient agent token is this SOP's most common failure); then switch
lanes. Escalate to Mr. McRitchie only when no lane has the grant, naming the
vault and the missing grant.

## 5. Operator-supplied secrets never touch chat

A secret that starts in Mr. McRitchie's hands (a fresh service-account
token, a console-only key) must not be pasted into a session transcript —
transcripts are durable. Hand him this three-step for HIS terminal:

```bash
read -rs T       # he pastes the secret, screen stays blank (-r: a backslash
                 # in the token survives; without it read corrupts silently)
# then the apply command, interpolating $T where the value goes
unset T          # the shell forgets the secret once applied
```

The apply command still passes `$T` through argv (see step 3's note); the
protections here are against the durable copies — transcript and shell
history hold the literal `$T`, never the value.

For the reverse direction (a value he must paste into a UI), put it on his
clipboard — `printf '%s' "$VALUE" | pbcopy` — and clear the clipboard after
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

   For an operator-supplied secret the agent never held, Mr. McRitchie runs
   the same digest pair in HIS terminal, or simply reopens the item in the
   1Password UI and eyeballs it. `--reveal` piped straight to a digest never
   lands plaintext in a transcript; `--reveal` alone does — that is the line.
2. **Proof by refusal**: where the design says a lane must NOT reach the
   item, run that read and confirm it fails. A wall nobody has probed is a
   hope, not a wall.
3. **Census in the same pass**: add or update the item's row in
   [`credential-inventory.md`](../../../modules/credential-inventory.md)
   (and the rotation recipe in
   [`secrets-rotation.md`](../../../system/secrets-rotation.md) if the
   credential rotates). The inventory is the census; this SOP is the
   procedure — keep both true.
