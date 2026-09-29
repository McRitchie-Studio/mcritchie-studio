# One clip candidate of a music video (stage 5): a ~25 s window that starts on
# a musical boundary and spans a seam, cut to R2 by bin/find-clips. The prompt
# is the filled Higgsfield swap prompt (MusicVideos::ClipPrompt).
class VideoClip < ApplicationRecord
  SEAMS = MusicVideos::ClipFinder::SEAMS
  CAST_SHAPES = MusicVideos::ClipCast::SHAPES
  STATUSES = %w[proposed approved rejected].freeze
  LENGTH_MS = (MusicVideos::ClipFinder::MIN_MS..MusicVideos::ClipFinder::MAX_MS)

  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :video_clips

  validates :ordinal, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :music_video_slug }
  validates :start_ms, :end_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :seam, inclusion: { in: SEAMS }
  validates :cast_shape, inclusion: { in: CAST_SHAPES }
  validates :status, inclusion: { in: STATUSES }
  validates :prompt, presence: true
  validate :length_is_about_25_seconds
  validate :seam_inside_the_window
  validate :performers_belong_to_the_video
  validate :object_key_names_the_window

  def name = "Clip #{ordinal}"

  def duration_ms = end_ms - start_ms

  def approved? = status == "approved"

  def target = music_video.video_performers.find { |p| p.ordinal == target_performer }

  private

  def length_is_about_25_seconds
    return unless start_ms.is_a?(Integer) && end_ms.is_a?(Integer)

    errors.add(:end_ms, "makes a #{duration_ms} ms clip; clips run 24 to 26 s") unless LENGTH_MS.cover?(duration_ms)
    duration = music_video&.duration_ms
    errors.add(:end_ms, "is past the end of the video") if duration && end_ms > duration
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
    expected = MusicVideos::ObjectKeys.clip(source_key: music_video&.source_object_key, ordinal:, seam:, cast_shape:,
                                            start_ms:, end_ms:)
    errors.add(:object_key, "must be #{expected}") unless object_key == expected
  rescue ArgumentError, TypeError
    errors.add(:object_key, "cannot be checked against the video's source folder")
  end
end
