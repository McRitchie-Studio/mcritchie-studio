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
end
