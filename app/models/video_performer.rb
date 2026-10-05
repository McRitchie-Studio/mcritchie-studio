# One person on screen in a music video (Person N), grouped by the agent from
# visible cues (outfit, hair, eyewear, jewelry), never face recognition. The
# operator resolves it: link an artist, or mark it an extra.
#
# The operator also says who REPLACES them (the recast): an athlete (Person) in
# one of that athlete's looks (Appearance), or an explicit "keep as is". Only
# the operator sets it; the agent API refuses the keys.
class VideoPerformer < ApplicationRecord
  VISIBILITIES = %w[clear partial].freeze
  SIGHTING_KEYS = %w[t_ms visibility].freeze
  # music_videos/<artist>/<video>/stills/person_<NN>_<mmss>.jpg
  STILL_KEY = %r{\A(?<folder>music_videos/[a-z0-9_]+/[a-z0-9_]+/)stills/person_(?<nn>\d{2})_\d{4,}\.jpg\z}

  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, inverse_of: :video_performers
  belongs_to :artist, foreign_key: :artist_slug, primary_key: :slug, optional: true
  belongs_to :recast_person, class_name: "Person", foreign_key: :recast_person_slug, primary_key: :slug, optional: true
  belongs_to :recast_appearance, class_name: "Appearance", foreign_key: :recast_appearance_slug,
                                 primary_key: :slug, optional: true

  validates :label, presence: true
  validates :ordinal, numericality: { only_integer: true, greater_than: 0 },
                      uniqueness: { scope: :music_video_slug }
  validate :sightings_are_times_and_visibility
  validate :stills_live_under_the_video
  validate :artist_or_extra_not_both
  validate :recast_names_an_athlete_and_their_look

  def name = "Person #{ordinal}"

  # The card is closed. A music video needs an artist or an extra. A cinematic
  # video credits no artists, so there the recast answer closes the card too.
  def resolved?
    return true if artist_slug.present? || extra?

    music_video&.cinematic? ? recast? || recast_keep? : false
  end

  # An athlete and one of their looks are both chosen.
  def recast? = recast_person_slug.present? && recast_appearance_slug.present?

  # An athlete with no look: the look they were given is gone. Choose another.
  def recast_pending? = recast_person_slug.present? && recast_appearance_slug.blank?

  # Nothing is owed: recast in full, kept on purpose, or an extra nobody recast.
  def recast_decided? = recast? || recast_keep? || (extra? && recast_person_slug.blank?)

  # "Test Athlete > Home Blue", or just the athlete while the look is missing.
  def recast_label
    return unless recast_person

    [recast_person.full_name, recast_appearance&.descriptor].compact.join(" > ")
  end

  def sightings_by_time = sightings.sort_by { |s| s["t_ms"] }

  # Stills for this person's look, clearest first: a still taken at a clear
  # sighting, then a partial one, then one no sighting names. Posted order breaks
  # ties. Visibility is the agent's grouping call, never face analysis.
  def reference_still_keys
    still_object_keys.each_with_index
                     .sort_by { |key, i| [VISIBILITIES.index(still_visibility(key)) || VISIBILITIES.size, i] }
                     .map(&:first)
  end

  # "clear", "partial", or nil: the clearest sighting at the second a still was taken.
  def still_visibility(key)
    second = still_second(key)
    sightings.select { |s| s["t_ms"] / 1000 == second }.map { |s| s["visibility"] }
             .min_by { |v| VISIBILITIES.index(v) }
  end

  private

  # person_01_0230.jpg -> 150 (the frame's mm:ss in the video).
  def still_second(key)
    mmss = key[/_(\d{4,})\.jpg\z/, 1] or return
    mmss[0..-3].to_i * 60 + mmss[-2..].to_i
  end

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

  # Checked only when the recast changes, so a look retired later does not
  # make an old row unsaveable.
  def recast_names_an_athlete_and_their_look
    return unless recast_person_slug_changed? || recast_appearance_slug_changed? || recast_keep_changed?

    if recast_keep? && (recast_person_slug.present? || recast_appearance_slug.present?)
      return errors.add(:recast_keep, "cannot be set on a performer who is recast")
    end
    return errors.add(:recast_appearance_slug, "needs the athlete it belongs to") if recast_person_slug.blank? && recast_appearance_slug.present?
    return if recast_person_slug.blank?
    return errors.add(:recast_person_slug, "names no person") unless Person.exists?(slug: recast_person_slug)
    return if recast_appearance_slug.blank?
    return if Appearance.recastable.exists?(slug: recast_appearance_slug, person_slug: recast_person_slug)

    errors.add(:recast_appearance_slug, "is not a live look of that athlete")
  end
end
