# One person on screen in a music video (Person N), grouped by the agent from
# visible cues (outfit, hair, eyewear, jewelry), never face recognition. The
# operator resolves it: link an artist, or mark it an extra.
class VideoPerformer < ApplicationRecord
  VISIBILITIES = %w[clear partial].freeze
  SIGHTING_KEYS = %w[t_ms visibility].freeze
  # music_videos/<artist>/<video>/stills/person_<NN>_<mmss>.jpg
  STILL_KEY = %r{\A(?<folder>music_videos/[a-z0-9_]+/[a-z0-9_]+/)stills/person_(?<nn>\d{2})_\d{4,}\.jpg\z}

  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :video_performers
  belongs_to :artist, foreign_key: :artist_slug, primary_key: :slug, optional: true

  validates :label, presence: true
  validates :ordinal, numericality: { only_integer: true, greater_than: 0 },
                      uniqueness: { scope: :music_video_slug }
  validate :sightings_are_times_and_visibility
  validate :stills_live_under_the_video
  validate :artist_or_extra_not_both

  def name = "Person #{ordinal}"

  def resolved? = artist_slug.present? || extra?

  def sightings_by_time = sightings.sort_by { |s| s["t_ms"] }

  private

  def sightings_are_times_and_visibility
    ok = sightings.is_a?(Array) && sightings.all? do |s|
      s.is_a?(Hash) && s.keys.sort == SIGHTING_KEYS && s["t_ms"].is_a?(Integer) && s["t_ms"] >= 0 &&
        VISIBILITIES.include?(s["visibility"])
    end
    errors.add(:sightings, "must be a list of {t_ms, visibility: clear|partial}") unless ok
  end

  def stills_live_under_the_video
    unless still_object_keys.is_a?(Array) && still_object_keys.all?(String)
      return errors.add(:still_object_keys, "must be a list of object keys")
    end

    folder = music_video&.source_object_key.to_s[%r{\Amusic_videos/[^/]+/[^/]+/}]
    still_object_keys.each do |key|
      m = STILL_KEY.match(key)
      if m.nil? || m[:folder] != folder || m[:nn].to_i != ordinal
        errors.add(:still_object_keys, "#{key} is not #{folder}stills/person_#{format('%02d', ordinal.to_i)}_<mmss>.jpg")
      end
    end
  end

  def artist_or_extra_not_both
    errors.add(:extra, "cannot be set on a performer linked to an artist") if extra? && artist_slug.present?
  end
end
