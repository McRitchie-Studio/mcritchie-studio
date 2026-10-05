# One generated MP4 the operator uploaded back for a chunk (recast pipeline,
# piece 3): take 1, take 2 ... per chunk, each its own object in R2 under the
# video's generated/ folder. Takes are kept, never overwritten.
#
# A take names its chunk by ordinal AND window (start_ms, end_ms), because the
# chunk rows are replaced on a re-tile: the same windows keep their takes, a
# different tiling leaves the old takes filed but belonging to no chunk.
#
# The current take of a chunk is the one with the latest current_since: a new
# upload is current, and the operator can put an older one back (make_current!).
class VideoChunkTake < ApplicationRecord
  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :chunk_takes

  validates :chunk_ordinal, :number, numericality: { only_integer: true, greater_than: 0 }
  validates :number, uniqueness: { scope: %i[music_video_slug chunk_ordinal] }
  validates :start_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :end_ms, numericality: { only_integer: true, greater_than: :start_ms }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :current_since, presence: true
  validate :object_key_names_the_take

  def name = "Take #{number}"

  # Whether this take was generated for that chunk as it is cut now.
  def for?(chunk)
    chunk.chunk? && chunk.music_video_slug == music_video_slug && chunk.ordinal == chunk_ordinal &&
      chunk.start_ms == start_ms && chunk.end_ms == end_ms
  end

  # Put this take in front of its siblings, whatever their clocks say.
  def make_current!(at: Time.current)
    latest = self.class.where(music_video_slug:, chunk_ordinal:).where.not(id:).maximum(:current_since)
    update!(current_since: latest && latest >= at ? latest + 0.001 : at)
  end

  private

  def object_key_names_the_take
    expected = MusicVideos::ObjectKeys.take(source_key: music_video&.source_object_key, ordinal: chunk_ordinal,
                                            start_ms:, end_ms:, number:)
    errors.add(:object_key, "must be #{expected}") unless object_key == expected
  rescue ArgumentError, TypeError
    errors.add(:object_key, "cannot be checked against the video's source folder")
  end
end
