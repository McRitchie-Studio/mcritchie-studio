# Phase 2 — Actions CD for the hub (WIP prep, blocked on operator setup)

The two deploy workflows are drafted in `.github/workflows/qa-deploy.yml` and
`prod-deploy.yml`. This branch is prep only — no PR yet. To finish + ship Phase 2:

## 1. Operator setup (~10 min, admin only)
- Heroku deploy token, in a private terminal:
  `heroku authorizations:create --description github-actions-deploy --short`
- GitHub → repo Settings → Environments:
  - **`qa`** — secret `HEROKU_API_KEY` = token · no protection rules.
  - **`production`** — Required reviewers → add yourself · secret `HEROKU_API_KEY`
    = same token. (If required-reviewers is greyed out on a private/free repo, skip
    it — `workflow_dispatch` still needs a human click, which is the confirm.)
- App names are hardcoded in the workflows: QA `mcritchie-studio-qa`, prod
  `mcritchie-studio` (matches the Heroku remotes).

## 2. Conductor changes (bin/release.rb) — the "trigger + observe" rewrite
- **QA path in `prepare`** (~L2236-2266): stop calling `bin/qa-server deploy` (the
  local Heroku push). The sweep's `gh pr merge` onto `release` already pushes
  `release`, which auto-triggers `qa-deploy.yml`. The conductor's QA duty shrinks
  to proceeding optimistically (open the `release->main` PR on Tier-2 CI green);
  optionally `gh run watch` the qa-deploy run for the log. `bin/qa-server
  run_deploy` (~L460-488) becomes break-glass.
- **Prod path in `deploy_app :git_push_heroku`** (~L3253-3278): replace the local
  `git push <remote> <frozen>:refs/heads/main` with:
  ```
  gh workflow run prod-deploy.yml -f sha=<frozen> -f release_pr=<pr>
  run_id=$(gh run list --workflow=prod-deploy.yml --limit 1 --json databaseId -q '.[0].databaseId')
  gh run watch "$run_id" --exit-status
  ```
  The operator approves the `production` Environment prompt mid-run; `gh run watch`
  blocks until the job (incl. the `/up` smoke) concludes, and its exit status
  drives `deploy_app`'s existing abort. `gate_sop("deploy:#{repo}")` records the
  workflow conclusion instead of the local push.
- **`push_frozen_main`** (~L2637) unchanged — still advances `origin/main` by
  ref-push (the `release->main` formality; prod-deploy reads that SHA).
- `config/release_repos.yml` hub `prod_deploy`: consider a new
  `strategy: github_actions` adapter, or keep `git_push_heroku` and branch on an
  env flag; the mechanic is now the workflow.

## 3. Validation (after setup)
- Merge a trivial PR into `release` → confirm `qa-deploy.yml` fires and QA `/up`
  → 200.
- `gh workflow run prod-deploy.yml -f sha=<current release SHA>` → approve the
  Environment prompt → confirm prod `/up` → 200.
- Then wire the conductor changes and run a full canary through `prepare`/`ship`.

## Design invariants (don't regress)
- prod-deploy is `workflow_dispatch`, **not** `push:[main]` (else the ship's
  `release->main` ref-push self-fires it).
- QA smoke is informational (optimistic); prod smoke is hard-gated.
- Secrets are **Environment**-scoped, not repo-wide — the prod token lives behind
  the reviewer-gated `production` env so a fork PR can't exfiltrate it.
