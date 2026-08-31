# frozen_string_literal: true

module Desks
  # The /deployments desk panel's data, assembled in ONE place with a FIXED number of
  # queries.
  #
  # WHAT THE PANEL IS FOR. Mr. McRitchie's ask was to SEE what the desks are rather than
  # read a markdown table — so this leads with the four numbers you need to judge the
  # machine at a glance (how many desks, how many band slots are free, how many are dirty,
  # how many the sweep is holding), then the desks that need attention, then — for a desk
  # that is gone — WHY it was safe to take. It deliberately does not render the registry.
  #
  # FIXED QUERY COUNT is a property, not an accident: test/integration/board_query_budget_test.rb
  # asserts /deployments stays flat as cards are added, and a panel that queried per desk
  # would make the page cost grow with the number of worktrees — which is the one number
  # that grows fastest around here.
  class Panel
    # Enough desks to scan, capped so an 85-desk ecosystem does not push the board off the
    # page. The tile carries the TRUE total, so the cap can never read as desks vanishing —
    # the same contract the board's capped Shipped column keeps.
    LIVE_LIMIT = 30
    REMOVED_LIMIT = 8
    VANISHED_LIMIT = 10

    # A snapshot older than this is called out. Desks turn over in minutes during a sweep,
    # so a six-hour-old capacity figure is not a stale number, it is a wrong one.
    STALE_AFTER = 6.hours

    attr_reader :snapshot, :live, :removed, :vanished, :live_total, :apps

    def self.build = new

    def initialize
      @snapshot = DeskSnapshot.latest
      open_scope = DeskRecord.open_episodes

      @live_total = open_scope.count
      @live = open_scope.order(Arel.sql(ATTENTION_ORDER)).limit(LIVE_LIMIT).to_a
      @removed = DeskRecord.removed.newest_first.limit(REMOVED_LIMIT).to_a
      @vanished = DeskRecord.vanished(as_of: @snapshot&.generated_at)
                            .newest_first.limit(VANISHED_LIMIT).to_a
      @apps = load_apps(open_scope)
    end

    # Dirty desks first (someone's uncommitted work is on them), then desks the sweep has
    # already cleared for teardown, then the rest newest-seen first. The panel's job is to
    # put the desks that need a decision at the top of the list, not to sort alphabetically.
    ATTENTION_ORDER = "dirty DESC, cleanup_candidate DESC, last_seen_at DESC NULLS LAST, id DESC"

    def any? = @live_total.positive? || @removed.any? || @snapshot.present?

    def free_slots = snapshot&.free_slots
    def band_size = snapshot&.band_size
    def dirty_count = snapshot&.dirty_desks || live.count(&:dirty)
    def held_count = snapshot&.withheld_desks

    def generated_at = snapshot&.generated_at

    def stale?
      return false if generated_at.blank?

      generated_at < STALE_AFTER.ago
    end

    # True when nothing has ever synced. The panel says so plainly rather than rendering
    # a row of zeros, because "no desks" and "nobody has told us about the desks" are
    # different facts and only one of them is reassuring.
    def unsynced? = snapshot.nil?

    def truncated_live = [@live_total - @live.size, 0].max

    private

    # ONE grouped query for the per-app strip. Postgres FILTER keeps the three counts in a
    # single pass — three separate `.group(...).count` calls would be three round trips
    # that can disagree if a sync lands between them.
    def load_apps(scope)
      scope.group(:app_slug)
           .pluck(Arel.sql("app_slug"),
                  Arel.sql("COUNT(*)"),
                  Arel.sql("COUNT(*) FILTER (WHERE dirty)"),
                  Arel.sql("COUNT(*) FILTER (WHERE cleanup_candidate)"))
           .map { |slug, total, dirty, free| { slug: slug.presence || "unknown", total: total, dirty: dirty, free: free } }
           .sort_by { |row| [-row[:total], row[:slug]] }
    end
  end
end
