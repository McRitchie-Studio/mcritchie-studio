# Secrets Rotation Runbook

> **When to read this:** A token/key/secret needs to be rotated — scheduled, compromised, or expiring. Each section is a self-contained procedure: where the secret is stored, how to regenerate it at the source, how to push the new value to every consumer, how to verify the rotation succeeded.

> **The PROCEDURE is the `credential-rotation` SOP** — `docs/agents/agents/steffon/sops/credential-rotation.md`. It owns store enumeration, ordering, verification, rollback and the receipt, and it applies to every secret including the ones with no section here. **This file is the per-credential appendix**: what each secret is, where it lives, and how to regenerate it at the source. Run the SOP; reach for the matching section below as an accelerator. Where the two disagree, the SOP wins and the section below gets fixed in the same pass.

The 1Password account is `alex@mcritchie.studio` (account ID `MWOV5OT5BRHATI4EGMN26C5DPA`). There are **six vaults**, not two: `studio-agents` (agent lane), `studio-agents-admin` (ship lane — separate service account, `bin/setup-1pass-token --admin`), `studio-applications` (app runtime and CI), `industries-agents`, `family-agents`, and `Commercial Welding`. Vault choice and the lane that may write each one are [`credential-filing`](../agents/steffon/sops/credential-filing.md) §§1-4. The Heroku fleet is **ten apps**, not two: `mcritchie-studio(-qa)`, `turf-monster-mainnet`, `turf-monster-qa`, `mcritchie-industries(-qa)`, `rolio-prod`, `rolio-qa`, `tax-studio`, `moms-app` — a per-app section below that names only one or two of them is describing that secret's consumers, not the fleet, and the `credential-rotation` SOP's Phase 1 sweeps all ten regardless. After every rotation, re-run `bin/ecosystem-build` so the dev `.env` files refresh from Heroku's new config.

---

## 1Password service account token

**Store:** the macOS dev shell only (`~/.zprofile`, `OP_SERVICE_ACCOUNT_TOKEN`). Never in Heroku — it's the bootstrap secret, not a runtime one.

**Symptoms of rotation needed:** `op vault list` returns 401 / "service account token revoked." Token compromise (committed to a repo, screenshotted, etc.).

**Procedure:**
1. https://start.1password.com → Developer Tools → Service Accounts.
2. Find the existing service account row. Click "Rotate token" (or delete + recreate with read on `studio-agents`). The admin token is a second, separate service account with read on `studio-agents-admin` — rotate it the same way and install it with `bin/setup-1pass-token --admin`.
3. Copy the new `ops_...` token to clipboard.
4. From `~/projects/mcritchie-studio`: `bin/setup-1pass-token`. The script reads from `pbpaste`, validates the prefix, replaces the existing line in `~/.zprofile`, chmods 600, and verifies with `op vault list`.
5. `source ~/.zprofile` (or open a new terminal).

**Verify:** `op vault list` lists `studio-agents`. `bin/ecosystem-build` reaches Phase 4 cleanly.

---

## Heroku API key (`HEROKU_API_KEY`)

**Store:** 1Password item `heroku.studio.agents` in `studio-agents`. Pre-cutover the fleet key is the `legacy-personal-api-key` field (delete it at the app-transfer cutover); after, the lane's `credential` field. `bin/ecosystem-build` Phase 4 reads legacy-first with the same fallback, then writes `~/.zprofile`.

**Symptoms of rotation needed:** `heroku auth:whoami` returns 401. Heroku-side suspicion of compromise.

**Procedure:**
1. Mint the replacement lane (admin profile): `heroku authorizations:create -s identity,read-protected,write-protected -d "heroku.studio.agents" -S` → the `HRKU-...` token.
2. Update 1Password → `heroku.studio.agents` → the active key field (`legacy-personal-api-key` pre-cutover, `credential` after) → paste the new token; update `authorization-id`. Save.
3. Remove the old `HEROKU_API_KEY` line from `~/.zprofile`: `sed -i '' '/HEROKU_API_KEY/d' ~/.zprofile`.
4. Re-run `bin/ecosystem-build` — Phase 4 re-fetches `heroku.studio.agents` from 1P, writes the new key to `~/.zprofile`, and `heroku auth:whoami` against it.
5. Revoke the old token: `heroku authorizations` to list, then `heroku authorizations:revoke <id>` for the old one.

**Verify:** `heroku auth:whoami` returns `alex@mcritchie.studio`. `heroku apps` lists both apps.

---

## Rails `RAILS_MASTER_KEY`

**Store:** Heroku config var on both apps + `config/master.key` (gitignored) locally + 1Password (recommended backup).

**Symptoms of rotation needed:** master key compromise (committed accidentally, leaked from CI logs, etc.). This is the single most disruptive secret to rotate because it decrypts `config/credentials.yml.enc` — rotating it means RE-ENCRYPTING, not replacing. Users are NOT logged out by it on production: `SECRET_KEY_BASE` is a separate Heroku config var on both `mcritchie-studio` and `turf-monster-mainnet` (measured 2026-09-09), and an environment `SECRET_KEY_BASE` is what Rails uses, so the master key cannot reach the session secret there. Off those apps, sessions still survive as long as the procedure below pastes the same plaintext back; regenerate credentials from scratch and `secret_key_base` changes, and then every session and signed URL dies too.

