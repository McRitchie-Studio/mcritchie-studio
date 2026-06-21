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
      release = Release.current || Release.open!(slug.present? ? { slug: slug } : {})
      release.reopen! if release.state == "assembled"
      release.update!(branch: "release/#{release.slug.sub(/\Arel-/, '')}") if release.branch.blank?

      Task.where(slug: slugs).each do |task|
        release.add(task) unless release.tasks.exists?(slug: task.slug)
      end

      release.assemble!
      release
    end

    # Stamp the deployed commit + flip the RC (and its member tasks) to shipped.
    def ship!(release:, deployed_sha:, by: nil, production_url: nil)
      release.update!(
        deployed_sha: deployed_sha,
        production_url: production_url.presence || release.production_url
      )
      release.ship!(by: by)
      release
    end

    # The reviewed tasks eligible to ride the next release (the default queue the
    # CLI assembles when no explicit slugs are given).
    def eligible_task_slugs
      Task.where(stage: "reviewed").order(:position).pluck(:slug)
    end
  end
end
