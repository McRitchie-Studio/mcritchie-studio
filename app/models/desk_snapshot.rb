# frozen_string_literal: true

# DeskSnapshot — one `bin/agent-worktree snapshot --write`, recorded.
#
# The desk facts belong on DeskRecord; these are the properties of the RUN and of nothing
# else: how many slots the Redis band is handing out right now, how many are free, how
# many desks the sweep withheld and why it could. The operator's stated question for
# /deployments is "how many desks, how many free slots" — that number lives here, with
# the timestamp that says how old the answer is, because a capacity figure with no age
# on it is the kind of number people trust for a week.
class DeskSnapshot < ApplicationRecord
  validates :generated_at, presence: true

  scope :newest_first, -> { order(generated_at: :desc, id: :desc) }

  # How many snapshots to keep. A sweep writes one on every `remove`, every `new`, and
  # every explicit refresh, so this table grows with teardown activity and nothing reads
  # further back than the last few. Trimming on write keeps the panel's `latest` query
  # cheap without a scheduled job to forget about.
  RETAIN = 100

  def self.latest = newest_first.first

  def self.record!(payload)
    generated = begin
      Time.zone.parse(payload["generated_at"].to_s)
    rescue ArgumentError, TypeError
      nil
    end

    snapshot = create!(
      generated_at: generated || Time.current,
      projects_dir: payload["projects_dir"],
      hub_dir: payload["hub_dir"],
      desk_count: Array(payload["worktrees"]).size,
      capacity: payload["capacity"].is_a?(Hash) ? payload["capacity"] : {},
      summary: payload["summary"].is_a?(Hash) ? payload["summary"] : {},
      redis_db_range: payload["redis_db_range"].is_a?(Hash) ? payload["redis_db_range"] : {}
    )
    prune!
    snapshot
  end

  def self.prune!
    keep = newest_first.limit(RETAIN).pluck(:id)
    where.not(id: keep).delete_all
  end

  # Slots the band can actually hand out right now. Reads the sweep's OWN arithmetic
  # (allocatable_free: the soft band intersected with physically-existing Redis DBs,
  # minus what is allocated) rather than recomputing it here — a second implementation
  # of a capacity number is a second answer waiting to disagree with the first.
  def free_slots = capacity["free"]
  def used_slots = capacity["used"]
  def band_size = capacity["current"]
  def physical_max = capacity["physical_max"]

  def dirty_desks = summary["dirty_worktrees"]
  def withheld_desks = summary["withheld"]
  def cleanup_candidates = summary["cleanup_candidates"]
  def running_desks = summary["running_or_port_busy"]
end
