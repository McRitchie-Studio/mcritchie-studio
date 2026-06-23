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
    # `bin/release merge` calls after `gh pr merge`. Idempotent: a task already
    # on the release is left untouched. Returns the release. Raises (via
    # Release#add) if the task isn't `reviewed`.
    def adopt!(task)
      release = Release.current_or_open!
      release.add(task) unless release.tasks.exists?(slug: task.slug)
      release
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
    # slow-dyno race that left the RC stuck `assembling`). Atomic + producer-first
    # like prepare! was. Returns the active release, or nil when none is active and
    # none was curated.
    def curate!(task_slugs: [], slug: nil)
      slugs = Array(task_slugs).compact
      if slugs.any?
        Release.open!(slug: slug) if slug.present? && Release.current.nil?
        Release::Ordering.producer_first(Task.where(slug: slugs).to_a).each { |task| adopt!(task) }
      end

      release = Release.current
      return release unless release

      # Repo-aware eligibility: a release can't deploy a repo it doesn't know how
      # to deploy. An unknown-repo member raises here (inside prepare!'s
      # transaction) before any assemble, rolling the whole curation back.
      validate_members!(release)
      release
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
    # each entry is { slug, branch, kind ("gem"/"app"), repo, version }. `branch`
    # is the member's feature branch (apps merge it; gems have none and ride the
    # record). `version` is the gem's declared version (nil for apps, and nil for
    # gems when the version_file isn't reachable — the CLI resolves it locally at
    # publish time). This is what `bin/release` reads to skip the merge for gems
    # and to publish them producer-first at ship.
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
          version: kind == :gem ? Release::Repos.gem_version(task.release_repo) : nil
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
