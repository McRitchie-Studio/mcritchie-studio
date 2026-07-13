class Release
  # Orchestrates the release-record lifecycle behind the `bin/release` CLI (and
  # the "Prepare release" / "Run Deployment" kickoffs). The git + deploy mechanics
  # live in the CLI; this owns the record state so it stays testable and
  # deterministic regardless of who/what runs it.
  module Conductor
    module_function

    # --- the sweep (Steffon's self-healing qa-deploy, steps 1–3) --------------

    # DETECT the work a qa-deploy run should sweep onto the next release: every
    # `reviewed` task (whether or not its PR is merged yet — `merged` says which)
    # plus any `assembled` STRAGGLER — a member of no/another release (a prior RC
    # shipped/aborted without it) that must re-ride the current candidate. A PURE
    # read, so the CLI previews it under --dry-run. Returns
    # { "reviewed" => [tasks], "stragglers" => [tasks] } in board order.
    # Both lists empty + no active release ⇒ qa-deploy is an idempotent no-op.
    def sweep_candidates(release = Release.current)
      {
        "reviewed"   => Task.where(stage: "reviewed").order(:position).to_a,
        "stragglers" => straggler_tasks(release)
      }
    end

    # The `assembled` tasks NOT riding the given (current) release: a prior
    # cycle's leftovers. With no active release EVERY assembled task is a
    # straggler (assembled work always belongs on the next candidate). NULL-safe
    # by hand: `where.not(release_slug: nil-slug)` would match nothing under SQL
    # null semantics.
    def straggler_tasks(release = Release.current)
      scope = Task.where(stage: "assembled")
      scope = scope.where("release_slug IS NULL OR release_slug != ?", release.slug) if release
      scope.order(:position).to_a
    end

    # SWEEP one task onto the active release (opening one if none): attach it
    # (release_slug + `merged: "release"`) WITHOUT moving its stage — the
    # membership write `bin/release merge`/`prepare` record after `gh pr merge`.
    # The `reviewed → assembled` flip is deferred to qa_green! (QA-green only).
    # Returns the release.
    #
    # Idempotent AND crash-safe: a member already stamped `merged` ("release" OR
    # "main") is left untouched — sweep! never regresses a `merged: "main"`
    # member (an interrupted Avi ship) back to "release". That promise is
    # absolute across releases: the short-circuit below covers CURRENT-release
    # members, and Release#add refuses the main→release downgrade when a LATER
    # release re-adopts a cross-release straggler. A member attached but
    # NOT yet merged-stamped (a pre-`merged`-field row, or a half-recorded batch)
    # is re-run through `add`, which heals the stamp.
    #
    # `override: true` is the audited `bin/release merge --override` escape
    # hatch: a NOT-yet-`reviewed` target is first flipped to `reviewed` with
    # Current.task_event_review_bypass stamped onto that transition
    # (Task#write_stage_event), so the review skip leaves a `review_bypassed`
    # paper-trail row on the audit spine — never a silent skip — and the swept
    # member then rides the standard reviewed→assembled QA-green flip. The flag
    # resets in `ensure` so it can't leak onto a later (in-process) transition.
    def sweep!(task, override: false)
      release = Release.current_or_open!
      stamp_session_mascot(release)
      # The first sweep IS the start of assembly — record it so the stage
      # timeline stamps `assembling` (tracker node 2 goes live) without relying
      # on a separate agent post. Idempotent across the whole sweep wave.
      unless release.event_started?("assemble_release")
        record_event!(
          release: release,
          step: "assemble_release",
          status: "started",
          source: "conductor",
          idempotency_key: "#{release.slug}:assemble_release:started"
        )
      end
      record_assembly_intent!(task)
      member = release.tasks.find_by(slug: task.slug)
      target = member || task
      # Already swept (or further along — ff'd to main): nothing to do, and
      # nothing may be regressed.
      return release if member && member.merged.present?

      # Only flag a genuine bypass: an override on an already-eligible target
      # changes nothing, so it records no skip.
      if override && !%w[reviewed assembled].include?(target.stage)
        begin
          Current.task_event_review_bypass = true
          target.update!(stage: "reviewed")
        ensure
          Current.task_event_review_bypass = nil
        end
      end

      release.add(target, override: override)
      release.reload
    end

    # The QA-GREEN flip (Steffon's qa-deploy, step 6): QA booted + smoked green,
    # so every swept `reviewed` member flips to `assembled` (merged stays
    # "release" — matrix: assembled+release = QA-green, waiting on Avi) and the
    # release itself assembles. On a QA-deploy FAILURE this is simply never
    # called — members stay `reviewed` (+ merged "release") for the next
    # self-healing run. Idempotent: already-`assembled` members (stragglers, or
    # a re-run) don't move again; assemble! no-ops on an assembled release.
    #
    # `usage_by_slug` is the optional best-effort per-member usage for the
    # reviewed→assembled flip (captured locally by `bin/release prepare`; the
    # flip runs on prod, transcript-less). Each flip runs inside
    # Current.with_task_event_usage so the assembled TaskEvent carries it; a
    # missing entry records the deterministic spine only.
    def qa_green!(release, usage_by_slug: {}, qa_url: nil)
      usage_by_slug ||= {}
      Release.transaction do
        # Revive `tested_at`: reaching qa_green! IS the QA-green verdict (the
        # g3_candidate gate closes green immediately after). Stamped at the top of
        # the transaction so it precedes the assembled/qa_deployed stamps written
        # INSIDE this same block.
        #
        # This is NOT a wall-clock guarantee, and nothing here should claim one:
        # assembling_started_at was already stamped back at MERGE time (sweep!),
        # and qa_deploy_started_at before the QA deploy — so both precede tested_at
        # chronologically even though Release::STAGES lists them after it. The
        # stamps are a LOGICAL stage order, deliberately out of chronological
        # order, which is why `current_stage` is MONOTONIC over them.
        #
        # stamp_stage! is the model's single stamp seam: it validates the stage
        # name and is first-write-wins, so a re-run of a green sweep never moves it.
        release.stamp_stage!("tested")
        # Flip PRODUCER-FIRST (gems before consumers, honoring dependencies) so
        # the assembled column's positions land in the same order the conductor
        # publishes/deploys in — each stage flip stamps the member's board rank.
        pending = Release::Ordering.producer_first(release.tasks.where(stage: "reviewed").to_a)
        pending.each do |task|
          Current.with_task_event_usage(usage_by_slug[task.slug]) { task.assemble! }
        end
        assemble!(release)
        # Stamp Live-on-QA (deploy_qa:completed → `qa_deployed`) HERE — atomic
        # with the member flip — so the /deployments tracker only reaches "Live
        # on QA" green once the members are ACTUALLY `assembled`. bin/release used
        # to stamp it a step EARLIER (record_qa_deploy, before this flip and
        # before the post-deploy hooks), so a viewer saw a green "Live on QA"
        # while the members were still `reviewed`, and a failure in that gap left
        # a lying all-green release. `qa_url` comes from the caller (real prepare)
        # or the URL record_qa_url already persisted; blank in the model/test path
        # (no real QA deploy) → nothing stamped, exactly as before.
        live_url = qa_url.presence || release.qa_url.presence
        if live_url
          record_event!(
            release: release,
            step: "deploy_qa",
            status: "completed",
            source: "conductor",
            url: live_url,
            idempotency_key: "#{release.slug}:deploy_qa:#{live_url}:completed"
          )
        end
      end
      release.reload
    end

    # BLOCK-ON-REGRESSION (Steffon's pre-QA gate): the tier tests on
    # origin/release caught a regression, so the offending task is EJECTED from
    # the candidate — detached (release_slug + `merged` cleared) and blocked for
    # rework with the feedback as a qa_feedback Activity — while the REST of the
    # RC rides on untouched. Clearing `merged` pairs with the documented git
    # remediation (revert the member's merge commit on `release`, never a
    # force-push): after the revert its PR is genuinely off the branch, so the
    # next sweep of the reworked task correctly re-merges. Returns the task.
    def eject!(task, feedback: nil, by: "steffon")
      Task.transaction do
        task.update!(release_slug: nil, merged: nil)
        task.block!(by: by, kind: "rework")
        if feedback.present?
          Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                           agent_slug: by.presence, description: feedback)
        end
      end
      task
    end

    # Stamp the git-location on a set of members — the `merged: "main"` write
    # Avi's `bin/release ship` records per repo right after that repo's
    # `release → main` fast-forward lands on origin (matrix: assembled+main =
    # ff'd, prod-deploy in flight). An interrupted Avi run reads this to skip
    # re-ff'ing; Task#ship! re-stamps "main" at the record step regardless, so a
    # missed stamp degrades to the git no-op, never a wrong deploy. Validated by
    # Task's `merged` inclusion — an unknown location raises. Returns the slugs.
    def record_merged!(slugs:, merged:)
      list = Array(slugs)
      Task.where(slug: list).find_each { |task| task.update!(merged: merged) }
      list
    end

    # The sweep/assembly bookend: the assembly window OPENS when the task is swept
    # onto the release train (Steffon's qa-deploy), before QA-green concludes it.
    # This gives analytics an explicit start timestamp for the assembly window
    # instead of relying only on the reviewed→assembled transition. Idempotent
    # through Task#record_intent_event.
    def record_assembly_intent!(task, actor: nil)
      return nil unless task&.stage == "reviewed"

      actor ||= assembly_actor(task)
      task.record_intent_event(to_stage: "assembled", actor: actor, source: "conductor")
    end

    def assembly_actor(task)
      reviewed = task.task_events.transitions.where(to_stage: "reviewed").chronological.last
      return reviewed.actor if reviewed&.actor.present?

      reviewers = task.latest_intent_reviewers("reviewed")
      primary = Array(reviewers).find { |r| %w[primary heavy].include?(r["weight"].to_s) } || Array(reviewers).first
      primary&.dig("slug")
    end

    # Pre-flight REVIEW-GATE screen for the sweep (`bin/release merge`/`prepare`)
    # — the decision the CLI runs over the requested slugs BEFORE any `gh pr
    # merge`, so an unreviewed PR can't be merged onto `release` by accident (the
    # incident: PR #138 merged straight in during the scheduled wait). A PURE
    # read: it only CLASSIFIES; the bypass itself is RECORDED later, on the audit
    # spine, when sweep! flips an overridden target (see sweep!). Each slug is
    # one of:
    #   "eligible"   — sweepable: `reviewed` (passed review) or `assembled`
    #                  (a straggler re-riding the next candidate)
    #   "blocked"    — NOT sweepable and no --override → the run must abort
    #   "overridden" — NOT sweepable but --override given → proceeds, audited at sweep!
    #   "missing"    — no such task on the board
    # Returns a JSON-serializable decision:
    #   { rows: [{slug, stage, status}], blocked:[slug], overridden:[slug],
    #     missing:[slug], proceed: bool }  (proceed=false iff any slug is blocked).
    def screen_merge(slugs, override: false)
      rows = Array(slugs).map do |slug|
        task   = Task.find_by(slug: slug)
        status =
          if task.nil?                                        then "missing"
          elsif %w[reviewed assembled].include?(task.stage)   then "eligible"
          elsif override                                      then "overridden"
          else                                                     "blocked"
          end
        { "slug" => slug, "stage" => task&.stage, "status" => status }
      end
      pick = ->(s) { rows.select { |r| r["status"] == s }.map { |r| r["slug"] } }
      {
        "rows"       => rows,
        "blocked"    => pick.call("blocked"),
        "overridden" => pick.call("overridden"),
        "missing"    => pick.call("missing"),
        "proceed"    => rows.none? { |r| r["status"] == "blocked" }
      }
    end

    # The SYNCHRONOUS record-side qa-deploy: sweep (curate!) then QA-green flip
    # (qa_green!) in one transaction — for model-driven flows and tests, where
    # there is no real QA deploy between the two halves. The production caller
    # `bin/release prepare` runs the halves SPLIT: curate! (sweep) → git merges +
    # QA deploy + wait_for_boot → qa_green! ONLY once QA is confirmed up — so a
    # QA failure leaves the swept members `reviewed` for the next self-healing
    # run. Atomic: an ineligible or unknown-repo member raises and rolls the
    # whole prepare! back. Returns the release (nil when there is nothing to
    # sweep and none is active — the idempotent no-op).
    def prepare!(task_slugs: [], slug: nil, usage_by_slug: {})
      Release.transaction do
        release = curate!(task_slugs: task_slugs, slug: slug)
        return release unless release

        qa_green!(release, usage_by_slug: usage_by_slug)
        release
      end
    end

    # The SWEEP half of prepare! — steps 1–3 of the self-healing qa-deploy:
    # detect the work (sweep_candidates), ensure a release exists, and sweep!
    # each detected task onto it (attach + `merged: "release"`; stages do NOT
    # move — qa_green! owns the flip). With explicit `task_slugs` the sweep is
    # narrowed to those tasks (operator curation); with none it sweeps EVERY
    # `reviewed` task + `assembled` straggler. Nothing detected and nothing
    # active → nil (the idempotent no-op).
    #
    # SELF-ATOMIC: wraps its own body in a transaction. The atomicity can't be
    # borrowed from prepare!'s wrapper, because the production caller
    # `bin/release prepare` invokes curate! STANDALONE (its own process, no outer
    # DB txn). Without the wrapper a validate_members! raise AFTER sweep! has
    # opened a candidate and attached members would strand a half-curated release
    # on the board — and the single-active-release rule then makes that stranded
    # RC block every other session. The transaction rolls the whole curation back
    # instead. Nested inside prepare!'s transaction, AR joins the outer txn, so
    # this is a no-op wrapper there. Producer-first. Returns the active release,
    # or nil when none is active and nothing was swept.
    def curate!(task_slugs: [], slug: nil)
      Release.transaction do
        slugs = Array(task_slugs).compact
        tasks =
          if slugs.any?
            Task.where(slug: slugs).to_a
          else
            candidates = sweep_candidates
            candidates["reviewed"] + candidates["stragglers"]
          end
        if tasks.any?
          Release.open!(slug: slug) if slug.present? && Release.current.nil?
          Release::Ordering.producer_first(tasks).each { |task| sweep!(task) }
        end

        release = Release.current
        stamp_session_mascot(release)

        # Repo-aware eligibility: a release can't deploy a repo it doesn't know how
        # to deploy. An unknown-repo member raises here, rolling the whole curation
        # back (the opened candidate + the swept members) via the wrapper
        # transaction above.
        validate_members!(release) if release
        release
      end
    end

    # Flip the swept, QA-deployed RC assembling→assembled — the release-state half
    # of qa_green! (which also flips the reviewed MEMBERS). Idempotent: a no-op
    # when the release is already assembled, so re-running against an in-flight RC
    # (no new members) never errors. Reached LAST, after wait_for_boot confirms
    # the QA dyno is up, so a slow boot can't leave the RC flipped `assembled`
    # against an app that isn't actually serving.
    def assemble!(release)
      release.assemble! if release.state == "assembling"
      record_event!(
        release: release,
        step: "assemble_release",
        status: "completed",
        source: "conductor",
        idempotency_key: "#{release.slug}:assemble_release:completed"
      )
      unless release.event_started?("qa_smoke")
        record_event!(
          release: release,
          step: "qa_smoke",
          status: "started",
          source: "conductor",
          idempotency_key: "#{release.slug}:qa_smoke:started"
        )
      end
      record_event!(
        release: release,
        step: "qa_smoke",
        status: "completed",
        source: "conductor",
        idempotency_key: "#{release.slug}:qa_smoke:completed"
      )
      release
    end

    # Guard: every member must classify to a known release_kind (:gem or :app).
    # An :unknown member means its repo is in neither registry section of
    # config/release_repos.yml, so the conductor has no adapter to ship it.
    # Raises ArgumentError naming the offending members so the operator can fix
    # the task's repo or register it.
    def validate_members!(release)
      unknown = release.ordered_members.select { |task| task.release_kind == :unknown }
      return if unknown.none?

      named = unknown.map { |task| "#{task.slug} (#{task.release_repo.presence || 'no repo'})" }
      raise ArgumentError,
            "release #{release.slug} can't deploy unknown repo(s): #{named.join(', ')} — " \
            "register the repo in config/release_repos.yml or fix the task's repo"
    end

    # The per-member release plan the CLI consumes, in producer-first order:
    # each entry is { slug, branch, kind ("gem"/"app"), repo, version,
    # post_deploy_cmd, merged }. `branch` is the member's feature branch (apps
    # merge it; gems have none and ride the record). `version` is the gem's
    # declared version (nil for apps, and nil for gems when the version_file
    # isn't reachable — the CLI resolves it locally at publish time).
    # `post_deploy_cmd` is the optional one-off command (a shell/rake line) the
    # pipeline runs on the deployed app AFTER it boots — on the QA app in
    # `prepare`, the prod app in `ship` (nil when the task declares none).
    # `merged` is the git-location (Task::MERGED_STATES — nil/"release"/"main"),
    # the crash-recovery signal an interrupted deploy heartbeat reads. This is
    # what `bin/release` reads to skip the merge for gems, publish them
    # producer-first at ship, and run the post-deploy hook.
    def member_plan(release)
      release.ordered_members.map do |task|
        kind = task.release_kind
        {
          slug: task.slug,
          # Apps merge their feature branch; gems have none — they ride the record
          # and publish by version. (A gem task may still carry a branch from the
          # slug trickle-down, so null it here rather than rely on it being unset.)
          branch: kind == :gem ? nil : task.devops_field("branch"),
          kind: kind.to_s,
          repo: task.release_repo,
          version: kind == :gem ? Release::Repos.gem_version(task.release_repo) : nil,
          post_deploy_cmd: task.devops_field("post_deploy_cmd"),
          merged: task.merged
        }
      end
    end

    # The per-REPO deploy plan the multi-repo conductor consumes: member_plan
    # (already producer-first) collapsed into one entry per repo, in the same
    # producer-first order (group_by preserves first-appearance, so gem repos —
    # whose members lead member_plan — stay first). Each entry is
    # { repo, kind, members, release_branch, qa_app, prod_deploy } where:
    #   * GEM repos carry nil release_branch/qa_app/prod_deploy — a gem is
    #     published, not deployed, and rides the release as a record (no branch).
    #   * APP repos carry the persistent `release` branch (the same name in every
    #     repo), the qa-server key, and the prod_deploy adapter read from
    #     config/release_repos.yml.
    # All keys are symbol-keyed and the values are JSON-serializable.
    def repo_plan(release)
      member_plan(release).group_by { |member| member[:repo] }.map do |repo, members|
        gem = Release::Repos.gem?(repo)
        {
          repo: repo,
          kind: Release::Repos.kind(repo),
          members: members,
          release_branch: gem ? nil : Release::BRANCH,
          qa_app: gem ? nil : Release::Repos.qa_app(repo),
          prod_deploy: gem ? nil : Release::Repos.prod_deploy(repo)
        }
      end
    end

    # Stamp the deployed commit + flip the RC to shipped first, then flip member
    # tasks to shipped one at a time. The release-state commit is intentionally
    # first so the live /deployments board shows the fresh Last Release as soon
    # as prod is deployed; the member cadence is controlled by +member_pause+.
    # `usage_by_slug` is the optional best-effort per-member usage (model/tokens/
    # cost), captured by `bin/release ship` from the conductor's LOCAL session
    # transcript and keyed by task slug. It rides onto each member's shipped
    # TaskEvent (Release#ship! sets Current.with_task_event_usage per task). A
    # missing/blank entry → that member's shipped event records the spine only.
    def ship!(release:, deployed_sha:, by: nil, production_url: nil, usage_by_slug: {}, member_pause: 0)
      release.update!(
        deployed_sha: deployed_sha,
        production_url: production_url.presence || release.production_url
      )
      unless release.event_started?("deploy_prod")
        record_event!(
          release: release,
          step: "deploy_prod",
          status: "started",
          source: "conductor",
          actor: by,
          sha: deployed_sha,
          url: production_url.presence || release.production_url,
          idempotency_key: "#{release.slug}:deploy_prod:started"
        )
      end
      record_event!(
        release: release,
        step: "deploy_prod",
        status: "completed",
        source: "conductor",
        actor: by,
        sha: deployed_sha,
        url: production_url.presence || release.production_url,
        idempotency_key: "#{release.slug}:deploy_prod:completed"
      )
      release.ship!(by: by, usage_by_slug: usage_by_slug, member_pause: member_pause)
      # Re-stamp AFTER the ship commits so the read-only "Last Release" wears the
      # mascot of whoever actually ran the deploy (a handoff swaps it). Defensive
      # by design (see stamp_session_mascot) — a mascot stamp must never undo a
      # completed, irreversible prod ship.
      stamp_session_mascot(release)
      release
    end

    # The reviewed tasks eligible to ride the next release (the default queue the
    # release-builder autonomy policy evaluates).
    def eligible_tasks
      Task.where(stage: "reviewed").order(:position).to_a
    end

    def eligible_task_slugs
      eligible_tasks.map(&:slug)
    end

    # Read-only release-builder policy decision for the reviewed queue. The
    # caller still owns any side effects: this only says whether QA assembly can
    # proceed automatically or should be proposed for operator confirmation.
    def builder_policy_decision(tasks = nil)
      Release::BuilderPolicy.evaluate(tasks || eligible_tasks)
    end

    # Record the QA deployment URL on the release (the deploy itself is run by
    # bin/qa-server). Lets the board's current-release header link straight to QA
    # while the candidate is still in flight. It deliberately does NOT stamp the
    # stage-advancing `deploy_qa:completed` event — that lands in qa_green!,
    # atomic with the reviewed→assembled member flip, so "Live on QA" green never
    # precedes the members actually being assembled (see qa_green!).
    def record_qa_url(release:, qa_url:)
      release.update!(qa_url: qa_url)
      release
    end

    # Persist the per-repo SHAs deployed to QA onto the release, so the board (and
    # ship) can show exactly which commit each repo's QA app is running. `shas` is
    # a { repo => sha } hash; MERGED into the existing metadata["qa_shas"].
    #
    # NON-CLOBBERING by design: a blank/empty incoming value is IGNORED, never
    # written. A partial `prepare` (e.g. from a gem-less box that can't resolve a
    # sibling's origin/release HEAD) passes "" for the repos it couldn't freeze;
    # without this guard a re-run would overwrite a previously-frozen GOOD SHA with
    # "", and `ship`'s frozen_sha_for would then fall back to live origin/release
    # HEAD — the exact post-prepare drift the freeze exists to prevent. Non-blank
    # values still update in place; brand-new repo keys are still added.
    def record_qa_shas(release:, shas:)
      meta = release.metadata.deep_dup
      existing = meta["qa_shas"].is_a?(Hash) ? meta["qa_shas"] : {}
      shas.to_h.each do |repo, sha|
        sha = sha.to_s
        existing[repo.to_s] = sha unless sha.empty?
      end
      meta["qa_shas"] = existing
      release.update!(metadata: meta)
      release
    end

    # Persist WHAT THE G3 PRE-QA GATE ACTUALLY CERTIFIED, per repo:
    #   metadata["qa_gates"][repo] = { "sha" =>, "cmd" =>, "ok" => true,
    #                                  "ci" => { "state" =>, "checks" => [...] } }
    #
    # The "ci" half is the AUDITOR's verdict on the SAME SHA — what GitHub CI made
    # of the commit the local gate just certified (bin/release's ci_cross_check;
    # CiStatus.for_sha). It is recorded so a DISAGREEMENT is auditable after the
    # run instead of scrolling past in a terminal, and so agreement data accrues
    # release over release. It is INERT for the gate logic below: ship_gate_skip?
    # reads "ok"/"cmd"/"sha" and nothing else, so the auditor can never arm or
    # disarm G4 — it can only tell you the gate deserves a second look. Absent
    # (nil) when the auditor was not consulted; a state of "none"/"unverified"
    # means GitHub had nothing to say, which is NOT a red.
    #
    # This is the ONLY evidence G4's ship gate accepts for skipping its own suite
    # (Release::ShipSequence.ship_gate_skip?). It is deliberately NOT derivable
    # from anything else on the release: `qa_shas` records what was DEPLOYED to
    # QA, and the registry records what WOULD be run — neither proves a suite ran.
    # Written by bin/release's pre_qa_gate ONLY after the suite returns green, so
    # a gate that was skipped, misconfigured, or red leaves NO record and G4 fails
    # open (runs the suite). See ship_gate_skip? for the disarm bug this closes.
    #
    # Keyed by repo and MERGED, like record_qa_shas: a re-run of `prepare` (the
    # sweep is self-healing) re-certifies and overwrites its own repo's record,
    # while leaving the other repos' verdicts from this run intact.
    def record_qa_gate(release:, repo:, sha:, cmd:, ok:, ci: nil)
      meta = release.metadata.deep_dup
      gates = meta["qa_gates"].is_a?(Hash) ? meta["qa_gates"] : {}
      record = { "sha" => sha.to_s, "cmd" => cmd.to_s, "ok" => ok ? true : false }
      record["ci"] = ci.to_h.transform_keys(&:to_s) if ci.is_a?(Hash) && ci.any?
      gates[repo.to_s] = record
      meta["qa_gates"] = gates
      release.update!(metadata: meta)
      release
    end

    # The canonical role owner of each Deploy-lane stage — the actor stamped on the
    # OPEN intent when the CLI doesn't pass one. Mirrors StageAgentsHelper::STAGE_OWNER
    # (the view-layer backfill for actor-less completed transitions): Steffon
    # (Platform Engineer) QAs the assembled RC, Avi runs the ship. Kept here, on the
    # record side, so `record_deploy_intents!` defaults the actor without reaching
    # into a helper.
    DEPLOY_LANE_ACTORS = { "assembled" => "steffon", "shipped" => "avi" }.freeze

    # Record the Deploy-lane OPEN intents that drive the live "who's on it now" crew
    # ticker on /deployments + the consolidated Stage Timeline
    # (StageAgentsHelper#in_progress_work reads the open intent for the member's NEXT
    # pipeline stage): who is QA-ing the RC (Steffon → assembled) and who is shipping
    # it (Avi → shipped) RIGHT NOW, recorded the moment `bin/release prepare` / `ship`
    # starts that lane's work. This is the Deploy mirror of `bin/reviewer-select`,
    # which records the primary/light pair → reviewed by default. Without it the QA/ship
    # crew slots render as empty dashed placeholders until the transition lands — the
    # 2026-06-25 incident where the conductor had to hand-run `bin/task intent --to
    # shipped --actor avi` and an unfilled ship slot slipped through mid-deploy.
    #
    # Records an OPEN intent for EVERY member of `release`. Append-only + idempotent
    # BY CONSTRUCTION (record_intent_event): an identical OPEN intent is REUSED rather
    # than stacked, and it is superseded once the member's REAL transition lands — so a
    # re-run never duplicates a row. `actor` defaults to the stage's canonical role
    # owner (DEPLOY_LANE_ACTORS). Returns the slugs that carry a (new or reused) intent.
    #
    # The two lanes record DIFFERENTLY because the QA window does not map cleanly onto a
    # pipeline transition:
    #   * shipped (what `bin/release ship` fires) → a plain Avi → shipped intent,
    #     superseded when `ship!` lands the shipped transition.
    #   * assembled (what `bin/release prepare` fires) → the Steffon QA intent via
    #     #record_qa_intent. A swept member is still `reviewed` at prepare time (the
    #     flip waits for QA-green), so the plain toward-`assembled` intent renders;
    #     an already-`assembled` member (a straggler / re-run) gets the qa-marked
    #     toward-`shipped` intent instead so it still reads as LIVE QA.
    def record_deploy_intents!(release, to_stage:, actor: nil)
      return [] unless release

      to_stage = to_stage.to_s
      actor = (actor.presence || DEPLOY_LANE_ACTORS[to_stage]).to_s.strip.presence
      release.ordered_members.filter_map do |task|
        event = to_stage == "assembled" ? record_qa_intent(task, actor: actor) : task.record_intent_event(to_stage: to_stage, actor: actor)
        task.slug if event
      end
    end

    # The Steffon assembled-QA intent — the live "who's QA-ing the RC now" ticker that
    # `bin/release prepare` fires, per member stage:
    #   * still `reviewed` (THE standard flow: swept onto the RC, flip deferred to
    #     QA-green) → the plain toward-`assembled` intent renders, since
    #     NEXT_PIPELINE_STAGE[reviewed] == assembled and no assembled transition
    #     exists yet; qa_green!'s flip supersedes it.
    #   * already `assembled` (a straggler re-riding the RC, or a re-run after the
    #     QA-green flip landed) → a toward-`assembled` intent would (a) no-op in
    #     record_intent_event (the transition exists) and (b) read off the wrong
    #     (next) stage on the board — so record the QA intent toward `shipped` with
    #     the `qa` marker instead. It is superseded by the SHIP — the real
    #     transition that ENDS QA — and the board (StageAgentsHelper#open_deploy_intent)
    #     re-homes the marked intent into the ASSEMBLED lane, distinct from Avi's
    #     unmarked ship intent.
    # Idempotent + superseded-on-real-transition either way. Returns the intent (nil
    # once the member has shipped, so a shipped member's prepare call no-ops).
    def record_qa_intent(task, actor:)
      if task.stage == "assembled"
        task.record_intent_event(to_stage: "shipped", actor: actor, qa: true)
      else
        task.record_intent_event(to_stage: "assembled", actor: actor)
      end
    end

    # Record a [post-deploy] outcome line on a member task's devops.checks_run —
    # the audit trail for the command the release pipeline ran on the deployed app
    # (`bin/release prepare` → QA app, `ship` → prod app). IDEMPOTENT: a re-run
    # REPLACES the prior line for the SAME command+app instead of piling up
    # duplicates (post-deploy commands are expected idempotent, so prepare/ship are
    # re-runnable) — the recorded line always reflects the LAST outcome. Does NOT
    # change stage, so it writes no TaskEvent. Returns the updated checks_run array.
    def record_post_deploy_check(task_slug:, app:, cmd:, ok:, at: Time.current)
      task   = Task.find_by!(slug: task_slug)
      meta   = task.metadata.deep_dup
      devops = meta["devops"].is_a?(Hash) ? meta["devops"] : {}
      checks = Array(devops["checks_run"]).map(&:to_s)

      signature = "[post-deploy] #{cmd} on #{app}"
      checks.reject! { |line| line == signature || line.start_with?("#{signature} ") }
      checks << "#{signature} → #{ok ? 'ok' : 'FAILED'} (#{at.utc.iso8601})"

      devops["checks_run"] = checks
      meta["devops"] = devops
      task.update!(metadata: meta)
      checks
    end

    def record_event!(release:, step:, status:, **attrs)
      release.record_event!(step: step, status: status, **attrs)
    end

    # Build + deliver release notes for a shipped release — reusing the exact
    # Formatter + DiscordClient behind POST /api/v1/release_notes. Delivers rich
    # embeds (a summary + one card per task) when the release fits Discord's
    # 10-embed cap, else the plain-text fallback — the Formatter#discord_payload
    # chooser decides. Non-fatal by design: a missing webhook or delivery error
    # returns the message without delivering, so it never fails an
    # already-completed ship. Returns { message:, delivered: } (message is the
    # text render, kept for preview regardless of which payload shipped).
    def post_release_notes(release:, app: "mcritchie-studio", environment: "production", dry_run: false)
      unless release.event_started?("release_notes")
        record_event!(
          release: release,
          step: "release_notes",
          status: "started",
          source: "conductor",
          idempotency_key: "#{release.slug}:release_notes:started"
        )
      end

      formatter = ReleaseNotes::Formatter.new(
        app: app,
        environment: environment,
        release: release.slug,
        sha: release.deployed_sha,
        url: release.production_url,
        tasks: release.tasks.order(:position).to_a,
        # The post-ship smoke seal (bin/release step 5c recorded it BEFORE this), so
        # the notes body + Discord carry the SAME 🟢/🔴 verdict the board shows. nil
        # when unsealed (a manual / pre-seal ship) → the seal line is simply omitted.
        seal: release.smoke_seal
      )
      message = formatter.message

      delivered = false
      unless dry_run
        begin
          ReleaseNotes::DiscordClient.deliver(**formatter.discord_payload)
          delivered = true
        rescue StandardError => e
          # Defense in depth: this runs AFTER an irreversible prod deploy + ship!,
          # so a notification failure (missing webhook, HTTP error, or any
          # transport blip) must never raise. Swallow + log; the ship stands.
          Rails.logger.warn("[release-notes] delivery failed (non-fatal): #{e.class}: #{e.message}")
          delivered = false
        end
      end

      record_event!(
        release: release,
        step: "release_notes",
        status: "completed",
        source: "conductor",
        idempotency_key: "#{release.slug}:release_notes:completed"
      )

      { message: message, delivered: delivered }
    end

    # --- archive (the DevOps loop's conclusion: shipped → archived) ----------

    # The shipped tasks NOT carried by the last shipped release — exactly the set
    # `bin/release archive` would archive. A PURE read (no mutation), so it backs
    # the CLI's --dry-run preview. The operator-confirmed rule: archive every
    # `shipped` task that is NOT a member of Release.last_shipped. Pre-conductor
    # shipped tasks (no release_slug → in no release) fall in this set; the last
    # release's own members stay shipped as the board's read-only "Last Release".
    def archivable_completed_slugs
      keep = Release.last_shipped&.tasks&.pluck(:slug) || []
      Task.where(stage: "shipped").where.not(slug: keep).pluck(:slug)
    end

    # Archive every shipped task not carried by the last shipped release
    # (archivable_completed_slugs), leaving ONLY that release's members as the
    # board's "Last Release". NEVER touches active (designed…assembled) or blocked
    # tasks — they're outside the `shipped` scope by construction. Idempotent: a
    # re-run finds nothing new to archive. Wrapped in a transaction so a mid-batch
    # failure rolls the whole archive back. Returns
    # { archived: [slugs], kept: [slugs], count: N } (kept = the last-release
    # member slugs left as shipped).
    def archive_completed!
      slugs = archivable_completed_slugs
      kept  = Release.last_shipped&.tasks&.pluck(:slug) || []
      Task.transaction do
        Task.where(slug: slugs).find_each(&:archive!)
      end
      { archived: slugs, kept: kept, count: slugs.size }
    end

    # --- conductor mascot ------------------------------------------------------

    # Stamp the running conductor SESSION's Pokémon mascot onto `release` so the
    # deployments board shows who's working it. The session id rides in on
    # Current.conductor_session_id (set by bin/release's heroku-run payload, since
    # local shell env doesn't cross the boundary). A no-op when no session is in
    # context — so non-conductor callers (the board, model-driven flows) never
    # stamp. DEFENSIVE: the stamp runs alongside (and, at ship, AFTER) irreversible
    # deploy ops, so any failure is swallowed + logged — a mascot must never break
    # a release. Returns the release.
    def stamp_session_mascot(release)
      return release unless release

      sid = Current.conductor_session_id.to_s.strip
      return release if sid.empty?

      release.stamp_conductor_mascot!(sid)
    rescue StandardError => e
      Rails.logger.warn("[release-mascot] stamp failed (non-fatal): #{e.class}: #{e.message}")
      release
    end
  end
end
