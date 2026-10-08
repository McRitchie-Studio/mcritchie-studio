# Start Here — the full index

Every agent doc, by the need it answers. The entry map
([`index.md`](index.md), installed as `AGENTS.md`) links here instead of carrying
this table, so a session loads it only when it goes looking. Every SOP and
heartbeat has a row under [SOPs and heartbeats](#sops-and-heartbeats), generated
by `bin/sop-registry` from the same files as the SOP Registry, so each row names
its invocation exactly.

## Start Here

| Need | Read |
|------|------|
| Ecosystem map | `mcritchie-studio/docs/ECOSYSTEM.md` |
| Fresh-machine rebuild | `mcritchie-studio/docs/agents/system/house-burn-down.md` |
| DevOps v3 design (ratified 2026-09-24, landing in phases) | `mcritchie-studio/docs/agents/system/devops-v3-design.md` |
| Agent sessions and capability APIs design (proposed, awaiting Alex's review; tiers, grants, capability matrix) | `mcritchie-studio/docs/agents/system/agent-sessions-design.md` |
| Guard catalog (proposed, awaiting Alex's decision; every refusal with delete, by construction or keep) | `mcritchie-studio/docs/agents/system/guard-catalog.md` |
| Knowledge layer design (proposed, awaiting Alex's review; five tiers, the Drive shelf, the walker, who reads what) | `mcritchie-studio/docs/agents/system/knowledge-layer-design.md` |
| Ecosystem build script | `mcritchie-studio/docs/agents/system/ecosystem-build.md` |
| Agent culture | `mcritchie-studio/docs/agents/modules/culture.md` |
| Credentials and 1Password | `mcritchie-studio/docs/agents/modules/credentials.md` |
| Credential item names | `mcritchie-studio/docs/agents/modules/credential-inventory.md` |
| **Source control (GitHub): architecture, auth, usage** | `mcritchie-studio/docs/agents/modules/source-control.md` |
| Shared email operations | `mcritchie-studio/docs/agents/modules/email-operations.md` |
| Managed app registry | `mcritchie-studio/docs/agents/modules/app-registry.md` |
| New app onboarding (tiers + SOP) | `mcritchie-studio/docs/agents/system/new-app-onboarding-sop.md` |
| **App templates (base vs web3 bolt-on)** | `mcritchie-studio/docs/agents/system/app-templates.md` |
| Ports, servers, callbacks | `mcritchie-studio/docs/agents/modules/ports-and-processes.md` |
| Object storage (R2 buckets and tokens; legacy S3) | `mcritchie-studio/docs/agents/modules/object-storage.md` |
| Asset library plan (storage tiers, Wave 2 cutover recipe, asset catalog, AWS exit) | `mcritchie-studio/docs/agents/system/asset-library-plan.md` |
| R2 cutover record: the hub and Turf Monster cutovers as run, and the step 7 checklist | `mcritchie-studio/docs/agents/system/r2-cutover-record.md` |
| Music video pipeline plan (four pipelines, pipeline 3 stages, data model, R2 tree) | `mcritchie-studio/docs/agents/system/music-video-pipeline-plan.md` |
| Business facts quick reference (when to pull from and add to `FACTS.md`) | `mcritchie-studio/docs/agents/modules/knowledge-capture.md` |
| Parallel DevOps and QA graduation | `mcritchie-studio/docs/agents/modules/parallel-agent-devops.md` |
| Agent presence (who is working, machine headroom) | `mcritchie-studio/docs/agents/system/agent-presence.md` |
| Modular PR review SOP | `mcritchie-studio/docs/agents/modules/pr-review-sop.md` |
| Zap protocol (small mid-cycle fixes, no new task) | `mcritchie-studio/docs/agents/modules/zap-protocol.md` |
| Pokémon builder soul (the general builder every task is built by) | `mcritchie-studio/docs/agents/agents/pokemon/role.md` |
| Tywin, the Cyvasse admin soul (character, admin charter, playbook and five setups) | `mcritchie-studio/docs/agents/agents/tywin/soul.md` |
| Modal lifecycle (build in the app, graduate to a gem) | `mcritchie-studio/docs/agents/modules/modal-lifecycle.md` |
| Workflows (five soul launchers) | `mcritchie-studio/docs/agents/modules/heartbeats.md` |
| Tyrion soul (Cyvasse's house player: character, game style, five setups, voice) | `mcritchie-studio/docs/agents/agents/tyrion/soul.md` |
| Tyrion runtime design (isolated runner, bot API, threat model; not built) | `mcritchie-studio/docs/agents/agents/tyrion/runtime.md` |
| DevOps task-board handoff | `mcritchie-studio/docs/agents/modules/devops-task-board.md` |
| Fast lane (`bin/task begin` / `bin/submit`) | `mcritchie-studio/docs/agents/modules/devops-task-board.md` |
| Fast lane entry rules (where each command runs, author set, submit-wait, long form) | `mcritchie-studio/docs/agents/modules/fast-lane.md` |
| Task-board API (auth + contract) | `mcritchie-studio/docs/agents/modules/task-board-api.md` |
| Parallel agents and worktrees | `mcritchie-studio/docs/agents/modules/worktrees.md` |
| LLM adapter policy | `mcritchie-studio/docs/agents/modules/llm-adapters.md` |
| Island background animator | `mcritchie-studio/docs/agents/system/island-background-animator.md` |
| Codex runtime updates | `mcritchie-studio/docs/agents/modules/codex-updates.md` |
| Backend discipline | `mcritchie-studio/docs/agents/modules/backend-discipline.md` |
| Tests | `mcritchie-studio/docs/agents/modules/testing.md` |
| Pre-flight (the builder's optional local check) | `mcritchie-studio/docs/agents/modules/pre-flight.md` |
| DoR gate (the Definition-of-Ready verdict) | `mcritchie-studio/docs/agents/modules/gates/dor.md` |
| G2 Review gate (primary + light lanes) | `mcritchie-studio/docs/agents/modules/gates/g2-review.md` |
| G3 Candidate gate (pre-QA + QA deploy) | `mcritchie-studio/docs/agents/modules/gates/g3-candidate.md` |
| G4 Ship gate (frozen-SHA + prod deploy) | `mcritchie-studio/docs/agents/modules/gates/g4-ship.md` |
| Deploys | `mcritchie-studio/docs/agents/modules/deployment.md` |
| CDN rollout (edge + origin lockdown) | `mcritchie-studio/docs/agents/system/cdn-rollout.md` |
| Hub web memory: allocator choice and Metrics API measurement plan | `mcritchie-studio/docs/agents/system/web-memory-allocator.md` |
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

## SOPs and heartbeats

<!-- BEGIN sop-registry: generated by bin/sop-registry from the SOP files; edit those, then run bin/sop-registry --write -->
| SOP or heartbeat | Read |
|------------------|------|
| `Avi Heartbeat` launcher | `mcritchie-studio/docs/agents/agents/avi/HEARTBEAT.md` |
| Avi `arbitrate-block` SOP (a builder contested a review block; Avi rules) | `mcritchie-studio/docs/agents/agents/avi/sops/arbitrate-block.md` |
| Avi `deploy-with-task` SOP | `mcritchie-studio/docs/agents/agents/avi/sops/deploy-with-task.md` |
| Avi `qa-release` SOP | `mcritchie-studio/docs/agents/agents/avi/sops/qa-release.md` |
| `Carl Heartbeat` launcher | `mcritchie-studio/docs/agents/agents/carl/HEARTBEAT.md` |
| Carl `pr-review-light` SOP (the light reviewer's own steps) | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-light.md` |
| Carl `pr-review-primary` SOP (the primary reviewer's own steps) | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-primary.md` |
| Carl `pr-review-slow` SOP (the slow variant of pr-review) | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review-slow.md` |
| Carl `pr-review` SOP (the orchestrator) | `mcritchie-studio/docs/agents/agents/carl/sops/pr-review.md` |
| Pokemon `digest-video` SOP (download, store and record a music video; stage 1 of pipeline 3) | `mcritchie-studio/docs/agents/agents/pokemon/sops/digest-video.md` |
| Pokemon `download-instagram` SOP (yt-dlp download of an Instagram reel or post; cookie path unmeasured) | `mcritchie-studio/docs/agents/agents/pokemon/sops/download-instagram.md` |
| Pokemon `download-tiktok` SOP (yt-dlp download of a TikTok video; unmeasured) | `mcritchie-studio/docs/agents/agents/pokemon/sops/download-tiktok.md` |
| Pokemon `download-youtube` SOP (yt-dlp H.264 download of a YouTube video or section) | `mcritchie-studio/docs/agents/agents/pokemon/sops/download-youtube.md` |
| Pokemon `email-image` SOP (make an email header with Alex in a Claude Code session: show base assets, generate, iterate, approve on his word, export) | `mcritchie-studio/docs/agents/agents/pokemon/sops/email-image.md` |
| Pokemon `wrap-it-up` SOP (hand a stuck session to a fresh one, then clear its board) | `mcritchie-studio/docs/agents/agents/pokemon/sops/wrap-it-up.md` |
| `Rex Heartbeat` launcher (CMO) | `mcritchie-studio/docs/agents/agents/rex/HEARTBEAT.md` |
| Rex `constraint-diagnosis` SOP (find the one thing limiting demand) | `mcritchie-studio/docs/agents/agents/rex/sops/constraint-diagnosis.md` |
| Rex `content-sprint` SOP (the weekly test-at-volume loop) | `mcritchie-studio/docs/agents/agents/rex/sops/content-sprint.md` |
| Rex `launch-warmup` SOP (gated rollout of a new app, domain or email list) | `mcritchie-studio/docs/agents/agents/rex/sops/launch-warmup.md` |
| `Steffon Heartbeat` launcher | `mcritchie-studio/docs/agents/agents/steffon/HEARTBEAT.md` |
| Steffon `app-deploy-standard` SOP (single-use apps: profile, contract, `bin/register-app`) | `mcritchie-studio/docs/agents/agents/steffon/sops/app-deploy-standard.md` |
| Steffon `archive-shipped` SOP | `mcritchie-studio/docs/agents/agents/steffon/sops/archive-shipped.md` |
| Steffon `bucket-provision` SOP (per-app R2 pair + tokens) | `mcritchie-studio/docs/agents/agents/steffon/sops/bucket-provision.md` |
| Steffon `chrome-profiles` SOP (avatar-menu roster, fresh Mac) | `mcritchie-studio/docs/agents/agents/steffon/sops/chrome-profiles.md` |
| Steffon `clean-infra` SOP (worktrees, disk, "no space") | `mcritchie-studio/docs/agents/agents/steffon/sops/clean-infra.md` |
| Steffon `credential-filing` SOP (naming, logos, vault lanes) | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-filing.md` |
| Steffon `credential-rotation` SOP (rotate one secret everywhere) | `mcritchie-studio/docs/agents/agents/steffon/sops/credential-rotation.md` |
| Steffon `domain-dns` SOP (verify, MX, SPF, DKIM, DMARC) | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-dns.md` |
| Steffon `domain-purchase` SOP (buy on Squarespace, prove ownership) | `mcritchie-studio/docs/agents/agents/steffon/sops/domain-purchase.md` |
| Steffon `production-deploy` SOP | `mcritchie-studio/docs/agents/agents/steffon/sops/production-deploy.md` |
| Steffon `r2-backup` SOP (backup bucket, nightly run, garbage collection, restore) | `mcritchie-studio/docs/agents/agents/steffon/sops/r2-backup.md` |
| Steffon `website-launch` SOP (hosted site: Squarespace or our app) | `mcritchie-studio/docs/agents/agents/steffon/sops/website-launch.md` |
| Steffon `workspace-icon` SOP (badged software icons per client, /credentials matrix, 1Password vault icons) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-icon.md` |
| Steffon `workspace-launch` SOP (new domain to first draft, walks the operator) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-launch.md` |
| Steffon `workspace-provision` SOP (client Google Workspace read access) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-provision.md` |
| Steffon `workspace-signup` SOP (Google Workspace, alex@ + team@) | `mcritchie-studio/docs/agents/agents/steffon/sops/workspace-signup.md` |
| `Turf Monster Heartbeat` launcher | `mcritchie-studio/docs/agents/agents/turf_monster/HEARTBEAT.md` |
| Turf Monster `collect-vault-revenue` SOP (sweep entry fees out, then Squads to a wallet) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/collect-vault-revenue.md` |
| Turf Monster `content-build` SOP (drain the idea queue, write the takes) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/content-build.md` |
| Turf Monster `contest-rehearsal` SOP (QA devnet lifecycle) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/contest-rehearsal.md` |
| Turf Monster `entry-forfeit` SOP (withdraw one entrant, forfeit fee) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/entry-forfeit.md` |
| Turf Monster `live-score-watch` SOP | `mcritchie-studio/docs/agents/agents/turf_monster/sops/live-score-watch.md` |
| Turf Monster `market-refresh` SOP (rebuild a span's benchmarks from fresh lines) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/market-refresh.md` |
| Turf Monster `post-to-x` SOP (winning team + video in, drafted and approved post on @turfmonstershow out) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/post-to-x.md` |
| Turf Monster `roster-sync` SOP (refresh players/teams before a season) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/roster-sync.md` |
| Turf Monster `sleeper-auction-watch` SOP (live draft valuation) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/sleeper-auction-watch.md` |
| Turf Monster `tiktok-draft` SOP (clip slug in, a private draft in Alex's TikTok inbox and its code-written caption out) | `mcritchie-studio/docs/agents/agents/turf_monster/sops/tiktok-draft.md` |
| `Xan Heartbeat` launcher | `mcritchie-studio/docs/agents/agents/xan/HEARTBEAT.md` |
| Xan `clean-up` SOP (board → 0 + infra sweep) | `mcritchie-studio/docs/agents/agents/xan/sops/clean-up.md` |
| Xan `full-cycle` SOP | `mcritchie-studio/docs/agents/agents/xan/sops/full-cycle.md` |
| Xan `grade-events` SOP | `mcritchie-studio/docs/agents/agents/xan/sops/grade-events.md` |
| Xan `share-insights` SOP | `mcritchie-studio/docs/agents/agents/xan/sops/share-insights.md` |
| `address-blocker` (recontextualize, fix, resubmit) | `mcritchie-studio/docs/agents/modules/address-blocker.md` |
| `building-sop` (feature-agent build flow + local-review decision) | `mcritchie-studio/docs/agents/modules/building-sop.md` |
| `contact-capture` (offer Alex a create or update of an Apple Contacts card from a forwarded email's signature) | `mcritchie-studio/docs/agents/modules/contact-capture.md` |
| `credential-issues` (log it privately, triage rotate-now vs weekly) | `mcritchie-studio/docs/agents/modules/credential-issues.md` |
| `dream` (the bank of good answers, in a platform sequence and one per soul; capture and sign-off) | `mcritchie-studio/docs/agents/modules/dream.md` |
| `focus-session` (hold an epic, file just-in-time, build wide, review your own PRs) | `mcritchie-studio/docs/agents/modules/focus-session.md` |
| `form-fill` (complete an application from records, ask only what they cannot answer) | `mcritchie-studio/docs/agents/modules/form-fill.md` |
| `gmail-capture` (read-only mailbox pull into the desk queue) | `mcritchie-studio/docs/agents/modules/gmail-capture.md` |
| `knowledge-capture` (team@, intake protocol, sweep) | `mcritchie-studio/docs/agents/modules/knowledge-capture.md` |
| `launch-build-queue` (work /build app requests: claim, build, point the subdomain, mark live) | `mcritchie-studio/docs/agents/modules/launch-build-queue.md` |
| `process-backlog` (groom designed, build four wide) | `mcritchie-studio/docs/agents/modules/process-backlog.md` |
| `slack-capture` (connect, read, categorize a channel) | `mcritchie-studio/docs/agents/modules/slack-capture.md` |
| `token-session` (GitHub token session broken: 401, `Bad credentials`, push refused) | `mcritchie-studio/docs/agents/modules/token-session.md` |
| `work-backlog` (your own tasks, two-three wide) | `mcritchie-studio/docs/agents/modules/work-backlog.md` |
<!-- END sop-registry -->
