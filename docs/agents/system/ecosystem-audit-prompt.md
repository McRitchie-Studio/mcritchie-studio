# Ecosystem Audit Prompt

Paste the block below into a fresh Claude session (any modern Claude Code session
with Bash + Read tools) to kick off a structural audit of the McRitchie ecosystem.

The prompt deliberately asks Claude to **stop and ask questions first** before
doing the bulk of the audit, so the work is shaped by the operator's priorities
rather than guesses.

---

```
You are doing a structural audit of my 5-repo McRitchie ecosystem. Be heavy,
be thorough, and don't be afraid to recommend big architectural changes — I
want these to be my core long-term apps and they need to grow well.

## What you're auditing

Five repos under ~/projects/ (already cloned on this machine):

| Repo | Role |
|------|------|
| mcritchie-studio | Flagship Rails app (port 3000). SSO hub. NFL/News/Content/Task pipelines. Owns the ecosystem recovery scripts. |
| turf-monster | Rails satellite (port 3100). Sports pick'em with Solana onchain. |
| studio | Shared Rails engine (gem). Auth, SSO, error logging, theme, ImageCache. |
| solana-studio | Ruby gem. Solana RPC + ed25519 + borsh + tx builder. |
| turf-vault | Anchor/Rust smart contract. Onchain escrow for Turf Monster. |

## Where to start reading (do this BEFORE asking questions)

1. mcritchie-studio/README.md — has the canonical recovery flow
2. mcritchie-studio/docs/agents/system/house-burn-down.md — 8-phase recovery protocol + 12 gotchas
3. mcritchie-studio/bin/ecosystem-build — 470-line idempotent installer/verifier
4. mcritchie-studio/bin/setup-1pass-token — pasteboard-based 1P token install
5. mcritchie-studio/CLAUDE.md — big; covers data model, routes, conventions
6. turf-monster/CLAUDE.md — also big; covers Solana flows, contest lifecycle
7. turf-monster/README.md — satellite README
8. studio/lib/studio.rb + studio/app/ — what the engine exposes
9. solana-studio/lib/ — what the gem exposes
10. turf-vault/Anchor.toml + programs/turf-vault/src/lib.rs — the smart contract surface

## Specific concerns to audit

### Build process + recovery
- Is bin/ecosystem-build the right abstraction? Could it be more modular?
  Less brittle? Is the 8-phase split sensible or should phases merge/split?
- The "1Password service token is the bootstrap secret" model — is that the
  right gate, or should we use SSH keys / GitHub App installation tokens /
  something else?
- Are there any prereqs the script silently assumes (PATH order, Xcode CLT,
  brew taps) that would bite a truly fresh Mac?
- bin/setup-1pass-token is macOS-only (uses pbpaste). Should we plan for Linux?

### Cross-app architecture
- The "flagship hub + satellites" model — does it scale to 5 more apps?
  10? Or do we need a different topology (e.g. a meta-repo, a shared
  "platform" gem, a workspace tool like Bazel/Nx)?
- Studio engine is consumed by mcritchie-studio + turf-monster via Gemfile
  git refs. When we add app #3, does that pattern hold or do we need
  release tags + a Gemfury?
- SSO flow goes hub → satellite (one-way). Should auth eventually move to
  a dedicated service rather than living in the hub?
- Solana code is split across solana-studio (gem) and Solana::* classes
  in turf-monster (app-local). Where's the right line? Should more move
  to the gem?

### Naming consistency (look for the same concept named differently)
Known examples to start from — find more:
- `web2_solana_address` (managed wallet) vs `web3_solana_address` (Phantom).
  Not self-explanatory. What would a new contributor guess these mean?
- `Solana::Client` (the class) vs `SolanaStudio` (the gem). Which is the
  brand? Are there places still calling it `SolanaStudio::Client`?
- `agent.solana` (1Password item) → `SOLANA_ADMIN_KEY` (env var) →
  `Solana::Vault.admin_keypair` (Ruby). Three names for the same thing.
- `bin/setup-1pass-token` vs `bin/ecosystem-build` — what's the verb
  convention? Should there be a `bin/<verb>-<noun>` standard?
- `MOCK_PUBKEY_B58` (e2e mock) vs `alex.update!(web3_solana_address: ...)`
  in seed.rb that overrides to the same value. Tracking that mapping is
  non-obvious.
- Across the two Rails apps: do tasks/news/contests use consistent stage
  vocabulary? (e.g. is "open" used to mean the same thing everywhere?)

### Test infrastructure
- Two Rails apps + Anchor program. Three test frameworks (minitest +
  Playwright + ts-mocha). Any shared patterns worth extracting?
- The turf-monster test_solana_stubs.rb initializer is a recent addition.
  Should similar test stubs exist in mcritchie-studio? Pattern for app-
  level stubs in test env?
- Playwright e2e has @devnet tests that need SOLANA_BOT_KEY. There's no
  CI running them today. Is that acceptable? If we add CI, what's the
  shape?
- mcritchie-studio has 504 tests, turf-monster 97. Coverage feels uneven
  — is that real or are turf-monster's tests under-developed?

### Documentation + agentic context
This is high priority. I want each fresh Claude session to onboard fast.
- CLAUDE.md in mcritchie-studio is ~27k tokens. Token-budget-aware?
  Should it split into focused files that load on demand?
- turf-monster has docs/AUTH.md, SOLANA.md, FORMULAS.md, UI_PATTERNS.md
  — a topic-file pattern. Is mcritchie-studio missing that structure?
- The /docs route renders agent docs. Is the same pattern in turf-monster?
- Memory system at ~/.claude/projects/-Users-alex-projects/memory/ —
  read MEMORY.md and the individual memory files. Are they being
  written well? Used well? Missing entries?
- Per-app CLAUDE.md vs ecosystem-wide context — is there an
  "ecosystem CLAUDE.md" that lives anywhere? Should there be?
- The recovery doc is in mcritchie-studio. Should it be in its own
  meta-repo so it survives if the flagship is rewritten?
- README.md vs CLAUDE.md vs docs/ — what's the bright line? Is it
  consistent across both apps?

### Scalability + future-proofing
- If we add tax-studio (planned, port 3003), apartments_studio, etc.,
  what breaks? What needs to be generalized first?
- The mcritchie-studio flagship pattern: every new app needs SSO links
  added to the hub's navbar. Manual. Should this be data-driven?
- Heroku-as-deploy is baked into a lot of docs. If we move to Fly/Render
  later, what would need to change?

## How to work with me

1. **Read first, ask second.** Spend ~20-30 min reading the files above
   and noting what you find. Don't ask questions until you've actually
   read CLAUDE.md, house-burn-down.md, and bin/ecosystem-build end-to-
   end. Trust-but-verify everything you read against actual code/state.

2. **Then come back with 5-10 questions.** Specific, materially-shaping
   questions — not "what do you want me to focus on?" but things like
   "I see X and Y use different conventions; which is the source of
   truth, or should both move to Z?". Group questions by section
   (build / architecture / naming / tests / docs).

3. **After I answer, deliver the audit in tiers.** I want quick wins
   AND a structural roadmap. Output something like:
   - **Tier 1 — Quick wins** (renames, small refactors, doc fixes
     I can ship today)
   - **Tier 2 — Cleanup projects** (1-3 day efforts: e.g. extract
     more into solana-studio, normalize stage vocabulary)
   - **Tier 3 — Architectural moves** (week+ efforts: e.g. introduce
     a platform gem, swap deploy target, restructure docs)
   For each, give: the concrete change, why it matters, the cost,
   and the risk if we DON'T do it.

4. **Don't make changes during the audit phase.** Read-only until
   I approve a plan. If you really want to commit something, propose
   it and wait.

5. **Treat agentic context as a first-class concern.** Anything that
   makes future Claude sessions slower, more error-prone, or more
   redundant is a real problem. Specifically inspect:
   - Memory files at ~/.claude/projects/-Users-alex-projects/memory/
   - All CLAUDE.md files
   - Cross-references between docs
   - The /docs route's discoverability

6. **Suggest big changes freely.** I want these apps to be my core
   long-term stack. If you think the SSO hub model needs to die, say
   so and tell me what should replace it. If CLAUDE.md should be
   nuked and reborn as 12 topic files, say that. I will push back if
   I disagree — just give me your honest read.

## Deliverable

A single audit document (markdown, can be long) saved to
mcritchie-studio/docs/agents/system/ecosystem-audit-{date}.md with:
- Executive summary (3-5 bullets — what's healthy, what's not, what's
  the top recommendation)
- Findings organized by concern (build, architecture, naming, tests,
  docs, scalability)
- Tier 1/2/3 recommendation list
- An "agentic context" section calling out what makes onboarding a
  fresh Claude session slow or error-prone, with specific fixes
- A "no-regrets renames" section listing variable/method/file
  rename pairs I could apply via sed if I wanted

Begin by reading the files listed above. Then come back with your
questions before doing the bulk of the audit.
```

---

## How to use this prompt

1. Open a fresh Claude Code session (any directory works — the prompt
   tells Claude to operate on `~/projects/`).
2. Paste the block above.
3. Claude will spend 20-30 min reading, then come back with questions.
4. Answer the questions (the doc Claude produces will be only as good
   as your answers — be honest about priorities).
5. Claude delivers the audit doc.
6. You decide what to ship.

## When to re-run this audit

Worth re-running:
- Every time you add a new app to the ecosystem (so the audit catches
  drift before it calcifies).
- Quarterly, if no new apps were added (slow drift still happens).
- Anytime you feel a fresh Claude session is "slow to onboard" — that's
  usually a signal that the docs/agentic-context layer needs another pass.
