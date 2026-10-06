# One chunk of the source as one alt video swaps it (recast pipeline, piece
# 13): alt video x chunk. Made by Build Clips, one per chunk, with the chunk's
# window copied, so the clip keeps its window if the source is ever re-tiled.
#
# It holds the MP4s generated for it as numbered versions (AltVideoClipVersion),
# all kept; exactly one is primary whenever any exists (the latest
# primary_since). The primary is what the full-video preview and the stitch use.
# A clip can be flagged for a regenerate, which the next upload clears.
class AltVideoClip < ApplicationRecord
  REGENERATE_NOTE_MAX = 280

  belongs_to :alt_video, foreign_key: :alt_video_slug, primary_key: :slug, inverse_of: :clips
  has_many :versions, -> { order(:number) }, class_name: "AltVideoClipVersion", inverse_of: :clip,
           dependent: :destroy

  validates :chunk_ordinal, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :alt_video_slug }
  validates :start_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :end_ms, numericality: { only_integer: true, greater_than: :start_ms }
  validates :regenerate_note, length: { maximum: REGENERATE_NOTE_MAX }

  # Timeline windows (MusicVideos::StitchTimeline) read ordinal, start_ms, end_ms.
  def ordinal = chunk_ordinal

  def name = "Clip #{chunk_ordinal}"

  def duration_ms = end_ms - start_ms

  # The source chunk this clip was built from, as it is cut now: same ordinal
  # and same window. nil after a re-tile that moved the window.
  def chunk_in(chunks) = chunks.find { |c| c.ordinal == chunk_ordinal && c.start_ms == start_ms && c.end_ms == end_ms }

  # The version the preview and the stitch use: the newest upload, unless the
  # operator put an older one in front. nil until one arrives.
  def primary_version = versions.max_by { |v| [v.primary_since, v.number] }

  def regenerate_requested? = regenerate_requested_at.present?

  def request_regenerate!(note = nil, at: Time.current)
    update!(regenerate_requested_at: at, regenerate_note: note.to_s.squish.presence)
  end

  def clear_regenerate! = update!(regenerate_requested_at: nil, regenerate_note: nil)
end
