# frozen_string_literal: true

module Appearances
  # ONE CHARACTER-SHEET BUILD PER LOOK, OFF THE REQUEST. A build takes about two
  # minutes and Heroku cuts a request at 30 s, so the paid call runs in
  # SheetBuildJob and the look carries its state (building / done / failed).
  #
  # THE GUARD IS ONE CONDITIONAL UPDATE: a look is claimed only if the row is not
  # already building (or its building is stale), so two presses cannot both win.
  # A build older than STALE_AFTER is treated as crashed and may be replaced.
  class SheetBuild
    STALE_AFTER = 15.minutes
    BUILDING = "building"
    DONE = "done"
    FAILED = "failed"

    STARTED_NOTICE = "Building the character sheet in the background; it takes about two minutes. " \
                     "The page refreshes itself until it is done."

    class Busy < StandardError; end

    # The readiness refusals (NoGenerator, NoIdentityPhoto) raise here, before
    # anything is claimed, so the operator reads them at once.
    def self.start!(appearance, number: nil)
      Appearances::GenerateArtifact.new(appearance, number: number).check!
      started_at = claim!(appearance)
      SheetBuildJob.perform_later(appearance.slug, started_at.iso8601(6), number)
      started_at
    rescue Busy, Appearances::GenerateArtifact::NoGenerator, Appearances::GenerateArtifact::NoIdentityPhoto
      raise
    rescue StandardError => e
      finish(appearance, started_at, FAILED, e.message) if started_at
      raise
    end

    # Returns the claim's started_at (the token the job finishes against).
    def self.claim!(appearance)
      now = Time.current.floor(6)
      claimed = Appearance.where(id: appearance.id)
                          .where("sheet_build_state IS DISTINCT FROM ? OR sheet_build_started_at IS NULL " \
                                 "OR sheet_build_started_at < ?", BUILDING, now - STALE_AFTER)
                          .update_all(sheet_build_state: BUILDING, sheet_build_started_at: now,
                                      sheet_build_finished_at: nil, sheet_build_error: nil, updated_at: now)
      raise Busy, busy_message(appearance) if claimed.zero?

      now
    end

    # Runs in the job. Takes the build before the paid call, so a re-run of the
    # same job or a job left behind by a stale reclaim returns without spending.
    def self.run(appearance, started_at:, number: nil)
      running_at = take(appearance, started_at)
      return unless running_at

      begin
        Appearances::GenerateArtifact.call(appearance, number: number)
        finish(appearance, running_at, DONE)
      rescue Appearances::GenerateArtifact::NoGenerator, Appearances::GenerateArtifact::NoIdentityPhoto => e
        finish(appearance, running_at, FAILED, e.message)
      rescue StandardError => e
        log = ErrorLog.capture!(e)
        log.target = appearance
        log.target_name = appearance.slug
        log.save!
        finish(appearance, running_at, FAILED, e.message)
      end
    end

    # Swaps the claim's started_at for the run's own: the new value is the token
    # this run finishes against, and the stale window restarts from here, not
    # from enqueue. Returns nil when the claim is no longer this job's.
    def self.take(appearance, started_at)
      running_at = [Time.current.floor(6), started_at + Rational(1, 1_000_000)].max
      taken = Appearance.where(id: appearance.id, sheet_build_state: BUILDING, sheet_build_started_at: started_at)
                        .update_all(sheet_build_started_at: running_at, updated_at: Time.current)
      running_at if taken == 1
    end

    # Only the build that holds the claim may close it; a stale build that
    # finishes late leaves its replacement alone.
    def self.finish(appearance, started_at, state, error = nil)
      Appearance.where(id: appearance.id, sheet_build_state: BUILDING, sheet_build_started_at: started_at)
                .update_all(sheet_build_state: state, sheet_build_finished_at: Time.current,
                            sheet_build_error: error, updated_at: Time.current)
    end

    def self.busy_message(appearance)
      started = Appearance.where(id: appearance.id).pick(:sheet_build_started_at)
      since = started ? " (started #{ActiveSupport::Duration.build((Time.current - started).round).inspect} ago)" : ""
      "A character sheet is already building for this look#{since}. Nothing new was started or spent."
    end
  end
end
