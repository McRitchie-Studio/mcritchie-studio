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
  #   main     rung  ← nothing. Shipped work has ARRIVED; see PARKED_STAMP below.
  #
  # A sweep re-stamps accepted → release, and a ship re-stamps release → main — which
  # counts nothing — so the rungs empty on their own as work advances. After a
  # production ship every card falls quiet, the "clock starts over" the row exists to
  # show, with no counter to reset and nothing to get out of sync.
  #
  # ARCHIVED TASKS ARE EXCLUDED TOO, and that filter is doing real work even though
  # `main` no longer counts: a task can be archived while still stamped `accepted` or
  # `release`, and counting it would hold a rung open for work nobody is advancing.
  # test/models/ci/app_ladder_test.rb exercises exactly that shape — an archived task
  # at a COUNTED rung — because a fixture stamped `main` cannot bite this filter.
  class AppLadder
    RUNGS = %w[accepted release main].freeze

    # Which `merged` stamp parks a task at which rung.
    #
    # `main` is deliberately ABSENT. Work stamped `merged: "main"` has ARRIVED — it
    # shipped, nothing waits there, and the stamp is permanent until the task is
    # archived. Counting it meant a card never went quiet: the hub sat at "37 on main"
    # indefinitely, so the clock never reset even though the production ship is the
    # reset point the operator chose. Parked means WAITING, and only the two rungs
    # below main have anything waiting on them.
    #
    # A card showing "1 on accepted" moments after a ship is therefore correct and
    # must keep showing: that is real work queued for the next sweep, not residue.
    PARKED_STAMP = {
      "accepted" => Task::MERGED_ACCEPTED,
      "release" => Task::MERGED_RELEASE
    }.freeze

    Card = Struct.new(:repo, :rungs, keyword_init: true) do
      def rung(branch) = rungs.find { |r| r.branch == branch }

      def needs_attention? = rungs.any?(&:needs_attention?)

      def parked_total = rungs.sum(&:parked_count)

      # THE RUNG THE METER REPORTS ON — "what is this app's suite doing right now".
      #
      # A running rung always wins: a suite in flight is the live news, and it is the
      # only state the operator can act on while it is happening. Failing that, the
      # rung with the NEWEST verdict, because that is the most recent thing CI
      # actually said about this app. `accepted` is the last resort so a card with no
      # verdicts anywhere still names the rung its work would reach first.
      #
      # Deliberately ONE rung, not a meter per rung: three check-lists on one card is
      # the two-rows-saying-the-same-thing shape the CI meter already learned to
      # collapse, and the badges below carry the per-rung verdict anyway.
      def active_rung
        rungs.find { |r| r.state == :pending } ||
          rungs.select(&:verdict_at).max_by(&:verdict_at) ||
          rung("accepted")
      end

      # The checks the meter draws, or nil when this app has nothing ingested — a
      # meter must not render a hopeful zero out of an absence.
      #
      # The cache lives HERE rather than on the rung: a rung is a frozen value object,
      # so it cannot hold one, and this read costs a query. `defined?` rather than
      # `||=` so a genuine nil is cached too — an app with no ingested checks is the
      # common case on a quiet board, and re-querying it per call is the N+1 this
      # memo exists to prevent.
      def progress
        return @progress if defined?(@progress)

        @progress = active_rung&.progress
      end

      # Where the card points. The Actions run behind the active rung, so clicking the
      # card lands on the run in progress rather than a repo home page.
      def run_url = active_rung&.run_url

      # Worst rung first, then "has work waiting" ahead of idle. Mirrors the board's
      # own instinct of floating what needs a human to the top.
      def sort_key = rungs.map(&:sort_key).min || [Ci::LadderRung::STATE_RANK[:green], 1]

      def gem? = Release::Repos.gem?(repo)
    end

    class << self
      # EVERY three-rung repo gets a card — including one that declares no CI suite.
      #
      # This filter used to drop a suiteless repo as noise, on the argument that three
      # `not_built` rungs teach the eye nothing. That was wrong twice. A repo is on the
      # ladder whether or not it runs tests, and its rungs still move; hiding the card
      # hid the movement. Concretely: solana-studio sat `accepted` +1 ahead of
      # `release` with no task behind it, and the row could not show it because the
      # card did not exist. A card reading "not built" is a true and useful statement —
      # this repo ships without a suite — where an absent card says nothing at all.
      def reportable_repos = Release::Repos.three_rung_repos

      # Build every card. One board query for the parked counts (not one per
      # rung per repo), then each rung folds its own branch's suite runs.
      def build(repos: reportable_repos)
        parked = parked_index
        repos.map { |repo| card_for(repo, parked) }.sort_by(&:sort_key)
      end

      def card_for(repo, parked = parked_index)
        rungs = RUNGS.map do |branch|
          Ci::LadderRung.for(repo: repo, branch: branch, parked_count: parked.dig(repo, branch).to_i)
        end
        Card.new(repo: repo, rungs: rungs)
      end

      # => { "turf-monster" => { "accepted" => 2 } }
      #
      # A COUNT and nothing more. It used to carry the newest `updated_at` per rung
      # so a green verdict older than that could be called stale — a rule removed on
      # 2026-08-20 because the stamp is always written after the run starts, so it
      # fired by construction. See Ci::LadderRung's note for the measurement.
      def parked_index
        index = Hash.new { |h, k| h[k] = Hash.new(0) }

        Task.where.not(stage: "archived")
            .where(merged: PARKED_STAMP.values)
            .pluck(:merged, :metadata)
            .each do |merged, metadata|
              branch = PARKED_STAMP.key(merged)
              next if branch.blank?

              repos_for(metadata).each { |repo| index[repo][branch] += 1 }
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
