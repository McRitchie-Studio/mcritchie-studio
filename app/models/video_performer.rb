# One person on screen in a music video (Person N), grouped by the agent from
# visible cues (outfit, hair, eyewear, jewelry), never face recognition. The
# operator may name it (link an artist, or mark it an extra); naming is
# optional, and an unnamed performer is simply one with neither.
#
# The operator also says who REPLACES them (the recast): an athlete (Person) in
# one of that athlete's looks (Appearance). The default is no swap. recast_keep
# is the card's Keep Original checkbox: it keeps the athlete and look the
# operator picked (remembered, so unchecking it restores them) but
# nothing reads them as a swap while it is set: not the prompts, not the swap
# target, not the hand-off. A row with no athlete is not swapped either way.
# Only the operator sets it; the agent API refuses the keys.
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

  # The letter this person goes by in clip prompts and on lettered reference
  # frames: Person 2 is B in every clip of the source (MusicVideos::PersonLetters).
  def letter = MusicVideos::PersonLetters.for(ordinal)

  # The card owes nothing. Naming an artist is optional and the swap is off by
  # default, so every card is closed except a swap still waiting for its look.
  def resolved? = recast_decided?

  # The operator linked an artist: the optional rolodex half of the card.
  def named? = artist_slug.present?

  # Swapping: an athlete is picked and Keep Original is unchecked, with or without a look.
  def swap? = recast_person_slug.present? && !recast_keep?

  # Keep Original is checked over a remembered athlete (and maybe a look).
  def swap_remembered? = recast_person_slug.present? && recast_keep?

  # Who and what the prompts, the swap target and the hand-off use: nil while
  # the swap is off, whatever is remembered.
  def swap_person = (recast_person if swap?)
  def swap_look = (recast_appearance if swap?)

  # An athlete and one of their looks are both chosen.
  def recast? = swap? && recast_appearance_slug.present?

  # A person chosen with no look: they have none yet (the picker lists people
  # with 0 looks), or the one they were given is gone. The card stays open
  # until a look is chosen.
  def recast_pending? = swap? && recast_appearance_slug.blank?

  # Nothing is owed: recast in full, or not swapped (the default). Only a swap
  # waiting for its look is owed one.
  def recast_decided? = !recast_pending?

  # What the cast card draws (and what the recast endpoint answers): "none",
  # nobody remembered, only the Replace with search; "kept", Keep Original is
  # checked over a remembered athlete; "pending", swapping to an athlete with no
  # look; "recast", swapping to an athlete in a look.
  def swap_state
    return "none" if recast_person_slug.blank?
    return "kept" if recast_keep?

    recast_appearance_slug.present? ? "recast" : "pending"
  end

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
    # Turning the swap off only flips the flag: what is remembered may have aged.
    return if recast_keep? && !recast_person_slug_changed? && !recast_appearance_slug_changed?

    return errors.add(:recast_appearance_slug, "needs the athlete it belongs to") if recast_person_slug.blank? && recast_appearance_slug.present?
    return if recast_person_slug.blank?
    return errors.add(:recast_person_slug, "names no person") unless Person.exists?(slug: recast_person_slug)
    return if recast_appearance_slug.blank?
    return if Appearance.recastable.exists?(slug: recast_appearance_slug, person_slug: recast_person_slug)

    errors.add(:recast_appearance_slug, "is not a live look of that athlete")
  end
end
