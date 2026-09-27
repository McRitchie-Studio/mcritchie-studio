module Athletes
  # WHAT THIS ATHLETE'S BUILD IS, DERIVED FROM THE MEASUREMENT RATHER THAN THE CROP.
  #
  # WHY THIS EXISTS AT ALL, when the task that spawned it is called "describe
  # athletes from headshots". A headshot is head and shoulders. It cannot see a
  # body, so a vision model asked for "build" from one is guessing from a collar —
  # and a confidently wrong build is worse than an empty one, because the empty
  # field shows on the person page and invites a human to fill it while the wrong
  # one silently poisons every prompt built from it (Athlete#physical_brief).
  #
  # THE MEASUREMENT IS ALREADY THERE, which is what settles it. Measured on
  # production 2026-09-26: all 2,051 athletes carry BOTH height_inches and
  # weight_lbs (range 67..81 in, 156..380 lb, zero implausible values), while
  # build/skin_tone/hair_description were empty for every one of them. So the
  # better source was on the record the whole time and needed no API call.
  #
  # IT COSTS NOTHING AND COVERS MORE. 2,043 of those 2,051 have a cached headshot,
  # so a vision-only pass could never reach the other 8 — this reaches all of them,
  # for $0.
  #
  # THE STRING LEADS WITH THE NUMBERS. The adjective band below is a judgement and
  # arguable; the height and weight are facts. Putting them first means the worst
  # case is a debatable adjective attached to a correct measurement, never a bare
  # adjective standing in for one.
  module BuildFromMeasurements
    # PLAUSIBILITY WINDOW, not a validation. A row outside it is not described
    # rather than described wrongly — the same "prefer blank to a guess" rule the
    # vision half follows. Deliberately wider than the observed production range
    # (67..81 in, 156..380 lb) so a legitimate outlier signing is described,
    # while a unit mix-up (centimetres in an inches column: 180 "inches") or a
    # zero-filled import is not.
    HEIGHT_INCHES = (48..96).freeze
    WEIGHT_LBS = (100..500).freeze

    # BMI BANDS, CHOSEN AGAINST REAL ROWS rather than against the general-population
    # chart, because a 6 ft 5 in 380 lb offensive tackle is not "obese", he is an
    # offensive tackle. Each band was read back against production athletes at its
    # edges (measured 2026-09-26):
    #
    #   24.4  blake-grupe      K    67 in 156 lb  -> lean
    #   26.7  jaxon-smith-njigba WR 72 in 197 lb  -> athletic, well-built
    #   30.8  a 74 in 240 lb linebacker           -> solidly built, muscular
    #   38.7  a 75 in 310 lb defensive tackle     -> heavy, powerfully built
    #   41.7  trent-brown      OT   80 in 380 lb  -> very heavy, massive frame
    #
    # The observed population spans ~24 to ~45, so every band below is reachable
    # except the bottom one — kept anyway because the window above admits lighter
    # rows than football currently supplies.
    BANDS = [
      [22.0, "slight, wiry"],
      [26.0, "lean"],
      [30.0, "athletic, well-built"],
      [34.0, "solidly built, muscular"],
      [39.0, "heavy, powerfully built"],
      [Float::INFINITY, "very heavy, massive frame"]
    ].freeze

    # The imperial BMI constant: 703 x lb / in^2.
    BMI_FACTOR = 703.0

    # DOES THE RECORD CARRY BOTH MEASUREMENTS AT ALL? Reported, never graded. It is
    # the wider of the two predicates below and it exists to tell the two data gaps
    # apart in the run report: "no measurement on file" from "a measurement on file
    # that this source cannot use".
    def self.measured?(athlete)
      return false if athlete.nil?

      athlete.height_inches.present? && athlete.weight_lbs.present?
    end

    # CAN THIS SOURCE DERIVE A BUILD FOR THIS ROW? This is the population the free
    # lane's verdict grades (lib/tasks/athletes.rake, rule 2), and it is narrower than
    # #measured? on purpose.
    #
    # STILL A FACT ABOUT THE ROW, NOT A VERDICT ABOUT IT, which is the property the
    # rule depends on. "Both values are integers inside a frozen constant range" is
    # read off the record against HEIGHT_INCHES and WEIGHT_LBS; it never runs the BMI
    # maths, never consults BANDS, and never formats a string. So a deriver whose
    # judgement is broken — a band table that lost its catch-all, an inverted
    # comparison, a formatting raise — still shows up to the caller as a lane that had
    # derivable rows and wrote none of them, which is exactly what rule 2 is for. That
    # is the `nfl:upload_headshots` defect the rule exists to make impossible:
    # `candidates: 2048`, `cached: 0`, a clean summary, exit 0, for its whole life.
    #
    # WHY NOT GRADE ON #measured?, which the first cut did. Presence of the two columns
    # is not the same question as usability of their values, and the gap between them
    # is reachable: a unit mix-up (centimetres in an inches column: 180 "inches") is
    # measured-but-underivable, so it was counted as a row the lane should have written
    # and never could. On the warm re-run that row is the ONLY one left wanting a
    # build, so the lane reported "had the input for 1, wrote 0" and aborted — on every
    # run, for ever, with nothing wrong. Measured in the desk 2026-09-26: one 180in/200lb
    # row beside three sound ones fills three on the cold pass, then every re-run
    # reports build_measured=1 build_filled=0. A verdict that cannot be cleared by
    # fixing the lane is a verdict that gets switched off.
    #
    # WHAT GUARDS THIS PREDICATE, since the rule can no longer. A broken #in_window?
    # would silence rule 2 rather than trip it, so the window is pinned by the suite
    # instead — test/services/athletes/build_from_measurements_test.rb walks both
    # edges of both ranges through #derivable? and #describe together. The split is
    # deliberate: the suite guards the precondition, the rule guards the judgement.
    def self.derivable?(athlete)
      return false if athlete.nil?

      in_window?(height_inches: athlete.height_inches, weight_lbs: athlete.weight_lbs)
    end

    # Returns the build sentence, or NIL when the measurements cannot support one.
    # Nil is a real answer here and the caller writes nothing for it.
    def self.call(athlete)
      return nil if athlete.nil?

      describe(height_inches: athlete.height_inches, weight_lbs: athlete.weight_lbs)
    end

    # Split from #call so the bands can be exercised over literals, without
    # manufacturing an Athlete row per band.
    #
    # It re-checks the window rather than trusting the caller to have asked
    # #derivable? first: this is also the entry point the suite and a console use over
    # literals, and a deriver that formats whatever it is handed is how a
    # centimetre-valued row gets described as "15 ft 0 in".
    def self.describe(height_inches:, weight_lbs:)
      return nil unless in_window?(height_inches: height_inches, weight_lbs: weight_lbs)

      height = Integer(height_inches)
      weight = Integer(weight_lbs)

      "#{height / 12} ft #{height % 12} in, #{weight} lb; #{frame_for(height, weight)}"
    end

    # THE ONE READING OF THE WINDOW, shared by the predicate the caller grades on and
    # the deriver the caller grades. Two copies would be two things to keep in
    # agreement, and a rule that disagreed with its own deriver about the boundary is
    # precisely the false positive this pass removed.
    def self.in_window?(height_inches:, weight_lbs:)
      height = Integer(height_inches, exception: false)
      weight = Integer(weight_lbs, exception: false)
      return false unless height && weight

      HEIGHT_INCHES.cover?(height) && WEIGHT_LBS.cover?(weight)
    end

    # The first band whose ceiling the BMI is under. `BANDS` ends at INFINITY so
    # this can never fall through to nil — a `detect` with no final catch-all is
    # how a heavier-than-expected signing would have come back blank.
    def self.frame_for(height, weight)
      bmi = BMI_FACTOR * weight / (height * height)
      BANDS.detect { |ceiling, _label| bmi < ceiling }.last
    end

    private_class_method :frame_for
  end
end
