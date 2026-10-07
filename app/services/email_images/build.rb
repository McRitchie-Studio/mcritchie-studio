# frozen_string_literal: true

module EmailImages
  # ONE PAID ROUND PER BRIEF AT A TIME, OFF THE REQUEST — Appearances::SheetBuild's
  # claim/take/finish pattern, on the brief row.
  #
  # The claim is one conditional UPDATE that also spends the round: a brief is
  # claimed only if it is not already building (or its building is stale) AND it
  # has a round left, so two presses cannot both win and a fifth round cannot
  # start. The job takes the claim before the paid call, so a re-run or a job
  # left behind by a stale reclaim returns without spending, and only the build
  # holding the claim may close it.
  class Build
    STALE_AFTER = 15.minutes
    BUILDING = EmailImageBrief::BUILDING
    DONE = EmailImageBrief::DONE
    FAILED = EmailImageBrief::FAILED

    STARTED_NOTICE = "Generating header candidates in the background; each takes a minute or two. " \
                     "The page refreshes itself until they are done."

    class Busy < StandardError; end

    REFUSALS = [Busy, Generate::NoGenerator, Generate::RoundsExhausted, Generate::MissingReference].freeze

    def self.start!(brief, count: nil, notes: nil)
      Generate.new(brief, count: count).check!
      started_at = claim!(brief)
      EmailImageBuildJob.perform_later(brief.slug, started_at.iso8601(6), count, Prompt.clean_notes(notes))
      started_at
    rescue *REFUSALS
      raise
    rescue StandardError => e
      finish(brief, started_at, FAILED, e.message) if started_at
      raise
    end

    # THE CLI'S ROUND (bin/email-image generate): the same free refusals, the
    # same claim, the same take/finish, run in this process instead of a job so
    # the agent driving the SOP gets its candidates back in one command. Returns
    # the claim time; the brief's build_state says whether the round succeeded.
    def self.run_now!(brief, count: nil, notes: nil)
      Generate.new(brief, count: count).check!
      started_at = claim!(brief)
      run(brief, started_at: started_at, count: count, notes: notes)
      started_at
    end

    def self.claim!(brief)
      now = Time.current.floor(6)
      claimed = EmailImageBrief.where(id: brief.id)
                               .where("build_state IS DISTINCT FROM ? OR build_started_at IS NULL " \
                                      "OR build_started_at < ?", BUILDING, now - STALE_AFTER)
                               .where("rounds_used < max_rounds")
                               .update_all(["build_state = ?, build_started_at = ?, build_finished_at = NULL, " \
                                            "build_error = NULL, rounds_used = rounds_used + 1, updated_at = ?",
                                            BUILDING, now, now])
      raise Busy, busy_message(brief) if claimed.zero?

      now
    end

    def self.run(brief, started_at:, count: nil, notes: nil)
      running_at = take(brief, started_at)
      return unless running_at

      begin
        # The claim spent the round, so the row's counter IS this round's number.
        round = EmailImageBrief.where(id: brief.id).pick(:rounds_used)
        Generate.call(brief, count: count, round: round, notes: notes)
        finish(brief, running_at, DONE)
      rescue *REFUSALS => e
        finish(brief, running_at, FAILED, e.message)
      rescue StandardError => e
        log = ErrorLog.capture!(e)
        log.target = brief
        log.target_name = brief.slug
        log.save!
        finish(brief, running_at, FAILED, e.message)
      end
    end

    def self.take(brief, started_at)
      running_at = [Time.current.floor(6), started_at + Rational(1, 1_000_000)].max
      taken = EmailImageBrief.where(id: brief.id, build_state: BUILDING, build_started_at: started_at)
                             .update_all(build_started_at: running_at, updated_at: Time.current)
      running_at if taken == 1
    end

    def self.finish(brief, started_at, state, error = nil)
      EmailImageBrief.where(id: brief.id, build_state: BUILDING, build_started_at: started_at)
                     .update_all(build_state: state, build_finished_at: Time.current,
                                 build_error: error, updated_at: Time.current)
    end

    def self.busy_message(brief)
      row = EmailImageBrief.where(id: brief.id).pick(:build_state, :build_started_at, :rounds_used, :max_rounds)
      state, started, used, max = row
      if used.to_i >= max.to_i && state != BUILDING
        return "This brief has used all #{max} rounds. Nothing new was started or spent."
      end

      since = started ? " (started #{ActiveSupport::Duration.build((Time.current - started).round).inspect} ago)" : ""
      "Candidates are already generating for this brief#{since}. Nothing new was started or spent."
    end
  end
end
