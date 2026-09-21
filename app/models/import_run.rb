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

  def self.last_success_for(source)
    for_source(source).succeeded.order(finished_at: :desc).first
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
