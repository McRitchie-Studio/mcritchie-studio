class Release
  # Orchestrates the release-record lifecycle behind the `bin/release` CLI (and
  # the "Prepare release" / "Run Deployment" kickoffs). The git + deploy mechanics
  # live in the CLI; this owns the record state so it stays testable and
  # deterministic regardless of who/what runs it.
  module Conductor
    module_function

    # Additive find-or-create: extend the active release if one exists (reopening
    # an assembled RC so the new work re-QAs), else open a fresh one. Adds each
    # given reviewed task that isn't already a member, then re-assembles.
    # Returns the release. Raises (via Release#add) if a task isn't `reviewed`.
    def prepare!(task_slugs:, slug: nil)
      slugs = Array(task_slugs).compact
      # Atomic: if any task isn't reviewed, Release#add raises and the whole
      # thing rolls back — no dangling `assembling` release left behind.
      Release.transaction do
        release = Release.current || Release.open!(slug.present? ? { slug: slug } : {})
        release.reopen! if release.state == "assembled"
        release.update!(branch: "release/#{release.slug.sub(/\Arel-/, '')}") if release.branch.blank?

        # Add in producer-first order so members land at producer-before-consumer
        # positions (gems before the apps that consume them). `add` raises if a
        # task isn't reviewed — inside the transaction, so a bad task rolls the
        # whole thing back.
        Release::Ordering.producer_first(Task.where(slug: slugs).to_a).each do |task|
          release.add(task) unless release.tasks.exists?(slug: task.slug)
        end

        release.assemble!
        release
      end
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
          branch: task.devops_field("branch"),
          kind: kind.to_s,
          repo: task.release_repo,
          version: kind == :gem ? Release::Repos.gem_version(task.release_repo) : nil
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
  end
end
