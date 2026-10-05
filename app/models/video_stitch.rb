# One full-length stitch of a tiled video (recast pipeline, piece 4): every
# chunk's current take crossfaded across the overlaps, over the source audio.
# Stitches are numbered per video and kept, never overwritten.
#
# A stitch is REQUESTED on the page, RUNNING while ffmpeg works on it (a local
# hub's StitchVideoJob, or bin/stitch-video on the Mac), then DONE with its
# measurements or FAILED with the reason. `takes` is the take each chunk had
# at the request: [{ "ordinal", "start_ms", "end_ms", "take" }]. The stitch is
# built from exactly those, and it is stale once any chunk has moved on.
class VideoStitch < ApplicationRecord
  STATES = %w[requested running done failed].freeze
  OPEN_STATES = %w[requested running].freeze
  TAKE_KEYS = %w[ordinal start_ms end_ms take].freeze
  REASON_MAX = 500
  # A run this old with no answer is taken for dead (a closed lid, a killed job).
  RUN_TIMEOUT = 30.minutes

  class WrongState < StandardError; end

  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :stitches

  validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :music_video_slug }
  validates :state, inclusion: { in: STATES }
  validates :failure_reason, length: { maximum: REASON_MAX }
  validates :duration_ms, :byte_size, numericality: { only_integer: true, greater_than: 0 }, if: :done?
  validate :takes_name_each_chunk_once
  validate :object_key_names_the_stitch

  STATES.each { |name| define_method(:"#{name}?") { state == name } }

  def name = "Stitch #{number}"

  def open? = OPEN_STATES.include?(state)

  # Running, but for so long that nothing is likely still working on it.
  def stuck?(now: Time.current) = running? && started_at.present? && started_at < now - RUN_TIMEOUT

  # "1, 2, 1, 1": the take number of each chunk, in chunk order.
  def take_list = takes.map { |t| t["take"] }.join(", ")

  # What the stitcher needs (MusicVideos::Stitcher's request), every take
  # resolved to its object.
  def as_request
    source_key = music_video.source_object_key
    as_json(only: %w[number state object_key failure_reason duration_ms byte_size width height frame_rate warnings
                     started_at finished_at])
      .merge("music_video_slug" => music_video_slug, "source_object_key" => source_key,
             "source_duration_ms" => music_video.duration_ms,
             "takes" => takes.map do |t|
               t.slice(*TAKE_KEYS).merge("object_key" => MusicVideos::ObjectKeys.take(
                 source_key:, ordinal: t["ordinal"], start_ms: t["start_ms"], end_ms: t["end_ms"], number: t["take"]
               ))
             end)
  end

  # The take each chunk has now, in the shape `takes` records. Chunks with no
  # take are left out, so the list never equals a full stitch's.
  def self.takes_of(chunks)
    chunks.filter_map do |chunk|
      take = chunk.current_take
      take && { "ordinal" => chunk.ordinal, "start_ms" => chunk.start_ms, "end_ms" => chunk.end_ms, "take" => take.number }
    end
  end

  # Why this stitch no longer shows the video as it stands, one phrase per
  # cause; empty while it is current. Read against the video's chunks now.
  def stale_reasons(chunks = music_video.video_chunks.to_a)
    used = takes.index_by { |t| t["ordinal"] }
    retiled = chunks.map { |c| [c.ordinal, c.start_ms, c.end_ms] } != takes.map { |t| t.values_at("ordinal", "start_ms", "end_ms") }
    reasons = retiled ? ["the video was re-tiled"] : []
    chunks.each do |chunk|
      then_take = used.dig(chunk.ordinal, "take")
      now_take = chunk.current_take&.number
      if !retiled && now_take != then_take
        reasons << "#{chunk.name.downcase} is now on #{now_take ? "take #{now_take}" : 'no take'} (stitched with take #{then_take})"
      end
      reasons << "#{chunk.name.downcase} is flagged for a regenerate" if chunk.regenerate_requested?
    end
    reasons
  end

  def stale?(chunks = music_video.video_chunks.to_a) = stale_reasons(chunks).any?

  # requested -> running. force: also from running (a run that died), and
  # from failed (run it again). Raises WrongState otherwise.
  def start!(force: false, at: Time.current)
    with_lock do
      raise WrongState, "#{name} is done" if done?
      raise WrongState, "#{name} is #{state}, not requested" unless requested? || force

      update!(state: "running", started_at: at, finished_at: nil, failure_reason: nil)
    end
    self
  end

  # running -> done, with what the stitcher measured.
  def finish!(report, at: Time.current)
    with_lock do
      raise WrongState, "#{name} is #{state}, not running" unless running?

      update!(report.to_h.stringify_keys.slice("duration_ms", "byte_size", "width", "height", "frame_rate")
                    .merge(state: "done", finished_at: at, warnings: Array(report.to_h.stringify_keys["warnings"]).map(&:to_s)))
    end
    self
  end

  # requested or running -> failed, with the reason. A done stitch stays done.
  def fail!(reason, at: Time.current)
    with_lock do
      raise WrongState, "#{name} is #{state}" unless open?

      update!(state: "failed", finished_at: at, failure_reason: reason.to_s.squish.presence&.first(REASON_MAX) || "no reason given")
    end
    self
  end

  private

  def takes_name_each_chunk_once
    ok = takes.is_a?(Array) && takes.any? && takes.all? do |t|
      t.is_a?(Hash) && t.keys.sort == TAKE_KEYS.sort && t.values.all?(Integer) && t["take"].positive?
    end
    return errors.add(:takes, "must name one take per chunk: ordinal, start_ms, end_ms, take") unless ok

    errors.add(:takes, "names a chunk twice") if takes.map { |t| t["ordinal"] }.uniq.size != takes.size
  end

  def object_key_names_the_stitch
    expected = MusicVideos::ObjectKeys.stitched(source_key: music_video&.source_object_key, number:)
    errors.add(:object_key, "must be #{expected}") unless object_key == expected
  rescue ArgumentError, TypeError
    errors.add(:object_key, "cannot be checked against the video's source folder")
  end
end
