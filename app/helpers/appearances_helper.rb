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
    AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT => "past the limit of #{Appearances::GatherReferencePhotos::CHOSEN_LIMIT}"
  }.freeze

  # THE FACE SCORE'S OWN CHIP, banded rather than continuous: the operator is
  # asking "can you see his face in this one?", which is a three-way answer, and a
  # gradient across 100 values would make two adjacent photographs look different
  # when the judgement is the same.
  #
  # The bands are named against GatherReferencePhotos::FACE_VISIBLE_THRESHOLD so
  # the colour and the `face not visible` rejection chip can never disagree: a
  # photograph styled as a failure here is exactly one that would be labelled
  # obscured if it lost.
  def face_score_chip(photo)
    score = photo.face_score.to_f
    if score >= 0.75
      "bg-success/10 text-success-ink border-success/40"
    elsif score >= Appearances::GatherReferencePhotos::FACE_VISIBLE_THRESHOLD
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

  # WHAT IS KNOWN ABOUT WHETHER THIS PHOTOGRAPH CAN BE MINTED — evidence, never a
  # prediction, and nil when nothing is known.
  #
  # The measurements behind both branches are on AppearanceReferencePhoto's own
  # readers. The wording matters as much as the logic: "failed in all four measured
  # mints" is a fact about four mints, while "will fail" would be a claim about this
  # photograph that nobody has tested. Face size in frame is the variable, and face
  # size is exactly what we cannot measure without a vision key.
  def mint_evidence(photo)
    if photo.mint_proven?
      { label: "mints — measured", tone: :good,
        title: "Our mirrored ESPN headshot is a tight face crop and is the only " \
               "photograph that has ever completed a Higgsfield reference (2026-09-25)." }
    elsif photo.mint_shape_failed_before?
      { label: "wide crop — this shape failed to mint", tone: :bad,
        title: "All four measured mints of wide sideline/action shots failed at " \
               "prepare, at 500px and at full resolution (2026-09-25). Face size in " \
               "frame is the variable, and we cannot measure it without a vision key." }
    end
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
end
