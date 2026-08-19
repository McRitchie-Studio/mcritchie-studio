# frozen_string_literal: true

module Ci
  # The /deployments app-ladder row: one card per three-rung repo, each carrying
  # its `accepted` / `release` / `main` rungs.
  #
  # WHAT IT IS FOR. An application's progress along the ladder is decoupled from
  # the Next Release card — work sits merged on `accepted` for hours before a
  # sweep promotes it, and between releases the Next Release card reads "none
  # active" while three repos quietly hold unshipped work. This row is that
  # in-between state, which had no surface at all.
  #
  # THE CLOCK RESETS AT THE SHIP, BY DERIVATION. Parked counts come from the
  # task board's own `merged` column, so nothing is stored and nothing can drift:
  #
  #   accepted rung  ← tasks stamped merged:"accepted"  (reviewed, awaiting sweep)
  #   release  rung  ← tasks stamped merged:"release"   (on the candidate, in QA)
  #   main     rung  ← tasks stamped merged:"main"      (shipped, not yet archived)
  #
  # A sweep re-stamps accepted → release, and a ship re-stamps release → main, so
  # the lower rungs empty on their own as work advances. After a production ship
  # every card falls quiet — which is the "clock starts over" the row exists to
  # show — with no counter to reset and nothing to get out of sync.
  #
  # ARCHIVED TASKS ARE EXCLUDED. `archived` is terminal and its `merged: "main"`
  # stamp is permanent, so counting it would leave every main rung growing
  # forever and never resetting.
  class AppLadder
    RUNGS = %w[accepted release main].freeze

    # Which `merged` stamp parks a task at which rung.
    PARKED_STAMP = {
      "accepted" => Task::MERGED_ACCEPTED,
      "release" => Task::MERGED_RELEASE,
      "main" => Task::MERGED_MAIN
    }.freeze

    Card = Struct.new(:repo, :rungs, keyword_init: true) do
      def rung(branch) = rungs.find { |r| r.branch == branch }

      def needs_attention? = rungs.any?(&:needs_attention?)

      def parked_total = rungs.sum(&:parked_count)

      # Worst rung first, then "has work waiting" ahead of idle. Mirrors the board's
      # own instinct of floating what needs a human to the top.
      def sort_key = rungs.map(&:sort_key).min || [Ci::LadderRung::STATE_RANK[:green], 1]

      def gem? = Release::Repos.gem?(repo)
    end

    class << self
      # The repos this row can honestly report on: three-rung AND carrying a
      # declared CI suite.
      #
      # WHY THE SECOND HALF. `solana-studio` is a real three-rung gem, but
      # `GithubWorkflowRun::GEM_CI_WORKFLOWS` maps it to nil — "ships no suite
      # workflow — declared, not overlooked". Ci::BranchGate fails closed on an
      # unresolved workflow, so every one of its rungs reads :none forever. A card
      # that can only ever say "not built" on all three rungs is noise, not signal,
      # and it would train the eye to ignore exactly the state that matters on the
      # repos that DO report.
      #
      # This is a derived rule, not a hardcoded list: a repo joins the row the day
      # it declares a suite, and leaves if it stops.
      def reportable_repos
        Release::Repos.three_rung_repos.select { |repo| GithubWorkflowRun.ci_workflow_for(repo).present? }
      end

      # Build every card. One board query for the parked counts (not one per
      # rung per repo), then BranchGate per rung.
      def build(repos: reportable_repos)
        parked = parked_index
        repos.map { |repo| card_for(repo, parked) }.sort_by(&:sort_key)
      end

      def card_for(repo, parked = parked_index)
        rungs = RUNGS.map do |branch|
          bucket = parked.dig(repo, branch) || { count: 0, newest_at: nil }
          Ci::LadderRung.for(
            repo: repo,
            branch: branch,
            parked_count: bucket[:count],
            newest_parked_at: bucket[:newest_at]
          )
        end
        Card.new(repo: repo, rungs: rungs)
      end

      # => { "turf-monster" => { "accepted" => { count: 2, newest_at: Time } } }
      #
      # `updated_at` is the proxy for "when this task landed on this rung" — the
      # stamp and the stage move are the last writes a task takes at each seam.
      # It is deliberately a board fact rather than a git fact: see
      # Ci::LadderRung's note on why staleness is proven from timestamps we hold.
      def parked_index
        index = Hash.new { |h, k| h[k] = {} }

        Task.where.not(stage: "archived")
            .where(merged: PARKED_STAMP.values)
            .pluck(:merged, :updated_at, :metadata)
            .each do |merged, updated_at, metadata|
              branch = PARKED_STAMP.key(merged)
              next if branch.blank?

              repos_for(metadata).each do |repo|
                bucket = index[repo][branch] ||= { count: 0, newest_at: nil }
                bucket[:count] += 1
                bucket[:newest_at] = [bucket[:newest_at], updated_at].compact.max
              end
            end

        index
      end

      # A task can name several repos, and it parks on the rung in EVERY repo it
      # names — a multi-repo task is not "in" one of them.
      def repos_for(metadata)
        devops = metadata.is_a?(Hash) ? (metadata["devops"] || {}) : {}
        list = devops["repositories"]
        list = [list] if list.is_a?(String)
        Array(list).map { |r| r.to_s.strip }.reject(&:empty?).uniq
      end
    end
  end
end
