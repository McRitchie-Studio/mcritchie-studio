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
  def self.fresh_success?(source, within: 1.day)
    for_source(source).succeeded.where(finished_at: within.ago..).exists?
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
