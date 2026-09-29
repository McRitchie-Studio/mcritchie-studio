module Appearances
  # The sheet prompt for a music-video look: CharacterSheetPrompt's 5x2 layout
  # and head views, dressed as the performer is in the video's stills instead of
  # in a football uniform. UNMEASURED: no sheet has been generated from this
  # text yet, so the first real one is its test.
  class ArtistSheetPrompt
    # Repeated in every panel, for the reason CharacterSheetPrompt gives: a
    # global rule stated once loses to a panel's own description.
    PANEL_SUFFIX = ", in the same outfit, hair, eyewear and jewelry as the reference stills".freeze

    def self.call(appearance) = new(appearance).call

    def initialize(appearance)
      @appearance = appearance
    end

    def call
      [preamble, left_columns, right_columns, closing].join("\n\n")
    end

    private

    def preamble
      <<~TEXT.strip
        Generate a character model reference sheet of this exact person as a single image, laid out as a
        5-column by 2-row grid, identical neutral grey seamless studio background and identical even studio
        lighting in every panel.

        The reference images are stills of this person from a music video. Dress them exactly as they
        appear in those stills: the same outfit, hair, eyewear and jewelry, clearly visible in EVERY
        SINGLE PANEL.
      TEXT
    end

    def left_columns
      <<~TEXT.strip
        LEFT TWO COLUMNS, full body standing figures each spanning the full height of both rows:
        Column 1: full body facing forward#{PANEL_SUFFIX}.
        Column 2: full body facing away showing the back#{PANEL_SUFFIX}. The head is turned ONLY SLIGHTLY to the left, a relaxed glance of about fifteen degrees.
      TEXT
    end

    def right_columns
      lines = CharacterSheetPrompt::HEAD_VIEWS.map { |view| "  - #{view}#{PANEL_SUFFIX}." }
      <<~TEXT.strip
        RIGHT THREE COLUMNS, six head-and-upper-torso views, three on the top row and three on the
        bottom row:
        #{lines.join("\n")}
      TEXT
    end

    def closing
      "The SAME individual in every panel, facial features faithful to the reference stills. " \
        "Photorealistic, sharp focus."
    end
  end
end
