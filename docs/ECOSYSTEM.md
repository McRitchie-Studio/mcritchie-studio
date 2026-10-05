# McRitchie Ecosystem

The two-minute orientation for the McRitchie stack: every live repo, its port and
host, the services behind them, and where to read next. The registries this page
summarises are `config/satellites.yml` (ports, Heroku apps, hosts),
`config/release_repos.yml` (what the release ladder ships) and
`config/qa_environments.yml` (QA copies). When a row here and a registry disagree,
the registry wins; fix the row.

## Apps

Status uses three words: **live** (a product people use), **showcase** (a rebuilt
portfolio app) and **archived** (nothing deploys it). Every app runs on Heroku.

| App | Status | Role | Port | Production | QA |
|-----|--------|------|------|------------|----|
| [`mcritchie-studio`](https://github.com/McRitchie-Studio/mcritchie-studio) | live | Flagship hub: task board and DevOps pipeline, agent registry and activity, SSO source for the satellites, NFL data, news and content pipelines, email broadcasts, recovery scripts, agent docs | 3000 | https://mcritchie.studio | https://qa.mcritchie.studio |
| [`turf-monster`](https://github.com/McRitchie-Studio/turf-monster) | live | Sports pick'em; entries and payouts settle on Solana through `turf-vault` | 3100 | https://turfmonster.media | https://qa.turfmonster.media |
| [`mcritchie-industries`](https://github.com/McRitchie-Studio/mcritchie-industries) | live | Business knowledge base: acquisitions, companies, financials, clients | 3500 | https://www.mcritchie.industries | https://qa.mcritchie.industries |
| [`cyvasse`](https://github.com/McRitchie-Studio/cyvasse) | live | Hex strategy board game | 3600 | https://cyvasse.mcritchie.studio | none |
| [`moms-app`](https://github.com/McRitchie-Studio/moms-app) | live, not showcased | Karen McRitchie's family audiobook and slideshow site | 4400 | https://karenmcritchie.com | none |
| [`dads-app`](https://github.com/McRitchie-Studio/dads-app) | showcase | Photo slideshow of Greig McRitchie | 3700 | https://greigmcritchie.com | none |
| [`prisoners-dilemma`](https://github.com/McRitchie-Studio/prisoners-dilemma) | showcase | Iterated prisoner's dilemma tournament in the browser | 3800 | https://prisoners-dilemma.mcritchie.studio | none |
| [`weekly-lock`](https://github.com/McRitchie-Studio/weekly-lock) | showcase | One confident NFL pick a week | 3900 | https://weekly-lock.mcritchie.studio | none |
| [`rantly`](https://github.com/McRitchie-Studio/rantly) | showcase | Social network with a 140-character minimum | 4000 | https://rantly.mcritchie.studio | none |
| [`portfolio`](https://github.com/McRitchie-Studio/portfolio) | showcase | Alex's portfolio of web apps | 4100 | https://portfolio.mcritchie.studio | none |
| [`10and5`](https://github.com/McRitchie-Studio/10and5) | showcase | Restaurant mystery-shopper platform | 4200 | https://10and5.mcritchie.studio | none |
| [`search-position`](https://github.com/McRitchie-Studio/search-position) | showcase | Google search position checker | 4300 | https://search-position.mcritchie.studio | none |

Archived: `rolio`, `chain-ops`, `tax-studio` and `acquisition-studio`. The first
three keep their port blocks (3300, 3400, 3200) in `config/satellites.yml`, and
the release ladder ships none of them. `mcritchie-industries` succeeds
`acquisition-studio`.

Local desks take ports from each app's hundred-block (the hub's is `3000-3099`):
[`docs/agents/modules/ports-and-processes.md`](agents/modules/ports-and-processes.md).

## Shared code

| Repo | Role | Consumed by |
|------|------|-------------|
| [`studio-engine`](https://github.com/McRitchie-Studio/studio-engine) | Shared Rails engine on RubyGems: passwordless auth and SSO, theme, error logs, email transport, modals, link previews, local review and local inbox | `mcritchie-studio`, `turf-monster`, `mcritchie-industries`, `cyvasse`, `moms-app`, `rantly` |
| [`solana-studio`](https://github.com/McRitchie-Studio/solana-studio) | Ruby Solana client on RubyGems: RPC, keypairs, Borsh, transactions, SPL tokens | `turf-monster` |
| [`turf-vault`](https://github.com/McRitchie-Studio/turf-vault) | Anchor escrow program on Solana with a 2-of-3 signer set, deployed to devnet and mainnet | `turf-monster` |

```text
studio-engine ──> mcritchie-studio · mcritchie-industries · cyvasse · moms-app · rantly
              └─> turf-monster ──> solana-studio
                               └─> turf-vault (devnet + mainnet)
```

`studio-engine` is the base every engine app is built on; the Solana arm bolts on
only for an on-chain app. The decision and its reasoning:
[`docs/agents/system/app-templates.md`](agents/system/app-templates.md).

## Services

| Service | What | Read |
|---------|------|------|
| Hosting | Heroku, one app per repo. The hub deploys through GitHub Actions (`prod-deploy.yml`); Turf Monster through its `bin/deploy`; every other app by git push | [`docs/agents/modules/deployment.md`](agents/modules/deployment.md) |
| Source control and CI | GitHub org `McRitchie-Studio`; GitHub Actions CI in every repo; app code walks `accepted` → `release` → `main` | [`docs/agents/modules/source-control.md`](agents/modules/source-control.md) |
| Object storage | Cloudflare R2 in the Studio's Cloudflare account; `<app>-dev` and `<app>-production` buckets per app | [`docs/agents/modules/object-storage.md`](agents/modules/object-storage.md) |
| Email | Resend, through `Studio::Email.deliver` from `studio-engine`, with a durable outbox per app; local desks capture mail at `/_studio/local_emails` | [`docs/agents/modules/email-operations.md`](agents/modules/email-operations.md) |
| Secrets | 1Password: vault `studio-agents` (agent lane, `OP_SERVICE_ACCOUNT_TOKEN`) and `studio-agents-admin` (ship lane, `OP_ADMIN_SERVICE_ACCOUNT_TOKEN`); `bin/setup-1pass-token` installs a token and `bin/lib/op_vaults.rb` is the map | [`docs/agents/modules/credentials.md`](agents/modules/credentials.md) |
| Solana | `turf-vault` on devnet and mainnet; QA runs on devnet with no real money | `turf-monster/docs/SOLANA.md`, `turf-vault/docs/CURRENT_DEPLOYMENT.md` |

## Where to start

| If you are… | Read first |
|-------------|------------|
| Setting up a fresh Mac | [`bin/ecosystem-build`](../bin/ecosystem-build) and [`docs/agents/system/house-burn-down.md`](agents/system/house-burn-down.md) |
| Starting an agent session | `/Users/alex/projects/AGENTS.md`, then [`docs/agents/start-here.md`](agents/start-here.md) (the full index) |
| Building a task | [`docs/agents/modules/building-sop.md`](agents/modules/building-sop.md) |
| Adding an app | [`docs/agents/agents/steffon/sops/app-deploy-standard.md`](agents/agents/steffon/sops/app-deploy-standard.md), `bin/register-app`, `bin/register-satellite --list`, `studio-engine/docs/NEW_APP_SETUP.md` |
| Working on Solana | `turf-monster/docs/SOLANA.md` and `turf-vault/docs/CURRENT_DEPLOYMENT.md` |
| Working on auth | `studio-engine/docs/USER_CONTRACT.md`, [`docs/topics/auth-and-sso.md`](topics/auth-and-sso.md), `turf-monster/docs/AUTH.md` |

## Recovery in four commands

On a fresh Mac with Homebrew installed:

```bash
git clone https://github.com/McRitchie-Studio/mcritchie-studio.git ~/projects/mcritchie-studio
cd ~/projects/mcritchie-studio
bin/ecosystem-build       # phases 1-3: installs the toolchain, stops at phase 4 for the 1Password token
bin/setup-1pass-token     # paste the token to the clipboard first
bin/ecosystem-build       # phase 4 on: pulls .env from Heroku, clones siblings, boots servers
```

Full protocol: [`docs/agents/system/house-burn-down.md`](agents/system/house-burn-down.md).
