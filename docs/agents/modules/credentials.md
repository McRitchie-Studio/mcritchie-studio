# Credentials

Credential docs are split into two layers:

- This file defines how agents may access credentials.
- [`credential-inventory.md`](credential-inventory.md) lists known item names and references without exposing secret values.

## Contract

- Never print secrets into the terminal or transcript.
- Use `/opt/homebrew/bin/op` directly for targeted reads.
- Prefer repo scripts that write or consume secrets without echoing them.
- Do not scan vaults broadly unless Alex explicitly asks.
- Do not edit agent tool permissions or `.claude/settings*.json` to gain credential access.
- If a permission is missing, report the exact vault, item, and operation needed instead of inventing a workaround.

## Personal data in a public repo

**`mcritchie-studio` and its sibling repos are PUBLIC.** Confirm rather than
assume — `gh api repos/<owner>/<repo> --jq .visibility` — because the rule below
only binds for a public one, and the answer is not visible from a working copy.

Before committing a personal email address, phone number, home address, or
anyone's full name **other than the ecosystem's own public identities**, stop and
route it to 1Password instead. It is not a secret in the credential sense, which
is exactly why it slips through: there is nothing to redact, no token to rotate,
and every existing guard is looking for something that looks like a key.

**The trigger is publication, not merge.** A pushed branch on a public repo is
already world-readable, and a force-push does not retract it — the orphaned
commit stays reachable by SHA. So the check belongs BEFORE `git push`, not before
merge, and "we can strip it in a follow-up" is not a remedy.

Already-public identities are fine and need no ceremony: the git author address,
a business domain's own contact, an open-source author's address in a vendored
file. What this rule is about is **third parties who did not choose to be
published** — most often family.

Measured 2026-09-04 (`/tasks/chrome-profile-order-sop`): a config file keyed on
account email carried two family members' personal Gmail addresses into PR #1212.
Neither had ever appeared in the repository before. Review caught it; by then
the branch had been public for roughly forty minutes. The fix was to move the
whole file into 1Password and commit only a `.example` — see
`docs/agents/agents/steffon/sops/chrome-profiles.md`.

## 1Password Service Account

Agent shells use `OP_SERVICE_ACCOUNT_TOKEN` from `~/.zprofile`, installed by:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/setup-1pass-token
```

**Two lanes, two vaults, two tokens.** `bin/lib/op_vaults.rb` is the ONE place
that maps a lane to its vault and token; no other file should name a vault.

| Lane | Vault (default) | Token variable | Loaded where |
|------|-----------------|----------------|--------------|
| `agent` — build, review, merge | `studio-agents` | `OP_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile` — every shell |
| `deployer` — ship, deploy | `studio-agents-admin` | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile.admin` — opt-in |

Install the admin one with `bin/setup-1pass-token --admin`; ship lanes then
`source ~/.zprofile.admin`. It is deliberately NOT auto-loaded, so an ordinary
agent shell cannot MINT an admin credential: the 1Password read is the step that
is structurally blocked. That a shell does not come to HOLD one is a **separate**
mechanism, in `bin/gh-token`: it refuses to cache a deployer token
(`CACHEABLE_IDENTITIES`), checks that before the cache read, and purges any slot
an older version left behind. Both hold today; they are worth naming apart,
because only the first is enforced here. A
machine whose vaults are named differently sets `MCR_OP_VAULT_AGENT` /
`MCR_OP_VAULT_ADMIN` rather than editing any script.

A `bin/gh-token --identity deployer` that fails naming
`OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is the isolation WORKING — do not route around
it by granting the agent token access to the admin vault.

### An admin lane is MEANT to hold admin credentials

Everything above says what an ordinary agent shell **cannot** do. It never says
what the admin lanes **can**, and that omission has a cost: a lane entitled to
admin access reads its own credential failure as a locked door and escalates,
rather than fixing a machine it is entitled to fix.

So state the other half. **`production-deploy` is an admin act**, and the agent
running it holds the `deployer` lane — the admin token and the
`github.mcritchie-admin` identity — exactly as a build lane holds the agent
one. Admin credentials are withheld from **ordinary shells**, not from the admin
lanes.

That makes the decision rule one line: **on an admin lane, an admin credential
that is absent or refused is a SETUP gap on this machine — not a sign that the
lane is closed to you.** WHICH gap decides who closes it, and
`OpVaults#diagnose` already prints the right one rather than guessing:

| State of the machine | Remedy | Whose |
|---|---|---|
| `~/.zprofile.admin` on disk, absent from THIS shell | `source ~/.zprofile.admin`, then retry | **yours** |
| no `~/.zprofile.admin` at all — never provisioned | `bin/setup-1pass-token --admin`, once | **Alex's** — the install reads the token off his clipboard |

