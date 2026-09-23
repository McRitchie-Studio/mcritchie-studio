# One run of an external importer.
#
# Answers a question a record's own `updated_at` cannot: WHEN THE SOURCE WAS
# LAST READ. A player untouched since March is not stale if the import ran this
# morning and nflverse simply had nothing new for them — without this, record
# freshness and feed freshness look identical, and a sync cannot tell "nothing
# changed" from "nothing was checked".
class ImportRun < ApplicationRecord
  SOURCES = %w[nflverse_players nflverse_schedule].freeze
  STATUSES = %w[running ok failed].freeze

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }

  scope :for_source, ->(s) { where(source: s) }
  scope :succeeded, -> { where(status: "ok") }

  # The most recent COMPLETED success for a source.
  #
  # `where.not(finished_at: nil)` is load-bearing, not tidiness. Postgres sorts
  # NULLS FIRST on a DESC order, so a row that is `ok` but never stamped a
  # finish — a hand-made row, or a crash between the two writes — sorted ahead
  # of every real success and won this lookup, handing the caller a run that
  # never ended and a nil `finished_at` to do freshness arithmetic on. Measured
  # on this schema, not reasoned from the docs: against an ok/3-days-ago row and
  # an ok/nil row, this returned the nil one before the guard was added.
  def self.last_success_for(source)
    for_source(source).succeeded.where.not(finished_at: nil).order(finished_at: :desc).first
  end

  # Did this source finish a successful run inside `within`?
  #
  # THE QUESTION A CALLER HAS TO ASK NOW THAT THE EXIT CODE NO LONGER ANSWERS
  # IT. Nflverse::SeedPlayers rescues a feed outage and returns rather than
  # raising — deliberately, so a dead upstream cannot abort a deploy — so the
  # process exits 0 whether the import read the feed or never reached it. Any
  # lane that graded that importer by `&&` on its exit status has been reading a
  # constant since. The run row is the verdict; this is how to read it.
  #
  # Asked in SQL rather than off `last_success_for`, so the answer cannot depend
  # on how NULLs happen to sort, and so "no runs at all" and "no RECENT run"
  # both come back false without a nil check at every call site.
  #
  # WHAT `within` ALONE CANNOT ASK: "did THIS run succeed". The window answers
  # "did SOME run succeed today", and the two come apart on the second rebuild
  # of a day. Measured end-to-end against the real importer: with an `ok` run
  # finished two hours ago, a fresh run whose feed is down records ITS OWN run
  # `failed` (`track` stamps it and re-raises) and then RETURNS from `call`'s
  # FeedUnavailable rescue — so the process exits 0, the day already holds a
  # success, and this predicate answered `true` through a total outage.
  #
  # `since` is the caller's own boundary — the wall-clock moment it started the
  # run it is about to grade. A success that finished BEFORE that moment belongs
  # to somebody else's run and cannot vouch for this one.
  #
  # IT ONLY EVER NARROWS. The floor is the LATER of the two bounds, so passing
  # `since` can never widen `within`, and a caller cannot accidentally turn a
  # freshness check into "has it ever worked". Every existing answer stays the
  # same or becomes stricter — this is an improvement on the old behaviour, not
  # a regression of it.
  def self.fresh_success?(source, within: 1.day, since: nil)
    floor = within.ago
    floor = [floor, boundary_for(since)].max unless since.nil?
    for_source(source).succeeded.where(finished_at: floor..).exists?
  end

  # A `since` that cannot be read is REFUSED, never quietly dropped. Falling
  # back to the wide window on an unparseable boundary would hand the caller the
  # exact false green it passed `since` to close, and it would do it silently —
  # the failure mode this whole model exists to end.
  #
  # STRICT ISO 8601, NOT `Time.zone.parse`. Measured, because the lenient reader
  # is worse here than no reader: `Time.zone.parse("last tuesday-ish")` does not
  # return nil, it returns TODAY AT MIDNIGHT — a boundary hours earlier than any
  # run, silently restoring the whole-day window the caller was trying to
  # escape. `Time.zone.iso8601` raises on that, on "", and on "garbage", and
  # accepts exactly the shape the rebuild lane emits (`date -u
  # +%Y-%m-%dT%H:%M:%SZ`). A refusal an operator can see beats a boundary that
  # quietly means something else.
  def self.boundary_for(since)
    return since unless since.is_a?(String)

    begin
      Time.zone.iso8601(since)
    rescue ArgumentError
      raise ArgumentError, "fresh_success? since: cannot read #{since.inspect} as ISO 8601 — " \
                           "refusing to fall back to the wider window"
    end
  end

  # Wraps a run so a crash is recorded as `failed` rather than left `running`
  # forever, which would read as "an import is in progress" to anyone checking.
  def self.track(source)
    run = create!(source: source, started_at: Time.current, status: "running")
    result = yield(run)
    run.update!(status: "ok", finished_at: Time.current)
    result
  rescue StandardError => e
    run&.update(status: "failed", finished_at: Time.current, detail: e.message.to_s[0, 500])
    raise
  end
end
