module Appearances
  # THE CHARACTER-SHEET PROMPT FOR ONE OF OUR CAST: a mascot or a puppet, never a
  # real human (Character; epic email-image-builder, addendum "Characters").
  #
  # A SEPARATE PROMPT, NOT A BRANCH IN CharacterSheetPrompt. That one is written
  # for an athlete: "this exact man", football pads, a nameplate, "facial features
  # faithful to the reference photograph", "Photorealistic". Every one of those is
  # wrong for a drawn character, and the likeness wording is the part that must
  # never reach one: a character is fictional, so the prompt asks the generator to
  # keep a DESIGN consistent, not to carry a face.
  #
  # The layout is the turnaround Alex asked for (piece B art-directs it): a
  # full-body turn on the top row and expressions on the bottom, one image, so the
  # panels are generated together and cannot drift apart.
  class CastSheetPrompt
    TURNAROUND = [
      "front view",
      "three-quarter view facing left",
      "side profile facing left",
      "back view"
    ].freeze

    EXPRESSIONS = [
      "neutral and friendly",
      "big open-mouthed grin",
      "fierce and determined",
      "surprised",
      "laughing"
    ].freeze

    def self.call(appearance) = new(appearance).call

    def initialize(appearance)
      @appearance = appearance
      @character = appearance.character
    end

    def call
      [preamble, design, turnaround, expressions, closing].compact_blank.join("\n\n")
    end

    private

    def name = @appearance.owner_name
    def kind = @character&.kind.presence || "character"

    def preamble
      <<~TEXT.strip
        Generate a character model reference sheet of #{name}, an original illustrated #{kind}, as a single
        image laid out in two rows on an identical plain light-grey background with identical even lighting in
        every panel. Draw the character exactly as designed in the reference images: the same proportions,
        silhouette, colours, markings, outfit and accessories in every panel.
      TEXT
    end

    def design
      lines = ["This look: #{@appearance.descriptor}."]
      lines << "Colourway: #{@appearance.colorway}." if @appearance.colorway.present?
      lines << @appearance.generation_notes.to_s.strip if @appearance.generation_notes.present?
      lines.join(" ")
    end

    def turnaround
      views = TURNAROUND.each_with_index.map { |view, i| "  #{i + 1}. full body, #{view}" }
      ["TOP ROW, a full-body turnaround, four panels left to right:", *views].join("\n")
    end

    def expressions
      views = EXPRESSIONS.each_with_index.map { |mood, i| "  #{i + 1}. head and shoulders, #{mood}" }
      lead = "BOTTOM ROW, five expression panels left to right"
      lead += ", in keeping with this personality: #{personality}" if personality.present?
      ["#{lead}:", *views].join("\n")
    end

    # The profile's personality, minus an editor's bracketed marker such as the
    # seed's "[Draft for Alex]", and without its closing full stop (the line
    # ends in a colon).
    def personality
      @character&.personality.to_s.squish.sub(/\A\[[^\]]*\]\s*/, "").truncate(240).delete_suffix(".").presence
    end

    def closing
      "The SAME character in every panel. Match the illustration style of the reference images. " \
        "No text, labels, captions or logos anywhere in the image."
    end
  end
end