The second row is the **only** credential step on either lane that is his
([`token-session.md`](token-session.md) → *The one honest escalation*). Never
reach for it without testing the first. On 2026-08-30 an agent read a deployer
refusal as the never-provisioned case and put a repeated hand-mint chore on
Alex while a production deploy waited; the token had been on disk for two
days and sourcing it worked on the first try. Handing a deploy back to him
because a credential failed is the operator toil `AGENTS.md` forbids.

#### Two ways the CHECK lies

Both were measured on 2026-09-15, after a session read the SOP, measured the
admin token as absent, and reported production blocked. The token was present the
whole time, with the deployer item reading cleanly.

**1. A pipe runs `source` in a subshell.** Every stage of a pipeline is its own
process, so the export lands in a child that exits before the next command reads
it — the token measures ABSENT while being perfectly present:

```bash
source ~/.zprofile.admin 2>&1 | head -3    # ✗ the export dies with the subshell
source ~/.zprofile.admin                   # ✓
[ -n "$OP_ADMIN_SERVICE_ACCOUNT_TOKEN" ] && \
  echo "admin token: set (${#OP_ADMIN_SERVICE_ACCOUNT_TOKEN} chars)"
```

Report a token by LENGTH, never by value — and never probe with
`echo "${VAR:-absent}"`. The `:-` form substitutes only when the variable is
EMPTY, so the one case it is meant to detect is the case that prints the secret.

**2. A bare `op` tests the AGENT lane, whatever you sourced.** `op` takes its
credential from `OP_SERVICE_ACCOUNT_TOKEN` and no other variable, so a direct
read in a shell that HAS sourced `~/.zprofile.admin` still authenticates as the
agent:

```text
$ op item get github.mcritchie-admin --vault studio-agents-admin --fields label=app-id
[ERROR] "studio-agents-admin" isn't a vault in this account.
```

That answer is about the token in hand — not about the vault, and not about your
grant. It is also indistinguishable by text from the same error raised by a
genuinely wrong vault name, which the 2026-09-02 entity-first rename left behind
in code still asking for a bare `agents`. The `bin/` stack never hits this
because `OpVaults.op_env` swaps the lane's token in for the child `op`; do the
same by hand for a direct read:

```bash
OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN" \
  op item get github.mcritchie-admin --vault studio-agents-admin \
  --fields label=app-id >/dev/null && echo "admin vault: readable"
```

### Who spent the quota

The daily read cap is **1,000, account-wide** — shared by every service account
and every lane — so one careless loop stops the whole ecosystem. Every `op`
invocation the `bin/` stack makes is therefore recorded, and the question is a
query rather than an investigation:

```bash
bin/op-reads                 # by calling command, last 24h
bin/op-reads --by context    # by fan-out, when MCR_OP_METER_CONTEXT was exported
bin/op-reads --tail 40       # the raw rows
```

| Piece | What it is |
|---|---|
| `bin/lib/op_meter.rb` | the Ruby half — `OpMeter.popen` wraps the call; `bin/lib/agent_api.rb`, `bin/lib/task_board.rb`, `bin/gh-token` use it |
| `bin/lib/op-meter.sh` | the shell half — `op_metered <bin> <args…>`, sourced by `bin/secret`, `bin/gh-app-git-credential`, `bin/ecosystem-build`, `bin/setup-1pass-token` |
| `<projects>/.agents/op-reads.log` | the append-only log: timestamp, calling command, action, outcome, seam, pid, context |
| `bin/op-reads` | the read-only query |

**New `op` call sites go through the wrapper.** That is the whole contract — a
bare `op` is invisible to the log, and an unattributed read is the defect this
closes. Metering is best-effort in both halves: it never raises, never changes
the child's exit status, and never costs a read of its own, so a consumer's
fallback for an absent or rate-limited `op` is untouched.

⚠️ `op service-account ratelimit` **itself costs a read** — do not poll it.
There is deliberately **no alarm or budget threshold**; once spend is
attributable it is findable.

Verify:

```bash
/opt/homebrew/bin/op whoami
```

Expected user type: `SERVICE_ACCOUNT`.

Default access is the AGENT vault (`studio-agents`). The ADMIN vault (`studio-agents-admin`) is granted to a SEPARATE service account, never added to this one — that separation is what stops a build lane MINTING an admin credential; the 1Password read is the step it blocks, which is narrower than the claim that a build lane can never hold one (see above). Additional vaults should be granted deliberately for a role or task, such as a DevOps-specific vault for AWS credentials.

## GitHub (`gh` / `git`)

> **Operating knowledge — architecture, the two identities, auth recovery,
> symptom→fix, and usage in the workflow — now lives in
> [`source-control.md`](source-control.md).** This section keeps only what is
> 1Password-shaped: the items, their fields, and how to wire them.
>
> **Blocked on a credential right now?** It is yours to fix, not
> Alex's: `eval "$(bin/gh-auth-refresh --export)"`

Since the 2026-07-29 org migration every repo lives under the **McRitchie-Studio**
org, and `git`/`gh` authenticate as one of **two GitHub App** installations
rather than a personal token.

