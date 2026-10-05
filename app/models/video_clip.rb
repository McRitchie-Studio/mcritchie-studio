# One cut of a music video, stored in R2 by bin/find-clips, with its filled
# Higgsfield swap prompt (MusicVideos::ClipPrompt). Two kinds share the table
# and number their own ordinals from 1:
#
#   candidate  a ~25 s window that starts on a musical boundary and spans a
#              seam (stage 5); the operator approves or rejects it.
#   chunk      one tile of the whole video (MusicVideos::ChunkTiler), cut at
#              the chunk length and overlap its video records (25 s and 5 s
#              by default), the last one ending at the video's end. No seam.
class VideoClip < ApplicationRecord
  KINDS = %w[candidate chunk].freeze
  SEAMS = MusicVideos::ClipFinder::SEAMS
  CAST_SHAPES = MusicVideos::ClipCast::SHAPES
  STATUSES = %w[proposed approved rejected].freeze
  LENGTH_MS = (MusicVideos::ClipFinder::MIN_MS..MusicVideos::ClipFinder::MAX_MS)

  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :video_clips

  scope :candidates, -> { where(kind: "candidate") }
  scope :chunks, -> { where(kind: "chunk") }

  validates :kind, inclusion: { in: KINDS }
  validates :ordinal, numericality: { only_integer: true, greater_than: 0 },
                      uniqueness: { scope: %i[music_video_slug kind] }
  validates :start_ms, :end_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :seam, inclusion: { in: SEAMS }, unless: :chunk?
  validates :seam, :seam_ms, absence: { message: "is not for a chunk: a chunk has no seam" }, if: :chunk?
  validates :cast_shape, inclusion: { in: CAST_SHAPES }
  validates :status, inclusion: { in: STATUSES }
  validates :prompt, presence: true
  validate :length_fits_the_kind
  validate :chunk_fits_the_videos_tiling, if: :chunk?
  validate :seam_inside_the_window
  validate :performers_belong_to_the_video
  validate :object_key_names_the_window

  def chunk? = kind == "chunk"

  def name = "#{chunk? ? 'Chunk' : 'Clip'} #{ordinal}"

  def duration_ms = end_ms - start_ms

  def approved? = status == "approved"

  def target = music_video.video_performers.find { |p| p.ordinal == target_performer }

  private

  def length_fits_the_kind
    return unless start_ms.is_a?(Integer) && end_ms.is_a?(Integer)

    unless chunk? || LENGTH_MS.cover?(duration_ms)
      errors.add(:end_ms, "makes a #{duration_ms} ms clip; clips run 24 to 26 s")
    end
    duration = music_video&.duration_ms
    errors.add(:end_ms, "is past the end of the video") if duration && end_ms > duration
  end

  # A chunk is cut at its video's own tiling (chunk length and overlap): no
  # longer than a chunk, and starting where its ordinal puts it on the stride.
  # The stitch (recast pipeline) relies on it: neighbours overlap exactly.
  def chunk_fits_the_videos_tiling
    tiling = music_video&.chunk_tiling
    return errors.add(:kind, "chunk needs the video's chunk length and overlap, and it has none") unless tiling
    return unless ordinal.is_a?(Integer) && ordinal.positive? && start_ms.is_a?(Integer) && end_ms.is_a?(Integer)

    unless (1..tiling[:chunk_ms]).cover?(duration_ms)
      errors.add(:end_ms, "makes a #{duration_ms} ms chunk; this video's chunks run up to #{tiling[:chunk_ms]} ms")
    end
    expected = MusicVideos::ChunkTiler.start_of(ordinal, **tiling)
    return if start_ms == expected

    errors.add(:start_ms, "must be #{expected} for chunk #{ordinal} (a #{MusicVideos::ChunkTiler.stride(**tiling)} ms stride)")
  end

  def seam_inside_the_window
    return if seam_ms.nil? || !start_ms.is_a?(Integer) || !end_ms.is_a?(Integer)

    errors.add(:seam_ms, "must fall inside the clip") unless seam_ms > start_ms && seam_ms < end_ms
  end

  def performers_belong_to_the_video
    unless performer_ordinals.is_a?(Array) && performer_ordinals.all?(Integer)
      return errors.add(:performer_ordinals, "must be a list of performer ordinals")
    end

    known = music_video&.video_performers&.map(&:ordinal) || []
    unknown = (performer_ordinals + [target_performer].compact) - known
    errors.add(:performer_ordinals, "names no such person: #{unknown.join(', ')}") if unknown.any?
  end

  def object_key_names_the_window
    errors.add(:object_key, "must be #{expected_object_key}") unless object_key == expected_object_key
  rescue ArgumentError, TypeError
    errors.add(:object_key, "cannot be checked against the video's source folder")
  end

  def expected_object_key
    source_key = music_video&.source_object_key
    return MusicVideos::ObjectKeys.chunk(source_key:, ordinal:, start_ms:, end_ms:) if chunk?

    MusicVideos::ObjectKeys.clip(source_key:, ordinal:, seam:, cast_shape:, start_ms:, end_ms:)
  end
end
