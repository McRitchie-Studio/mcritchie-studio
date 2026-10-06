# A video digested from a platform URL (docs/agents/system/music-video-pipeline-plan.md):
# a music video, or a cinematic one (kind).
# The source MP4 lives in R2 under `source_object_key`. caption_timing is cue
# times and section markers only: lyric text is never stored.
class MusicVideo < ApplicationRecord
  KINDS = %w[music_video cinematic].freeze
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
  # Every clip row; the two kinds below never mix in a list.
  has_many :video_clips, -> { order(:kind, :ordinal) }, foreign_key: :music_video_slug,
           primary_key: :slug, inverse_of: :music_video, dependent: :destroy
  # The seam-picked ~25 s candidates the operator approves or rejects (stage 5).
  has_many :clip_candidates, -> { where(kind: "candidate").order(:ordinal) }, class_name: "VideoClip",
           foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :music_video
  # The whole video tiled into overlapping chunks, in time order (bin/find-clips --tile).
  has_many :video_chunks, -> { where(kind: "chunk").order(:ordinal) }, class_name: "VideoClip",
           foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :music_video
  # The generated versions of this source (recast pipeline, piece 13), each
  # with its own swap set, numbered from 1. The chunks above are shared by all.
  has_many :alt_videos, -> { order(:number) }, foreign_key: :music_video_slug, primary_key: :slug,
           inverse_of: :music_video, dependent: :restrict_with_exception

  has_many :looks, class_name: "Appearance", foreign_key: :music_video_slug, primary_key: :slug,
           inverse_of: :music_video, dependent: :nullify

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
  validate :chunk_tiling_can_tile

  def to_param = slug

  # Seam candidates come after the cast, so a clips_ready video's cast is
  # confirmed too. Chunks do not wait for it (bin/digest-video cuts them).
  def cast_confirmed? = CAST_CONFIRMED_STAGES.include?(stage)

  def cinematic? = kind == "cinematic"

  # Performers swapped to an athlete who still waits for a look. Nobody else
  # owes a recast answer: the swap is off by default.
  def recast_open = video_performers.reject(&:recast_decided?)

  # No swap is left waiting for a look: the later pieces' "may we generate".
  def recast_assigned? = video_performers.any? && recast_open.empty?

  # Ready once the vision pass has left people. Naming artists is optional and
  # the swap is off by default (and editable after the confirm), so nothing on
  # a card has to be pressed first.
  def cast_ready?
    stage == "digested" && video_performers.any?
  end

  def confirm_cast!
    with_lock do
      raise CastNotReady, cast_blocker unless cast_ready?

      update!(stage: "cast_confirmed")
      MusicVideos::LabelChunks.call(self) # the named artists and extras set who each chunk targets
    end
  end

  def cast_blocker
    return "the cast is already confirmed" if cast_confirmed?
    "no performers yet: the vision pass has not posted any" if video_performers.none?
  end

  # { chunk_ms:, overlap_ms: } the current chunks were cut with (bin/find-clips
  # --tile), or nil for a video never tiled.
  def chunk_tiling
    { chunk_ms:, overlap_ms: chunk_overlap_ms } if chunk_ms && chunk_overlap_ms
  end

  # Build Clips may make an alt video: the cast is confirmed and the video
  # is tiled. The swaps need not be complete: the snapshot takes them as they are.
  def can_build_clips? = cast_confirmed? && video_chunks.any?

  # Why Build Clips is off, as one phrase; nil when it is on.
  def build_clips_blocker
    return "confirm the cast first" unless cast_confirmed?
    "the video is not tiled into chunks yet" if video_chunks.none?
  end

  def kind_label = kind == "cinematic" ? "Cinematic video" : "Music video"

  # clips_ready while at least one candidate is approved; back to cast_confirmed
  # when none is. Chunks never move the stage.
  def sync_clip_stage!
    return unless cast_confirmed?

    update!(stage: clip_candidates.where(status: "approved").exists? ? "clips_ready" : "cast_confirmed")
  end

  # A timecode link into the source video. YouTube only for now.
  def timecode_url(t_ms)
    return unless platform == "youtube"

    "#{source_url}#{source_url.include?('?') ? '&' : '?'}t=#{t_ms / 1000}s"
  end

  private

  def chunk_tiling_can_tile
    return if chunk_ms.nil? && chunk_overlap_ms.nil?

    why = MusicVideos::ChunkTiler.problem(chunk_ms:, overlap_ms: chunk_overlap_ms)
    errors.add(:chunk_ms, why) if why
  end

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
