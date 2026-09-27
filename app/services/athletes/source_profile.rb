module Athletes
  # ONE PERSON AS AN OUTSIDE SOURCE DESCRIBES THEM — normalized, already parsed,
  # and carrying no trace of which source it came from beyond `source` itself.
  #
  # ── WHY A VALUE OBJECT AND NOT A HASH OF ESPN JSON ───────────────────────────
  #
  # ESPN is the primary source by the operator's decision (2026-09-27: "we can use
  # ESPN as our primary fetch data about this player. We can always add supliment
  # data sourses later"), and the second half of that sentence is the design
  # constraint. `Athletes::AcquireOrValidate` decides what to WRITE and what to
  # REFUSE to overwrite; if it read `athlete.dig("position", "abbreviation")` it
  # would be an ESPN client with a decision attached, and adding a second source
  # would mean either a second copy of the whole act or a shape check at every
  # field. So the providers own the vocabulary and hand over THIS, and the act
  # knows nothing about anybody's JSON.
  #
  # ── EVERY FIELD IS ALREADY OUR UNITS, OUR VOCABULARY, OUR SLUGS ──────────────
  #
  # A provider does the whole translation before it gets here:
  #   · `height_inches` / `weight_lbs` are INTEGERS or nil — never "6' 2\"" (see
  #     Athletes::DisplayMeasurement, and `unparsed` below for what nil costs).
  #   · `position` is already through PositionConcern.normalize_position with the
  #     source's own map, so it is our vocabulary and not the feed's.
  #   · `team_slug` is a slug that exists in `teams`, not an abbreviation.
  #
  # ── `unparsed` IS THE HONEST HALF OF A STRICT PARSER ─────────────────────────
  #
  # DisplayMeasurement refuses anything it cannot read, which would otherwise mean
  # a field silently arriving nil and the act reporting nothing at all — the exact
  # silence the strictness was bought to avoid. So a provider records the RAW
  # string beside the field name it could not fill, and the act prints it. A field
  # that is genuinely absent upstream is simply not in this hash; a field that was
  # PRESENT and UNREADABLE is, and those are different facts.
  SourceProfile = Struct.new(
    :source,          # Symbol — :espn. Named in every report line, so a wrong value is visible.
    :source_id,       # String — the provider's own id. ESPN's `athlete.id`, our `athletes.espn_id`.
    :first_name,
    :last_name,
    :jersey_number,   # Integer or nil
    :position,        # String, our vocabulary, or nil
    :team_slug,       # String — a slug present in `teams`, or nil for a free agent
    :height_inches,   # Integer or nil
    :weight_lbs,      # Integer or nil
    :headshot_url,    # String or nil
    :college,         # String or nil — carried for the report; no column holds it yet
    :unparsed,        # Hash field_name => the raw string the parser refused
    keyword_init: true
  ) do
    def full_name = [first_name, last_name].compact_blank.join(" ")

    def unparsed = self[:unparsed] || {}

    # WHETHER THIS PROFILE IS WORTH ACTING ON AT ALL. A provider that answered
    # with neither an id nor a name has not identified a person, and the act
    # refuses rather than writing a row made of nils.
    def identified? = source_id.to_s.strip.present? && full_name.present?
  end
end
