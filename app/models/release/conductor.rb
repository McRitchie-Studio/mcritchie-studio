class Release
  # Orchestrates the release-record lifecycle behind the `bin/release` CLI (and
  # the "Prepare release" / "Run Deployment" kickoffs). The git + deploy mechanics
  # live in the CLI; this owns the record state so it stays testable and
  # deterministic regardless of who/what runs it.
  module Conductor
    module_function

    # Record a PR-merge INTO the persistent `release` branch: attach the task to
    # the active release (opening one if none is active), flipping the TASK from
    # `reviewed` to `assembled`. This is the membership-at-merge entrypoint that
    # `bin/release merge` calls after `gh pr merge`. Returns the release. Raises
    # (via Release#add) if the task isn't `reviewed`.
    #
    # Idempotent AND self-healing: a member already riding the train at
    # `assembled` is left untouched, but a member still ATTACHED (release_slug
    # set) whose stage has regressed off `assembled` — e.g. a re-review reverted
    # the stage while keeping membership, the live half-state — is RE-RUN through
    # `add` (which flips a `reviewed` member back to `assembled`, reopening the RC
    # if it had assembled, and raises for any other stage per the top line). The
    # old `unless exists?` guard no-op'd that case, so the half-state could never
    # self-heal and had to be fixed by hand.
    #
    # `override: true` is the audited `bin/release merge --override` escape hatch:
    # it lets `add` attach a NOT-yet-`reviewed` task, AND it stamps the review skip
    # onto the audit spine. The bypass marker rides on the SAME transition event the
    # flip writes (Current.task_event_review_bypass → Task#write_stage_event), so the
    # override leaves a `review_bypassed` paper-trail row — never a silent skip. The
    # flag is reset in `ensure` so it can't leak onto a later (in-process) transition.
    def adopt!(task, override: false)
      release = Release.current_or_open!
      member = release.tasks.find_by(slug: task.slug)
      target = member || task
      # Only flag a genuine bypass: an override on an already-`reviewed` (or
      # already-`assembled`) target changes nothing, so it records no skip.
      Current.task_event_review_bypass = true if override && !%w[reviewed assembled].include?(target.stage)

      if member.nil?
        release.add(task, override: override)
      elsif member.stage != "assembled"
        # Hand any non-`assembled` member back to `add` — NOT a narrower
        # `== "reviewed"` check. `add` heals a `reviewed` one and deliberately
        # RAISES for any other stage (blocked, etc.), mirroring the nil → add(task)
        # path above. Narrowing to `== "reviewed"` here would silently no-op those
        # off-path members, reintroducing the asymmetry the review flagged.
        release.add(member, override: override)
      end
      release
    ensure
      Current.task_event_review_bypass = nil
    end

    # Pre-flight REVIEW-GATE screen for `bin/release merge` — the decision the CLI
    # runs over the requested slugs BEFORE any `gh pr merge`, so an unreviewed PR
    # can't be merged onto `release` by accident (the incident: PR #138 merged
    # straight in during the scheduled wait). A PURE read: it only CLASSIFIES; the
    # bypass itself is RECORDED later, on the audit spine, when adopt! flips an
    # overridden member (see adopt!). Each slug is one of:
    #   "reviewed"   — passed review, safe to merge
    #   "blocked"    — NOT reviewed and no --override → the run must abort
    #   "overridden" — NOT reviewed but --override given → proceeds, audited at adopt!
    #   "missing"    — no such task on the board
    # Returns a JSON-serializable decision:
    #   { rows: [{slug, stage, status}], blocked:[slug], overridden:[slug],
    #     missing:[slug], proceed: bool }  (proceed=false iff any slug is blocked).
    def screen_merge(slugs, override: false)
      rows = Array(slugs).map do |slug|
        task   = Task.find_by(slug: slug)
        status =
          if task.nil?                   then "missing"
          elsif task.stage == "reviewed" then "reviewed"
          elsif override                 then "overridden"
          else                                "blocked"
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

    # Assemble the active release for QA. On the persistent-`release` model
    # membership flips at PR-merge time (adopt!), so prepare! is NO LONGER the
    # add path: with no `task_slugs` it just finds the current release and
    # assembles it (the CLI then deploys `origin/release` to QA). It does NOT
    # auto-add reviewed work.
    #
    # `task_slugs` stays for OPERATOR CURATION — explicitly named tasks are
    # adopt!ed onto the release before assembling (producer-first so members land
    # at producer-before-consumer positions). Atomic: a non-reviewed or
    # unknown-repo member raises and rolls the whole prepare! back — no dangling
    # `assembling` release left behind. Returns the release (nil if none active
    # and none curated).
    def prepare!(task_slugs: [], slug: nil)
      Release.transaction do
        release = curate!(task_slugs: task_slugs, slug: slug)
        return release unless release

        assemble!(release)
        release
      end
    end

    # The CURATE half of prepare! — adopt any operator-named `task_slugs` onto the
    # active release (opening one if none + a `slug` is given) and validate the
    # members, but DO NOT assemble. Split out so the boot-gated CLI can curate +
    # deploy + wait_for_boot, then assemble ONLY after QA is confirmed up (the
    # slow-dyno race that left the RC stuck `assembling`).
    #
    # SELF-ATOMIC: wraps its own body in a transaction. The atomicity can't be
    # borrowed from prepare!'s wrapper, because the production caller
    # `bin/release prepare` invokes curate! STANDALONE (its own process, no outer
    # DB txn). Without the wrapper a validate_members! raise AFTER adopt! has
    # opened a candidate and flipped members to `assembled` would strand a
    # half-curated release on the board — and the single-active-release rule then
    # makes that stranded RC block every other session. The transaction rolls the
    # whole curation back instead. Nested inside prepare!'s transaction, AR joins
    # the outer txn, so this is a no-op wrapper there. Producer-first. Returns the
    # active release, or nil when none is active and none was curated.
    def curate!(task_slugs: [], slug: nil)
      Release.transaction do
        slugs = Array(task_slugs).compact
        if slugs.any?
          Release.open!(slug: slug) if slug.present? && Release.current.nil?
          Release::Ordering.producer_first(Task.where(slug: slugs).to_a).each { |task| adopt!(task) }
        end

        release = Release.current

        # Repo-aware eligibility: a release can't deploy a repo it doesn't know how
        # to deploy. An unknown-repo member raises here, rolling the whole curation
        # back (the opened candidate + the adopt!-flipped members) via the wrapper
        # transaction above.
        validate_members!(release) if release
        release
      end
    end

    # Flip the curated, QA-deployed RC assembling→assembled — the ASSEMBLE half of
    # prepare!. Idempotent: a no-op when the release is already assembled, so
    # re-running prepare! against an in-flight RC (no new members) never errors.
    # The CLI calls this LAST, after wait_for_boot confirms the QA dyno is up, so a
    # slow boot can't leave the RC flipped `assembled` against an app that isn't
    # actually serving.
    def assemble!(release)
      release.assemble! if release.state == "assembling"
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
    # post_deploy_cmd }. `branch` is the member's feature branch (apps merge it;
    # gems have none and ride the record). `version` is the gem's declared version
    # (nil for apps, and nil for gems when the version_file isn't reachable — the
    # CLI resolves it locally at publish time). `post_deploy_cmd` is the optional
    # one-off command (a shell/rake line) the pipeline runs on the deployed app
    # AFTER it boots — on the QA app in `prepare`, the prod app in `ship` (nil when
    # the task declares none). This is what `bin/release` reads to skip the merge
    # for gems, publish them producer-first at ship, and run the post-deploy hook.
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
          post_deploy_cmd: task.devops_field("post_deploy_cmd")
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

    # Stamp the deployed commit + flip the RC (and its member tasks) to shipped.
    def ship!(release:, deployed_sha:, by: nil, production_url: nil)
      Release.transaction do
        release.update!(
          deployed_sha: deployed_sha,
          production_url: production_url.presence || release.production_url
        )
        release.ship!(by: by)
      end
      release
    end

    # The reviewed tasks eligible to ride the next release (the default queue the
    # CLI assembles when no explicit slugs are given).
    def eligible_task_slugs
      Task.where(stage: "reviewed").order(:position).pluck(:slug)
    end

    # Record the QA deployment URL on the release (the deploy itself is run by
    # bin/qa-server). Lets the board's current-release header link straight to QA.
    def record_qa_deploy(release:, qa_url:)
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

    # Build + deliver release notes for a shipped release — reusing the exact
    # Formatter + DiscordClient behind POST /api/v1/release_notes. Non-fatal by
    # design: a missing webhook or delivery error returns the message without
    # delivering, so it never fails an already-completed ship. Returns
    # { message:, delivered: }.
    def post_release_notes(release:, app: "mcritchie-studio", environment: "production", dry_run: false)
      message = ReleaseNotes::Formatter.new(
        app: app,
        environment: environment,
        release: release.slug,
        sha: release.deployed_sha,
        url: release.production_url,
        tasks: release.tasks.order(:position).to_a
      ).message

      delivered = false
      unless dry_run
        begin
          ReleaseNotes::DiscordClient.deliver(content: message)
          delivered = true
        rescue StandardError => e
          # Defense in depth: this runs AFTER an irreversible prod deploy + ship!,
          # so a notification failure (missing webhook, HTTP error, or any
          # transport blip) must never raise. Swallow + log; the ship stands.
          Rails.logger.warn("[release-notes] delivery failed (non-fatal): #{e.class}: #{e.message}")
          delivered = false
        end
      end

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
  end
end
