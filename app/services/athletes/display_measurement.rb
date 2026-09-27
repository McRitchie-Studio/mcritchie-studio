module Athletes
  # HEIGHT AND WEIGHT ARRIVE AS PROSE. This turns it back into the integers the
  # schema holds — or into nil, loudly, and never into a guess.
  #
  # ── WHY THIS EXISTS AT ALL ────────────────────────────────────────────────────
  #
  # Measured against ESPN 2026-09-27, for Bo Nix (4426338) and Ashton Jeanty
  # (4890973) alike, the numeric fields are EMPTY and only the display strings
  # carry the value:
  #
  #     "height"        => nil          "weight"        => nil
  #     "displayHeight" => "6' 2\""     "displayWeight" => "217 lbs"
  #
  # `athletes.height_inches` and `athletes.weight_lbs` are integers, so something
  # has to read that prose. This is that something, and it is a separate object
  # from the provider that fetches it because a SECOND source will also hand over
  # display strings — the operator's own framing, 2026-09-27: "we can always add
  # supliment data sourses later". A parser living inside the ESPN client would be
  # copied the day that happens, and two copies of a measurement rule drift.
  #
  # ── WHY IT REFUSES INSTEAD OF GUESSING ───────────────────────────────────────
  #
  # This is the trap the whole task was filed around: a wrong integer here raises
  # NOTHING. It lands in `height_inches`, feeds `Athlete#physical_brief`'s
  # "Build:" line, and reaches the character-sheet prompt as a body that is simply
  # the wrong shape — and no test, log line or operator glance would catch it,
  # because a plausible number looks exactly like a correct one.
  #
  # So every method here is STRICT. A string it cannot read confidently returns
  # nil, and `Athletes::AcquireOrValidate` reports the raw string it could not read
  # rather than storing a number nobody can trace. Refusing is recoverable; a
  # silent wrong build is not.
  #
  # The bounds are part of that strictness, not decoration. They are what catches
  # the parse that "worked": read `"5' 13\""` as 73 and the arithmetic is fine
  # while the input was nonsense, so an inches part outside 0-11 is a refusal, and
  # a total outside the range a professional football player occupies is too.
  module DisplayMeasurement
    # The inhabited range for each measurement, as a REFUSAL boundary and not a
    # validation of the athlete. Generous on purpose — the job is to reject a
    # misparse ("6" read as 6 inches, a stray 2026 read as a weight), never to
    # have an opinion about an unusual body.
    HEIGHT_INCHES_RANGE = (48..96).freeze
    WEIGHT_LBS_RANGE = (100..450).freeze

    # The placeholders a feed uses to mean "we do not know", which must read as
    # nil rather than as an unparsable surprise. Compared after squishing and
    # downcasing.
    BLANKS = ["", "-", "--", "---", "n/a", "na", "none", "null", "tbd", "0"].freeze

    # FEET AND INCHES, in the shapes a feed actually emits. Both parts of the
    # string are optional past the feet, because a round height loses its inches:
    # "6'", "6' 0\"", "6'0\"" and "6-0" are one man.
    #
    #   6' 2"   ->  74        (the measured ESPN shape)
    #   5' 8"   ->  68
    #   6'0"    ->  72        (no space)
    #   6'      ->  72        (no inches part at all)
    #   6 ft 2  ->  74
    #   6-2     ->  74
    #   5' 13"  ->  nil       (inches out of range: a misparse, not a tall man)
    #   ""      ->  nil
    #   nil     ->  nil
    FEET_INCHES = /
      \A
      (?<feet>\d{1,2})                      # feet
      \s* (?: ' | ’ | -{1} | \s*ft\.?\s* )  # the foot mark: quote, hyphen or "ft"
      \s*
      (?: (?<inches>\d{1,2}) \s* (?: " | '' | ” | in\.? )? )?   # inches, optional
      \s*
      \z
    /x

    # POUNDS. The unit is optional because a feed drops it as often as it sends
    # it; what is NOT optional is that the whole string be a number and a unit,
    # so "217 lbs (est)" refuses rather than quietly becoming 217.
    POUNDS = /
      \A
      (?<pounds>\d{2,3})
      \s*
      (?: lbs?\.? | pounds? )?
      \z
    /xi

    # Inches, or nil when the string cannot be read as a height with confidence.
    def self.height_inches(value)
      raw = squish(value)
      return nil if blank_marker?(raw)

      match = FEET_INCHES.match(raw)
      return nil unless match

      feet = match[:feet].to_i
      inches = match[:inches].to_i
      # 12 inches is a foot the writer forgot to carry, not a measurement. Both
      # readings of "5' 12\"" are speculation, so neither is stored.
      return nil unless (0..11).cover?(inches)

      total = (feet * 12) + inches
      HEIGHT_INCHES_RANGE.cover?(total) ? total : nil
    end

    # Pounds, or nil when the string cannot be read as a weight with confidence.
    def self.weight_lbs(value)
      raw = squish(value)
      return nil if blank_marker?(raw)

      match = POUNDS.match(raw)
      return nil unless match

      pounds = match[:pounds].to_i
      WEIGHT_LBS_RANGE.cover?(pounds) ? pounds : nil
    end

    # A JERSEY NUMBER, which is prose for the same reason the others are: ESPN
    # sends `jersey` as the string "30" and `displayJersey` as "#30". Nothing here
    # invents a number from a word, and 0 is a LEGAL jersey (the league has
    # allowed it since 2023), which is why it is handled here and not swept up by
    # BLANKS — `squish` sends "0" through this method's own branch first.
    #
    #   "30"  -> 30     "#2" -> 2      "0" -> 0
    #   ""    -> nil    "--" -> nil    "QB" -> nil
    def self.jersey_number(value)
      raw = squish(value)
      return nil if raw.empty?
      return 0 if raw == "0" || raw == "#0"

      match = /\A#?(?<number>\d{1,2})\z/.match(raw)
      return nil unless match

      match[:number].to_i
    end

    def self.squish(value) = value.to_s.strip.gsub(/\s+/, " ")
    private_class_method :squish

    def self.blank_marker?(raw) = BLANKS.include?(raw.downcase)
    private_class_method :blank_marker?
  end
end
