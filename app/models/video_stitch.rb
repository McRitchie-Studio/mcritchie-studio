# One full-length stitch of an alt video (recast pipeline, pieces 4 and 13):
# every clip's primary version crossfaded across the overlaps, over the
# source's audio. Stitches are numbered per alt video and kept, never
# overwritten. music_video_slug stays as the source's slug.
#
# A stitch is REQUESTED on the page, RUNNING while ffmpeg works on it (a local
# hub's StitchVideoJob, or bin/stitch-video on the Mac), then DONE with its
# measurements or FAILED with the reason. `takes` is the version each clip had
# as primary at the request: [{ "ordinal", "start_ms", "end_ms", "take" }]
# ("take" is the version number; the key keeps piece 4's API shape). The
# stitch is built from exactly those, and it is stale once a primary moves on.
class VideoStitch < ApplicationRecord
  STATES = %w[requested running done failed].freeze
  OPEN_STATES = %w[requested running].freeze
  TAKE_KEYS = %w[ordinal start_ms end_ms take].freeze
  REASON_MAX = 500
  # A run this old with no answer is taken for dead (a closed lid, a killed job).
  RUN_TIMEOUT = 30.minutes

  class WrongState < StandardError; end

  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug
  belongs_to :alt_video, foreign_key: :alt_video_slug, primary_key: :slug, inverse_of: :stitches

  validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :alt_video_slug }
  validates :state, inclusion: { in: STATES }
  validates :failure_reason, length: { maximum: REASON_MAX }
  validates :duration_ms, :byte_size, numericality: { only_integer: true, greater_than: 0 }, if: :done?
  validate :takes_name_each_chunk_once
  validate :object_key_names_the_stitch, on: :create
  validate :belongs_to_the_alt_videos_source

  STATES.each { |name| define_method(:"#{name}?") { state == name } }

  def name = "Stitch #{number}"

  def open? = OPEN_STATES.include?(state)

  # Running, but for so long that nothing is likely still working on it.
  def stuck?(now: Time.current) = running? && started_at.present? && started_at < now - RUN_TIMEOUT

  # "1, 2, 1, 1": the version number of each clip, in clip order.
  def take_list = takes.map { |t| t["take"] }.join(", ")

  # What the stitcher needs (MusicVideos::Stitcher's request), every version
  # resolved to its object.
  def as_request
    video = alt_video.music_video
    versions = alt_video.clips.to_h { |c| [c.chunk_ordinal, c.versions.index_by(&:number)] }
    as_json(only: %w[number state object_key failure_reason duration_ms byte_size width height frame_rate warnings
                     started_at finished_at])
      .merge("music_video_slug" => music_video_slug, "alt_video" => alt_video.number,
             "source_object_key" => video.source_object_key, "source_duration_ms" => video.duration_ms,
             "takes" => takes.map do |t|
               version = versions.dig(t["ordinal"], t["take"])
               t.slice(*TAKE_KEYS).merge("object_key" => version&.object_key)
             end)
  end

  # The primary version each clip has now, in the shape `takes` records.
  # Clips with none are left out, so the list never equals a full stitch's.
  def self.takes_of(clips)
    clips.filter_map do |clip|
      version = clip.primary_version
      version && { "ordinal" => clip.chunk_ordinal, "start_ms" => clip.start_ms, "end_ms" => clip.end_ms,
                   "take" => version.number }
    end
  end

  # Why this stitch no longer shows the alt video as it stands, one phrase per
  # cause; empty while it is current. Read against the alt video's clips now.
  def stale_reasons(clips = alt_video.clips.to_a)
    used = takes.index_by { |t| t["ordinal"] }
    clips.each_with_object([]) do |clip, reasons|
      then_number = used.dig(clip.chunk_ordinal, "take")
      now_number = clip.primary_version&.number
      if now_number != then_number
        reasons << "#{clip.name.downcase} is now on #{now_number ? "version #{now_number}" : 'no version'} " \
                   "(stitched with #{then_number ? "version #{then_number}" : 'none'})"
      end
      reasons << "#{clip.name.downcase} is flagged for a regenerate" if clip.regenerate_requested?
    end
  end

  def stale?(clips = alt_video.clips.to_a) = stale_reasons(clips).any?

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

  # Checked when the stitch is requested; stitches moved from piece 4 keep
  # their objects where they were (stitched/), so later saves do not re-check.
  def object_key_names_the_stitch
    expected = MusicVideos::ObjectKeys.alt_stitched(source_key: alt_video&.music_video&.source_object_key,
                                                    alt_number: alt_video&.number, number:)
    errors.add(:object_key, "must be #{expected}") unless object_key == expected
  rescue ArgumentError, TypeError
    errors.add(:object_key, "cannot be checked against the video's source folder")
  end

  def belongs_to_the_alt_videos_source
    return unless alt_video

    errors.add(:music_video_slug, "must be #{alt_video.music_video_slug}") unless music_video_slug == alt_video.music_video_slug
  end
end