**Procedure (per app — do each Rails app separately):**
1. Edit `config/credentials.yml.enc` with the *current* key: `EDITOR='code --wait' bin/rails credentials:edit`.
2. Save all credentials to a scratch file outside the repo (you'll need to re-add them after rotation).
3. Delete `config/credentials.yml.enc` and `config/master.key`.
4. Regenerate: `EDITOR='code --wait' bin/rails credentials:edit` — Rails creates a fresh `master.key` + empty `credentials.yml.enc`.
5. Paste your scratch-file credentials back into the editor. Save.
6. Capture the new master key: `cat config/master.key`.
7. `heroku config:set RAILS_MASTER_KEY=<new_key> --app mcritchie-studio` (or `--app turf-monster-mainnet`).
8. Update the matching 1Password item (recommended naming: `mcritchie.studio/RAILS_MASTER_KEY`, `turf-monster/RAILS_MASTER_KEY`).
9. Update local `.env`: `sed -i '' '/^RAILS_MASTER_KEY=/d' .env && echo "RAILS_MASTER_KEY=<new_key>" >> .env`.
10. Commit `config/credentials.yml.enc` to the repo. Push.

**Verify:** App boots locally (`bin/rails server`). `heroku logs --tail --app <app>` after a deploy shows no `:secret_key_base` errors. Direct login still works in each app.

**Warning:** Rotating session secrets logs users out unless the old key is kept readable; the hub's procedure is [Hub `SECRET_KEY_BASE`](#hub-secret_key_base). Apps that opt into shared SSO need compatible secrets; Turf Monster currently isolates its money-app cookie and uses direct login.

---

## Hub `SECRET_KEY_BASE`

**Store:** Heroku config on `mcritchie-studio` only. It has no 1Password home. Turf Monster and every other app carry their own key.

**What derives from it, and what a swap does to each** (measured against studio-engine 0.92.0 and Rails 8.1, task [`hub-rotates-secret-key-base`](https://mcritchie.studio/tasks/hub-rotates-secret-key-base)):

| Consumer | At the swap |
|----------|-------------|
| Session cookie and every signed or encrypted cookie | **Survives** while `OLD_SECRET_KEY_BASE` holds the old key (`config/initializers/secret_key_base_rotation.rb`): Rails reads each cookie under the old key and re-writes it under the new key on the visitor's next request. The initializer derives the old key's cookie secrets with SHA256 stated, the digest live cookies are sealed with |
| Board API tokens (`message_verifier("api_auth")`) | **Breaks.** Every outstanding token answers 401. `bin/lib/agent_api.rb` callers drop the cache on a 401 and re-mint; `bin/session-insights` never does, so delete the cache (below). An in-flight `bin/submit` holds its own `AGENT_API_TOKEN`, so swap with no ship or release running |
| Contact-form proof (`message_verifier(:contact_form)`, 1-day TTL) | **Breaks** for a form loaded before the swap: the row saves flagged `no_browser_proof`, and Alex is not notified |
| Active Storage signed ids (`/rails/active_storage/...` URLs, direct-upload ids) | **Breaks** for URLs minted before the swap. The hub renders none in its own views (link previews use the service URL, `blob.url`), so the exposure is an in-flight direct upload |
| `Studio::SessionFingerprint` (`key_generator`, `studio/session-fingerprint`) | Changes once: open tabs read session drift and rehydrate. Nobody is signed out |
| `Studio::Link` magic links and referrals | **Survive.** They are random tokens stored in `studio_links`, not verifier blobs (the MessageVerifier store was retired in engine 0.31.0) |
| Active Record encryption, signed Global IDs, Action Text, `generates_token_for` | Not used by the hub |
| `RAILS_MASTER_KEY` credentials, CSRF tokens (held in the session) | Independent of the key / survive with the session |

Message verifiers are deliberately **not** rotated: the old key is the leaked one, and a verifier rotation would let its holder keep minting board tokens or signed blob ids (sequential, so any file) for the whole window. For the same reason the cookie window is the exposure: while `OLD_SECRET_KEY_BASE` is set, the old key can still forge a session. Close it as soon as active sessions have migrated.

**Procedure.** Three steps, each its own card.

1. **Ship the rotation code** (`hub-rotates-secret-key-base`). With `OLD_SECRET_KEY_BASE` unset it is a no-op.
2. **Swap**, only after step 1 runs in production. The release lane runs it from the hub checkout with `HEROKU_API_KEY` in the environment.

   Before it:
   - `/Users/alex/projects/.agents/bin/release status` shows no release or ship mid-run.
   - `expected_old_prefix` in `config/secret_rotation.yml` names the live key (see **The expected prefix** below).

   ```bash
   /Users/alex/projects/mcritchie-studio/bin/secret-key-base-swap swap
   ```

   The script refuses, changing nothing, unless all of these hold:
   - `SECRET_KEY_BASE` is set, is 128 hex characters, and its SHA-256 starts with `expected_old_prefix`.
   - `OLD_SECRET_KEY_BASE` is unset.
   - The SHA256 rotation code runs on the app: a one-off dyno defines `SecretKeyBaseRotation::HASH_DIGEST_CLASS`.
   - The key it mints is 128 hex characters and differs from the live key.

   It then sets both vars in ONE PATCH (one release, one restart), reads the config back, and exits 0 only when the stored prefixes match. It prints `old=` and `new=`, each a 16-character SHA-256 prefix, and never a key. Keys travel by stdin, never argv. `--help` exits 3 and an unrecognized argument exits 2, both before any Heroku read.

   **Checks**, in order:
   - `heroku releases --app mcritchie-studio -n 1` shows one release setting both vars.
   - Stored: the script's `stored SECRET_KEY_BASE=… OLD_SECRET_KEY_BASE=…` line carries its `new=` and `old=` prefixes.
   - Live: `heroku run --exit-code --app mcritchie-studio -- bin/rails secret_key_base:verify_rotation` prints `runtime=` the `new=` prefix, `old=` the `old=` prefix, `rotations signed=1 encrypted=1`, a `probe digest=SHA256 encrypted=true signed=true; SHA1 control encrypted=false signed=false` line, then `PASS`, and exits 0. Its probe is sealed with the derivation a live request on the old key used (the app's configured key-generator digest), never through `Rails.application.key_generator(old)`, and the SHA1 control must not read.
   - `curl -s -o /dev/null -w '%{http_code}\n' https://mcritchie.studio/up` and `/signin` answer 200 (`/login` is a 301 to `/signin`).
   - Real-cookie proof, which `verify_rotation` approximates but does not replace: before the swap, `curl -c jar.txt https://mcritchie.studio/signin` and unmask the page's `csrf-token` (`pad XOR token`, 32 + 32 bytes); after it, `curl -b jar.txt` the same page. The same unmasked token means the pre-swap session read. A new one means it did not.
   - Board tokens: the cached token now 401s (`curl -s -o /dev/null -w '%{http_code}\n' -H @<(printf 'Authorization: Bearer %s\n' "$(jq -r .token /Users/alex/projects/.agents/atomic-capture/token.json)") https://mcritchie.studio/api/v1/tasks`); then `rm -f /Users/alex/projects/.agents/atomic-capture/token.json` and `/Users/alex/projects/.agents/bin/task show hub-rotates-secret-key-base` succeeds on a fresh mint.
   - Sign-in persists: a browser signed in before the swap loads `https://mcritchie.studio/tasks` without a login (Alex's own session is the check at his next visit).
   - Watch `ErrorLog` and Sentry for 15 minutes for `InvalidSignature` or `InvalidMessage` spikes.

   **Rollback** (symmetric, one PATCH, so sessions written under either key keep reading):

   ```bash
   /Users/alex/projects/mcritchie-studio/bin/secret-key-base-swap rollback
   ```

   It exchanges the two vars. It refuses, changing nothing, unless `OLD_SECRET_KEY_BASE` is set, is 128 hex characters, differs from `SECRET_KEY_BASE`, and has the `expected_old_prefix` SHA-256 prefix. Re-run the checks with the prefixes exchanged. If the app will not boot at all, `heroku releases:rollback --app mcritchie-studio` restores the prior config (old key, no `OLD_SECRET_KEY_BASE`). Sessions written during the window are then lost; everyone from before is fine.
3. **Close the window** (its own card). No code change is needed, since the initializer is a no-op when the var is unset. While the var stays set the old key can still forge a session, so prefer days to weeks.

   ```bash
   jq -n '{OLD_SECRET_KEY_BASE: null}' | curl -sS --fail-with-body -X PATCH \
     -H "Accept: application/vnd.heroku+json; version=3" -H "Content-Type: application/json" \
     -H @<(printf 'Authorization: Bearer %s\n' "$HEROKU_API_KEY") --data-binary @- \
     -o /dev/null -w '%{http_code}\n' https://api.heroku.com/apps/mcritchie-studio/config-vars   # 200
   ```

   The same card sets `expected_old_prefix` to the swap's `new=` prefix. A rollback needs the pre-swap value, so the config changes only once the window is closed.

**The expected prefix.** `config/secret_rotation.yml` holds `expected_old_prefix`: the first 16 hex characters of the SHA-256 of the key a swap retires, which is the live key whenever no window is open. It is a prefix, never a full digest. Two sources give it without printing a key: the `new=` line of the previous swap, and the `runtime=` field of `heroku run --app mcritchie-studio -- bin/rails secret_key_base:verify_rotation`, which the dyno computes from the key it runs on (with the window closed the task exits 1 and still prints the field). Confirm the config against the `runtime=` field before a swap.

**Past rotations:** the dated record is [`../archive/secrets-rotation-2026-10-07.md`](../archive/secrets-rotation-2026-10-07.md).

---

## Managed-wallet encryption key (`MANAGED_WALLET_ENCRYPTION_KEY`)

**Store:** 1Password item `agent.managed_wallet` (field `encryption key`) + Heroku config on `turf-monster-mainnet` + `.env` locally. Shipped as OPSEC-015 (`KeyGenerator`-derived KDF for managed-wallet keypair encryption).

**What it does:** Every managed wallet (`web2_solana_address`) has its Ed25519 secret encrypted at rest with a key derived from `MANAGED_WALLET_ENCRYPTION_KEY` via `ActiveSupport::KeyGenerator`. Rotating the key requires re-encrypting every managed-wallet secret column — a controlled, online operation but disruptive enough to be its own runbook.

**Symptoms of rotation needed:** Suspected key compromise (committed accidentally, leaked from logs). Routine quarterly hygiene tied to the Solana admin-key cadence. A `RAILS_MASTER_KEY` incident alone does NOT require it: in production the v2 key derives from `MANAGED_WALLET_ENCRYPTION_KEY` only, and the KDF salt is a fixed label (`turf-monster managed wallet v2`), not `secret_key_base`. Only legacy untagged rows — none on production since the 2026-05-20 migration — read `secret_key_base`.

**The procedure is Phase 2 of the [`credential-rotation`](../agents/steffon/sops/credential-rotation.md) SOP — and it is gated on a DEPLOY.** The code that makes a rotation possible (`managed-wallet-key-rotation`: the decrypt-only `MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS`, a verified re-seal in `solana:reencrypt_managed_wallets`, and the read-only `solana:verify_managed_wallet_keys`) must be RUNNING on the app before the key is touched. Merged is not deployed. The SOP's Gate 0 proves it on the dyno. Follow that file, not this one; there is deliberately no second copy of the steps here.

**History, so nobody restores the old recipe.** Until 2026-09-09 this section carried a step-by-step rotation, and every load-bearing step of it was fabricated. It set a `MANAGED_WALLET_ENCRYPTION_KEY_NEW` that nothing read, and it called a `managed_wallets:reencrypt` task that did not exist. It verified against a `web2_solana_secret_encrypted` column that does not exist either; the real column is `encrypted_web2_solana_private_key`. The real task of that date skipped every row carrying `v2:`, printed `0 migrated, N already v2, 0 failed`, and exited 0 while every wallet became undecryptable. The variable the code reads now is `…_PREVIOUS` (the retiring key), not `…_NEW`.

**Last rotation:** none. The 2026-05-20 run recorded here was the OPSEC-015 legacy→v2 **migration**, which re-encrypted under the key already in use; the key itself has never been rotated.

**Warning:** If `MANAGED_WALLET_ENCRYPTION_KEY` is lost while the wallets are still in use, every managed wallet becomes unrecoverable. Treat it with the same care as `RAILS_MASTER_KEY` — 1Password + cold backup.

---

## Solana admin key (`SOLANA_ADMIN_KEY`)

**Store:** two different items, because local and production hold DIFFERENT KEYS today.

| Where | Item | Vault | Field label |
|---|---|---|---|
| Local `.env` | none: `bin/ecosystem-build` stopped writing `solana.turf.admin` (`BLSBw8fX…`) on 2026-10-06, and that key was rotated out and archived on 2026-10-09 (see **Solana governance key** below); `SOLANA_ADMIN_KEY` is production-only | — | — |
| `turf-monster-mainnet` + `turf-monster-qa` Heroku config | `agent.xan.solana` (`8K81…`) | `studio-agents-admin` | `private key`, SPACED |

> **Where it lives is measured, not assumed.** This row said `studio-agents-admin`
> from 2026-09-15, but the item stayed in `studio-agents`, which every agent's
> token opens, until 2026-10-09. That day it was copied into the admin vault
> (verified to derive to `8K81…`) and the original archived. A 2026-10-09
> derivation of both apps' Heroku values reads `8K81…`.

> **That split is deliberate and temporary (2026-09-15).** The turf keys were
> refiled entity-first into three agent-readable items — `solana.turf.admin`
> (governance; rotated out 2026-10-09 and replaced by `solana.turf.governance` in
> the admin vault), `solana.turf.system` (server, mainnet) and
> `solana.turf.system.devnet` (server, devnet/QA). Local bringup moved onto the
> first immediately. **Production has NOT moved.** `7auwTL…` read 0 SOL on
> mainnet at 09:12 that day and was funded at 09:20 the same morning (1.0000 SOL
> at `finalized` later that day) — read the balance rather than either number,
> because the cutover turns on whether it is sufficient for SUSTAINED fee
> payment, not merely non-zero, and repointing an underfunded fee payer breaks
> settlement.
> Prod and QA also still SHARE one key until `solana.turf.system.devnet` lands
> on QA. Rotating the key production actually uses means rotating
> `agent.xan.solana`, and that needs `source ~/.zprofile.admin`.

**Symptoms of rotation needed:** Suspected wallet compromise. Routine quarterly hygiene. Adding/removing a multisig signer.

**Procedure.** Run every step that touches 1Password in the admin lane:
`source ~/.zprofile.admin`, then run `op` with
`OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"`. Print public keys
only. The secret is never an argument, so it never lands in shell history or the
process list.

1. **Mint** into a private temp file. Never `-o -`: it prints the secret.
   `--force` is required because `mktemp` has already created the file, and
   without it `solana-keygen` refuses to overwrite it.

   ```bash
   umask 077; f="$(mktemp -t new-admin-key)"
   solana-keygen new --no-bip39-passphrase --silent --force --outfile "$f"
   NEW_PUBKEY="$(solana-keygen pubkey "$f")"; echo "$NEW_PUBKEY"   # public key only
   ```

2. **File it as a NEW item, from a template FILE.** Do not overwrite the
   current item: the old secret can still own SOL, a nonce account, a mint
   authority or a Squads seat, and overwriting it strands them (step 8). Ruby
   converts the keypair to the 88-character base58 secret the env var holds and
   writes it into a `0600` template file, and `op item create --template` reads
   that file. Do not pipe a template into `op item create -`: a piped template
   can be ignored, and `op` then makes an empty "Untitled SecureNote". Never
   fall back to a `field[concealed]=…` argument.

   ```bash
   t="$(mktemp -t new-admin-item)"                  # 0600 under the umask above
   op item template get "API Credential" > "$t"     # holds no secret
   ruby -rjson -e '
     a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
     b = JSON.parse(File.read(ARGV[0])).pack("C*")
     abort "refusing: the keypair file is not 64 bytes" unless b.bytesize == 64
     n = b.unpack1("H*").to_i(16); s = +""
     while n > 0; n, r = n.divmod(58); s.prepend(a[r]); end
     s = "1" * b.bytes.take_while(&:zero?).size + s
     item = JSON.parse(File.read(ARGV[1]))
     (item["fields"] ||= []) << { "id" => "private key", "label" => "private key",
                                  "type" => "CONCEALED", "value" => s }
     File.write(ARGV[1], JSON.generate(item))
   ' "$f" "$t"
   op item create --vault studio-agents-admin --title "<new item title>" \
     --template "$t" "wallet-address[text]=$NEW_PUBKEY" > /dev/null
   rm -P "$t"
   ```

   `> /dev/null` because `op item create` prints the item it made. **Mind the
   field label**: the `solana.turf.*` items in `studio-agents` spell it
   `private-key`; the items in `studio-agents-admin` spell it `private key`,
   with a space.

3. **Prove the filed secret derives the public key.** Run it from a
   turf-monster checkout; it prints a public key and nothing else.

   ```bash
   op item get "<new item title>" --vault studio-agents-admin --fields "label=private key" --reveal \
     | ruby -r ./lib/solana/signer_isolation -e 'puts Solana::SignerIsolation.derive_pubkey($stdin.read)'
   echo "$NEW_PUBKEY"                               # the two must match
   ```

4. **Before rotating**, run the on-chain `update_signers` instruction to swap the new pubkey into `VaultState.signers`. This requires 2-of-3 cosign. **Confirm the signer set for the cluster you are rotating** — this procedure ends on `turf-monster-mainnet` (step 5), so assume mainnet unless you have checked. `turf-vault/docs/CURRENT_DEPLOYMENT.md` records the program ID, upgrade authority, threshold and signer set for each cluster under its own heading — read `## Mainnet`, not `## Devnet`. (`turf-vault/scripts/squad.json`'s `members` is what `scripts/initialize-mainnet.js` builds its `initialize` signer array from; it is a script input and the historical record, not the deployment record.) Verify live truth on-chain before signing: `solana program show <PROGRAM_ID> --url <mainnet-beta|devnet>` for the upgrade authority, then read `VaultState` (`seeds = [b"vault"]` against that program ID) for the signers and threshold. `turf-vault/docs/KEY_ROTATION.md` is a SUPERSEDED plan — read it for background, never as the procedure.
5. **Point the app at the new key**, only after step 4 has landed on chain.
   Note the current release first; it is what a rollback returns to:
   `heroku releases -n 1 --app turf-monster-mainnet`. `heroku config:set` takes
   its values on the command line, so it cannot carry the secret. Use the
   Platform API, which creates a release just as `config:set` does. Set
   `SOLANA_MULTISIG_SIGNERS` in the same request, to the new signer set in slot
   order (public keys). The app's model of the signer set comes from it; left
   alone, the treasury pages go on offering the evicted key as a co-signer.

   ```bash
   SIGNERS="<slot 1>,<slot 2>,<slot 3>"             # public keys only
   umask 077; h="$(mktemp)"
   heroku auth:token | sed 's/^/Authorization: Bearer /' > "$h"
   op item get "<new item title>" --vault studio-agents-admin --fields "label=private key" --reveal \
     | SIGNERS="$SIGNERS" ruby -rjson -e 'print JSON.generate(
         "SOLANA_ADMIN_KEY" => $stdin.read.strip,
         "SOLANA_MULTISIG_SIGNERS" => ENV.fetch("SIGNERS"))' \
     | curl -sS -o /dev/null -w '%{http_code}\n' -X PATCH \
         https://api.heroku.com/apps/turf-monster-mainnet/config-vars \
         -H "Accept: application/vnd.heroku+json; version=3" \
         -H "Content-Type: application/json" \
         -H @"$h" --data-binary @-
   rm -P "$h"
   ```

   The API answers with every config var, secrets included, so the body is
   discarded and only the HTTP status prints; `200` is success. QA's form of
   the same pipe is step 8 of turf-monster's `docs/qa-signing-key-rotation.md`.
6. No local step: `bin/ecosystem-build` writes no `SOLANA_ADMIN_KEY` into a local `.env`.
7. Delete the keypair file, `rm -P "$f"`: it holds the unencrypted secret. "Securely" is not available here: macOS has no `shred`, and `man rm` says `-P` "has no effect". On APFS the guarantee is *unlinked*, not *erased* — so keep the window short and treat the plaintext as exposed if the disk is ever suspect.
8. **Retire the old item last.** Read what the old public key still owns: SOL,
   a nonce account, a mint authority, token accounts, a Squads seat. Move each,
   then archive the item (`op item delete <id> --vault <its vault> --archive`),
   as step 6 of **Solana governance key** below does.
9. **`update_signers` is not the only registration — and since 2026-09-15 this key is on the other one on DEVNET only.** Xan (`8K81…`) WAS a member of both Squads V4 multisigs holding the turf-vault program upgrade authority. Two config ceremonies on 2026-09-15 — devnet 09:41:25 MDT, mainnet 09:46:51-55 MDT, five minutes apart and not one transaction — removed it from **both**; that afternoon devnet Squads transaction #18 **added it back** (14:02:10 MDT), so it is **a seated devnet member and absent on mainnet** (read from each Squad's config transactions at `finalized` 2026-09-16). Re-measured at `finalized` 2026-10-09, after the governance rotation, each cluster reads **threshold 3 of FIVE**, all mask 7, and the two clusters do not carry the same five — mainnet `7auwTL…`/`3Qj4v9…`/`7ZDJ…`/`9gACbz…`/`4bKNSqkr…`, devnet `2eGs8G3w…`/`3Qj4v9…`/`7ZDJ…`/`8K81…`/`4bKNSqkr…`. `turf-vault/scripts/squad.json` still lists the old three and is provenance only. So rotating `SOLANA_ADMIN_KEY` no longer requires a paired Squads rotation on mainnet, and still does on devnet. **Check before assuming either way**: read the live multisig rather than this sentence, because `update_signers` and a Squads config transaction are different authorities and one moving has never implied the other. If the key you are rotating IS seated, the Squads half is a config transaction at https://app.squads.so doing `removeMember(old)` + `addMember(new)` approved by the CLEAN members; the `credential-rotation` SOP's worked example carries the full order and the proofs.
10. There is no second `update_signers`. On the DEPLOYED v0.25.0 `signers` is `[Pubkey; 3]` and the instruction does `vault.signers = new_signers` — a whole-set replace across three fixed slots — so step 4 already evicted the old pubkey in the same transaction. (turf-vault's `accepted` keeps that array at three and appends `signers_ext: [Pubkey; 2]` at offset 1443, read through `all_signers()`; slots 4-5 are never in `VaultState.signers`. That build is not deployed, so this step is still a three-slot replace today.) The only way to hold old and new at once is to evict a third signer for the duration; see the `credential-rotation` SOP's worked example before choosing that.

**Verify:** from a turf-monster checkout, the app's key derives the new public
key, and the line prints a public key only:
`heroku config:get SOLANA_ADMIN_KEY --app turf-monster-mainnet | ruby -r ./lib/solana/signer_isolation -e 'puts Solana::SignerIsolation.derive_pubkey($stdin.read)'`.
`heroku config:get SOLANA_MULTISIG_SIGNERS --app turf-monster-mainnet` equals the
new signer set. A test contest settlement completes successfully (admin signs as `admin`, human cosigns).

---

## Solana governance key (`solana.turf.governance`)

**What it is:** the agent's governance seat on BOTH turf-vault Squads V4
multisigs (the program upgrade authority): `4bKNSqkrKeggSyrds16Ak7rcB4ibvGJ4ZLsKjvQgC3Vk`,
mask 7 on mainnet `4H3fP3ot…` and devnet `7nRuVw3V…`. It is in no `VaultState`
signer set and no Heroku config. `scripts/squad-upgrade.js` signs with it through
the roster in `turf-vault/scripts/lib/squad-clusters.js` (role `governance`).

**Store:** 1Password `solana.turf.governance`, vault `studio-agents-admin`, field
`private key` (SPACED). Only the admin service account opens that vault:
`source ~/.zprofile.admin`, then run `op` with
`OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"`. `squad-upgrade.js`
does that swap itself for an admin-vault seat.

**It replaced `solana.turf.admin` (`BLSBw8fX…`) on 2026-10-09.** That key had sat in
local env files on many desks. The rotation, the reference for the next one:

1. **Read first.** `node scripts/squad-inventory.js` (members, masks, threshold),
   then every proposal on each cluster. Land or cancel any open one. A proposal
   at or below `staleTransactionIndex` can never execute and may be left.
2. **Mint and file.** `solana-keygen new --no-bip39-passphrase --silent --outfile <scratch>`
   with `umask 077`; base58 the 64 bytes in a process; write the item with
   `op item create --vault studio-agents-admin --template <600-mode file>`
   (a piped template is ignored and makes an empty "Untitled SecureNote");
   read it back and check it derives; delete both files. Print the public key only.
3. **One config transaction per cluster**, built by
   `turf-vault/scripts/ceremony/rotate-admin-seat.js`:
   `removeMember(old)` + `addMember(new, mask 7)`, threshold unchanged, created
   and voted by the cluster's clean `system` seat. Dry run by default, `--send`
   arms it, and every later step reads the on-chain actions back first.
4. **Approvals.** Mainnet needs two of Mr. McRitchie's wallets in the Squads
   app. No Squads UI reaches the devnet Squad for his wallets, so devnet's
   approvals come from agent seats; on 2026-10-09, on his instruction, the
   outgoing key cast devnet's third vote (`--allow-outgoing-signer`, devnet
   `--approve` only).
5. **Verify** with `check_squads_rotation` (the `credential-rotation` SOP) on each
   cluster, `node scripts/check-signer-slots.js` (VaultState must not move), and
   `squad-inventory.js` (the autonomy line must read as before: mainnet HANDOFF,
   devnet AUTONOMOUS).
6. **Empty the old key, then archive it.** `scripts/ceremony/sweep-admin-seat.js`
   (SOL) refuses until the old key is out of the multisig, and
   `sweep-admin-tokens.js` (canonical USDC and USDT only) empties and closes its
   token accounts. Both dry runs simulate without a key. Then `op item delete <id> --vault studio-agents --archive`.
   Prove revocation by DERIVATION, not by grepping the address: a grep for a
   public key cannot see a secret. Derive the public key of every keypair-shaped
   value in Heroku config and local `.env*` files, and print names and public
   keys only.

**Emptied 2026-10-09:** on mainnet `BLSBw8…` reads 0 SOL and owns no token
accounts. `sweep-admin-seat.js` moved the SOL, and `sweep-admin-tokens.js` moved
19.841973 USDT and 0.0011 USDC to `7ZDJp7FU…` and closed both accounts, paid by
`4bKNSqkr…`. Both read the key from the 1Password archive without unarchiving
it. About 3.69 devnet SOL remains, which has no value.

---

## Anthropic API key (`ANTHROPIC_API_KEY`)

**Store:** 1Password item `anthropic` + Heroku config on `mcritchie-studio` + `.env` locally.

**Symptoms of rotation needed:** Suspected compromise. Anthropic console shows unusual usage. Quarterly hygiene.

**Procedure:**
1. https://console.anthropic.com → Settings → API Keys → "Create Key" (name it e.g. `mcritchie-studio-2026-Q2`).
2. Copy the `sk-ant-api...` value (only shown once).
3. Update 1Password `anthropic` → field `api key` → paste the new value. Save.
4. `heroku config:set ANTHROPIC_API_KEY=<new_value> --app mcritchie-studio`.
5. Re-run `bin/ecosystem-build`.
6. After 24h of confirmed normal operation, revoke the old key in the Anthropic console.

**Verify:** `bin/rails runner 'require "net/http"; r = Net::HTTP.post(URI("https://api.anthropic.com/v1/messages"), {model: "claude-haiku-4-5-20251001", max_tokens: 10, messages: [{role: "user", content: "ping"}]}.to_json, "x-api-key" => ENV["ANTHROPIC_API_KEY"], "anthropic-version" => "2023-06-01", "content-type" => "application/json"); puts r.code'` returns `200`.

---

## X (Twitter) API credentials

**Store:** 1Password item `agent.turf.x` in `studio-agents` — five concealed fields, read by LABEL: `Bearer Token`, `Consumer Key`, `Consumer Key Secret`, `Access Token`, `Access Token Secret` (labels measured 2026-09-22; values never revealed). Plus `.env` locally. **NOT on Heroku:** re-measured 2026-09-22, `mcritchie-studio` carries none of the five `X_*` vars, so step 4 below is a SET, not a rotation. The older item `x.api` has been absent from the vault since 2026-08-29 — see `credential-inventory.md`.

**Symptoms of rotation needed:** X suspends the app and reissues. Quarterly hygiene.

**The 5 vars:**
- `X_BEARER_TOKEN` — read-only (News intake)
- `X_API_KEY`, `X_API_SECRET` — OAuth 1.0a app credentials (write, for `X::PostMedia`)
- `X_ACCESS_TOKEN`, `X_ACCESS_TOKEN_SECRET` — OAuth 1.0a user credentials (for posting as @turfmonstershow)

**Procedure:**
1. https://developer.x.com/en/portal/projects → the `mcritchie-studio` project → app keys & tokens.
2. For each of the 5 values, click "Regenerate" → copy → save to 1Password `agent.turf.x`, into the field whose LABEL matches (the item has no `api_key`/`api_secret` fields; they are `Consumer Key` / `Consumer Key Secret`).
3. The app MUST have "Read and Write" permission — verify on the User authentication settings page. If not, the post will silently 401.
4. `heroku config:set X_BEARER_TOKEN=... X_API_KEY=... X_API_SECRET=... X_ACCESS_TOKEN=... X_ACCESS_TOKEN_SECRET=... --app mcritchie-studio`.
5. Re-run `bin/ecosystem-build`.

**Verify:** `bin/rails news:intake` succeeds (uses bearer). For write creds, post a test Content via `Content::PostToX` against a draft contest, then delete the tweet.

---

## Higgsfield API credentials (`HIGGSFIELD_API_KEY` + `HIGGSFIELD_API_SECRET`)

**Store:** 1Password item **`higgsfield.studio.agents`** in the `studio-agents`
vault, plus `.env` locally. **No Heroku config** — `mcritchie-studio` carried no
`HIGGSFIELD_*` var at all on 2026-09-20, so there is nothing to push unless that
changes. References:

- `op://studio-agents/higgsfield.studio.agents/api-key` — **one field holding
  both halves**, `<KEY_ID>:<KEY_SECRET>`. Split it on the FIRST colon:
  before → `HIGGSFIELD_API_KEY`, after → `HIGGSFIELD_API_SECRET`.

**Renamed 2026-09-20.** This was `agent.higgesfield` — the legacy inverted
`agent.<service>` form, carrying a misspelling that this runbook used to say was
preserved deliberately. The `credential-filing` SOP grandfathers legacy names but
says to rename one when you next touch it and fix every reference in the same
pass, so the typo had no reason to outlive that pass. The old item is retitled
`agent.higgesfield (RETIRED - use higgsfield.studio.agents)` and carries a pointer
note; its value is kept only as a fallback until the replacement key is proven to
authenticate. **Do not rotate the retired item** — nothing reads it.

**A credential is TWO values, and the console hands them over PRE-JOINED as
one string.** This is the single fact that makes the whole thing confusing, so
take it slowly:

- Higgsfield issues a **key ID** and a **secret**
  ([docs.higgsfield.ai](https://docs.higgsfield.ai/docs/authentication): *"a
  credential consists of two separate values: a key ID and a secret"*).
- The console shows them as **one masked field labelled `api-key`**, whose value
  is literally `<KEY_ID>:<KEY_SECRET>`. The official `higgsfield-js` SDK calls
  this exact form `HF_CREDENTIALS`.
- So **"there is no secret field" is the expected view, not a missing secret.**
  The secret is the half after the colon. On 2026-09-20 that view was read as a
  move to single-key auth; measurement said otherwise, and the pair is intact.
- The API takes them re-joined anyway — `Authorization: Key <id>:<secret>` —
  which is what `app/services/higgsfield/client.rb` already sends, from the two
  env vars. **No code change is needed.** There is no Bearer mode and no
  `api-key:` header alternative
  ([the console's own quick-start](https://open.higgsfield.ai/quick-start) says
  so explicitly).

⚠ **The `api-key` label is a trap** — it names the whole credential here, while
the vendor's own `HF_API_KEY` names only the key ID. Read the value's format
before splitting it, never the label.

**Identify what you are holding by LENGTH, which reveals nothing.** After a
`read -rs T`, run `echo ${#T}`:

| Length | What you are holding |
|--------|----------------------|
| **101** | the full credential, `KEY_ID:SECRET` — one colon, 36 + 1 + 64. This is what the console gives you. |
| **36** | the key ID alone (a UUID) — the secret half is missing |
| **64** | the secret alone (lowercase hex) — the ID half is missing |

Measured 2026-09-20 against both the filed credential and the retired April 2026
key: a 36-character UUID and a 64-character lowercase-hex secret.

`hf-api-key` and `hf-secret` are **legacy header names** the API still accepts,
not field names — earlier versions of step 2 sent readers hunting for them in
the item. Do not.

**Procedure:**

1. Higgsfield Console (`console.higgsfield.ai`, which redirects to
   `open.higgsfield.ai`) → API keys → regenerate.
2. Copy the `api-key` value WHOLE, colon included. `echo ${#T}` should say
   **101**; anything else means you have half of it.
3. Update `higgsfield.studio.agents`. The operator pastes with `read -rs T` and
   never into a session transcript — `credential-filing` SOP §5.
4. Verify by **digest, not plaintext** — `credential-filing` SOP §6.
5. Re-run `bin/ecosystem-build`.

**Verify:** `bin/rails content:assets_agent SLUG=<a-content-slug>` completes
successfully. **As of 2026-09-20 that could not pass**: the account answered
`not_enough_credits` on every media type, which is exactly why a new key was
issued on a new plan. A rotation whose only proof is the 1Password write is
verified only that far — say so rather than recording a green verify.

---

## TikTok credentials (`TIKTOK_CLIENT_KEY/SECRET/REFRESH_TOKEN/OPEN_ID`)

**Store:** the client key and secret in the 1Password item `tiktok.studio.agents` in the `studio-agents` vault (fields `client-key`, `client-secret`) + Heroku config on `mcritchie-studio` + `.env` locally. The refresh token, the open id and the granted scope live in the hub's database (`tiktok_connections`, the token encrypted), written by the sign-in: nobody files them. `TIKTOK_REFRESH_TOKEN` / `TIKTOK_OPEN_ID` are a fallback, read only when no connection is stored; as of 2026-10-08 the item's `refresh-token` and `open-id` fields and production's pair are still filled from the hand-filed sign-in, and are to be retired (below).

**Refresh token rotates roughly every 1 year, but use shortens it.** Watch for `invalid_grant` errors from `Tiktok::OAuthClient`.

**Procedure (client key/secret — app-level, rarely changes):**
1. https://developers.tiktok.com → the sandbox app → regenerate Client Secret.
2. Update the item's `client-key` and `client-secret`.
3. Put both on the production app through `credential-filing`.

**Procedure (refresh token + open_id — user-level, rotates with re-auth):**
1. Visit `https://mcritchie.studio/admin/tiktok/connect` (admin-only).
2. Sign in to TikTok as the sandbox app's target user.
3. The hub stores the connection itself. The page that comes back says it is connected and saved, with the account, the granted scope and the refresh token's expiry day. It shows no token; nothing is copied to 1Password or Heroku.

A refresh token TikTok rotates during a token refresh is saved over the stored one by `Tiktok::OAuthClient`.

**The stored connection depends on the Active Record Encryption keys** (`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT`). Production and QA each hold all three, a different set per app, filed as `active-record-encryption.studio.applications` and `active-record-encryption.studio-qa.applications` (vault `studio-applications`); never copy production's set to QA or the reverse. On an app that lacks them the sign-in refuses before it asks TikTok for anything. Losing or changing those keys makes the stored row unreadable: the server then counts as not connected (it does not fall back to the env pair), and the recovery is to sign in again at `/admin/tiktok/connect`, which replaces the row. These keys are not rotated on a cadence: a forced change (a compromise) loses the stored facts and needs a TikTok sign-in, so it is a recovery event, not a rotation, and an app whose config lost them while its 1Password item is intact gets the same values back ([`credentials.md`](../modules/credentials.md#fact-encryption-keys)).

**The hand-filed pair is retired after the first stored sign-in.** Until then production holds `TIKTOK_REFRESH_TOKEN` and `TIKTOK_OPEN_ID`, and the 1Password item's `refresh-token` and `open-id` are filled. Once a stored sign-in probes clean, remove both from production config and blank the item's `refresh-token` and `open-id` (the `tiktok-draft` SOP, Setup step 6). To drop the stored connection, press Disconnect on the connected page; it says whether the env pair is still set.

The sign-in asks for drafts only. `TIKTOK_SCOPES` widens it; see `docs/topics/content-pipeline.md`, "TikTok API posting". When the sign-in does not connect, the page says why; the fixes are in the `tiktok-draft` SOP's "Setup".

**Verify:** `bin/tiktok-draft --whoami --production` prints the account.

---

## AWS S3 credentials (`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`)

**Store:** Per-app `.env` files + per-app Heroku config + 1Password.

**Procedure:**
1. https://console.aws.amazon.com → IAM → Users → the `studio` user → Security credentials → Create access key.
2. Copy both values.
3. Update 1Password (recommended item name: `aws.studio`).
4. `heroku config:set AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... --app mcritchie-studio` (repeat for `turf-monster-mainnet`).
5. Update each app-local `.env` that uses S3.
6. Re-run `bin/ecosystem-build` (writes to per-app `.env` from Heroku).
7. After 24h of confirmed normal operation, deactivate the old key in IAM.

**Verify:** `bin/rails runner 'puts Studio::S3.list(prefix: "headshots").first(3).inspect'` returns S3 keys without errors.

---

## Google OAuth (`GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET`)

**Store:** Per-app Heroku config + 1Password.

**Procedure:**
1. https://console.cloud.google.com → APIs & Services → Credentials → your OAuth 2.0 Client.
2. Click "Reset Secret" — confirm.
3. Copy the new client secret. (Client ID does NOT change on reset.)
4. Update 1Password.
5. `heroku config:set GOOGLE_CLIENT_SECRET=... --app mcritchie-studio` (and `--app turf-monster-mainnet` if they share — currently they have separate OAuth clients).
6. Re-run `bin/ecosystem-build`.

**Verify:** Sign in via Google on each app.

**Authorized redirect URIs — do not prune this list.** Production and QA share
ONE OAuth client (`GOOGLE_CLIENT_ID` is byte-identical on `mcritchie-studio` and
`mcritchie-studio-qa`), and it carries one URI per deploy target: the apex
callback for production and the `qa.` one for QA. Deleting either ends sign-in on
that target. The callback host is pinned to `APP_HOST`
(`config/initializers/omniauth.rb`), so ALIAS hosts such as `www.` need no entry
and adding one would re-open the mismatch the pinning closed. Full table:
`docs/agents/modules/deployment.md` § McRitchie Studio → Root-Domain Launch.

**Note:** Google OAuth tokens (the access/refresh tokens per user) are NOT rotated as part of this — those live in `users.uid` and re-issue automatically on next sign-in. This procedure rotates only the *app-level* client secret.

---

## Quick reference: the rotation cadence

| Secret | Recommended rotation | Trigger |
|--------|---------------------|---------|
| 1P service token | yearly + on compromise | Hygiene |
| Heroku API key | yearly | Hygiene |
| `RAILS_MASTER_KEY` | **only on compromise** — disruptive (rotates session signing key) | Compromise only |
| `SOLANA_ADMIN_KEY` | quarterly + on suspicion | Pre-mainnet |
| `solana.turf.governance` (Squads seat) | on suspicion; a Squads config transaction per cluster | Exposure |
| Anthropic API key | quarterly | Hygiene |
| X API credentials | yearly | Hygiene |
| Higgsfield | yearly | Hygiene |
| TikTok client secret | yearly | Hygiene |
| TikTok refresh token | on `invalid_grant` (1y default) | Auth error |
| AWS S3 keys | quarterly | Hygiene |
| Google OAuth client secret | yearly | Hygiene |

Add a calendar reminder for the quarterly cycle so this doesn't slip.

---

## Rotation log

The receipt, written by the `credential-rotation` SOP's final phase. One row per
rotated credential. **No values, no digests, no key material** — this repo is
public, and the log records WHAT and WHEN, never what the value is.

| Date (UTC) | 1Password item | Reason | Stores updated | How verified | Old value revoked | Task |
|------------|----------------|--------|----------------|--------------|-------------------|------|
| 2026-10-07 | _(none: `SECRET_KEY_BASE` has no 1Password home; Heroku config is its only store)_ | `tax-studio` shared the hub's `SECRET_KEY_BASE`, so either app could forge or read the other's cookies and message verifiers | Heroku `tax-studio` (release v29); hub key untouched | env digests of `tax-studio` and `mcritchie-studio` now differ; the runtime `secret_key_base` matches the new env value; `/up` 200, `/login` 200; a fleet sweep of 18 apps (env and runtime digests) found no other shared pair | n/a: the old value is the hub's live key, still in service | https://mcritchie.studio/tasks/split-tax-studio-secret-key |
| 2026-10-09 | `solana.turf.governance` (`studio-agents-admin`) replaces `solana.turf.admin` (`studio-agents`, now archived) | `solana.turf.admin` (`BLSBw8fX…`), a seat on both turf-vault Squads, had sat in local env files on many desks | Squads mainnet config tx #6 (executed 16:42:51 UTC by Mr. McRitchie) and devnet #19 (16:48:36 UTC; third vote by the outgoing key on his instruction): `removeMember BLSBw8…` + `addMember 4bKNSqkr…` mask 7, threshold 3; turf-vault roster and `CURRENT_DEPLOYMENT.md` | `check_squads_rotation` PASS on both clusters; `check-signer-slots.js` shows VaultState unchanged; `squad-inventory.js` reads mainnet HANDOFF 2 of 5 and devnet AUTONOMOUS 3 of 5, as before; no Heroku config value (`turf-monster-mainnet`, `turf-monster-qa`) or local `.env*` file (284 scanned) derives to `BLSBw8…` | On chain and in 1Password, yes: off both multisigs; on Mr. McRitchie's rulings its SOL went to `4bKNSqkr…` (0.5) and `7ZDJp7FU…` (the rest), and its USDT and USDC went to `7ZDJp7FU…` with both token accounts closed. It reads 0 SOL with no token accounts; item archived. **Owed in turf-monster:** it was the sign-in wallet of the house account (`turf`, role admin). The seed no longer carries it, and a deployed row that holds it (QA and production rows not read) keeps it until `bin/rails users:clear_rotated_out_wallet` runs on `turf-monster-qa` and `turf-monster-mainnet` (this task's post-deploy hook). Until then, treat this key as able to sign in as that admin | https://mcritchie.studio/tasks/rotate-mainnet-admin-key |
| 2026-10-09 | `agent.xan.solana` moved from `studio-agents` (archived) to `studio-agents-admin`; same value, not rotated | Production's `SOLANA_ADMIN_KEY` (`8K81…`) sat in the vault every agent's token opens | 1Password only; `turf-vault` roster seat `xan` now reads the admin vault with the admin token. No Heroku change: the value is unchanged | the admin copy derives to `8K81…` and every field matches; the default token reads neither the archived original nor the admin copy; a live resolve of all five turf-vault roster seats derives correctly | n/a: the value moved and was not rotated; the agent-readable copy is archived | https://mcritchie.studio/tasks/rotate-mainnet-admin-key |

---

## When this runbook is wrong

If a procedure here doesn't match the current code path (e.g. an env-var name has changed), fix this doc as part of whatever PR introduced the drift. Code is source of truth; this doc is the recovery layer.