### The items

The two GitHub App items are split across the two vaults — `github.mcritchie-agent` in `studio-agents`, `github.mcritchie-admin` in `studio-agents-admin` — see the two-lane table above. A ship session therefore runs `source ~/.zprofile.admin` BEFORE `export GH_APP_ITEM=github.mcritchie-admin`; without the admin token the deployer read refuses, by design.

| Identity (1Password item) | Lane | Grants |
|---------------------------|------|--------|
| `github.mcritchie-agent` (**default**) | build / review | Contents write + **Pull requests write** + Checks read + Actions write + Workflows write + Administration write + Metadata/Statuses read |
| `github.mcritchie-admin` (`export GH_APP_ITEM=github.mcritchie-admin`) | ship | Contents write + Actions write + Checks read + Secrets write + Administration write + Metadata/Statuses read. **No `pull_requests` grant at all** — the deployer cannot open or merge PRs by design |

Grants above are the installations' live permission sets, read 2026-08-12 from
`GET /app/installations`. Re-read them there rather than trusting this table if a
`not accessible by integration` ever disagrees with it.

Each item carries fields `app-id` and `client-id`. **The private key is the
`.pem` FILE attachment on the item — the concealed `private key` field is NOT
the key.** `bin/gh-app-git-credential` finds it *by suffix*, so no key filename
is baked in to rot at the next rotation.

`GH_APP_ITEM` selects the item (default `github.mcritchie-agent`). That one
export governs **both** legs — the git credential helper and the token broker —
so the two can never disagree about which identity a session is.

### Wiring (global, one time)

**Never point `~/.gitconfig` at a path inside a working tree.** `git checkout`
unlinks and recreates a file whose content differs between two commits, so for a
window the helper DOES NOT EXIST and any git operation needing credentials dies
with `gh-app-git-credential: No such file or directory` — measured four times on
2026-09-10 while the hub primary moved. Install a snapshot outside every working
tree instead, and wire THAT path:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/install-git-credential-helper            # installs, then prints the git config command to run
bin/install-git-credential-helper --check    # what is installed, and whether it is stale
```

The installer copies the helper's whole closure into
`~/.mcritchie/git-credential/versions/<digest>/` and points a stable `current`
symlink at it, so the wired path never moves.

**Install FIRST, then run the command it prints, as printed.** The wired path
points inside `~/.mcritchie/`, which does not exist until the installer creates
it — wiring first would aim github.com at a missing file, and the empty reset
this command preserves means `osxkeychain` will not answer in its place:

```bash
bin/install-git-credential-helper            # creates ~/.mcritchie/... and prints the line below
git config --global --replace-all credential."https://github.com".helper \
  "$HOME/.mcritchie/git-credential/current/bin/gh-app-git-credential" '/gh-app-git-credential$'
```

It is a `--replace-all` carrying a value-pattern, because `[credential "https://github.com"]` already holds TWO
values here — an empty reset, then the in-tree path — and (measured 2026-09-14 on
an isolated copy of `~/.gitconfig`) a plain `git config … helper "<path>"` fails
with *cannot overwrite multiple values with a single value*, while a bare
`--replace-all` succeeds and collapses both, dropping the empty reset that stops
the generic `[credential] helper = osxkeychain` answering github.com. The pattern
matches only this helper's own lines — the in-tree path today, an installed
snapshot on a later run — so the command converges on one value instead of
appending a second. On a machine with one value or none, git adds it. Mechanics
and the reasoning: `bin/lib/credential_helper_install.rb`.

**Re-run the INSTALLER after any change to the helper or anything it reaches** —
`bin/install-git-credential-helper`, and `--check` says when that is due. It
re-prints the wiring command; the wired path itself does not move, so there is
usually nothing to re-wire.

Confirm access with a **real** read/write — not the repo permissions API, which
reflects the *account's* access, not the *token's* grant (this once masked a
read-only token): `gh pr list` for read, a throwaway branch `git push` for write.

**Never print a token.** Report a SHA-256 prefix instead. The full hygiene rules,
the dotted-JWT redaction pattern, and the revoke-and-re-mint procedure are in
[`source-control.md`](source-control.md).

**Historical — the PAT era.** Until 2026-07-29 auth was a fine-grained PAT on
the `amcritchie` personal account (`agent.github`, wired via `gh auth login
--with-token` + `gh auth setup-git`). Fine-grained PATs cannot call the
check-runs API at all — which the CI gates read — so the PAT wiring is retired;
`agent.github` is deprecated pending deletion.

## Fresh Machine

On a wiped machine:

1. Clone `mcritchie-studio`.
2. Run `bin/ecosystem-build` until it stops at the 1Password token step.
3. Copy the service account token to the clipboard.
4. Run `bin/setup-1pass-token`.
5. Re-run `bin/ecosystem-build`.

The full recovery path lives in [`../system/house-burn-down.md`](../system/house-burn-down.md).
