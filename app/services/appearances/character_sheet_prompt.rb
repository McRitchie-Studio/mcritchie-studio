module Appearances
  # THE SHEET PROMPT — the operator-approved v4 layout, built from a look.
  #
  # A SEPARATE OBJECT BECAUSE THE PROMPT IS THE EXPENSIVE PART TO GET WRONG. Every
  # revision of this text cost a generated sheet to learn, so it is written down
  # once, tested without spending, and changed deliberately. The full measured
  # history lives in /Users/alex/projects/.agents/character-sheet-recipe.md.
  #
  # ⚠ REPEAT EVERY MUST-HOLD ATTRIBUTE INSIDE EVERY PANEL'S OWN INSTRUCTION.
  #
  # This is the rule that cost a round and it is the reason this file is shaped
  # the way it is. A global styling rule stated ONCE is overridden by a local
  # description that implies otherwise: "in full pads" at the top, followed by
  # panels described as "head-and-shoulders portraits", produced photo-day crops
  # with no pads at all. The local noun wins. So PANEL_SUFFIX is appended to every
  # single panel line rather than stated once in the preamble — and if you add an
  # attribute that must hold everywhere, it goes in PANEL_SUFFIX, not the preamble.
  #
  # ⚠ AND IT IS STILL NOT ENOUGH FOR CLOSE CROPS — do not read the rule above as
  # solved. MEASURED TWICE INDEPENDENTLY, and per-panel repetition failed to fix it
  # EITHER TIME:
  #
  #   1. On the operator-approved v4 artifact, by the coordinator.
  #   2. Again on this app's own 2026-09-27 run, through this repo's code path.
  #
  # Both were re-read with a criterion describing the OBSERVABLE silhouette rather
  # than naming the equipment, and both answered the same way:
  #
  #     full_body_left_two_have_pads   true
  #     six_head_panels_have_pads      FALSE
  #     reads_as_photo_day_jersey      true
  #
  # The two full-body figures show real pad structure; the six head views do not.
  # The operator approved the artifact, so the LOOK is acceptable — but the claim
  # that the clause was satisfied is false, and the open question is whether
  # per-panel repetition is simply insufficient at this crop or whether the
  # phrasing must describe the SILHOUETTE rather than name the equipment. Anyone
  # changing PADS_CLAUSE is working on that question.
  #
  # TWO MEASUREMENTS IS THE LOAD-BEARING PART, and this file is where it matters most,
  # because this is the copy a builder reads before touching PADS_CLAUSE. It used to
  # cite only the v4 re-measure and omit "either time" — which left the weakest of the
  # three recordings of this defect in the one place it is acted on, and invited a
  # builder to think repeating the clause harder was untried. It was tried, twice.
  # The other two recordings are config/image_generators.yml (`not_measured:` on
  # `openai_gpt5_sheet`) and docs/topics/content-pipeline.md; all three must agree.
  #
  # HOW THE FIRST CHECK MISSED IT, which is the transferable half: a criterion
  # phrased loosely ("pads visible in all panels") got a generous yes from a
  # vision judge; the same image, asked what a football shoulder pad does to a
  # silhouette, answered no. A judge answers the question you ask — so write the
  # criterion to describe the observable, never the intent.
  class CharacterSheetPrompt
    # THE ONE ATTRIBUTE THAT MUST SURVIVE EVERY CROP. Kept as its own constant
    # because it is the subject of an open question and wants to be findable.
    PADS_CLAUSE = "in FULL football pads - bulky shoulder pads worn UNDER the jersey " \
                  "creating a broad squared padded silhouette at the shoulders".freeze

    # APPENDED TO EVERY PANEL. See the rule above: this is what stops a panel's own
    # noun ("portrait") quietly cancelling the global instruction.
    PANEL_SUFFIX = ", #{PADS_CLAUSE}".freeze

    # The six right-hand head views, in the operator-approved reading order.
    HEAD_VIEWS = [
      "front neutral",
      "three-quarter left",
      "right profile",
      "three-quarter looking up",
      "front smiling",
      "rear view of the head"
    ].freeze

    def self.call(appearance, **kwargs) = new(appearance, **kwargs).call

    def initialize(appearance, colourway: nil, number: nil, surname: nil)
      @appearance = appearance
      @colourway = colourway
      @number = number
      @surname = surname
    end

    def call
      [preamble, left_columns, right_columns, closing].join("\n\n")
    end

    # WHAT THE SHEET IS OF. Falls back through the look before giving up, because
    # `colorway` is nil on most looks and the descriptor is what the operator
    # actually typed ("Broncos home").
    def colourway
      @colourway.presence ||
        @appearance&.colorway.presence ||
        @appearance&.descriptor.presence ||
        "team"
    end

    # THE SURNAME FOR THE NAMEPLATE, or nil.
    def surname
      @surname.presence || @appearance&.person&.full_name.to_s.split.last.presence
    end

    # ⚠ THE NUMBER IS STILL HAND-SUPPLIED HERE, AND THAT IS NOW A CHOICE RATHER THAN
    # A LIMIT. `athletes.jersey_number` landed 2026-09-27 (Athletes::AcquireOrValidate,
    # `:roster` policy), so the claim this comment used to make — that no table carries
    # a number and the approved v4 sheet's "14" had to be supplied by hand — is true
    # only of the sheets built before that day.
    #
    # NOTHING READS THE COLUMN FROM HERE YET, DELIBERATELY. Reading it would change the
    # text of every generated prompt, and a prompt change costs money to evaluate and
    # owes its own before/after artifacts; it is a task, not a side effect of correcting
    # a comment. Until then `number:` stays the caller's argument and is nil unless one
    # is passed, and the number and nameplate clauses omit THEMSELVES rather than
    # emitting a literal placeholder — a sheet reading "jersey number <NUMBER>" is worse
    # than a sheet with no number, because the model will happily render the brackets.
    def number = @number.presence

    private

    def preamble
      <<~TEXT.strip
        Generate a character model reference sheet of this exact man as a single image, laid out as a
        5-column by 2-row grid, identical neutral grey seamless studio background and identical even NFL
        team-photo-day lighting in every panel.

        He wears a #{colourway} game uniform#{number_clause}, #{PADS_CLAUSE}. This padded silhouette
        must be clearly visible in EVERY SINGLE PANEL including all the close-up head views - none of
        them are photo-day headshots, every one shows the padded shoulders.
      TEXT
    end

    def left_columns
      <<~TEXT.strip
        LEFT TWO COLUMNS, full body standing figures each spanning the full height of both rows:
        Column 1: full body facing forward, NO helmet, bare head#{PANEL_SUFFIX}, game pants and cleats.
        Column 2: full body facing away showing his back, wearing his helmet#{nameplate_clause}#{PANEL_SUFFIX}. His head is turned ONLY SLIGHTLY to the left - a subtle relaxed glance of about fifteen degrees, just enough to catch the edge of the helmet and a sliver of his jaw in profile. This is a gentle natural turn, NOT a sharp ninety-degree look over the shoulder, and the neck must appear relaxed and unstrained.
      TEXT
    end

    # EACH VIEW CARRIES THE SUFFIX ON ITS OWN LINE rather than one trailing "each
    # one in full pads" after the list. Same rule, one level down: a list item is
    # a local description too.
    def right_columns
      lines = HEAD_VIEWS.map { |view| "  - #{view}#{PANEL_SUFFIX}." }
      <<~TEXT.strip
        RIGHT THREE COLUMNS, six head-and-upper-torso views, three on the top row and three on the
        bottom row:
        #{lines.join("\n")}
      TEXT
    end

    def closing
      "The SAME individual in every panel, facial features faithful to the reference photograph. " \
        "Photorealistic, sharp focus."
    end

    def number_clause = number.present? ? ", jersey number #{number}" : ""

    def nameplate_clause
      return "" if surname.blank?

      part = ", nameplate #{surname.upcase}"
      part += " above number #{number}" if number.present?
      "#{part} clearly legible"
    end
  end
end
