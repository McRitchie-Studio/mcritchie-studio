# ONE PHOTOGRAPH WE FOUND OF A PERSON, chosen or rejected.
#
# The row survives the search that produced it so the operator can judge the
# SEARCH rather than only its result: a gallery showing just the winners cannot
# distinguish "the search found four good portraits and we took them all" from
# "the search found four stock logos and we took them for want of anything
# better". Both halves are on the page because both halves are the evidence.
class AppearanceReferencePhoto < ApplicationRecord
  belongs_to :appearance, foreign_key: :appearance_slug, primary_key: :slug,
                          inverse_of: :reference_photos, optional: true

  # OUR OWN COPY OF THE BYTES, when we made one. Same shape Athlete and Coach use for
  # their headshots, which is what lets Appearances::MirrorCandidates hand ImageCache
  # a per-photograph owner and satisfy its variant-unique-per-(owner, purpose)
  # constraint by construction rather than by working around it.
  #
  # NOT `dependent: :destroy`, matching Athlete and Coach. Destroying the row would
  # leave the S3 object behind either way (nothing here deletes from the bucket), so a
  # cascade would only make the DB forget where the object is — which is worse than a
  # row pointing at a photograph we no longer file.
  has_many :image_caches, as: :owner, class_name: "ImageCache", inverse_of: :owner,
                          dependent: nil

  # WHO FOUND THE PHOTOGRAPH, in descending order of how far we trust it.
  #
  #   headshot — our own mirrored copy of the ESPN portrait. The only URL whose
  #              public reachability we control and have measured.
  #   operator — typed into the look form by a human who looked at it.
  #   search   — an image-search provider's answer. Nobody has seen it.
  #
  # The gallery prints this beside every photograph, because "the search found
  # this" and "you chose this" deserve different confidence from a reviewer.
  SOURCE_HEADSHOT = "headshot".freeze
  SOURCE_OPERATOR = "operator".freeze
  SOURCE_SEARCH = "search".freeze
  SOURCES = [SOURCE_HEADSHOT, SOURCE_OPERATOR, SOURCE_SEARCH].freeze

  # WHY A CANDIDATE WAS PASSED OVER. Enumerated rather than free text so the
  # gallery can style them and so a new reason has to be declared here, where
  # the reader of a reject list will find it.
  #
  #   unfetchable   — failed the SSRF/reachability guard. Never sent anywhere.
  #   duplicate     — the same photograph reached us at two different URLs.
  #                   ⚠ NOTHING IN THE APP STAMPS THIS YET, and that is a stated
  #                   gap rather than an oversight. The unique index is on
  #                   (appearance_slug, image_url), so the same image served from
  #                   two URLs is two rows and can occupy two slots in one
  #                   identity — a real case (Wikimedia serves every file from both
  #                   `upload.wikimedia.org/.../500px-X` and
  #                   `commons.wikimedia.org/wiki/Special:FilePath/X`). Catching it
  #                   needs a perceptual hash of the BYTES, which means fetching
  #                   them, which this lane deliberately never does. The value is
  #                   declared so the gallery can render the state and so the fix
  #                   has somewhere to land.
  #   face_obscured — something LOOKED at it and found no usable face (a helmet,
  #                   the back of a head, a document scan). Stamped only when
  #                   Appearances::FaceVisibility actually ran on this photograph:
  #                   a candidate nobody classified is `beyond_limit`, because a
  #                   reason the operator reads as a judgement must not be a guess.
  #   not_a_photo   — not a photograph of a person at all: a scanned book page, a
  #                   media-guide PDF, a diagram. NEVER chosen at any supply level,
  #                   which is what separates it from `face_obscured`: a helmeted
  #                   shot of the right person is a poor reference, a scan of an
  #                   1896 edition of The Rape of the Lock is not a reference at
  #                   all. Both were real hits for "Drew Lock" (measured 2026-09-26:
  #                   12 of 20 Wikimedia Commons results were scanned documents).
  #   wrong_person  — the title names SOMEBODY ELSE. Measured 2026-09-25: a search
  #                   for "Drew Lock" returned `Drew Hutton.jpg`, whose face scored
  #                   90 and ranked SECOND in the identity. A photograph of a
  #                   stranger is not a poor reference either — an identity trained
  #                   on two men is a blended third man. See
  #                   Appearances::PersonNaming for what a title check can and
  #                   cannot catch.
  #   mixed_subjects— the classifier counted more than one visible face, so nothing
  #                   in the picture can be attributed to our person alone.
  #   face_unscored — NOTHING LOOKED AT THIS PHOTOGRAPH. Measured on production
  #                   2026-09-27 (`jaylen-waddle`): five candidates returned, three
  #                   scored, all five chosen — and one of the two unjudged ones was
  #                   titled "...Jaylen Waddle and L'Jarius Sneed", a correctly titled
  #                   photograph of TWO men. An unjudged candidate cannot be shown to
  #                   hold one person's face, so it is no longer chosen. Distinct from
  #                   `face_size_unmeasured`: that one was examined and the answer was
  #                   missing a field, this one was never examined.
  #   face_too_small— something MEASURED how much of the frame the head fills and it
  #                   is below Appearances::ReferenceEligibility::SHEET_FACE_FILL (the
  #                   trainer's stricter MINT_FACE_FILL is applied at spend time). This is
  #                   the variable four real mints turned on (2026-09-25).
  #   face_size_unmeasured — nobody measured the face size, so there is no evidence
  #                   this photograph survives Higgsfield's prepare step. The only
  #                   reason here that judges US rather than the photograph, and NOTHING
  #                   STAMPS IT ON A ROW: it is a verdict the MINT list applies at spend
  #                   time (Appearances::ReferenceSet#call), never a reason a photograph
  #                   was left out of the reference set. Declared so the helper can label
  #                   it where it is shown.
  #   beyond_limit  — good enough, but past the number we build an identity from.
  REJECTED_UNFETCHABLE = "unfetchable".freeze
  REJECTED_DUPLICATE = "duplicate".freeze
  REJECTED_FACE_OBSCURED = "face_obscured".freeze
  REJECTED_NOT_A_PHOTO = "not_a_photo".freeze
  REJECTED_WRONG_PERSON = "wrong_person".freeze
  REJECTED_MIXED_SUBJECTS = "mixed_subjects".freeze
  REJECTED_FACE_UNSCORED = "face_unscored".freeze
  REJECTED_FACE_TOO_SMALL = "face_too_small".freeze
  REJECTED_FACE_SIZE_UNMEASURED = "face_size_unmeasured".freeze
  REJECTED_BEYOND_LIMIT = "beyond_limit".freeze
  REJECTION_REASONS = [REJECTED_UNFETCHABLE, REJECTED_DUPLICATE, REJECTED_FACE_OBSCURED,
                       REJECTED_NOT_A_PHOTO, REJECTED_WRONG_PERSON, REJECTED_MIXED_SUBJECTS,
                       REJECTED_FACE_UNSCORED, REJECTED_FACE_TOO_SMALL,
                       REJECTED_FACE_SIZE_UNMEASURED, REJECTED_BEYOND_LIMIT].freeze

  # THE OPERATOR'S OWN VERDICT — the calibration half of the scouting page.
  #
  # TWO VALUES EXPRESS FOUR OUTCOMES, and that is why there is no `promote` value.
  # The verdict is read AGAINST `chosen`, so the interesting cell — "the machine
  # rejected this and I would have used it" — is already `keep` on an unchosen row.
  # A third value would encode the same fact twice and let the two disagree.
  #
  #   keep — I would put this photograph in the model.
  #   drop — I would leave it out.
  #   nil  — I have not judged it. NOT the same as `drop`; see #calibration_state.
  VERDICT_KEEP = "keep".freeze
  VERDICT_DROP = "drop".freeze
  VERDICTS = [VERDICT_KEEP, VERDICT_DROP].freeze

  # WHAT THE UNIQUE INDEX CAN PHYSICALLY HOLD, and the reason it is a validation
  # rather than a column limit.
  #
  # `index_reference_photos_unique_per_look` is a btree over (appearance_slug,
  # image_url). Postgres refuses a btree entry larger than about 2,704 bytes AT
  # INSERT TIME — not at migrate time — so without a cap here, one freakishly
  # long search hit would raise from inside the search action and lose the whole
  # batch. 2,048 is comfortably under the limit and comfortably over any real
  # image URL; a candidate longer than this is a data-URI or a tracking blob
  # rather than a photograph, so dropping it costs nothing.
  MAX_URL_LENGTH = 2_048

  validates :slug, presence: true, uniqueness: true
  validates :image_url, presence: true, length: { maximum: MAX_URL_LENGTH }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :appearance_slug, presence: true
  validates :rejection_reason, inclusion: { in: REJECTION_REASONS }, allow_blank: true
  validates :operator_verdict, inclusion: { in: VERDICTS }, allow_blank: true

  before_validation :generate_slug, on: :create

  scope :chosen, -> { where(chosen: true) }
  scope :rejected, -> { where(chosen: false) }
  scope :judged, -> { where.not(operator_verdict: nil) }

  # THE ORDER THE SEARCH RETURNED THEM IN — the raw column's ordering, and
  # deliberately NOT `gallery_order`.
  #
  # These two scopes answer different questions and the calibration page asks both.
  # `gallery_order` is OUR ranking, which is the thing under examination; this is
  # the provider's own, which is the evidence you examine it against. Showing only
  # the ranked order would make a bad search and a bad ranker look identical — the
  # operator could not tell "the archive handed us twelve books" from "we sorted
  # twelve books to the top".
  #
  # NULLS LAST, because the two floor rows (our headshot, the operator's URL) have
  # no provider rank and Postgres sorts NULL first in ascending order — so without
  # this the unranked rows would lead a column whose entire point is the rank.
  scope :found_order, -> {
    order(Arel.sql("position ASC NULLS LAST, created_at ASC, id ASC"))
  }

  # GALLERY ORDER — OUR ranking, not the provider's.
  #
  # Chosen photographs lead, because the first question the page answers is "what
  # did the identity get built from".
  #
  # Within each half, FACE SIZE leads, then face VISIBILITY, and the provider's
  # `position` only breaks ties. Size leads because size is the variable four real
  # mints turned on (2026-09-25: a bare-faced 556x780 sideline shot failed at prepare,
  # a tight ESPN headshot completed) — ordering on visibility alone put a photograph
  # that cannot mint at the top of the page with a confident 92 beside it.
  #
  # THE SORT AND Appearances::GatherReferencePhotos#final_score HAVE TO AGREE, because
  # one of them chose the photographs and the other one shows them: a gallery ordered
  # differently from the ranking reads as a ranking bug that is not there.
  #
  # That order is the whole point of the ranking step: the provider ranks by
  # its own idea of relevance, which says nothing about whether you can see the
  # person's face — and on the operator's own labelled example the provider's hit 1
  # was the only bare-faced photograph in a set of four while hits 2 and 3 were
  # helmets. Sorting by `position` would put the gallery back in the order the
  # ranking exists to correct, and the operator would see no change.
  #
  # NULLS LAST ON BOTH KEYS, for two different absences: an unscored row (nobody
  # looked) and an unranked one (the headshot and the operator's URL have no
  # provider rank). Postgres sorts NULL HIGH in ascending order and FIRST in
  # descending, so without this an unscored row would lead the gallery.
  scope :gallery_order, -> {
    order(Arel.sql("chosen DESC, face_fill DESC NULLS LAST, face_score DESC NULLS LAST, " \
                   "position ASC NULLS LAST, created_at ASC, id ASC"))
  }

  def to_param = slug

  # The photograph's own page, when the provider named one. Worth its own reader
  # because the gallery links the thumbnail to it: judging a search hit usually
  # means looking at where it came from, not only at the crop.
  #
  # READS THE LINKABLE FORM, not the raw column, so the caption's host and the
  # caption's link can never disagree about which URL they describe.
  def origin_url = page_link_url.presence || image_url

  # ONLY THE SCHEMES A BROWSER MAY BE HANDED. nil for anything else.
  LINKABLE_SCHEMES = %w[http https].freeze

  # `page_url` AS SOMETHING SAFE TO PUT IN AN href, or nil.
  #
  # The column holds whatever a third-party search engine put in its answer, stored
  # unvalidated ON PURPOSE: the row is evidence of what the search offered, and a
  # refused value is part of that evidence. `image_url` is separately cleared by
  # Appearances::FetchableUrl before anything is sent anywhere; `page_url` is never
  # sent anywhere, so it was never cleared — and that is exactly why it must be
  # judged here, at the one place it reaches a browser.
  #
  # TWO REAL SHAPES THIS REFUSES, and neither is hypothetical:
  #
  #   javascript://host/%0aalert(1)  parses with a host, so a host-presence check
  #                                  alone passes it straight into an href.
  #   espn.com                       a BARE DOMAIN, which the Serper parser emits
  #                                  when a row carries `source` and no `link`
  #                                  (see that parser's own note). As an href it is
  #                                  RELATIVE, so today it navigates the operator
  #                                  to /people/:person/models/espn.com on our own
  #                                  site rather than to the page they clicked for.
  def page_link_url
    return nil if page_url.blank?
    return nil unless LINKABLE_SCHEMES.include?(URI.parse(page_url).scheme&.downcase)

    page_url
  rescue URI::InvalidURIError
    nil
  end

  def from_search? = source == SOURCE_SEARCH

  # WHAT THE BROWSER SHOULD RENDER, which is NOT what the vendor should fetch.
  #
  # The scouting page paints twenty-odd tiles at once and Commons originals run 1-3 MB
  # each; MEASURED 2026-09-26, the third original onward answered **HTTP 429** and a
  # third of the gallery rendered as grey alt-text. `thumb_url` is the archive's own
  # small rendition of the same file.
  #
  # FALLS BACK TO THE ORIGINAL rather than rendering nothing: Serper reports no
  # thumbnail, Commons declines to make one for some formats, and every row filed before
  # this column existed has none. A tile with no picture is worse than a heavy one.
  def display_url = thumb_url.presence || image_url

  # WHAT A REMOTE FETCHER SHOULD BE HANDED — our mirrored copy, or nil.
  #
  # DISTINCT FROM `display_url` AND FROM `image_url`, and the three are not
  # interchangeable: `display_url` is for the operator's browser (small, the archive's
  # own rendition), `image_url` is the EVIDENCE of what the search offered, and this is
  # the only one of the three that a third party's server can be relied on to fetch.
  #
  # WHY IT CAN BE nil, and why the caller must not fall back to `image_url` when it is.
  # A mirror is attempted for the classifier shortlist only
  # (Appearances::GatherReferencePhotos::VISION_SHORTLIST) and can fail per photograph,
  # so most rows have none. Falling back to the remote URL is precisely the bug
  # Appearances::MirrorCandidates exists to fix: on 2026-09-26 Wikimedia answered 403
  # to Anthropic's fetcher (no User-Agent) and a silently unscored set put three
  # aircraft into a character model.
  def hosted_url
    image_caches.detect { |cache| cache.purpose == Appearances::MirrorCandidates::PURPOSE }&.url
  end

  # Did we manage to take our own copy of this photograph? The honest question behind
  # `hosted_url.present?`, worth its own name because "we have no copy" and "we have a
  # copy at no URL" would otherwise read the same.
  def mirrored? = hosted_url.present?

  def judged? = operator_verdict.present?
  def operator_keep? = operator_verdict == VERDICT_KEEP
  def operator_drop? = operator_verdict == VERDICT_DROP

  # WHERE THIS PHOTOGRAPH SITS IN THE FOUR-CELL AGREEMENT between the machine's
  # pick and the operator's, plus the fifth state of not having been judged.
  #
  #   :agreed_keep        both would use it.
  #   :agreed_reject      both would leave it out.
  #   :machine_overpicked we put it in the model; the operator would not have.
  #   :operator_promoted  we rejected it; the operator would have used it.
  #   :unjudged           no verdict recorded.
  #
  # `:operator_promoted` IS THE VALUABLE ONE and the reason this method is not just
  # a boolean `agrees?`. The other three cells tell us how well the ranking scores
  # the candidates it was already going to rank; a promotion says the ranking threw
  # away something it should have kept, which is the only cell that can teach it
  # something it does not already believe.
  #
  # `:unjudged` IS ITS OWN STATE rather than folded into a disagreement. Reading an
  # absent opinion as either agreement or disagreement would let a page the operator
  # has barely touched report a confident score.
  def calibration_state
    return :unjudged unless judged?

    if chosen?
      operator_keep? ? :agreed_keep : :machine_overpicked
    else
      operator_keep? ? :operator_promoted : :agreed_reject
    end
  end

  # ── MINT EVIDENCE ─────────────────────────────────────────────────────────────
  #
  # WHAT IS REPORTED HERE IS MEASUREMENT, NOT PREDICTION, and the distinction is the
  # whole reason these two readers are separate and narrow.
  #
  # Four real mints against https://api.higgsfield.ai/v1/custom-references on
  # 2026-09-25 (recorded on task `reference-photos-wrong-person`):
  #
  #   3 Commons sideline/action shots at 500px  → failed at prepare
  #   the SAME 3 at full resolution             → failed
  #   1 bare-faced sideline shot, full res      → failed
  #   1 ESPN headshot (tight face crop)         → COMPLETED in ~2 min
  #
  # So resolution is not the variable and the helmet is not the variable; face size
  # in frame is. FACE SIZE IS NOW MEASURED WHERE A CLASSIFIER RAN — `face_fill` is
  # Appearances::FaceVisibility's own answer to "how much of the frame does the head
  # fill", asked as its own number precisely because `face_score` could not be read
  # back for it ("small in frame" and "partly turned" both scored 0.6 on the old
  # prompt). Where no classifier ran the column is NULL and that is reported as an
  # absence of evidence, never as a small face.
  #
  # NOTHING HERE PREDICTS A MINT. It reports what is known and what is not, and
  # Appearances::ReferenceEligibility turns that into a verdict the page can print.
  #
  # THE ONE INPUT MEASURED TO MINT. Our own mirrored ESPN headshot is a tight face
  # crop and is the only photograph that has ever completed a reference.
  def mint_proven? = source == SOURCE_HEADSHOT

  # THE SHAPE THAT FAILED EVERY TIME IT WAS TRIED. A wide crop is a sideline or
  # crowd photograph, which is the shape three of the four failures shared. Judged with
  # PhotoMerit's own ratio so the page and the ranker cannot disagree about what
  # "wide" means; false when the provider reported no dimensions, because an unknown
  # shape is not a wide one.
  #
  # ⚠ IT IS NOT THE MINT TEST, and reading it as one is the trap this comment exists to
  # close: the FOURTH failure was 556x780, aspect 0.71 — portrait-shaped, the same
  # shape as the headshot that minted. So a photograph that is not wide has NOT been
  # shown to be mintable. `mint_verdict` is the test; this is one piece of evidence.
  def mint_shape_failed_before? = !mint_proven? && Appearances::PhotoMerit.wide?(self)

  # Was this photograph actually LOOKED AT by the classifier? Distinct from
  # `face_score.zero?`, which means "looked at and saw nothing" — the opposite
  # judgement from "never looked", and the page prints them differently.
  def face_scored? = face_score.present?

  # 0.0..1.0 as a percentage for the chip, or nil when nobody looked.
  def face_score_percent = face_scored? ? (face_score * 100).round : nil

  # Did anybody MEASURE the face size? The question `face_scored?` does not answer:
  # every row scored before the classifier was asked for a size has a visibility and
  # no fill, and those rows are exactly the ones the mint must refuse.
  def face_sized? = face_fill.present?

  def face_fill_percent = face_sized? ? (face_fill * 100).round : nil

  # MAY THIS PHOTOGRAPH BE A REFERENCE, AND MAY IT BE PAID TO A TRAINER — two
  # questions, two readers, one rule (Appearances::ReferenceEligibility).
  #
  # THE FLOOR IS EXEMPT FROM BOTH AND ONLY THE FLOOR IS. Our mirrored headshot is the one
  # input measured to complete a Higgsfield reference, and the operator's own URL is one
  # a human chose deliberately; neither came from a search and neither is the defect
  # this gate was built for. Every SEARCH hit has to earn its place.
  #
  # `person_name` IS PASSED IN RATHER THAN WALKED TO. The row can reach the person
  # through `appearance.person`, but that is two queries per tile on a page that
  # renders twenty of them, and the caller already holds the name.
  def reference_verdict(person_name)
    return Appearances::ReferenceEligibility::ELIGIBLE unless from_search?

    Appearances::ReferenceEligibility.verdict(self, **measurements(person_name))
  end

  # THE STRICTER ONE — the zero-shot sheet reads the first, Higgsfield's trainer reads
  # this. The difference is a measured face size, and the reason is that four of six
  # measured mints failed at prepare while the sheet path has no stage that can refuse.
  def mint_verdict(person_name)
    return Appearances::ReferenceEligibility::ELIGIBLE unless from_search?

    Appearances::ReferenceEligibility.mint_verdict(self, **measurements(person_name))
  end

  def reference_eligible?(person_name)
    reference_verdict(person_name) == Appearances::ReferenceEligibility::ELIGIBLE
  end

  def mint_eligible?(person_name)
    mint_verdict(person_name) == Appearances::ReferenceEligibility::ELIGIBLE
  end

  private

  # WHAT THIS ROW KNOWS, in the shape the rule asks for. Built once so the two verdicts
  # provably ask about the same photograph — passing three columns positionally in two
  # places is how one of them ends up reading `face_fill` into `subjects`.
  def measurements(person_name)
    { person_name: person_name, visibility: face_score, fill: face_fill,
      subjects: face_subjects }
  end

  def generate_slug
    self.slug ||= "refphoto-#{SecureRandom.hex(6)}"
  end
end
