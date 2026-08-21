# frozen_string_literal: true

module Ci
  # ONE rung of ONE repo's branch ladder (`accepted` / `release` / `main`), shaped
  # for display: a CI state, the sha that state describes, and how many tasks are
  # parked at this rung.
  #
  # STATES:
  #   :green :red :pending — folded from this branch's own SUITE runs (see .fold)
  #   :not_built           — no suite run ingested for this branch, or none that passed
  #
  # `:not_built` is deliberately NOT green: it means no suite run describes this
  # branch, and a caller treating that as passing would assert a verification nobody
  # performed. Ci::BranchGate states the same rule for its own `:none`; this class no
  # longer routes through it (see .for) but keeps the rule.
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

    # WHAT COUNTS AS A SUITE RUN — an ALLOW-LIST, and the polarity is the point.
    #
    # This was a deny-list of deploy names plus a generated-name regex, and it leaked:
    # turf-monster's "Devnet Nightly" (a daily schedule) is neither, so it VOTED in the
    # fold and ANCHORED the rung's sha — 23 rows on `main`, every one completed/skipped,
    # drawing a false RED for measured windows of 1.5h, 7.5h and 36h. `main` only moves
    # on a ship, so the nightly is usually the newest run there. And because
    # STATE_RANK[:red] is 0, that false red sorted the card to the TOP of the row.
    #
    # A deny-list is only ever as current as its last editor, and nothing pinned it:
    # renaming "Production Deploy" would silently have turned deploys into suite runs.
    # An allow-list keyed on the DECLARED suite fails closed on the next scheduled /
    # CodeQL / Pages workflow instead of admitting it. Fixing the fold alone would not
    # have cured this: a genuinely failing nightly — devnet RPC down, the normal failure
    # mode of a devnet integration test — still reddens a rung it has no business
    # describing, which is criterion 4's own intent missed for a non-deploy.
    #
    # The generated-name regex stays as belt-and-braces. It is redundant against the
    # allow-list today (no dependabot name is a declared suite), but 184 generated-name
    # runs carry head_branch accepted/main in production, and a future loosening of the
    # allow-list should not silently readmit them.
    GENERATED_RUN_NAME = /\A(bundler|github_actions|npm|docker) in /
    private_constant :GENERATED_RUN_NAME

    def self.suite_run?(repo, run)
      name = run.workflow_name.to_s
      return false if name.empty? || name.match?(GENERATED_RUN_NAME)

      GithubWorkflowRun.suite_workflows_for(repo).include?(name)
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
                                    .find { |run| suite_run?(repo, run) }
                                    &.head_sha
      return [] if newest_sha.blank?

      GithubWorkflowRun.for_repo(nwo)
                       .where(head_branch: branch.to_s, head_sha: newest_sha)
                       .order(Arel.sql("run_started_at DESC NULLS LAST"))
                       .to_a
                       .select { |run| suite_run?(repo, run) }
                       .group_by { |run| run.workflow_name.to_s }
                       .map { |_name, group| group.first }
    end

    # Buckets, borrowed VERBATIM from CiStatus::CHECK_RUN_BUCKETS (bin/lib/ci_status.rb)
    # so a rung and a gate can never disagree about what a conclusion means. The
    # previous fold read `conclusion != "success"` as red, which quietly narrowed the
    # pass set: `skipped` and `neutral` both certify as "skipping" there and were being
    # drawn RED here. `cancelled` is red in both, so the delta was exactly those two.
    PASS = "success"
    SKIPPING = %w[neutral skipped].freeze
    FAILING = %w[cancelled failure timed_out action_required startup_failure stale].freeze

    # Fail-closed, in CiStatus's own order, PLUS its companion rule.
    #
    #   nothing ingested            → :not_built   (an absence is never a pass)
    #   any fail/cancel             → :red
    #   anything unsettled/unknown  → :pending     (an unrecognised conclusion is NOT a pass)
    #   nothing actually PASSED     → :not_built   (an all-skipped set certifies nothing —
    #                                               ci_status.rb:875. Widening the pass set
    #                                               without this reads all-skipped as GREEN,
    #                                               a regression the old path never had.)
    #   otherwise                   → :green
    def self.fold(runs)
      return :not_built if runs.empty?

      completed = runs.select { |r| r.status.to_s == "completed" }
      conclusions = completed.map { |r| r.conclusion.to_s }

      return :red if conclusions.any? { |c| FAILING.include?(c) }
      return :pending if completed.size < runs.size
      return :pending if conclusions.any? { |c| c != PASS && !SKIPPING.include?(c) }
      return :not_built if conclusions.none?(PASS)

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
      # than an oversight — the card names what this leaves out (see #uncounted_lanes).
      #
      # CiCheckJob ingests only GithubWorkflowRun::CI_PROGRESS_WORKFLOWS, so a sibling
      # lane like studio-engine's Consumer CI has no rows here at all — widening the
      # filter finds nothing, which is why an earlier attempt to "align" the two halves
      # was inert. And the scope is load-bearing anyway: ci_check_job.rb:53-58 records
      # that folding a gem's sibling would drag its own track red on a failing consumer.
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
