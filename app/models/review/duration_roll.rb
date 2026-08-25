# frozen_string_literal: true

module Review
  # HOW LONG PR REVIEW TAKES ON THIS APP LATELY — the rolling average the
  # /deployments application cards carry, one Roll per repo.
  #
  # WHAT IS MEASURED. Wall clock, from the moment the review crew FIRST claims the
  # task to the moment its PR is merged into `accepted`. Both ends are already
  # defined — and already materialized — by Task::TestingPhases' `review` phase, so
  # this class deliberately computes NO span of its own:
  #
  #   start  ← the FIRST G2 gate attempt's started_at (TestingPhases#first_review_gate_run).
  #            FIRST, not most recent: a claim that lapses and is re-acquired is still
  #            the same review, and the operator chose the simple definition over one
  #            that subtracts the interruption gaps.
  #   finish ← the LAST transition to `reviewed`, which BY THE PIPELINE INVARIANT
  #            (`reviewed` ⟺ code-on-`accepted`) is the moment the PR merged onto
  #            `accepted`. Review merges and then moves the task; a merge failure
  #            leaves it `submitted`, so a `reviewed` stamp IS a merge.
  #
  # Reading the projection rather than re-deriving from gate_runs + task_events is the
  # whole point: /tasks/<slug> and /tasks/recent already render this number as the
  # "Review" phase, and a second definition living here is how two surfaces start
  # disagreeing about the same review. One rule, one place.
  #
  # WHY NOT TaskReviewClaim. It is not a history — task_slug is validated UNIQUE, one
  # live row per task, released on verdict. The claim timestamp is gone the moment
  # review ends. GateRun (via the projection) is the durable record.
  #
  # THE TWO EXCLUSIONS, both outlier rules, both operator-chosen:
  #
  #   · EVER BLOCKED — any task that carried a qa_feedback activity (`bin/task block`,
  #     a review send-back) at any point. Same signal the board's own card tone reads
  #     (Task#ever_blocked?, the board's @ever_blocked_slugs). This is doing more work
  #     than "a blocked review was slow": the projection's finish is the LAST
  #     transition to `reviewed`, so a task reviewed → blocked → rebuilt → re-reviewed
  #     measures the whole round trip as one review. Excluding it is what keeps that
  #     round trip out of the average.
  #   · OVER 60 MINUTES — MAX_SECONDS. Load-bearing rather than cosmetic: it is what
  #     absorbs a review interrupted by a session limit or a lapsed claim, where the
  #     gate stayed open across a gap nobody was reviewing in. Measured 2026-08-25
  #     against production, the spans it catches are 91m, 132m, 138m, 292m, 293m and
  #     2200m — none of them an hour of anyone's attention.
  #
  # BECAUSE THE CUT DOES REAL WORK, THE CARD MUST SHOW IT. A bare average hides how
  # much it is dropping, so every Roll carries `scanned` beside `sample` and the card
  # renders "3 of 13 excluded". That is not decoration; it is the honesty the 60m rule
  # costs.
  #
  # MULTI-REPO ATTRIBUTION. A task can name several repos (devops.repositories), and
  # Ci::AppLadder deliberately parks it on EVERY one — a multi-repo task is not "in"
  # one of them. A DURATION is different: crediting one review to two apps inflates
  # both averages with the same measurement. So a review is attributed to ONE repo —
  # Task#release_repo, the repo of the PR that actually merged (parsed from `pr_url`,
  # falling back to the declared repos when no PR url was recorded).
  #
  # THE WINDOW. Newest first, keep the usable ones until SAMPLE_SIZE are held or
  # SCAN_LIMIT have been looked at. `scanned` is the denominator the card reports, so
  # "3 of 13 excluded" means exactly: 13 recent reviews were read, 3 failed a rule,
  # 10 were averaged. SCAN_LIMIT bounds a repo whose recent history is mostly
  # outliers, and it is REPORTED rather than silent — a card reading "30 of 40
  # excluded" is telling the truth about a rough patch.
  #
  # ONE QUERY FOR EVERY CARD, not one per card — the N+1 this board has been bitten
  # by before. `by_repo` reads the candidate pool once and folds it in memory, the
  # same shape as Ci::AppLadder.parked_index and TasksController's
  # @ever_blocked_slugs / @ci_progress_by_slug batches.
  #
  # LIVE, NOT CACHED AT DEPLOY. Nothing is stored: the projection refreshes on every
  # stage change and every TaskEvent (Task#refresh_testing_phases_after_change), and
  # DeploymentsBroadcaster.app_ladder already re-renders this row on
  # saved_change_to_merged? || saved_change_to_stage? — which is precisely the write
  # that lands a review. The average moves as reviews land, with no caching pass to
  # wait for.
  class DurationRoll
    # The rolling window: how many usable reviews the average is taken over.
    SAMPLE_SIZE = 10
    # How far back a repo is read looking for those ten. Bounds a repo whose recent
    # history is mostly excluded; the overshoot is reported, never hidden.
    SCAN_LIMIT = 40
    # The outlier cut. A "review" longer than this is a window nobody was reviewing in.
    MAX_SECONDS = 60 * 60
    # The ecosystem-wide candidate pool read in the single query, newest review first.
    # Sized well past what every card's window can consume (5 cards x SCAN_LIMIT = 200)
    # and past the ENTIRE measured review history of the ecosystem (115 tasks with a
    # closed G2 span on 2026-08-25), so today it is a backstop rather than a filter.
    CANDIDATE_POOL = 250

    # The `review` phase span inside the materialized testing_phases jsonb.
    STATUS_PATH   = "{phases,review,status}"
    SECONDS_PATH  = "{phases,review,seconds}"
    FINISHED_PATH = "{phases,review,completed_at}"

    # One application's roll. `sample` is how many reviews the average covers,
    # `scanned` how many were read to find them — so `excluded` is the difference,
    # and the card can say what the rules dropped.
    Roll = Struct.new(:repo, :average_seconds, :sample, :scanned, keyword_init: true) do
      def excluded = scanned - sample

      # Is there an average to draw at all?
      def any? = sample.positive?

      # A full rolling ten. Below this the card names the sample size, because an
      # average over three reviews and one over ten are not the same claim.
      def full? = sample >= SAMPLE_SIZE

      # Reviews were read and every one of them failed a rule — distinct from a repo
      # that has never been reviewed, and the card says so.
      def all_excluded? = !any? && scanned.positive?
    end

    class << self
      # => { "<repo>" => Roll }, every requested repo present (a quiet repo gets an
      # empty Roll, never a missing key — a card must never render a blank or a NaN).
      def by_repo(repos: Ci::AppLadder.reportable_repos)
        candidates = candidates_by_repo
        blocked = ever_blocked_slugs(candidates.values.flatten.map(&:slug))
        repos.index_with { |repo| roll_for(repo, candidates[repo] || [], blocked) }
      end

      # One repo's roll. Costs the same two queries as the whole row, so callers
      # drawing more than one card want #by_repo.
      def for(repo) = by_repo(repos: [repo]).fetch(repo)

      def empty(repo) = Roll.new(repo: repo, average_seconds: nil, sample: 0, scanned: 0)

      private

      # Every task carrying a COMPLETED review span, newest review first, grouped by
      # the repo its merged PR lives in. One query.
      #
      # `status = completed` is what makes a `reviewed` transition a precondition: an
      # in-flight review has no finish, and a task that never reached `reviewed` never
      # merged. So no separate `merged` filter is needed here — and none is WANTED,
      # since the stamp is re-written accepted → release → main as work advances and
      # filtering on it would make the average depend on where a task sits today.
      def candidates_by_repo
        rows = Task.where("tasks.testing_phases #>> '#{STATUS_PATH}' = ?", "completed")
                   .where("tasks.testing_phases #>> '#{SECONDS_PATH}' IS NOT NULL")
                   .order(Arel.sql("tasks.testing_phases #>> '#{FINISHED_PATH}' DESC NULLS LAST"))
                   .limit(CANDIDATE_POOL)
                   .select(:id, :slug, :stage, :merged, :metadata, :testing_phases)
                   .to_a
        rows.group_by(&:release_repo)
      rescue StandardError => e
        # A board surface never 500s on a metric. Blank rolls read as "not enough
        # data", which is the honest thing to say when the read failed.
        ErrorLog.capture!(e)
        {}
      end

      # ARCHIVED TASKS COUNT. Archive is terminal bookkeeping, not a statement about
      # the review — and on 2026-08-25 all but a handful of measured reviews sat in
      # `archived`, so excluding them would empty four of five cards outright.

      # Which of these tasks ever carried a QA block. One indexed query, mirroring
      # TasksController#load_board_task_conversation.
      def ever_blocked_slugs(slugs)
        return Set.new if slugs.blank?

        Activity.where(task_slug: slugs, activity_type: "qa_feedback")
                .distinct.pluck(:task_slug).to_set
      rescue StandardError => e
        ErrorLog.capture!(e)
        Set.new
      end

      # Walk this repo's reviews newest first, keeping the usable ones until the
      # window is full or SCAN_LIMIT have been read.
      def roll_for(repo, tasks, blocked)
        kept = []
        scanned = 0

        tasks.each do |task|
          break if kept.size >= SAMPLE_SIZE || scanned >= SCAN_LIMIT

          scanned += 1
          seconds = review_seconds(task)
          next if seconds.nil?
          next if blocked.include?(task.slug)
          next if seconds > MAX_SECONDS

          kept << seconds
        end

        Roll.new(
          repo: repo,
          average_seconds: kept.any? ? (kept.sum.to_f / kept.size).round : nil,
          sample: kept.size,
          scanned: scanned
        )
      end

      def review_seconds(task)
        value = task.testing_phases.to_h.dig("phases", "review", "seconds")
        return nil if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
