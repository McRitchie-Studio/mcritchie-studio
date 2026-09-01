# Admin Signing Console — v2 (keyless coordinator)

## 🧊 ON ICE — decided by Mr. McRitchie, 2026-08-31

**Frozen, not removed.** Everything below still works and still ships. Nothing
here is deprecated, nothing is scheduled for deletion, and the earlier plan to
move the console to turf-monster is **cancelled, not pending** — see
[`agents/system/app-templates.md`](agents/system/app-templates.md). His words:
*"if it comes up for a purpose we can pick it up then."* So: stop investing in
it, and do not "finish" it.

**Why it went on ice.** Three facts that only mattered together:

1. **It has no unique job.** It supports exactly two instructions, `initialize`
   and `update_signers`, and **both already have another path**. Mainnet
   `initialize` runs from `turf-vault/scripts/initialize-mainnet.js` with the CLI
   keypair set to the `INIT_AUTHORITY`. Program upgrades go through the Squads
   2-of-3 upgrade authority (`turf-vault/scripts/squad-upgrade.js`) and never
   touched this console. Contest and treasury operations (`settle_contest`,
   `pause`, `sweep_operator_revenue`) are 2-of-3 **vault signer** operations that
   turf-monster's own flows handle.
2. **It has no users.** Zero signing requests in production. One durable nonce,
   on devnet. Mainnet sits on turf-vault v0.24 awaiting an upgrade window
   (`turf-vault/docs/CURRENT_DEPLOYMENT.md`). It has never been used for
   anything.

   That is **measured, not asserted** — and it is the one premise most likely to
   have changed by the time you read this, so re-run it rather than trusting the
   line above:

   ```bash
   heroku run --exit-code -a mcritchie-studio \
     "bin/rails runner 'puts %(requests=#{SigningRequest.count} nonces=#{DurableNonce.pluck(:cluster).tally})'"
   # 2026-08-31 → requests=0 nonces={"devnet"=>1}
   ```

