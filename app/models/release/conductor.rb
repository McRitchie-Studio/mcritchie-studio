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

        Task.where(slug: slugs).each do |task|
          release.add(task) unless release.tasks.exists?(slug: task.slug)
        end

        release.assemble!
        release
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
        rescue ReleaseNotes::DiscordClient::MissingWebhook, ReleaseNotes::DiscordClient::DeliveryError
          delivered = false
        end
      end

      { message: message, delivered: delivered }
    end
  end
end
