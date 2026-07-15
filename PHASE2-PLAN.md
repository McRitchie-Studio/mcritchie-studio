# Phase 2 — Actions CD for the hub

DevOps v2 Phase 2 moves the **hub's deploy MECHANIC** off the laptop into GitHub
Actions. Hub-only — rolio + turf-monster deploy exactly as before. The conductor
FLOW is unchanged (sweep → wait-for-QA-boot → flip assembled on green; ship gate →
deploy → smoke); only the deploy mechanic moved. (The flow/optimistic-QA changes
are Phase 3, not here.)

**Status:** env wiring DONE (operator) · conductor DONE (this branch) · remaining
= the first live canary.

## What ships here
- **Workflows** — `.github/workflows/qa-deploy.yml` (`workflow_dispatch`,
  optimistic `/up` smoke) and `prod-deploy.yml` (`workflow_dispatch`, hard `/up`
  smoke, reviewer-gated `production` Environment).
- **Strategy** — `config/release_repos.yml` hub `prod_deploy` is
  `strategy: github_actions` (`workflow: prod-deploy.yml`); the handler is
  registered in `Release::ShipSequence::STRATEGY_HANDLERS`. rolio stays
  `git_push_heroku`, turf stays `repo_script`.
- **Conductor** (`bin/release.rb`) — `dispatch_and_watch` fires a workflow and
  watches it to conclusion (finding its own run by a monotonic-run-id snapshot);
  `prepare`'s QA path dispatches `qa-deploy.yml` for `github_actions` apps
  (`bin/qa-server` otherwise); `deploy_app`'s `:github_actions` branch dispatches
  `prod-deploy.yml` at the frozen SHA. `push_frozen_main` still ref-advances
  `origin/main` (the `release->main` formality — the workflow deploys the SHA it
  is handed, not `origin/main`).

## Operator setup (DONE — kept here for fresh-machine rebuild)
- Heroku deploy token: `heroku authorizations:create --description
  github-actions-deploy --short`.
- GitHub → repo Settings → Environments:
  - **`qa`** — secret `HEROKU_API_KEY` = token · no protection rules.
  - **`production`** — required reviewer (the operator) · secret `HEROKU_API_KEY`
    = same token. That reviewer prompt IS the ship-confirm (it replaced the local
    interactive prompt).
- App names are hardcoded in the workflows: QA `mcritchie-studio-qa`, prod
  `mcritchie-studio` (matches the Heroku remotes).

## Remaining — the first live canary
- Merge a trivial PR into `release`, run `bin/release prepare` → confirm ONE
  `qa-deploy.yml` run fires at the release tip and QA `/up` → 200.
- Run `bin/release ship` → approve the `production` Environment prompt → confirm
  prod `/up` → 200 and the deploy gate records green.

## Design invariants (don't regress)
- Both deploy workflows are `workflow_dispatch`, **not** push-triggered: prod so
  the ship's `release->main` ref-push can't self-fire it; QA so the sweep's N PR
  merges into `release` fire ONE deploy of the final tip, not N.
- QA smoke is informational (optimistic); prod smoke is hard-gated.
- Secrets are **Environment**-scoped, not repo-wide — the prod token lives behind
  the reviewer-gated `production` env so a fork PR can't exfiltrate it.
