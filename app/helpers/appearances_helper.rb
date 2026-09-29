# THE CHIP PALETTES for the character-model page.
#
# In a helper rather than inline in the ERB for a reason that is specific to
# Tailwind: `config/tailwind.config.js` scans `app/helpers/**/*.rb`, so a class
# named here compiles exactly as one named in a view — while a class assembled
# from a fragment ("bg-#{role}/10") compiles in NEITHER place, because the scanner
# reads text and never runs Ruby. Every class below is therefore written out
# whole, and that is the constraint to respect when adding a state.
#
# EVERY COLOUR IS A THEME ROLE, never a raw Tailwind palette shade. The page has
# to read in light mode as well as dark, and `bg-emerald-900/50 text-emerald-300`
# — the pattern on the person page this one links from — is a dark-mode-only
# spelling that turns into unreadable dark-on-dark the moment the theme flips.
# `--color-success` and its `contrast_ink` partner are resolved per theme by the
# engine, which is the whole point of the 7-role system.
module AppearancesHelper
  # WHERE A PHOTOGRAPH CAME FROM, in descending order of how far we trust it. The
  # chip exists so a reviewer can tell "we mirrored this ourselves" from "a search
  # engine handed us this and nobody has looked at it" at a glance — which is the
  # difference between a reference set you would spend money on and one you would
  # not.
  SOURCE_CHIPS = {
    AppearanceReferencePhoto::SOURCE_HEADSHOT =>
      { label: "our headshot", classes: "bg-primary/10 text-primary border-primary/30" },
    AppearanceReferencePhoto::SOURCE_OPERATOR =>
      { label: "you added", classes: "bg-success/10 text-success-ink border-success/30" },
    AppearanceReferencePhoto::SOURCE_SEARCH =>
      { label: "web search", classes: "bg-warning/10 text-warning-ink border-warning/30" }
  }.freeze

  UNKNOWN_CHIP = { label: "unknown", classes: "bg-surface-alt text-muted border-subtle" }.freeze

  def reference_source_chip(photo)
    SOURCE_CHIPS.fetch(photo.source, UNKNOWN_CHIP)
  end

  # THE IDENTITY'S STATE AS ONE CHIP. Keyed on Appearance#higgsfield_reference_state
  # rather than on the raw status column, because two of the four states — never
  # minted, and a status word the vendor invented that we do not recognise — have
  # no value in that column to key on.
  #
  # `:unknown` IS STYLED AS A FAILURE on purpose. An unrecognised status is more
  # likely a failed reference than a new success word (Appearance's own comment
  # makes the same argument for reading it as "not ready"), and a chip that styled
  # it neutrally would let a dead identity sit on the page looking merely quiet.
  IDENTITY_CHIPS = {
    none: { label: "not requested",
            classes: "bg-surface-alt text-muted border-subtle" },
    pending: { label: "training",
               classes: "bg-warning/10 text-warning-ink border-warning/40" },
    ready: { label: "ready",
             classes: "bg-success/10 text-success-ink border-success/40" },
    unknown: { label: "unrecognised status",
               classes: "bg-danger/10 text-danger-ink border-danger/40" }
  }.freeze

  def identity_chip(appearance)
    IDENTITY_CHIPS.fetch(appearance.higgsfield_reference_state, UNKNOWN_CHIP)
  end

  # WHY A CANDIDATE WAS PASSED OVER, in the operator's words rather than the
  # column's. "beyond_limit" is a correct value and a useless label; the reviewer
  # needs to know that the photograph was fine and the list was full, because that
  # is the one rejection reason that means RAISE THE CAP rather than FIX THE SEARCH.
  REJECTION_LABELS = {
    AppearanceReferencePhoto::REJECTED_UNFETCHABLE => "unsafe to fetch",
    AppearanceReferencePhoto::REJECTED_DUPLICATE => "already have it",
    # "face not visible" rather than "helmet": a helmet is the commonest cause and
    # the one the operator named, but the classifier also rejects the back of a
    # head, a distant crowd shot and a document scan — and a label that named only
    # helmets would read as wrong on the other three.
    AppearanceReferencePhoto::REJECTED_FACE_OBSCURED => "face not visible",
    AppearanceReferencePhoto::REJECTED_NOT_A_PHOTO => "not a photo",
    # "NOT THIS PERSON" RATHER THAN "WRONG PERSON": the photograph is not wrong, it is of
    # somebody else, and the operator's next question is WHO — which the tile answers
    # underneath with the name it actually read.
    AppearanceReferencePhoto::REJECTED_WRONG_PERSON => "not this person",
    AppearanceReferencePhoto::REJECTED_MIXED_SUBJECTS => "more than one face",
    # NAMES THE MEASUREMENT, not the verdict. "too small" alone reads as a pixel
    # dimension, and this is about how much of the FRAME the head fills — the variable
    # four real mints turned on.
    # NAMES THE MISSING ACT, NOT THE PHOTOGRAPH. "nothing looked at this" is a statement
    # about us, and an operator who reads it as a judgement of the picture would calibrate
    # his taste against a verdict nobody gave.
    AppearanceReferencePhoto::REJECTED_FACE_UNSCORED => "nothing looked at this one",
    AppearanceReferencePhoto::REJECTED_FACE_TOO_SMALL => "face too small in frame",
    AppearanceReferencePhoto::REJECTED_FACE_SIZE_UNMEASURED => "face size never measured",
    AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT => "past the limit of #{Appearances::GatherReferencePhotos::CHOSEN_LIMIT}"
  }.freeze

  # THE FACE SCORE'S OWN CHIP, banded rather than continuous: the operator is
  # asking "can you see his face in this one?", which is a three-way answer, and a
  # gradient across 100 values would make two adjacent photographs look different
  # when the judgement is the same.
  #
  # The bands are named against Appearances::ReferenceEligibility::FACE_VISIBLE so the
  # colour and the `face not visible` rejection chip can never disagree: a photograph
  # styled as a failure here is exactly one that would be refused as obscured.
  #
  # ⚠ THE MIDDLE BAND HAD NO TEST, AND THE WHOLE PAGE 500'd ON IT. When the thresholds
  # moved out of GatherReferencePhotos this line kept naming the old constant, and every
  # request test stayed green: the only face-scored fixture in the suite was 0.92, which
  # returns on the FIRST branch and never evaluates the `elsif`. A local render of a row
  # scored 0.70 raised `uninitialized constant` and took the page with it. The three-band
  # test beside this one is the hole being closed — a banded helper needs a case per band,
  # or the untested bands are unexecuted code that looks covered.
  def face_score_chip(photo)
    score = photo.face_score.to_f
    if score >= 0.75
      "bg-success/10 text-success-ink border-success/40"
    elsif score >= Appearances::ReferenceEligibility::FACE_VISIBLE
      "bg-warning/10 text-warning-ink border-warning/40"
    else
      "bg-danger/10 text-danger-ink border-danger/40"
    end
  end

  def rejection_label(photo)
    REJECTION_LABELS.fetch(photo.rejection_reason, "not chosen")
  end

  # The host a photograph came from — "espn.com" — which is most of what a human
  # needs to judge a search hit before opening it. Returns nil rather than a
  # placeholder so the caption collapses instead of printing furniture.
  def reference_photo_host(photo)
    host = URI.parse(photo.origin_url.to_s).host
    host.presence&.delete_prefix("www.")
  rescue URI::InvalidURIError
    nil
  end

  # ── THE SCOUTING PAGE'S OWN CHIPS AND EXPLANATIONS ───────────────────────────
  #
  # Every class below is written out WHOLE for the reason this file's header gives:
  # `config/tailwind.config.js` scans helpers as text, so an assembled class
  # ("bg-#{role}/10") compiles nowhere. And every colour is a THEME ROLE, never a
  # raw palette shade, so the page reads in light mode as well as dark.

  # WHY A PHOTOGRAPH SCORED WHAT IT DID, in the free signals' own terms.
  #
  # THIS IS THE "WHY IT WON" THE OPERATOR ASKED FOR, and it is reconstructible for
  # nothing because Appearances::PhotoMerit is deterministic metadata arithmetic over
  # columns we already hold — no network, no spend, no stored explanation to go stale.
  #
  # ⚠ IT EXPLAINS THE FREE SCORE, WHICH IS NOT ALWAYS THE DECIDING ONE. Where the
  # vision classifier spoke, its face score outranks all of this
  # (GatherReferencePhotos#final_score puts a scored candidate a whole band above an
  # unscored one), so the page prints the face chip as the authority and these as the
  # reasoning underneath it. Saying so is the difference between an explanation and a
  # plausible story.
  def photo_merit_reasons(photo, person_name)
    reasons = []

    # THE ONE REFUSAL NO SCORE ON THIS PAGE CATCHES, so it leads and it returns early:
    # once the answer is "this is somebody else", the photograph's shape and rank are not
    # what the operator is asking about. Measured 2026-09-25: `Drew Hutton.jpg` scored 90
    # for face visibility and ranked SECOND in a Drew Lock identity.
    note = wrong_person_note(photo, person_name)
    return [{ label: note, tone: :bad }] if note

    if Appearances::PhotoMerit.document?(photo)
      # THE ONE HARD EXCLUSION, so it is the only reason worth printing for this row:
      # a scanned page is not a poor reference, it is not a reference. Returning
      # early keeps the tile from also explaining its aspect ratio, which nobody is
      # asking about once the answer is "this is a book".
      return [{ label: "not a photograph — a scan or document", tone: :bad }]
    end

    reasons << if Appearances::PhotoMerit.names_person?(photo, person_name)
      { label: "title names #{person_name}", tone: :good }
    else
      # NOT STYLED AS A FAILURE. A missing or foreign-language title is common and
      # says nothing about the photograph; it only means this signal could not help.
      { label: "title does not name #{person_name}", tone: :neutral }
    end

    reasons << { label: "portrait shape", tone: :good } if Appearances::PhotoMerit.portrait?(photo)
    reasons << { label: "wide crop — a sideline or crowd shot", tone: :bad } if Appearances::PhotoMerit.wide?(photo)
    reasons << { label: "too small to carry a face", tone: :bad } if too_small_for_face?(photo)
    reasons << { label: "found at hit #{photo.position}", tone: :neutral } if photo.position.present?

    reasons
  end

  MERIT_TONES = {
    good: "bg-success/10 text-success-ink border-success/30",
    bad: "bg-danger/10 text-danger-ink border-danger/30",
    neutral: "bg-surface text-muted border-subtle"
  }.freeze

  def merit_reason_classes(tone) = MERIT_TONES.fetch(tone, MERIT_TONES[:neutral])

  # PhotoMerit keeps its own predicate private, so this asks the same question of the
  # same constant rather than hard-coding 300 in a view.
  def too_small_for_face?(photo)
    longest = [photo.width, photo.height].compact.max
    longest.present? && longest < Appearances::PhotoMerit::MIN_USEFUL_EDGE
  end

  # THE OPERATOR-VERSUS-MACHINE CELLS. `:operator_promoted` is the only one styled as
  # a finding rather than as a status, because it is the only one that says the
  # ranking threw away something it should have kept.
  CALIBRATION_CHIPS = {
    agreed_keep: { label: "you agree — in the model",
                   classes: "bg-success/10 text-success-ink border-success/40" },
    agreed_reject: { label: "you agree — leave it out",
                     classes: "bg-surface-alt text-muted border-subtle" },
    machine_overpicked: { label: "you would drop this",
                          classes: "bg-warning/10 text-warning-ink border-warning/40" },
    operator_promoted: { label: "you would PROMOTE this",
                         classes: "bg-primary/10 text-primary border-primary/40" },
    unjudged: { label: "not judged", classes: "bg-surface text-muted border-subtle" }
  }.freeze

  def calibration_chip(photo) = CALIBRATION_CHIPS.fetch(photo.calibration_state, UNKNOWN_CHIP)

  # WHY A PHOTOGRAPH IS NOT OUR PERSON, WITH THE NAME WE READ — or nil.
  #
  # THE EVIDENCE IS THE POINT. "wrong person" is an assertion the operator has to take on
  # faith; "the title names Keenan Allen, not Josh Allen" is a claim he can check against
  # the tile he is looking at, and correct us on when the title is the thing that is wrong.
  #
  # ASKED OF Appearances::PersonNaming, which is the object that refused the photograph —
  # a second reading here could disagree with the verdict on the same tile.
  def wrong_person_note(photo, person_name)
    return nil if person_name.blank?

    verdict = Appearances::PersonNaming.judge(photo.title, person_name)
    return nil unless verdict.names_other?

    name = verdict.other_name.presence || "somebody else"
    "the title names #{name}, not #{person_name}"
  end

  # WHAT IS KNOWN ABOUT WHETHER THIS PHOTOGRAPH CAN BE MINTED — evidence, never a
  # prediction, and nil when nothing is known.
  #
  # "MINTED" HERE MEANS HIGGSFIELD'S TRAINER SPECIFICALLY. The zero-shot sheet has no
  # preparation stage to refuse a reference, so a photograph this chip calls unmintable is
  # still used by the generator the operator actually presses — which is why the wording
  # names the trainer rather than saying "unusable".
  #
  # The wording matters as much as the logic: "failed in all four measured mints" is a fact
  # about four mints, while "will fail" would be a claim about this photograph that nobody
  # has tested.
  def mint_evidence(photo, person_name = nil)
    return MINT_PROVEN_CHIP if photo.mint_proven?

    case photo.mint_verdict(person_name)
    when Appearances::ReferenceEligibility::FACE_UNSCORED
      # THE FREE EVIDENCE STILL BEATS NO EVIDENCE. Nothing looked at this photograph, but
      # three of the four measured failures were wide sideline crops and this one has that
      # shape — a stronger thing to tell the operator than "nobody looked".
      photo.mint_shape_failed_before? ? MINT_WIDE_CHIP : MINT_UNSCORED_CHIP
    when Appearances::ReferenceEligibility::FACE_SIZE_UNMEASURED then MINT_UNMEASURED_CHIP
    when Appearances::ReferenceEligibility::FACE_TOO_SMALL then mint_too_small_chip(photo)
    when Appearances::ReferenceEligibility::ELIGIBLE then mint_ready_chip(photo)
    end
  end

  # NOTHING LOOKED AT IT AT ALL — the state production was silently choosing from on
  # 2026-09-27, and the one with no number anywhere on the tile to disbelieve.
  MINT_UNSCORED_CHIP = {
    label: "nothing looked at this one", tone: :bad,
    title: "No vision classifier judged this photograph, so nothing can say whose face it " \
           "is, whether the face is visible, or how big it is. Measured on production " \
           "2026-09-27: five candidates, three judged, and all five were going into the " \
           "reference set - including a photograph of two men."
  }.freeze

  MINT_WIDE_CHIP = {
    label: "wide crop, unmeasured — this shape failed to mint", tone: :bad,
    title: "Nobody measured this photograph's face size, and three of the four measured " \
           "mints that failed at prepare were wide sideline crops like this one, at 500px " \
           "and at full resolution (2026-09-25)."
  }.freeze

  MINT_PROVEN_CHIP = {
    label: "mints — measured", tone: :good,
    title: "Our mirrored ESPN headshot is a tight face crop and is the only photograph " \
           "that has ever completed a Higgsfield reference (2026-09-25)."
  }.freeze

  # SOMETHING LOOKED AND REPORTED NO SIZE — a thinner answer than we asked for rather than
  # no answer, and it says what that costs rather than only that something is missing.
  MINT_UNMEASURED_CHIP = {
    label: "face size not measured — trainer only", tone: :bad,
    title: "Four of six measured Higgsfield mints failed at prepare and face size in " \
           "frame is the variable they turned on, so a photograph nobody measured is not " \
           "offered to the TRAINER. It is still used by the zero-shot character sheet, " \
           "which has no preparation step to refuse it."
  }.freeze

  def mint_too_small_chip(photo)
    { label: "face fills #{photo.face_fill_percent}% of the frame — too small to train",
      tone: :bad,
      title: "Measured at #{photo.face_fill_percent}% against a floor of " \
             "#{(Appearances::ReferenceEligibility::MINT_FACE_FILL * 100).round}%. The one " \
             "input that has ever completed a reference is a tight face crop; a bare-faced " \
             "556x780 sideline shot at 71% aspect still failed at prepare (2026-09-25)." }
  end

  def mint_ready_chip(photo)
    { label: "face fills #{photo.face_fill_percent}% of the frame", tone: :good,
      title: "Above the #{(Appearances::ReferenceEligibility::MINT_FACE_FILL * 100).round}% " \
             "floor, so this is offered to Higgsfield's trainer as well as to the sheet. " \
             "Nothing here predicts a mint — no photograph at this size has been tried." }
  end

  MINT_TONES = {
    good: "bg-success/10 text-success-ink border-success/40",
    bad: "bg-danger/10 text-danger-ink border-danger/40"
  }.freeze

  def mint_evidence_classes(tone) = MINT_TONES.fetch(tone, MINT_TONES[:bad])

  # THE SHAPE OF THE SEARCH'S FAILURE, as counts per reason.
  #
  # A BREAKDOWN RATHER THAN A SECOND GALLERY. The question it answers — "what KIND of
  # answer did the archive give us?" — is a question about proportions, and on a real
  # Commons answer for "Drew Lock" the proportion IS the finding: 12 of 20 rows were
  # scanned books. Rendering those twelve as twelve more tiles would bury that.
  def rejection_breakdown(photos)
    photos.reject(&:chosen?)
          .group_by { |photo| rejection_label(photo) }
          .transform_values(&:length)
          .sort_by { |_label, count| -count }
  end

  # HOW THE OPERATOR REFERS TO ONE OF THE FOUR SEARCHES — "no helmet", not
  # "Justin Jefferson Minnesota Vikings no helmet".
  #
  # THE SUBJECT IS STRIPPED RATHER THAN THE VARIANT LOOKED UP, and that is deliberate: a
  # lookup against Appearances::GatherReferencePhotos::QUERY_VARIANTS would label a row
  # filed by a variant that has since been REMOVED from the list as if it had no variant
  # at all, and those rows are exactly the ones a reader is trying to account for after
  # re-tuning the list. Stripping reads the row's own stored query, so a retired variant
  # still names itself.
  #
  # `name only` FOR THE BARE SUBJECT, because "" on a page is indistinguishable from a
  # missing value, and this variant is the one the other three are measured against.
  #
  # nil SUBJECT OR A QUERY THAT DOES NOT START WITH IT gives the query back whole. That
  # happens for a row filed against a different team (the subject carries the team, and
  # a traded player's old rows keep the old one), and showing the whole thing is the
  # honest answer — it says the row came from a question we no longer ask.
  def search_variant_label(query, subject:)
    text = query.to_s.strip
    return "an earlier search" if text.empty?

    prefix = subject.to_s.strip
    return text if prefix.empty? || !text.start_with?(prefix)

    text.delete_prefix(prefix).strip.presence || "name only"
  end

  # "1m 30s" / "45s": how long a sheet build ran, or has run so far.
  def sheet_build_duration(seconds)
    return "" if seconds.nil?

    minutes, secs = seconds.divmod(60)
    minutes.positive? ? "#{minutes}m #{secs}s" : "#{secs}s"
  end
end
