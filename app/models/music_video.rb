# A music video digested from a platform URL (docs/agents/system/music-video-pipeline-plan.md).
# The source MP4 lives in R2 under `source_object_key`. caption_timing is cue
# times and section markers only: lyric text is never stored.
class MusicVideo < ApplicationRecord
  KINDS = %w[music_video].freeze
  PLATFORMS = %w[youtube tiktok instagram].freeze
  STAGES = %w[digested cast_confirmed clips_ready].freeze
  CAST_CONFIRMED_STAGES = %w[cast_confirmed clips_ready].freeze
  SECTION_KINDS = %w[vocal instrumental].freeze
  CUE_KEYS = %w[start_ms end_ms].freeze
  SECTION_KEYS = %w[kind start_ms end_ms].freeze

  has_many :music_video_artists, foreign_key: :music_video_slug,
           primary_key: :slug, inverse_of: :music_video, dependent: :destroy
  has_many :artists, through: :music_video_artists
  has_many :video_performers, -> { order(:ordinal) }, foreign_key: :music_video_slug,
           primary_key: :slug, inverse_of: :music_video, dependent: :destroy
  has_many :video_clips, -> { order(:ordinal) }, foreign_key: :music_video_slug,
           primary_key: :slug, inverse_of: :music_video, dependent: :destroy

  class CastNotReady < StandardError; end

  validates :slug, :platform, :source_url, :source_id, :title, :source_object_key, presence: true
  validates :slug, uniqueness: true, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :source_id, uniqueness: { scope: :platform }
  validates :kind, inclusion: { in: KINDS }
  validates :platform, inclusion: { in: PLATFORMS }
  validates :stage, inclusion: { in: STAGES }
  validates :source_object_key, format: { with: %r{\Amusic_videos/.+\.mp4\z} }
  validates :duration_ms, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :caption_timing_is_timing_only

  def to_param = slug

  # Clips come after the cast, so a clips_ready video's cast is confirmed too.
  def cast_confirmed? = CAST_CONFIRMED_STAGES.include?(stage)

  # Ready once the vision pass has left people and each one is an artist or an extra.
  def cast_ready?
    stage == "digested" && video_performers.any? && video_performers.all?(&:resolved?)
  end

  def confirm_cast!
    with_lock do
      raise CastNotReady, cast_blocker unless cast_ready?

      update!(stage: "cast_confirmed")
    end
  end

  def cast_blocker
    return "the cast is already confirmed" if cast_confirmed?
    return "no performers yet: the vision pass has not posted any" if video_performers.none?

    open = video_performers.reject(&:resolved?).map(&:name)
    "#{open.to_sentence} #{open.one? ? 'is' : 'are'} neither an artist nor an extra" if open.any?
  end

  # clips_ready while at least one clip is approved; back to cast_confirmed when none is.
  def sync_clip_stage!
    return unless cast_confirmed?

    update!(stage: video_clips.where(status: "approved").exists? ? "clips_ready" : "cast_confirmed")
  end

  # A timecode link into the source video. YouTube only for now.
  def timecode_url(t_ms)
    return unless platform == "youtube"

    "#{source_url}#{source_url.include?('?') ? '&' : '?'}t=#{t_ms / 1000}s"
  end

  private

  def caption_timing_is_timing_only
    t = caption_timing
    ok = t.is_a?(Hash) && t.keys.sort == %w[cues sections] &&
         rows?(t["cues"], CUE_KEYS) && rows?(t["sections"], SECTION_KEYS) &&
         t["sections"].all? { |s| SECTION_KINDS.include?(s["kind"]) }
    errors.add(:caption_timing, "may hold only cue times and section markers, never caption text") unless ok
  end

  def rows?(list, keys)
    list.is_a?(Array) && list.all? do |row|
      row.is_a?(Hash) && row.keys.sort == keys.sort &&
        (keys - ["kind"]).all? { |k| row[k].is_a?(Integer) && row[k] >= 0 }
    end
  end
end
