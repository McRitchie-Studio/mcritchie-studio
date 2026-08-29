# Credentials

Credential docs are split into two layers:

- This file defines how agents may access credentials.
- [`credential-inventory.md`](credential-inventory.md) lists known item names and references without exposing secret values.

## Contract

- Never print secrets into the terminal or transcript.
- Use `/opt/homebrew/bin/op` directly for targeted reads.
- Prefer repo scripts that write or consume secrets without echoing them.
- Do not scan vaults broadly unless Mr. McRitchie explicitly asks.
- Do not edit agent tool permissions or `.claude/settings*.json` to gain credential access.
- If a permission is missing, report the exact vault, item, and operation needed instead of inventing a workaround.

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
| `agent` — build, review, merge | `agents-studio` | `OP_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile` — every shell |
| `deployer` — ship, deploy | `agents-admin` | `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` | `~/.zprofile.admin` — opt-in |

Install the admin one with `bin/setup-1pass-token --admin`; ship lanes then
`source ~/.zprofile.admin`. It is deliberately NOT auto-loaded, so an ordinary
agent shell cannot MINT an admin credential: the 1Password read is the step that
is structurally blocked. It is **not** the wider claim that such a shell can never
come to hold a deployer token — `bin/gh-token` serves an already-minted one from a
50-minute cache, and `/tasks/never-cache-deployer-token` closes that window. A
machine whose vaults are named differently sets `MCR_OP_VAULT_AGENT` /
`MCR_OP_VAULT_ADMIN` rather than editing any script.

A `bin/gh-token --identity deployer` that fails naming
`OP_ADMIN_SERVICE_ACCOUNT_TOKEN` is the isolation WORKING — do not route around
it by granting the agent token access to the admin vault.

Verify:

```bash
/opt/homebrew/bin/op whoami
```

Expected user type: `SERVICE_ACCOUNT`.

Default access is the AGENT vault (`agents-studio`). The ADMIN vault (`agents-admin`) is granted to a SEPARATE service account, never added to this one — that separation is what stops a build lane MINTING an admin credential; the 1Password read is the step it blocks, which is narrower than the claim that a build lane can never hold one (see above). Additional vaults should be granted deliberately for a role or task, such as a DevOps-specific vault for AWS credentials.

## GitHub (`gh` / `git`)

> **Operating knowledge — architecture, the two identities, auth recovery,
> symptom→fix, and usage in the workflow — now lives in
> [`source-control.md`](source-control.md).** This section keeps only what is
> 1Password-shaped: the items, their fields, and how to wire them.
>
> **Blocked on a credential right now?** It is yours to fix, not Mr.
> McRitchie's: `eval "$(bin/gh-auth-refresh --export)"`

Since the 2026-07-29 org migration every repo lives under the **McRitchie-Studio**
org, and `git`/`gh` authenticate as one of **two GitHub App** installations
rather than a personal token.

### The items

The two GitHub App items are split across the two vaults — `github.mcritchie-agent` in `agents-studio`, `github.mcritchie-deployer` in `agents-admin` — see the two-lane table above. A ship session therefore runs `source ~/.zprofile.admin` BEFORE `export GH_APP_ITEM=github.mcritchie-deployer`; without the admin token the deployer read refuses, by design.

| Identity (1Password item) | Lane | Grants |
|---------------------------|------|--------|
| `github.mcritchie-agent` (**default**) | build / review | Contents write + **Pull requests write** + Checks read + Actions write + Workflows write + Administration write + Metadata/Statuses read |
| `github.mcritchie-deployer` (`export GH_APP_ITEM=github.mcritchie-deployer`) | ship | Contents write + Actions write + Checks read + Secrets write + Administration write + Metadata/Statuses read. **No `pull_requests` grant at all** — the deployer cannot open or merge PRs by design |

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

```bash
git config --global credential."https://github.com".helper \
  "/Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential"
```

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
