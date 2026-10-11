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

    # THE BACK VIEW, column 2: bare head, hair visible, nameplate and number, and the
    # operator-approved fifteen-degree head turn. Constants so a test can read the
    # exact text that ships.
    BACK_VIEW_LEAD = "Column 2: full body facing away showing his back, NO helmet, bare head with his hair " \
                     "visible from behind".freeze
    BACK_VIEW_TURN = "His head is turned ONLY SLIGHTLY to the left - a subtle relaxed glance of about " \
                     "fifteen degrees, just enough to catch the edge of his ear and a sliver of his jaw in " \
                     "profile. This is a gentle natural turn, NOT a sharp ninety-degree look over the " \
                     "shoulder, and the neck must appear relaxed and unstrained.".freeze

    # ── THE REFERENCE ROLES AND THE UNIFORM (task player-sheet-uniform-and-build) ──
    #
    # Each attached image is named by its position and told what to take from it, so a
    # uniform photo of another player never lends his face and the body archetype never
    # lends its practice gear.
    ROLE_TEXT = {
      identity: "IDENTITY ANCHOR - this man's face. Every face on the sheet is his: take his facial " \
                "features, skin tone and hair from here and from nowhere else.",
      uniform: "UNIFORM REFERENCE - real game photos of his team's uniform in this colourway. Copy ONLY " \
               "the uniform from them: badges, patch placement, stripes, number font and outline, collar " \
               "and sleeve trim, pants and socks. Take NOTHING else: not a face, not a body, not a pose; the " \
               "players in them may be other men.",
      body: "BODY BUILD REFERENCE - match this body's build and proportions; take nothing else from it: " \
            "not the face, not the uniform."
    }.freeze

    UNIFORM_FROM_PHOTOS = "UNIFORM DETAILS - copy them EXACTLY from the UNIFORM REFERENCE images: the team " \
                          "logo on BOTH shoulders, the NFL shield at the collar, a captain \"C\" patch on the " \
                          "chest ONLY if the uniform references show one, the number font and outline, the " \
                          "collar and sleeve trim, and the pants and sock colours.".freeze
    UNIFORM_FROM_TEXT = "UNIFORM DETAILS, as on a real NFL game jersey: the team logo on BOTH shoulders, the " \
                        "NFL shield at the collar, the numbers in the team's own font and outline, the team's " \
                        "collar and sleeve trim, and the team's pants and sock colours. No captain patch.".freeze

    # The operator, 2026-10-11: "most football players have the same bulky athletic
    # build". Used only when a look resolves no archetype at all.
    GENERIC_BUILD = "BUILD: he has the bulky athletic build of an NFL player - broad padded shoulders, a " \
                    "thick muscular back, solid glutes and powerful thighs.".freeze
    BODY_IMAGE_RULE = "Match the BODY BUILD REFERENCE image's build and proportions in both full-body " \
                      "figures; take nothing else from it: not the face, not the uniform.".freeze

    # The six right-hand head views, in the operator-approved reading order.
    HEAD_VIEWS = [
      "front neutral",
      "three-quarter left",
      "right profile",
      "three-quarter looking up",
      "front smiling",
      "rear view of the head"
    ].freeze

    # ── THE ICED VARIANT (recast epic piece 15, the operator's spec 2026-10-06) ──
    #
    # The same grid, identity rules and pads rule, plus designer shades and an
    # iced-out jewelry set, held CONSISTENT across the sheet, and two head views
    # swapped for special shots (the rings held to the camera, the grill in a big
    # smile). One builder with a flag, not a copy, so a change to the layout or
    # the pads clause reaches both sheets.
    #
    # THE SHADES ARE ONE NAMED DESIGN, not "designer shades", because a vague noun
    # is re-imagined per panel and the operator asked for the SAME shades in every
    # panel. Per the rule above, the consistency demand is repeated per panel
    # (ICED_PANEL_SUFFIX), not stated once.
    SHADES = "one specific pair of designer sunglasses - black acetate frames, dark tinted lenses, " \
             "thin gold metal temples - worn over his eyes".freeze
    ICED_PANEL_SUFFIX = ", wearing the SAME sunglasses and the SAME iced-out jewelry set as every other panel".freeze

    # Generic pieces, used for any kind the person has no PersonJewelry record of.
    GENERIC_PIECES = {
      "chain" => "a heavy diamond-encrusted Cuban link chain with a large diamond pendant, worn OVER the jersey",
      "watch" => "a fully diamond-encrusted watch (iced-out bezel, dial and bracelet)",
      "bracelet" => "a diamond tennis bracelet",
      "grill" => "a diamond-encrusted grill covering his top and bottom teeth",
      "rings" => "diamond-encrusted rings on several fingers of both hands"
    }.freeze

    # The head views with the two special shots in place of "three-quarter
    # looking up" and "front smiling". Same count and positions, so the grid holds.
    RINGS_VIEW = "RINGS SHOT: facing the camera, both hands raised in front of his chest with the backs of " \
                 "his fingers turned to the lens so every ring is large, sharp and clearly readable".freeze
    GRILL_VIEW = "GRILL SHOT: front, a big wide open smile showing the diamond-encrusted grill on his teeth".freeze
    ICED_HEAD_VIEWS = HEAD_VIEWS.map { |view|
      { "three-quarter looking up" => RINGS_VIEW, "front smiling" => GRILL_VIEW }.fetch(view, view)
    }.freeze

    def self.call(appearance, **kwargs) = new(appearance, **kwargs).call

    # `iced:` defaults to the look's own flag, so an iced twin's build reads the
    # iced prompt with no change to Appearances::GenerateArtifact's call.
    # `references:` is the build's Appearances::SheetReferences: which images ride and
    # in what order, so the prompt can name each by position. Nil (a prompt read with
    # no build behind it) means one face and nothing else attached.
    def initialize(appearance, colourway: nil, number: nil, surname: nil, iced: nil, references: nil)
      @appearance = appearance
      @colourway = colourway
      @number = number
      @surname = surname
      @iced = iced.nil? ? appearance&.iced? || false : iced
      @references = references || (appearance && SheetReferences.prompt_only(appearance))
    end

    def iced? = @iced

    def call
      parts = [preamble]
      parts << reference_roles if @references
      parts += [uniform_clause, build_clause]
      parts << iced_clause if iced?
      parts += [left_columns, right_columns, closing]
      parts.compact.join("\n\n")
    end

    # WHAT THE SHEET IS OF. Falls back through the look before giving up, because
    # `colorway` is nil on most looks and the descriptor is what the operator
    # actually typed ("Broncos home"). An iced twin reads its BASE look: its own
    # descriptor ends in " · iced", which is not a uniform.
    def colourway
      uniform = @appearance&.iced? && @appearance.base_appearance || @appearance
      @colourway.presence ||
        uniform&.colorway.presence ||
        uniform&.descriptor.to_s.delete_suffix(Appearances::IcedTwin::SUFFIX).presence ||
        "team"
    end

    # THE SURNAME FOR THE NAMEPLATE, or nil: the caller's `surname:`, then the
    # person's stored `last_name`, and only when that is blank the last word of the
    # full name. The last word alone printed "BROWN" for Amon-Ra St. Brown and "NOY"
    # for Kyle Van Noy (task sheet-nameplate-quotes-surname); the importers already
    # keep a multi-word surname whole in `last_name`.
    def surname
      person = @appearance&.person
      @surname.presence ||
        person&.last_name.presence ||
        person&.full_name.to_s.split.last.presence
    end

    # THE NUMBER: the caller's `number:` when one is passed, otherwise THE LOOK'S OWN
    # `jersey_number` (task player-sheet-uniform-and-build, 2026-10-11). The column is
    # filled from the roster when a look is made (Appearance, `athletes.jersey_number`)
    # and edited on the look page; a sheet built with no argument used to come back
    # numberless, which is what the operator's review of a real sheet found. An iced
    # twin with no number of its own reads its base's: same uniform, same number.
    #
    # A LOOK WITH NO NUMBER STILL OMITS THE CLAUSES rather than emitting a placeholder
    # — a sheet reading "jersey number <NUMBER>" is worse than a sheet with no number,
    # because the model will happily render the brackets.
    def number
      @number.presence ||
        @appearance&.jersey_number ||
        (@appearance&.iced? && @appearance.base_appearance&.jersey_number) ||
        nil
    end

    PUNCTUATION_NAMES = { "-" => "hyphen", "'" => "apostrophe", "’" => "apostrophe", "." => "period",
                          " " => "space" }.freeze

    # "SMITH-NJIGBA" => "S-M-I-T-H, hyphen, N-J-I-G-B-A". Public so a test (or any
    # other prompt that draws a name) reads the one spelling rule.
    def self.spell(text)
      text.to_s.scan(/[[:alnum:]]+|[^[:alnum:]]/).map { |token|
        token.match?(/[[:alnum:]]/) ? token.chars.join("-") : PUNCTUATION_NAMES.fetch(token, token)
      }.join(", ")
    end

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

    # BOTH FULL-BODY FIGURES ARE BARE-HEADED (the operator, 2026-10-11: the helmeted
    # view becomes its own model later, not now). The back view used to say "wearing
    # his helmet", and that was the sheet's only helmet; a builder adding one back
    # should know it was taken out on purpose.
    def left_columns
      <<~TEXT.strip
        LEFT TWO COLUMNS, full body standing figures each spanning the full height of both rows:
        Column 1: full body facing forward, NO helmet, bare head#{panel_suffix}, game pants and cleats.
        #{BACK_VIEW_LEAD}#{nameplate_clause}#{panel_suffix}, game pants and cleats. #{BACK_VIEW_TURN}
      TEXT
    end

    # EACH VIEW CARRIES THE SUFFIX ON ITS OWN LINE rather than one trailing "each
    # one in full pads" after the list. Same rule, one level down: a list item is
    # a local description too.
    def right_columns
      lines = head_views.map { |view| "  - #{view}#{panel_suffix}." }
      <<~TEXT.strip
        RIGHT THREE COLUMNS, six head-and-upper-torso views, three on the top row and three on the
        bottom row:
        #{lines.join("\n")}
      TEXT
    end

    def closing
      "The SAME individual in every panel, facial features faithful to the IDENTITY ANCHOR photograph. " \
        "Photorealistic, sharp focus."
    end

    # WHAT EACH ATTACHED IMAGE IS FOR, by position. The images ride before this text
    # (ImageGeneration::OpenAI#request_body), in Appearances::SheetReferences' order.
    def reference_roles
      lines = @references.roles.map { |first, last, role| "  - #{image_span(first, last)}: #{ROLE_TEXT.fetch(role)}" }
      "REFERENCE IMAGES, in the order attached:\n#{lines.join("\n")}"
    end

    def image_span(first, last) = first == last ? "Image #{first}" : "Images #{first}-#{last}"

    # THE BADGES, named, because a plain jersey is what came back without them (the
    # operator's review, 2026-10-11). With uniform references the model is told to copy
    # them exactly, and the captain patch rides only if the photos show one.
    def uniform_clause
      return UNIFORM_FROM_PHOTOS if uniform_references?

      UNIFORM_FROM_TEXT
    end

    # THE BODY. The archetype's description always (it is text the operator can read on
    # /body-archetypes); the image instruction only when its image is attached.
    def build_clause
      archetype = @references&.archetype
      text = archetype ? "BUILD: he has #{archetype.description}." : GENERIC_BUILD
      text += " #{BODY_IMAGE_RULE}" if body_reference?
      text
    end

    def uniform_references? = @references.present? && @references.uniform_urls.any?
    def body_reference? = @references.present? && @references.body_url.present?

    def head_views = iced? ? ICED_HEAD_VIEWS : HEAD_VIEWS
    def panel_suffix = iced? ? "#{PANEL_SUFFIX}#{ICED_PANEL_SUFFIX}" : PANEL_SUFFIX

    # THE JEWELRY AND THE CONSISTENCY RULE. Each piece comes from the person's
    # PersonJewelry records when there are any (named and described, so a
    # champion is drawn in HIS rings), otherwise from GENERIC_PIECES.
    def iced_clause
      <<~TEXT.strip
        ICED-OUT LOOK. In every panel he also wears #{SHADES}, and this exact jewelry set:
        #{jewelry_lines.map { |line| "  - #{line}" }.join("\n")}
        CONSISTENCY: the sunglasses and every piece of jewelry are ONE fixed set - identical design, size,
        colour and position in every panel where they are visible. Never swap, add, drop or restyle a piece
        between panels.
      TEXT
    end

    def jewelry_lines
      [
        "chain: #{pieces('chain')}",
        "watch on his LEFT wrist: #{pieces('watch')}",
        "bracelet on his RIGHT wrist (the hand without the watch): #{pieces('bracelet')}",
        "grill: #{pieces('grill')}",
        "rings: #{rings}"
      ] + others
    end

    def jewelries
      @jewelries ||= @appearance&.person ? @appearance.person.jewelries.to_a : []
    end

    def pieces(kind)
      own = jewelries.select { |j| j.kind == kind }
      return GENERIC_PIECES.fetch(kind) if own.empty?

      own.map(&:prompt_phrase).join("; ")
    end

    def rings
      own = jewelries.select(&:ring?)
      return GENERIC_PIECES.fetch("rings") if own.empty?

      "his own championship rings, each rendered faithfully - #{own.map(&:prompt_phrase).join('; ')}"
    end

    def others
      jewelries.select { |j| j.kind == "other" }.map { |j| "also: #{j.prompt_phrase}" }
    end

    def number_clause = number.present? ? ", jersey number #{number}" : ""

    # THE SURNAME IS QUOTED LITERAL TEXT (task sheet-nameplate-quotes-surname). The
    # unquoted form, "nameplate LITTLE above number 39", came back on production
    # (2026-10-11) reading "PLAYER": a surname that is also an English word reads as
    # a description of the nameplate ("a little nameplate"), and the model invents a
    # name. Quoted, the word can only be the text to print. Straight quotes, as the
    # captain "C" patch in UNIFORM_FROM_PHOTOS; a double quote inside the surname is
    # dropped so it cannot close the literal early. Apostrophes, hyphens and periods
    # (O'NEIL, SMITH-NJIGBA, ST. BROWN) pass through untouched.
    #
    # AND SPELLED LETTER BY LETTER after the quotes (the operator, 2026-10-11): a
    # second, independent reading of the same text, so any surname the model could
    # misread (a word, a rare spelling) is pinned twice. Only letters and digits are
    # hyphen-spelled; punctuation and spaces are NAMED between the spelled parts
    # rather than spelled, because "S-M-I-T-H---N-J..." would make the name's own
    # hyphen indistinguishable from the spelling's separators. So:
    #   LITTLE        -> L-I-T-T-L-E
    #   SMITH-NJIGBA  -> S-M-I-T-H, hyphen, N-J-I-G-B-A
    #   O'NEIL        -> O, apostrophe, N-E-I-L
    #   ST. BROWN     -> S-T, period, space, B-R-O-W-N
    def nameplate_clause
      text = nameplate_text
      return "" if text.blank?

      part = %(, nameplate reading "#{text}" (spelled #{self.class.spell(text)}) in block capitals)
      part += " above number #{number}" if number.present?
      "#{part}, clearly legible"
    end

    def nameplate_text = surname.to_s.delete('"').squish.upcase.presence
  end
end
