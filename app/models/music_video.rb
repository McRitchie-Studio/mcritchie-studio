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
  # Every generated take the operator uploaded back, across all chunks. A take
  # finds its chunk by ordinal and window (VideoChunkTake#for?). Destroying the
  # video drops the rows; the objects stay in R2.
  has_many :chunk_takes, -> { order(:chunk_ordinal, :number) }, class_name: "VideoChunkTake",
           foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :music_video, dependent: :delete_all

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

  # Clips come after the cast, so a clips_ready video's cast is confirmed too.
  def cast_confirmed? = CAST_CONFIRMED_STAGES.include?(stage)

  def cinematic? = kind == "cinematic"

  # Performers the operator still owes a recast answer (an athlete and a look,
  # or "keep as is"). Extras nobody recast owe none.
  def recast_open = video_performers.reject(&:recast_decided?)

  # Every performer has its recast answer: the later pieces' "may we generate".
  def recast_assigned? = video_performers.any? && recast_open.empty?

  # Ready once the vision pass has left people and each one's card is closed
  # (VideoPerformer#resolved?).
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
    return if open.empty?

    "#{open.to_sentence} #{open.one? ? 'is' : 'are'} neither #{cinematic? ? 'recast, kept as is, an artist' : 'an artist'} nor an extra"
  end

  # { chunk_ms:, overlap_ms: } the current chunks were cut with (bin/find-clips
  # --tile), or nil for a video never tiled.
  def chunk_tiling
    { chunk_ms:, overlap_ms: chunk_overlap_ms } if chunk_ms && chunk_overlap_ms
  end

  # Chunks the operator asked to have generated again, in order.
  def chunks_flagged = video_chunks.select(&:regenerate_requested?)

  # Chunks with no generated take yet, in order.
  def chunks_without_take = video_chunks.reject(&:current_take)

  # The final stitch may run: the video is tiled, every chunk has a current
  # take, and none is flagged for a regenerate (recast pipeline, piece 4).
  def ready_to_stitch?
    video_chunks.any? && chunks_without_take.empty? && chunks_flagged.empty?
  end

  # Why the stitch may not run yet, as one sentence; nil when it may.
  def stitch_blocker
    return "the video is not tiled into chunks yet" if video_chunks.none?

    missing = chunks_without_take.map(&:name)
    flagged = chunks_flagged.map(&:name)
    parts = []
    parts << "#{missing.to_sentence} #{missing.one? ? 'has' : 'have'} no generated take" if missing.any?
    parts << "#{flagged.to_sentence} #{flagged.one? ? 'is' : 'are'} flagged for a regenerate" if flagged.any?
    parts.join("; ").presence
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
