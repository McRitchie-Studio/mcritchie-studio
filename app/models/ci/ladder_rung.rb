# frozen_string_literal: true

module Ci
  # ONE rung of ONE repo's branch ladder (`accepted` / `release` / `main`), shaped
  # for display: a CI state, the sha that state describes, and how many tasks are
  # parked at this rung.
  #
  # STATES:
  #   :green :red :pending :conflicted — a live verdict, straight from BranchGate
  #   :not_built                       — nothing ingested for this branch at all
  #
  # `:not_built` is deliberately NOT green, and it is the one interpretation this
  # class adds. BranchGate answers `:none` for "nothing ingested"; a caller that
  # treated that as passing would assert a verification nobody performed, which is
  # the same rule BranchGate states for itself.
  #
  # WHY THERE IS NO `:stale` STATE — removed 2026-08-20, and worth keeping written
  # down so it is not reinvented.
  #
  # This class used to call a green verdict `:stale` when a task parked at the rung
  # had been stamped LATER than the verdict's run started. That rule fired by
  # construction rather than on real staleness, because the two clocks measure
  # different events. The real order is always:
  #
  #     code lands on the branch → CI starts (run_started_at) → the sweep or ship
  #     writes the `merged` stamp (updated_at)
  #
  # so the stamp is ALWAYS later. Measured in production on 2026-08-20: turf-monster
  # `release` read green@e1217b6 from BranchGate while the badge rendered stale,
  # because a task was stamped 47 SECONDS after the run began. The `main` rung did
  # the same on all four repos after every ship (hub: verdict 17:13:15, ship stamped
  # 37 tasks at 17:21:53). The visible symptom was a card contradicting itself — a
  # green "RELEASE CI" meter beside a faded `release` badge, same rung.
  #
  # The rule was also OBSOLETE by then. It existed to paper over repos with no push
  # trigger on `accepted`, whose only `accepted` verdict came from a sweep's
  # batch-promote PR and could be hours old. `certify-accepted-everywhere` closed
  # that: every registered repo now builds `accepted` on push, so each tip earns its
  # own run and the verdict is fresh by construction.
  #
  # Staleness against a TRUE branch tip is not knowable from board data — this app
  # has no checkout and cannot read a tip. Bringing it back needs push-event
  # ingestion, so a verdict's SHA can be compared with the branch head. Comparing
  # two timestamps that measure different events is not a substitute, and shipping
  # it as one put a false claim on every card.
  class LadderRung
    # Order matters: this is the urgency ranking a display sorts by, worst first.
    STATE_RANK = {
      red: 0,
      conflicted: 1,
      pending: 2,
      not_built: 3,
      green: 4
    }.freeze

    ATTENTION_STATES = %i[red conflicted].freeze

    attr_reader :repo, :branch, :state, :sha, :verdict_at, :parked_count, :run_url

    def initialize(repo:, branch:, state:, sha: nil, verdict_at: nil, parked_count: 0, run_url: nil)
      @repo = repo.to_s
      @branch = branch.to_s
      @state = state.to_sym
      @sha = sha.presence
      @verdict_at = verdict_at
      @parked_count = parked_count.to_i
      @run_url = run_url.presence
      freeze
    end

    # Runs that do NOT describe whether the code is good. Excluded from every rung
    # reading, because a deploy landing on a sha would otherwise flip its CI badge
    # with no test having run — measured 2026-08-20: 102 "Production Deploy" and 117
    # "QA Deploy" runs are ingested, and Ci::ReviewGate.check_runs_payload folds every
    # workflow on the sha. Dependabot's per-PR runs carry a generated name and are
    # dropped the same way.
    DEPLOY_WORKFLOWS = ["Production Deploy", "QA Deploy"].freeze
    GENERATED_RUN_NAME = /\A(bundler|github_actions|npm|docker) in /
    private_constant :GENERATED_RUN_NAME

    def self.suite_run?(run)
      name = run.workflow_name.to_s
      return false if name.empty?
      return false if DEPLOY_WORKFLOWS.include?(name)

      !name.match?(GENERATED_RUN_NAME)
    end

    # Build one rung from the board's own data. No git, no live gh call.
    #
    # WHY THIS DOES NOT USE Ci::BranchGate. BranchGate is a GATE primitive: it folds
    # every check-run on a SHA, which is right for refusing a promote — a red lane of
    # any kind must block. A rung on a card answers a narrower question: what did the
    # SUITE say about THIS BRANCH. Reusing the gate's fold gave two wrong readings,
    # both measured on 2026-08-20:
    #
    #   · SHA-scoped, not branch-scoped. When the ladder is level, one sha carries runs
    #     for accepted AND release AND main (verified: ddfad29 on all three), so all
    #     three rungs folded the SAME runs and the three badges could never disagree —
    #     they carried no independent information at all.
    #   · Deploy runs counted. A Production Deploy on the sha moved the CI badge.
    #
    # So the rung reads its own: suite runs, on its own branch, for its own sha.
    def self.for(repo:, branch:, parked_count: 0)
      runs = branch_runs(repo, branch)
      newest = runs.first

      new(repo: repo, branch: branch,
          state: fold(runs),
          sha: newest&.head_sha, verdict_at: newest&.run_started_at,
          parked_count: parked_count, run_url: newest&.html_url)
    end

    # The suite runs for this branch's newest built sha — newest run per workflow, so a
    # re-run supersedes rather than double-counts.
    def self.branch_runs(repo, branch)
      nwo = Ci::ReviewGate.nwo_for(repo)
      return [] if nwo.empty?

      newest_sha = GithubWorkflowRun.for_repo(nwo)
                                    .where(head_branch: branch.to_s)
                                    .order(Arel.sql("run_started_at DESC NULLS LAST"))
                                    .to_a
                                    .find { |run| suite_run?(run) }
                                    &.head_sha
      return [] if newest_sha.blank?

      GithubWorkflowRun.for_repo(nwo)
                       .where(head_branch: branch.to_s, head_sha: newest_sha)
                       .order(Arel.sql("run_started_at DESC NULLS LAST"))
                       .to_a
                       .select { |run| suite_run?(run) }
                       .group_by { |run| run.workflow_name.to_s }
                       .map { |_name, group| group.first }
    end

    # Fail-closed, and in this order: nothing ingested is NOT a pass, a failure beats a
    # pending, and a pending beats a green. Only an all-green set reads green.
    def self.fold(runs)
      return :not_built if runs.empty?
      return :red if runs.any? { |r| r.status.to_s == "completed" && r.conclusion.to_s != "success" }
      return :pending if runs.any? { |r| r.status.to_s != "completed" }

      :green
    end

    # Kept as the single place a raw verdict becomes a rung state, so a caller that
    # already holds one (a test, a replay) resolves it the same way `fold` does.
    def self.resolve_state(raw)
      raw.to_sym == :none ? :not_built : raw.to_sym
    end

    # The CI checks behind this rung's verdict, as the meter draws them. Nil when we
    # hold no sha, or when nothing was ingested for it — a meter with nothing to
    # measure must not render a hopeful zero.
    #
    # NOT memoized here on purpose: this object is frozen (it is a value), so the
    # cache belongs to the caller. Ci::AppLadder::Card#progress holds it, and the
    # view reads that once per card.
    def progress
      return nil if sha.blank?

      nwo = Ci::ReviewGate.nwo_for(repo)
      return nil if nwo.empty?

      # SCOPED to the repo's declared suite workflow, and that is a KNOWN LIMIT rather
      # than an oversight — see /tasks/align-ladder-meter-with-badge.
      #
      # The badge beside this meter is Ci::BranchGate.verdict, which folds
      # GithubWorkflowRun — one row per WORKFLOW, so a repo with several lanes has all
      # of them counted. This meter reads CiCheckJob, which ingests only
      # GithubWorkflowRun::CI_PROGRESS_WORKFLOWS ("CI" + the declared gem suites), so
      # a lane like studio-engine's Consumer CI is never in this table at all.
      # Measured 2026-08-20: accepted@135e4e6 rendered a RED badge over a GREEN 3/3
      # meter because Consumer CI was red and could not reach here.
      #
      # Removing this filter does NOT fix that — there are no rows to find, so it is a
      # no-op (proven in review). Closing the gap means changing what is INGESTED, or
      # moving the meter onto the badge's own source at workflow grain, which costs
      # per-check detail. That is a design decision, not a filter tweak.
      rows = CiCheckJob.progress_rows(nwo, sha, GithubWorkflowRun.ci_workflow_for(repo))
      return nil if rows.blank?

      Ci::CheckProgress.from_check_runs(rows, sha: sha, run_started_at: verdict_at)
    end

    # The run row behind this verdict — its start time AND its html_url, in one read
    # (the card links to that url, so fetching only the timestamp would cost a second
    # query per rung). `run_started_at` is the honest time field: `created_at` is our
    # INGESTION time, which says when the webhook reached us, not when GitHub ran it.
    def self.latest_run(repo, branch, sha)
      return nil if sha.blank?

      nwo = Ci::ReviewGate.nwo_for(repo)
      return nil if nwo.empty?

      GithubWorkflowRun.for_repo(nwo)
                       .where(head_branch: branch.to_s, head_sha: sha)
                       .order(Arel.sql("run_started_at DESC NULLS LAST"))
                       .first
    end

    # THE LANE THE METER COUNTS. `progress` folds CiCheckJob scoped to this workflow,
    # and that scope is deliberate (ci_check_job.rb:53-58: folding a gem's sibling
    # Consumer CI would drag the gem's own track red on a failing consumer).
    def counted_lane = GithubWorkflowRun.ci_workflow_for(repo).presence

    # EVERY suite lane on this rung's own branch and sha — the same set the badge
    # folds, so the two halves of the card can never disagree about what exists. The
    # meter counts one of these (`counted_lane`); the rest are named on the card.
    #
    # => [{ name:, state: :green/:red/:pending, url: }]
    def lanes
      return [] if sha.blank?

      self.class.branch_runs(repo, branch)
          .map { |run| self.class.lane_for(run.workflow_name.to_s, run) }
          .sort_by { |lane| [LANE_RANK.fetch(lane[:state], 9), lane[:name]] }
    end

    # The lanes the meter is NOT counting. Empty for a single-lane repo, which is every
    # app — this only has content for a gem running its own suite plus a downstream
    # consumer suite, which is exactly where the green-meter-over-red-badge card came
    # from. Naming them is what stops the meter's scope reading as the whole story.
    def uncounted_lanes = lanes.reject { |lane| lane[:name] == counted_lane }

    LANE_RANK = { red: 0, pending: 1, green: 2 }.freeze

    def self.lane_for(name, run)
      state = if run.status.to_s != "completed" then :pending
              elsif run.conclusion.to_s == "success" then :green
              else :red
              end
      { name: name, state: state, url: run.html_url.presence }
    end

    def short_sha = sha.to_s[0, 7].presence

    def needs_attention? = ATTENTION_STATES.include?(state)

    def rank = STATE_RANK.fetch(state, STATE_RANK[:green])

    # A rung carrying parked work outranks an idle one at the same state, so a
    # quiet green card never sorts above one with work waiting behind it.
    def sort_key = [rank, parked_count.positive? ? 0 : 1]

    def label
      case state
      when :not_built then "not built"
      when :conflicted then "conflicted"
      else state.to_s
      end
    end
  end
end