3. **It has an unfixed control gap**, and the gap is not small. The signer page
   shows the operator an **opaque byte blob**. It signs via
   `phantom.signMessage`, so Phantom's own transaction preview **does not apply**
   — the wallet cannot tell the signer what they are approving. And the
   **Simulate** button proxies through **the same server that built the
   message**, so a compromised builder simulates its own lie. Two signers
   approving the same falsified screen is **one lie signed twice**: multisig
   defends against one signer going rogue, not against a compromised message
   builder. Until a signer can verify the message independently of the server
   that composed it, adding signers adds no assurance.

   **That gap is inherited, not new.** The retired v1 console
   (`Admin::SigningController` + `Signing::Cosigner`, retired 2026-06-02, which
   also held Mason's key server-side) had the identical RPC-proxy shape. v2
   removed the server-held key; it did not close this.

So rather than fix a display gap on a tool with no users and no unique job, the
whole thing is frozen.

**What would take it off ice — check this before assuming the ice is permanent.**
The console's one genuine advantage over the scripts is **multi-signer
coordination**: N wallets signing in **separate browsers**, anchored on a durable
nonce so a half-signed transaction does not expire between signers. No script
does that. So the reviving question is narrow and concrete:

> **Does Squads cover rotating the turf-vault 2-of-3 *signer set* (`update_signers`)?**

Squads holds the program's **upgrade** authority, which is a different thing from
the vault's signer set. If signer rotation turns out **not** to be covered there,
that is a job only this console does, and it comes off ice. **Nobody has
confirmed either way** — this is an open question, not a settled "Squads covers
it," and it should be answered before the next signer-set change, not after.

---

> The whole point of v2: **no signer private key in the repo, env, or server.**
> (v1 partial-signed with a server-held Mason cosigner key — `Admin::SigningController`
> + `Signing::Cosigner`, **retired 2026-06-02**; both files are gone.) The server is
> a pure coordinator: it builds an unsigned transaction, holds only the PUBLIC
> half-signed signatures, never signs, and broadcasts the assembled fully-signed
> tx (which needs no key). Admin-gated → safe on prod.

## What it does

A `SigningRequest` is a Squads-style queue row = one proposed on-chain instruction
+ its status (`awaiting_signatures` → `fully_signed` → `broadcast` / `failed`),
which members have signed, the target program + cluster, and per-signer sign links.

Two signer topologies, one console:

- **single** — one human wallet (e.g. turf-vault `initialize`, signed by the
  `INIT_AUTHORITY`; a Squads multisig can't substitute). Fresh blockhash, no
  coordination. This is the canonical "bring up a new contract" flow.
- **multi** — N wallets signing in **separate browsers/sessions** (e.g.
  `update_signers`, a 2-of-3 rotation: Mr. McRitchie `7ZDJ…` in one browser, Mason
  `Cyt…` in another). Coordinated over a **durable nonce** so a half-signed tx
  doesn't expire (recent blockhashes die in ~90s — too short for two people).

## Code map

| Piece | File |
|---|---|
| Queue model + lifecycle | `app/models/signing_request.rb` |
| Coordinator (keyless) | `app/controllers/admin/signing_requests_controller.rb` |
| Views (queue / new / show / per-signer sign) | `app/views/admin/signing_requests/` |
| Instruction builder (Borsh, PDA, durable nonce) | `app/services/signing/signing_request.rb` |
| Program-agnostic IDL registry | `app/services/signing/idl_registry.rb` + `idl.rb` |
| Keyless signature assembly | `app/services/signing/assembler.rb` |
| Keyless RPC proxy + blockhash/nonce fetch | `app/services/signing/rpc.rb` |

Routes: `/admin/signing_requests` (index/new/create/show) + member `sign`,
`submit_signature`, `broadcast`, `rpc`.

## How a signer signs (no web3.js)

A raw ed25519 signature **over the transaction message bytes IS a valid tx
signature** (proven by `Signing::Assembler`'s round-trip test). So the per-signer
page just: connect Phantom → assert the connected pubkey equals the expected
signer → **Simulate** (RPC proxy, `sigVerify:false`) → `phantom.signMessage(messageBytes)`
→ POST the public signature. The server ed25519-verifies it against the exact
message before storing. When the threshold is met, `Signing::Assembler.assemble`
slots the collected signatures into the unsigned tx and the coordinator broadcasts.

## Correctness gate

`Signing::ArgEncoder` Borsh-encodes against the **pinned IDL** committed under
`config/idl/`. For `update_signers` the encoded bytes are asserted byte-for-byte
against the known-good reference (see `test/services/signing/signing_request_test.rb`).
**Add the same byte-match reference for any new instruction** (e.g. capture the
proven `initialize` bytes during the first devnet run) before trusting it on mainnet.

## Durable nonce — first-class, non-expiring

A recent blockhash expires in ~90s — too short for two people signing in two
browsers (it's exactly what killed turf's first mainnet contest-create,
`BlockhashNotFound`). A **durable nonce** account stores a value that only
changes when a consuming tx lands, so a half-signed tx stays valid **indefinitely**.
The reusable primitives live in **solana-studio** (`Solana::SystemProgram` +
`Solana::NonceAccount`, byte-match tested); the console registers nonce accounts
as **`DurableNonce`** records and the queue/show views render anchored requests
as **⏱ non-expiring** (no 90s countdown).

**Authority:** every nonce-anchored tx must be signed by the nonce **authority**.
For the keyless console pick an authority that is **already one of the tx signers**
(e.g. Mason `CytJS…`, the fee payer) — then it signs the `nonceAdvance` in-wallet
and there is **no server key and no extra signature**. (turf's automated flows
instead use the admin managed-wallet as authority — a bot key, not a human's.)

### Create + register a nonce account (one-time, per cluster)

Rake (fee-payer key read from ENV at **run time only, never stored**; the
ephemeral nonce keypair signs creation once, then the authority controls it):

```bash
SOLANA_NONCE_PAYER_KEY=<base58 secret of a funded payer> \
  bin/rails "signing:create_nonce_account[devnet,CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR,mcritchie-ops]"
```

Pure-no-key alternative — operator's local Solana CLI keypair as payer, then register:

```bash
solana-keygen new -o /tmp/nonce.json --no-bip39-passphrase
solana create-nonce-account /tmp/nonce.json 0.0015 --nonce-authority <AUTHORITY_PUBKEY> --url devnet
bin/rails "signing:register_nonce[devnet,<NONCE_PUBKEY>,<AUTHORITY_PUBKEY>,label]"
```

The "New request" form then offers registered nonces in a dropdown. RPC: set
`SOLANA_DEVNET_RPC_URL` / `SOLANA_MAINNET_RPC_URL` (Helius, key stays server-side)
in `.env` — the console's proxy + blockhash/nonce reads use them.

## Devnet dogfood (the live two-browser proof — operator-run)

1. Create the devnet durable nonce account (above).
2. `/admin/signing_requests/new` → **update_signers** → paste nonce pubkey +
   authority → Build.
3. Open the request; send each signer their **sign link**.
4. Mr. McRitchie opens his link in one browser, Mason in another → each Connects
   Phantom (asserting the right wallet), Simulates (expect `err: null`), Signs.
5. When 2/2 are in, click **Broadcast**; confirm the signature on the explorer.
6. Capture the proven `update_signers` bytes already byte-match-tested; capture an
   `initialize` reference the first time you run it, then promote by switching the
   request cluster to `mainnet`.

## Promote to mainnet

Same code path — the IDL registry already carries the mainnet IDL
(`turf_vault.mainnet.json`). Create a **separate** mainnet durable nonce account,
set `SOLANA_MAINNET_RPC_URL`, and pick `mainnet` in the New-request form.
