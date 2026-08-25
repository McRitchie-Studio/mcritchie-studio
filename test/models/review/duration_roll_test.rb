# frozen_string_literal: true

require "test_helper"

module Review
  # The rolling review average, and — mostly — the two rules that decide what does
  # NOT count toward it. The exclusions are the whole reason the number is
  # trustworthy, so they get the bulk of the coverage here.
  class DurationRollTest < ActiveSupport::TestCase
    setup do
      Task.delete_all
      Activity.delete_all
      @now = Time.zone.parse("2026-08-25 12:00:00")
    end

    # --- the average itself ---------------------------------------------------

    test "the average covers the usable reviews and reports what it read" do
      review("clean-one", "turf-monster", minutes: 10, at: @now - 1.hour)
      review("clean-two", "turf-monster", minutes: 20, at: @now - 2.hours)

      roll = roll_for("turf-monster")

      assert_equal 15 * 60, roll.average_seconds
      assert_equal 2, roll.sample
      assert_equal 2, roll.scanned
      assert_equal 0, roll.excluded, "nothing was dropped, and the card says so"
    end

    test "a repo reads only its own reviews" do
      review("hub-review", "mcritchie-studio", minutes: 30, at: @now - 1.hour)
      review("turf-review", "turf-monster", minutes: 10, at: @now - 1.hour)

      assert_equal 30 * 60, roll_for("mcritchie-studio").average_seconds
      assert_equal 10 * 60, roll_for("turf-monster").average_seconds
    end

    # --- exclusion 1: ever blocked -------------------------------------------

    # A blocked task's review span runs from the FIRST claim to the LAST transition to
    # `reviewed` — so a send-back measures the whole build-fix-re-review round trip as
    # one review. That is what this rule keeps out.
    test "a task that was ever blocked is excluded" do
      review("was-blocked", "turf-monster", minutes: 5, at: @now - 1.hour, blocked: true)
      review("never-blocked", "turf-monster", minutes: 25, at: @now - 2.hours)

      roll = roll_for("turf-monster")

      assert_equal 25 * 60, roll.average_seconds, "the blocked review must not pull the average"
      assert_equal 1, roll.sample
      assert_equal 2, roll.scanned
      assert_equal 1, roll.excluded
    end

    # A RESOLVED block still excludes. The rule is "was blocked at any point", not
    # "is blocked now" — Task#ever_blocked? reads the durable qa_feedback ledger, and
    # a cleared block leaves that row behind exactly so this stays answerable.
    test "a resolved block still excludes the task" do
      task = review("blocked-then-cleared", "turf-monster", minutes: 5, at: @now - 1.hour, blocked: true)
      task.update_columns(stage: "shipped", blocked_at: nil)

      assert_equal 0, roll_for("turf-monster").sample
      assert_equal 1, roll_for("turf-monster").excluded
    end

    # --- exclusion 2: over sixty minutes -------------------------------------

    test "a review over sixty minutes is excluded" do
      review("marathon", "turf-monster", minutes: 61, at: @now - 1.hour)
      review("normal", "turf-monster", minutes: 9, at: @now - 2.hours)

      roll = roll_for("turf-monster")

      assert_equal 9 * 60, roll.average_seconds
      assert_equal 1, roll.sample
      assert_equal 1, roll.excluded
    end

    # THE BOUNDARY, pinned in both directions. The cut is "over 60 minutes", so
    # exactly sixty is IN. One second past it is out.
    test "exactly sixty minutes is kept and sixty-and-one-second is not" do
      review("on-the-line", "turf-monster", seconds: Review::DurationRoll::MAX_SECONDS, at: @now - 1.hour)
      review("just-over", "turf-monster", seconds: Review::DurationRoll::MAX_SECONDS + 1, at: @now - 2.hours)

      roll = roll_for("turf-monster")

      assert_equal 1, roll.sample
      assert_equal Review::DurationRoll::MAX_SECONDS, roll.average_seconds
      assert_equal 2, roll.scanned
    end

    # --- the window -----------------------------------------------------------

    test "the average covers at most the last ten usable reviews, newest first" do
      # 12 clean reviews, oldest first at 10 minutes rising to the newest at 120... but
      # capped at 60 so they stay usable: 5..16 minutes, newest = 16.
      12.times do |i|
        review("roll-#{format('%02d', i)}", "turf-monster", minutes: 5 + i, at: @now - (12 - i).hours)
      end

      roll = roll_for("turf-monster")

      assert_equal 10, roll.sample
      assert roll.full?
      # Newest ten are 7..16 minutes -> mean 11.5 minutes. The oldest two (5, 6) are
      # never read, so they are not "excluded" either — scanned counts what was read.
      assert_equal ((7..16).sum / 10.0 * 60).round, roll.average_seconds
      assert_equal 10, roll.scanned
      assert_equal 0, roll.excluded
    end

    test "excluded reviews are read past, so the window still fills to ten" do
      # Newest three are unusable; the ten behind them are clean.
      3.times { |i| review("bad-#{i}", "turf-monster", minutes: 90, at: @now - (i + 1).minutes) }
      10.times { |i| review("good-#{i}", "turf-monster", minutes: 12, at: @now - (i + 1).hours) }

      roll = roll_for("turf-monster")

      assert_equal 12 * 60, roll.average_seconds
      assert_equal 10, roll.sample
      assert_equal 13, roll.scanned, "it read past the three outliers to fill the ten"
      assert_equal 3, roll.excluded, "and the card can say '3 of 13 excluded'"
    end

    # The scan is BOUNDED. A repo whose recent history is all outliers must not walk
    # its whole history looking for ten — and the overshoot it reports is the truth
    # about that rough patch, not a silent truncation.
    test "the scan stops at SCAN_LIMIT and reports what it read" do
      (Review::DurationRoll::SCAN_LIMIT + 5).times do |i|
        review("outlier-#{format('%02d', i)}", "turf-monster", minutes: 90, at: @now - (i + 1).minutes)
      end

      roll = roll_for("turf-monster")

      assert_equal 0, roll.sample
      assert_equal Review::DurationRoll::SCAN_LIMIT, roll.scanned
      assert_equal Review::DurationRoll::SCAN_LIMIT, roll.excluded
    end

    # --- what is a candidate at all ------------------------------------------

    test "a review still in flight is not a candidate" do
      task = review("in-flight", "turf-monster", minutes: 10, at: @now - 1.hour)
      task.update_columns(testing_phases: {
        "cache_version" => Task::TestingPhases::VERSION,
        "phases" => { "review" => { "status" => "in_progress", "seconds" => 600,
                                    "started_at" => (@now - 10.minutes).iso8601,
                                    "completed_at" => nil, "source" => "gate_run" } }
      })

      assert_equal 0, roll_for("turf-monster").scanned, "an unfinished review has no duration to average"
    end

    # ARCHIVE IS BOOKKEEPING, not a statement about the review. On 2026-08-25 all but
    # a handful of measured reviews sat in `archived`; dropping them would have
    # emptied four of the five cards.
    test "an archived task still counts" do
      task = review("long-since-done", "turf-monster", minutes: 14, at: @now - 1.hour)
      task.update_columns(stage: "archived")

      assert_equal 14 * 60, roll_for("turf-monster").average_seconds
    end

    # --- multi-repo attribution ----------------------------------------------

    # A multi-repo task PARKS on every repo it names (Ci::AppLadder) but its DURATION
    # belongs to one: crediting one review to two apps inflates both averages with the
    # same measurement.
    test "a multi-repo task is attributed to the repo of the PR that merged" do
      review("spans-two-repos", "mcritchie-studio", minutes: 20, at: @now - 1.hour,
             repos: %w[mcritchie-studio turf-monster],
             pr_url: "https://github.com/McRitchie-Studio/turf-monster/pull/42")

      assert_equal 20 * 60, roll_for("turf-monster").average_seconds,
                   "the PR merged in turf-monster, so turf-monster owns the duration"
      assert_equal 0, roll_for("mcritchie-studio").scanned,
                   "and the hub must not be credited with the same review"
    end

    # --- the empty and partial states ----------------------------------------

    # A card must never render a blank or a NaN, so every requested repo gets a Roll.
    test "a repo with no measured review gets an empty roll, never a missing key" do
      rolls = Review::DurationRoll.by_repo(repos: %w[solana-studio])
      roll = rolls.fetch("solana-studio")

      assert_nil roll.average_seconds
      assert_equal 0, roll.sample
      assert_equal 0, roll.scanned
      refute roll.any?
      refute roll.all_excluded?, "nothing was read, so nothing was excluded"
    end

    test "a repo whose only reviews were all excluded says so distinctly" do
      review("only-one-and-blocked", "turf-monster", minutes: 5, at: @now - 1.hour, blocked: true)

      roll = roll_for("turf-monster")

      refute roll.any?
      assert roll.all_excluded?, "read-and-dropped is a different state from never-reviewed"
      assert_equal 1, roll.excluded
    end

    test "a partial sample is not full" do
      review("only-review", "turf-monster", minutes: 10, at: @now - 1.hour)

      roll = roll_for("turf-monster")

      assert roll.any?
      refute roll.full?, "one review is not a rolling ten and the card must not imply it is"
      assert_equal 1, roll.sample
    end

    # --- batching -------------------------------------------------------------

    # THE N+1 GUARD. Every card's roll comes out of ONE read of the candidate pool
    # plus ONE blocked-slug lookup, no matter how many repos are asked for.
    test "every repo's roll costs the same two queries as one repo's" do
      %w[turf-monster mcritchie-studio studio-engine].each_with_index do |repo, i|
        review("batch-#{i}", repo, minutes: 10, at: @now - (i + 1).hours)
      end

      # UNCACHED on purpose. The candidate read is repo-independent by design, so
      # Rails' query cache would serve the second call from memory and both counts
      # would come back 0 — a green that proves nothing about the code under test.
      one = count_queries { ActiveRecord::Base.uncached { Review::DurationRoll.by_repo(repos: %w[turf-monster]) } }
      all = count_queries do
        ActiveRecord::Base.uncached { Review::DurationRoll.by_repo(repos: Ci::AppLadder.reportable_repos) }
      end

      assert_equal one, all,
                   "reading five cards must cost what reading one costs — this row is not a per-card lookup"
      assert_operator all, :<=, 2, "one candidate read + one blocked-slug read"
    end

    private

    def roll_for(repo) = Review::DurationRoll.by_repo(repos: [repo]).fetch(repo)

    # A task carrying a COMPLETED review span of the given length, finished at `at`.
    # testing_phases is written with update_columns AFTER create on purpose: creating
    # the task fires Task#refresh_testing_phases_after_change, which would recompute
    # (and blank) a projection set inline.
    def review(slug, repo, at:, minutes: nil, seconds: nil, blocked: false, repos: nil, pr_url: nil)
      seconds ||= minutes * 60
      devops = { "repositories" => repos || [repo] }
      devops["pr_url"] = pr_url if pr_url
      task = Task.create!(slug: slug, title: "Review Roll Fixture #{slug.split('-').first.capitalize}",
                          stage: "reviewed", merged: Task::MERGED_ACCEPTED,
                          metadata: { "devops" => devops })
      task.update_columns(
        testing_phases: {
          "cache_version" => Task::TestingPhases::VERSION,
          "phases" => { "review" => { "status" => "completed", "seconds" => seconds,
                                      "started_at" => (at - seconds).iso8601,
                                      "completed_at" => at.iso8601, "source" => "gate_run" } }
        },
        testing_phases_version: Task::TestingPhases::VERSION
      )
      Activity.create!(task_slug: slug, activity_type: "qa_feedback", description: "sent back") if blocked
      task
    end

    def count_queries
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) do
        count += 1 unless payload[:name].to_s.in?(%w[SCHEMA TRANSACTION CACHE]) || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end
  end
end
