# frozen_string_literal: true

module Ci
  # ONE rung of ONE repo's branch ladder (`accepted` / `release` / `main`), shaped
  # for display: a CI state, the sha that state describes, when that verdict ran,
  # and how many tasks are parked at this rung.
  #
  # WHY THIS IS NOT JUST `Ci::BranchGate.verdict`. Rendering the raw verdict as a
  # status light LIES, and it was measured lying on 2026-08-19:
  #
  #   repo             accepted tip   BranchGate said
  #   turf-monster     c1959ef        green@abe8c51   (3 merges behind)
  #   studio-engine    a300cba        green@fdfca16   (stale)
  #
  # `BranchGate` answers "what is the newest INGESTED verdict for this branch",
  # which is the right answer to its own question. But only mcritchie-studio's
  # ci.yml carries `accepted` in its push triggers; turf-monster and studio-engine
  # are `[main, release]`. In those repos the only run ever tagged `accepted` is
  # the sweep's batch promote PR (`--base release --head accepted`, whose
  # `headBranch` reads `accepted`) — so between releases the verdict sits there,
  # green, describing a tree several merges old.
  #
  # HOW STALENESS IS PROVEN HERE — and why it does not need git. This app runs on
  # Heroku with no checkout, so it cannot read a branch tip and cannot diff the
  # verdict's sha against it. It does not need to: the BOARD already knows when
  # work landed on a rung. A task stamped `merged: "accepted"` reached that rung
  # when it was stamped. So:
  #
  #   stale  ⇔  work is parked at this rung whose merge landed AFTER the
  #             verdict's run started
  #
  # That is a claim about two timestamps we hold, not an inference about a tree we
  # cannot see. It cannot false-positive on a quiet rung (no parked work ⇒ never
  # stale) and it cannot false-negative on the measured case above (parked work
  # merged hours after the last batch-PR run ⇒ stale).
  #
  # STATES, and the two that exist to stop the lie:
  #   :green :red :pending :conflicted  — a live verdict, from BranchGate
  #   :stale                            — a verdict, but it predates parked work
  #   :not_built                        — nothing ingested for this branch at all
  #
  # `:stale` and `:not_built` are deliberately NOT green. A caller that treats
  # either as passing reintroduces exactly the silence this class exists to end —
  # the same rule Ci::BranchGate states for `:none`.
  class LadderRung
    # Order matters: this is the urgency ranking a display sorts by, worst first.
    STATE_RANK = {
      red: 0,
      conflicted: 1,
      stale: 2,
      pending: 3,
      not_built: 4,
      green: 5
    }.freeze

    ATTENTION_STATES = %i[red conflicted stale].freeze

    attr_reader :repo, :branch, :state, :sha, :verdict_at, :parked_count

    def initialize(repo:, branch:, state:, sha: nil, verdict_at: nil, parked_count: 0)
      @repo = repo.to_s
      @branch = branch.to_s
      @state = state.to_sym
      @sha = sha.presence
      @verdict_at = verdict_at
      @parked_count = parked_count.to_i
      freeze
    end

    # Build one rung from the board's own data. No git, no live gh call.
    def self.for(repo:, branch:, parked_count: 0, newest_parked_at: nil)
      verdict = Ci::BranchGate.verdict(repo, branch)
      raw = verdict[:state]&.to_sym || :none
      sha = verdict[:sha]
      run_at = latest_run_at(repo, branch, sha)

      state = resolve_state(raw: raw, run_at: run_at, newest_parked_at: newest_parked_at)

      new(repo: repo, branch: branch, state: state, sha: sha,
          verdict_at: run_at, parked_count: parked_count)
    end

    # `:none` is BranchGate's honest "nothing ingested"; we render it as
    # :not_built so the card says what the operator can act on.
    #
    # Staleness is only asked about a verdict that EXISTS and is otherwise clean.
    # A red rung stays red — a stale red is still a red, and demoting it to
    # "stale" would hide a failure behind a bookkeeping label.
    def self.resolve_state(raw:, run_at:, newest_parked_at:)
      return :not_built if raw == :none
      return raw unless raw == :green
      return raw if run_at.blank? || newest_parked_at.blank?

      newest_parked_at > run_at ? :stale : :green
    end

    # When the run behind this verdict STARTED. `run_started_at` is the honest
    # field: `created_at` is our ingestion time, which says when the webhook
    # reached us, not when GitHub ran the job.
    def self.latest_run_at(repo, branch, sha)
      return nil if sha.blank?

      nwo = Ci::ReviewGate.nwo_for(repo)
      return nil if nwo.empty?

      GithubWorkflowRun.for_repo(nwo)
                       .where(head_branch: branch.to_s, head_sha: sha)
                       .maximum(:run_started_at)
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
