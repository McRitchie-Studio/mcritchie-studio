# One generated MP4 uploaded back for a clip (recast pipeline, piece 13):
# version 1, version 2 ... per clip, each its own object in R2 under the alt
# video's folder, kept, never overwritten.
#
# Versions are their own table, not columns on the clip, because a clip exists
# before any version (Build Clips makes it empty) and keeps every upload.
# The primary is the version with the latest primary_since: a new upload is
# primary, and make_primary! puts an older one back in front. A timestamp, not
# a flag, so "exactly one primary" holds by construction, with no second row
# to clear in the same write.
class AltVideoClipVersion < ApplicationRecord
  belongs_to :clip, class_name: "AltVideoClip", foreign_key: :alt_video_clip_id, inverse_of: :versions

  validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :alt_video_clip_id }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :primary_since, presence: true
  validates :object_key, presence: true, uniqueness: true
  # Checked when the version is made; versions moved from piece 3's takes keep
  # their objects where they were (generated/), so later saves do not re-check.
  validate :object_key_names_the_version, on: :create

  def name = "Version #{number}"

  def primary? = clip.primary_version == self

  # Put this version in front of its siblings, whatever their clocks say.
  def make_primary!(at: Time.current)
    latest = self.class.where(alt_video_clip_id:).where.not(id:).maximum(:primary_since)
    update!(primary_since: latest && latest >= at ? latest + 0.001 : at)
  end

  private

  def object_key_names_the_version
    alt = clip&.alt_video
    expected = MusicVideos::ObjectKeys.alt_clip_version(
      source_key: alt&.music_video&.source_object_key, alt_number: alt&.number, ordinal: clip&.chunk_ordinal,
      start_ms: clip&.start_ms, end_ms: clip&.end_ms, number:
    )
    errors.add(:object_key, "must be #{expected}") unless object_key == expected
  rescue ArgumentError, TypeError
    errors.add(:object_key, "cannot be checked against the video's source folder")
  end
end
