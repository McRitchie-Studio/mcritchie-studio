# One generated version of a source video (recast pipeline, piece 13): the
# same music video recast two ways is two alt videos (a Cowboys version and a
# Vikings version). Numbered per source from 1, slug "<source>-alt-<n>".
#
# `swaps` is the cast card's swap set SNAPSHOTTED when Build Clips was pressed
# ([{ performer_ordinal, person_slug, appearance_slug, person_name, look_name }],
# swapped people only). It is jsonb on the row, not a child table, because it
# is written once, read whole, never edited and never queried by entry (the
# same reasoning as video_stitches.takes): a later edit of the cast card
# changes the card, never an alt video. Names are frozen with the slugs, so a
# prompt reads the snapshot alone.
#
# Its clips (AltVideoClip, one per source chunk) hold the MP4s generated for
# it; its stitches (VideoStitch) are its full-length cuts.
class AltVideo < ApplicationRecord
  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :alt_videos
  has_many :clips, -> { order(:chunk_ordinal) }, class_name: "AltVideoClip", foreign_key: :alt_video_slug,
           primary_key: :slug, inverse_of: :alt_video, dependent: :destroy
  has_many :stitches, -> { order(:number) }, class_name: "VideoStitch", foreign_key: :alt_video_slug,
           primary_key: :slug, inverse_of: :alt_video, dependent: :restrict_with_exception

  class NotReady < StandardError; end

  validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :music_video_slug }
  validates :slug, presence: true, uniqueness: true
  validate :slug_names_the_source_and_number
  validate :swaps_are_a_snapshot
  validate :swaps_never_change, on: :update

  def to_param = number.to_s

  def name = "Alt video #{number}"

  def swap_set = @swap_set ||= MusicVideos::SwapSet.new(swaps)

  # "Justin Jefferson > Vikings home · Dak Prescott > Cowboys white", or that
  # nobody is swapped.
  def swaps_summary
    labels = swap_set.to_a.map(&:label)
    labels.any? ? labels.join(" · ") : "nobody swapped"
  end

  def self.slug_for(music_video_slug, number) = "#{music_video_slug}-alt-#{number}"

  # Build Clips: the next alt video of the source, its swaps snapshotted from
  # the cast card now, and one clip per chunk. Locks the source so two presses
  # never share a number.
  def self.build_from!(video)
    transaction do
      video.lock!
      video.video_chunks.reset
      raise NotReady, video.build_clips_blocker unless video.can_build_clips?

      performers = video.video_performers.reset.includes(:recast_person, :recast_appearance).to_a
      number = video.alt_videos.maximum(:number).to_i + 1
      alt = video.alt_videos.create!(number:, slug: slug_for(video.slug, number),
                                     swaps: MusicVideos::SwapSet.live(performers).to_rows)
      video.video_chunks.each do |chunk|
        alt.clips.create!(chunk_ordinal: chunk.ordinal, start_ms: chunk.start_ms, end_ms: chunk.end_ms)
      end
      alt
    end
  end

  # Clips with a primary version, of how many.
  def progress
    list = clips.to_a
    [list.count(&:primary_version), list.size]
  end

  def clips_without_version = clips.reject(&:primary_version)

  def clips_flagged = clips.select(&:regenerate_requested?)

  # The full stitch may run: every clip has a primary version, none is flagged.
  def ready_to_stitch? = clips.any? && clips_without_version.empty? && clips_flagged.empty?

  # Why the stitch may not run yet, as one sentence; nil when it may.
  def stitch_blocker
    return "this alt video has no clips" if clips.none?

    missing = clips_without_version.map(&:name)
    flagged = clips_flagged.map(&:name)
    parts = []
    parts << "#{missing.to_sentence} #{missing.one? ? 'has' : 'have'} no generated version" if missing.any?
    parts << "#{flagged.to_sentence} #{flagged.one? ? 'is' : 'are'} flagged for a regenerate" if flagged.any?
    parts.join("; ").presence
  end

  # The newest finished stitch, or nil.
  def latest_stitch = stitches.select(&:done?).max_by(&:number)

  # When anything last happened here: built, a version uploaded or put in
  # front, a stitch moved. Read off loaded rows; the index preloads them.
  def last_activity_at
    times = [created_at, updated_at]
    clips.each do |clip|
      times << clip.updated_at
      clip.versions.each { |v| times.push(v.created_at, v.primary_since) }
    end
    stitches.each { |s| times << s.updated_at }
    times.compact.max
  end

  private

  def slug_names_the_source_and_number
    expected = self.class.slug_for(music_video_slug, number)
    errors.add(:slug, "must be #{expected}") unless slug == expected
  end

  def swaps_never_change
    errors.add(:swaps, "are a snapshot: build another alt video for other swaps") if will_save_change_to_swaps?
  end

  def swaps_are_a_snapshot
    ok = swaps.is_a?(Array) && swaps.all? do |row|
      row.is_a?(Hash) && row.keys.sort == MusicVideos::SwapSet::KEYS.sort &&
        row["performer_ordinal"].is_a?(Integer) && row["person_slug"].present? && row["person_name"].present?
    end
    return errors.add(:swaps, "must list each swap: #{MusicVideos::SwapSet::KEYS.join(', ')}") unless ok

    ordinals = swaps.map { |row| row["performer_ordinal"] }
    errors.add(:swaps, "names a person twice") if ordinals.uniq.size != ordinals.size
  end
end
