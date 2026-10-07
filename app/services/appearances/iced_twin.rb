# frozen_string_literal: true

module Appearances
  # THE ICED-OUT TWIN OF A LOOK: the same person in the same uniform, wearing
  # designer shades and diamond jewelry (the operator's ask, 2026-10-06: "create
  # Dak model" makes the Dak model AND an iced-out Dak model).
  #
  # The twin is its own Appearance, so the recast picker and the look dropdown
  # list it beside its base ("Cowboys white · iced"), and its sheet build is its
  # own build: the iced prompt is chosen by the twin's `iced` flag inside
  # Appearances::GenerateArtifact, so nothing here spends. Making a twin is a
  # free row; building its sheet is a separate, explicit, paid press.
  class IcedTwin
    SUFFIX = " · iced"

    class Refused < StandardError; end

    def self.create!(base) = new(base).create!

    # The base's live twin, or nil when it may have one made. A reason string
    # when it may not.
    def self.refusal(base)
      return "a look's iced twin cannot have a twin of its own" if base.iced?
      return "a music-video look is a performer, not a model, so it has no iced twin" if base.music_video_look?
      return "a retired look gets no iced twin" if base.retired?

      nil
    end

    def initialize(base)
      @base = base
    end

    # Idempotent: returns the existing live twin rather than a second one.
    def create!
      reason = self.class.refusal(@base)
      raise Refused, reason if reason

      @base.iced_twin || Appearance.create!(
        person_slug: @base.person_slug,
        team_slug: @base.team_slug,
        reference_url: @base.reference_url,
        generation_notes: @base.generation_notes,
        # NOT the colorway: Appearance.file_for_colorway! finds a person's look
        # by colorway, and must keep finding the base. The prompt reads the
        # uniform through the base instead (CharacterSheetPrompt#colourway).
        descriptor: Appearance.available_descriptor(@base.person_slug, "#{@base.descriptor}#{SUFFIX}"),
        iced: true,
        base_appearance_slug: @base.slug,
        # The same uniform, so the same number (piece 16's clip prompts name the
        # player by it); editable on the twin's own row afterwards.
        jersey_number: @base.jersey_number
      )
    end
  end
end
