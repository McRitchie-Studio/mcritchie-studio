# Start Here — the full index

Every agent doc, by the need it answers. The entry map
([`index.md`](index.md), installed as `AGENTS.md`) links here instead of carrying
this table, so a session loads it only when it goes looking. Every SOP and
heartbeat file on disk has a row, and each soul SOP row is labelled
`<Soul> <invocation> SOP`; `test/docs/start_here_label_guard_test.rb` holds both.

## Start Here

| Need | Read |
|------|------|
| Ecosystem map | `mcritchie-studio/docs/ECOSYSTEM.md` |
| Fresh-machine rebuild | `mcritchie-studio/docs/agents/system/house-burn-down.md` |
| DevOps v3 design (ratified 2026-09-24, landing in phases) | `mcritchie-studio/docs/agents/system/devops-v3-design.md` |
| Ecosystem build script | `mcritchie-studio/docs/agents/system/ecosystem-build.md` |
| Agent culture | `mcritchie-studio/docs/agents/modules/culture.md` |
| Credentials and 1Password | `mcritchie-studio/docs/agents/modules/credentials.md` |
| Credential item names | `mcritchie-studio/docs/agents/modules/credential-inventory.md` |
| **Source control (GitHub): architecture, auth, usage** | `mcritchie-studio/docs/agents/modules/source-control.md` |
| **GitHub token session broken (401, `Bad credentials`, push refused)** | `mcritchie-studio/docs/agents/modules/token-session.md` |
| Shared email operations | `mcritchie-studio/docs/agents/modules/email-operations.md` |
| Managed app registry | `mcritchie-studio/docs/agents/modules/app-registry.md` |
| New app onboarding (tiers + SOP) | `mcritchie-studio/docs/agents/system/new-app-onboarding-sop.md` |
| **App templates (base vs web3 bolt-on)** | `mcritchie-studio/docs/agents/system/app-templates.md` |
| Ports, servers, callbacks | `mcritchie-studio/docs/agents/modules/ports-and-processes.md` |
| Object storage (S3 buckets, keys, conventions) | `mcritchie-studio/docs/agents/modules/object-storage.md` |
| Knowledge capture (team@, intake protocol, sweep) | `mcritchie-studio/docs/agents/modules/knowledge-capture.md` |
| Slack capture (connect, read, categorize a channel) | `mcritchie-studio/docs/agents/modules/slack-capture.md` |
| Gmail capture (read-only mailbox pull into the desk queue) | `mcritchie-studio/docs/agents/modules/gmail-capture.md` |
| Credential issues (log it privately, triage rotate-now vs weekly) | `mcritchie-studio/docs/agents/modules/credential-issues.md` |
| Form fill (complete an application from records, ask only what they cannot answer) | `mcritchie-studio/docs/agents/modules/form-fill.md` |
| Parallel DevOps and QA graduation | `mcritchie-studio/docs/agents/modules/parallel-agent-devops.md` |
| Agent presence (who is working, machine headroom) | `mcritchie-studio/docs/agents/system/agent-presence.md` |
| Modular PR review SOP | `mcritchie-studio/docs/agents/modules/pr-review-sop.md` |
| Zap protocol (small mid-cycle fixes, no new task) | `mcritchie-studio/docs/agents/modules/zap-protocol.md` |
| Building SOP (feature-agent build flow + local-review decision) | `mcritchie-studio/docs/agents/modules/building-sop.md` |
| Focus session (hold an epic, file just-in-time, build wide, review your own PRs) | `mcritchie-studio/docs/agents/modules/focus-session.md` |
| Pokémon builder soul (the general builder every task is built by) | `mcritchie-studio/docs/agents/agents/pokemon/role.md` |
| Modal lifecycle (build in the app, graduate to a gem) | `mcritchie-studio/docs/agents/modules/modal-lifecycle.md` |
| Process backlog (groom designed, build four wide) | `mcritchie-studio/docs/agents/modules/process-backlog.md` |
| Work backlog (your own tasks, two-three wide) | `mcritchie-studio/docs/agents/modules/work-backlog.md` |
| Workflows (five soul launchers) | `mcritchie-studio/docs/agents/modules/heartbeats.md` |
| Carl heartbeat launcher | `mcritchie-studio/docs/agents/agents/carl/HEARTBEAT.md` |
| Carl PR review SOP (orchestrator) | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review.md` |
| Carl slow PR review SOP | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-slow.md` |
| Carl primary reviewer role SOP | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-primary.md` |
| Carl light reviewer role SOP | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-light.md` |
| Avi heartbeat launcher | `mcritchie-studio/docs/agents/agents/avi/HEARTBEAT.md` |
| Avi QA release SOP | `mcritchie-studio/docs/agents/agents/avi/sops/qa-release.md` |
| Avi deploy with task SOP | `mcritchie-studio/docs/agents/agents/avi/sops/deploy-with-task.md` |
| Avi arbitrate block SOP (a builder contested a review block; Avi rules) | `mcritchie-studio/docs/agents/agents/avi/sops/arbitrate-block.md` |
| Steffon heartbeat launcher | `mcritchie-studio/docs/agents/agents/steffon/HEARTBEAT.md` |
| Steffon production deploy SOP | `mcritchie-studio/docs/agents/agents/steffon/sops/production-deploy.md` |
| Steffon archive shipped SOP | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| Steffon clean infra SOP (worktrees, disk, "no space") | `mcritchie-studio/docs/agents/agents/steffon/sops/clean-infra.md` |
| Steffon bucket provision SOP (per-app S3 + IAM) | `mcritchie-studio/docs/agents/agents/steffon/sops/bucket-provision.md` |
| Steffon credential filing SOP (naming, logos, vault lanes) | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-filing.md` |
| Steffon credential rotation SOP (rotate one secret everywhere) | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-rotation.md` |
| Steffon workspace icon SOP (badged software icons per client, /credentials matrix, 1Password vault icons) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-icon.md` |
| Launch build queue SOP (work /build app requests: claim, build, point the subdomain, mark live) | `mcritchie-studio/docs/agents/modules/launch-build-queue.md` |
| Steffon workspace provision SOP (client Google Workspace read access) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-provision.md` |
| Steffon workspace launch SOP (new domain to first draft, walks the operator) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-launch.md` |
| Steffon domain purchase SOP (buy on Squarespace, prove ownership) | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-purchase.md` |
| Steffon workspace signup SOP (Google Workspace, alex@ + team@) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-signup.md` |
| Steffon domain DNS SOP (verify, MX, SPF, DKIM, DMARC) | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-dns.md` |
| Steffon website launch SOP (hosted site: Squarespace or our app) | `mcritchie-studio/docs/agents/agents/steffon/sops/website-launch.md` |
| Steffon Chrome profiles SOP (avatar-menu roster, fresh Mac) | `mcritchie-studio/docs/agents/agents/steffon/sops/chrome-profiles.md` |
| Turf Monster heartbeat launcher | `mcritchie-studio/docs/agents/agents/turf_monster/HEARTBEAT.md` |
| Turf Monster live score watch SOP | `mcritchie-studio/docs/agents/agents/turf_monster/sops/live-score-watch.md` |
| Turf Monster contest rehearsal SOP (QA devnet lifecycle) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/contest-rehearsal.md` |
| Turf Monster sleeper auction watch SOP (live draft valuation) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/sleeper-auction-watch.md` |
| Turf Monster entry forfeit SOP (withdraw one entrant, forfeit fee) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/entry-forfeit.md` |
| Turf Monster market refresh SOP (rebuild a span's benchmarks from fresh lines) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/market-refresh.md` |
| Turf Monster content build SOP (drain the idea queue, write the takes) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/content-build.md` |
| Turf Monster roster sync SOP (refresh players/teams before a season) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/roster-sync.md` |
| Address a blocker (shared primitive) | `mcritchie-studio/docs/agents/modules/address-blocker.md` |
| Xan heartbeat launcher | `mcritchie-studio/docs/agents/agents/xan/HEARTBEAT.md` |
| Xan grade events SOP | `mcritchie-studio/docs/agents/agents/xan/sops/grade-events.md` |
| Xan share insights SOP | `mcritchie-studio/docs/agents/agents/xan/sops/share-insights.md` |
| Xan full cycle SOP | `mcritchie-studio/docs/agents/agents/xan/sops/full-cycle.md` |
| Xan clean up SOP (board → 0 + infra sweep) | `mcritchie-studio/docs/agents/agents/xan/sops/clean-up.md` |
| Rex heartbeat launcher (CMO) | `mcritchie-studio/docs/agents/agents/rex/HEARTBEAT.md` |
| Rex constraint diagnosis SOP (find the one thing limiting demand) | `mcritchie-studio/docs/agents/agents/rex/sops/constraint-diagnosis.md` |
| Rex content sprint SOP (the weekly test-at-volume loop) | `mcritchie-studio/docs/agents/agents/rex/sops/content-sprint.md` |
| DevOps task-board handoff | `mcritchie-studio/docs/agents/modules/devops-task-board.md` |
| Fast lane (`bin/task begin` / `bin/ship`) | `mcritchie-studio/docs/agents/modules/devops-task-board.md` |
| Fast lane entry rules (where each command runs, author set, ship-wait, long form) | `mcritchie-studio/docs/agents/modules/fast-lane.md` |
| Task-board API (auth + contract) | `mcritchie-studio/docs/agents/modules/task-board-api.md` |
| Parallel agents and worktrees | `mcritchie-studio/docs/agents/modules/worktrees.md` |
| LLM adapter policy | `mcritchie-studio/docs/agents/modules/llm-adapters.md` |
| Island background animator | `mcritchie-studio/docs/agents/system/island-background-animator.md` |
| Codex runtime updates | `mcritchie-studio/docs/agents/modules/codex-updates.md` |
| Backend discipline | `mcritchie-studio/docs/agents/modules/backend-discipline.md` |
| Tests | `mcritchie-studio/docs/agents/modules/testing.md` |
| G1 Cert gate (builder certification) | `mcritchie-studio/docs/agents/modules/gates/g1-cert.md` |
| G2 Review gate (primary + light lanes) | `mcritchie-studio/docs/agents/modules/gates/g2-review.md` |
| G3 Candidate gate (pre-QA + QA deploy) | `mcritchie-studio/docs/agents/modules/gates/g3-candidate.md` |
| G4 Ship gate (frozen-SHA + prod deploy) | `mcritchie-studio/docs/agents/modules/gates/g4-ship.md` |
| Deploys | `mcritchie-studio/docs/agents/modules/deployment.md` |
| CDN rollout (edge + origin lockdown) | `mcritchie-studio/docs/agents/system/cdn-rollout.md` |
| Keeping docs clean | `mcritchie-studio/docs/agents/modules/docs-maintenance.md` |
| Memory maintenance | `mcritchie-studio/docs/agents/modules/memory-maintenance.md` |
| Result distillation (findings not raw ops) | `mcritchie-studio/docs/agents/modules/result-distillation.md` |
| Communication style (reporting to Alex) | `mcritchie-studio/docs/agents/modules/communication-style.md` |
| Audit playbook | `mcritchie-studio/docs/agents/modules/audit-playbook.md` |
| Shared SES production proof | `mcritchie-studio/docs/agents/audits/ses-production-proof-2026-06-14.md` |
| Current final closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-17.md` |
| Session retrospective | `mcritchie-studio/docs/agents/audits/session-retrospective-2026-06-17.md` |
| Prior final audit | `mcritchie-studio/docs/agents/audits/fresh-final-audit-2026-06-15.md` |
| Prior ecosystem closeout | `mcritchie-studio/docs/agents/audits/final-closeout-2026-06-14.md` |
| Latest ecosystem audit | `mcritchie-studio/docs/agents/audits/broader-ecosystem-audit-2026-06-14.md` |
| Delete later ledger | `mcritchie-studio/docs/agents/maintenance/delete-later.md` |
| Parking lot (kept, not on the board) | `mcritchie-studio/docs/agents/maintenance/parking-lot.md` |
| Dependency decisions (Dependabot backlog verdicts) | `mcritchie-studio/docs/agents/maintenance/dependency-decisions.md` |
