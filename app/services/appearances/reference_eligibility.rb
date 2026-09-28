module Appearances
  # MAY THIS PHOTOGRAPH BE USED AS A REFERENCE, AND MAY IT BE PAID TO A TRAINER? —
  # two questions, one rule, four callers.
  #
  # THE TWO QUESTIONS ARE NOT THE SAME QUESTION, and conflating them was a real design
  # error caught before it shipped. There are two generators:
  #
  #   ZERO-SHOT (Appearances::GenerateArtifact -> ImageGeneration::OpenAI). Reads the
  #   references AT GENERATION TIME. There is no preparation stage, so there is no
  #   stage that can refuse: a poor reference costs a poorer sheet, never a failed
  #   purchase. The operator asked for exactly this on 2026-09-27 — "it would be better
  #   if we provided a few headshots ... more context on facial structure and
  #   expressions" — so this path wants as many good photographs as we can vet.
  #
  #   TRAINED (Appearances::CreateCharacterReference -> Higgsfield). PREPARES the set
  #   before training, and that stage refuses: four of the measured mints failed at
  #   prepare. A photograph whose face size nobody measured is a coin-flip on a paid
  #   call, so this path demands positive evidence.
  #
  # `.verdict` answers the first. `.mint_verdict` answers the second — the same rule
  # plus one more demand. A single answer for both would either starve the sheet (the
  # operator's own request) or gamble the trainer's money.
  #
  # THE MEASUREMENT IT ENCODES. Four real mints against
  # https://api.higgsfield.ai/v1/custom-references on 2026-09-25 (recorded on task
  # `reference-photos-wrong-person`):
  #
  #   3 Commons sideline/action shots, 500px thumbs  -> failed at prepare
  #   the SAME 3 at full resolution                  -> failed
  #   1 BARE-FACED sideline shot, full resolution    -> failed
  #   1 ESPN headshot (tight face crop)              -> COMPLETED in ~2 min
  #
  # `fail_reason` was always "We couldn't prepare your photos for training. Please try
  # again." It reads transient and is not: the same input fails identically every time.
  # Resolution is not the variable and the helmet is not the variable — FACE SIZE IN
  # FRAME is.
  #
  # WHY A GUESS IS NOT AVAILABLE HERE. The failing bare-faced shot was 556x780,
  # aspect 0.71 — PORTRAIT-shaped, exactly like the headshot that minted. So no
  # metadata signal we hold separates a mintable photograph from an unmintable one,
  # and this object refuses to pretend otherwise: a candidate NOBODY MEASURED is
  # refused (`:face_size_unmeasured`) rather than waved through. That is the whole
  # judgement call in this file, and the reasoning is:
  #
  #   · the cached ESPN headshot is proven to mint, so refusing every search hit
  #     costs the operator PHOTOGRAPHS IN AN IDENTITY, never the identity itself;
  #   · minting an unmeasured set costs real money for a `failed` reference and
  #     leaves the look with no identity at all;
  #   · a blend or a paid failure is worse than a thin set. Refusing is the cheap
  #     mistake.
  #
  # ⚠ WHAT IT STILL CANNOT CATCH. A photograph whose face is big enough and visible
  # enough to pass here may still fail at prepare for a reason nobody has measured —
  # nothing here predicts a mint, it only refuses the shapes we have evidence against.
  # And the person check reads a TITLE (see Appearances::PersonNaming for the three
  # shapes that defeats).
  #
  # FOUR CALLERS, ONE OPINION, and that is why the rule lives here rather than in
  # any of them:
  #
  #   Appearances::GatherReferencePhotos — at file time, to decide `chosen` and to
  #     stamp the reason. `chosen` therefore means "in the reference set".
  #   Appearances::ReferenceSet — again over the PERSISTED rows, once per consumer.
  #     Rows outlive the rule that judged them: every row filed before this object
  #     existed was chosen by a ranking that never asked whose face it was, and neither
  #     generator should honour a verdict nobody would give today.
  #   Appearances::GenerateArtifact — through ReferenceSet, for the zero-shot sheet.
  #   AppearancesHelper — to explain the verdict on the tile.
  class ReferenceEligibility
    # THE ONE PASSING VERDICT.
    ELIGIBLE = :eligible

    # THE REFUSALS, IN THE ORDER THEY ARE TESTED. Each one is also the
    # `rejection_reason` the row is stamped with, so the enum on
    # AppearanceReferencePhoto and this list are the same vocabulary rather than two
    # that have to be mapped — a mapping is where a new reason gets forgotten.
    NOT_A_PHOTO = :not_a_photo
    WRONG_PERSON = :wrong_person
    MIXED_SUBJECTS = :mixed_subjects
    FACE_OBSCURED = :face_obscured
    FACE_UNSCORED = :face_unscored
    FACE_TOO_SMALL = :face_too_small
    FACE_SIZE_UNMEASURED = :face_size_unmeasured

    REFUSALS = [NOT_A_PHOTO, WRONG_PERSON, MIXED_SUBJECTS, FACE_OBSCURED, FACE_UNSCORED,
                FACE_TOO_SMALL, FACE_SIZE_UNMEASURED].freeze

    # BELOW THIS THE HEAD IS TOO SMALL IN FRAME TO MINT.
    #
    # THE NUMBER IS A JUDGEMENT AND THE BRACKET AROUND IT IS MEASURED. On
    # Appearances::FaceVisibility's published scale the proven ESPN headshot is a tight
    # crop (~0.9-1.0) and every failing sideline shot is distant (~0.1-0.3). Nothing
    # has ever been minted BETWEEN those two anchors, so this threshold sits at the
    # highest anchor below the proven input — "head and shoulders, the head about a
    # third of the frame" — and deliberately leaves the unmeasured middle on the
    # refusing side. A mint costs money and a refusal costs a photograph.
    #
    # LOWER IT WITH A MEASUREMENT, not with an opinion: mint one reference from a
    # single candidate that scored just under this, and record what prepare said.
    MINT_FACE_FILL = 0.6

    # THE FREE SHEET'S FLOOR, lower because a zero-shot sheet has no prepare step to refuse.
    # Above the prompt's 0.3 "upper body" anchor, so distant shots stay out; production
    # (Justin Jefferson, 2026-09-28) refused a clear 0.5-fill portrait at 0.6.
    SHEET_FACE_FILL = 0.4

    # BELOW THIS THE CLASSIFIER SAW NO USABLE FACE — a helmet, the back of a head, a
    # face lost in shadow.
    #
    # ⚠ THIS NOW EXCLUDES, AND IT USED ONLY TO LABEL. GatherReferencePhotos kept a
    # helmeted photograph with the argument that "a threshold that excluded would
    # starve a person of whom no clear photograph exists". The mint measurement
    # retired that argument: the three-photograph set that failed at prepare was
    # helmets, and a photograph with no visible face cannot contribute a face to a
    # face identity. Nobody is starved, because Appearances::ReferenceImages still
    # puts the proven headshot at the head of every set.
    FACE_VISIBLE = 0.5

    # BELOW THIS THERE IS NO PERSON IN THE PICTURE AT ALL — a document scan, a logo,
    # an empty stadium. The 0.15/0.0 split in FaceVisibility's prompt is written to
    # make exactly this distinction: 0.15 is "your man, face hidden", 0.0 is "this is
    # not a photograph of anybody".
    NO_PERSON = 0.1

    # MORE THAN ONE FACE CANNOT BE ATTRIBUTED TO ONE PERSON. A two-player photograph
    # scores beautifully on visibility and teaches the model a blend of two faces,
    # which is the same failure as the wrong-person photograph by a different route.
    MAX_SUBJECTS = 1

    # MAY THIS BE A REFERENCE AT ALL — the question both generators ask.
    #
    # ⚠ SOMETHING HAS TO HAVE LOOKED. This is the ONE absence this question refuses on, and
    # it came from production evidence rather than from reasoning. Measured on production
    # 2026-09-27, `jaylen-waddle`: five candidates returned, three scored, and ALL FIVE
    # chosen — including two the classifier never judged at all. One of those two is titled
    # "2024 Dolphins vs Titans Jaylen Waddle and L'Jarius Sneed", a correctly titled
    # photograph of TWO men, and it entered the reference set with no number on its tile
    # for an operator to disbelieve.
    #
    # A PHOTOGRAPH NOTHING LOOKED AT CANNOT BE SHOWN TO HOLD ONE PERSON'S FACE, and
    # "never mint an identity from mixed subjects" is an acceptance criterion rather than a
    # preference. So an unjudged candidate is refused as FACE_UNSCORED — NOT the same
    # refusal as FACE_SIZE_UNMEASURED: this one says nothing examined the photograph at
    # all, that one says the examination did not report one field.
    #
    # THE COST IS BOUNDED AND KNOWN. With no vision credential nothing scouted is chosen
    # and the zero-shot sheet falls back on the cached headshot — which is exactly what
    # that generator used before this task wired it to the set, so no path gets WORSE.
    # With a credential, most candidates are judged and the operator gets the several
    # references he asked for.
    #
    # EVERY OTHER REFUSAL IS A REFUSAL ON EVIDENCE: a document, a stranger, a crowd, a
    # hidden face, a face MEASURED to be too small.
    #
    # `candidate` is anything that answers `image_url`, `page_url` and `title` — an
    # Appearances::ImageSearch::Result at file time and an AppearanceReferencePhoto
    # afterwards. Duck-typed rather than branched, so the callers provably ask the same
    # question.
    #
    # The three measurements are passed as plain scalars rather than as a judgement
    # object, because one caller has them in a Hash the classifier just answered and
    # the other reads them off columns, and neither should have to build the other's
    # shape to ask.
    def self.verdict(candidate, person_name:, visibility: nil, fill: nil, subjects: nil)
      return NOT_A_PHOTO if PhotoMerit.document?(candidate)
      return NOT_A_PHOTO if visibility.present? && visibility < NO_PERSON
      return WRONG_PERSON if PersonNaming.judge(candidate.title, person_name).names_other?
      return MIXED_SUBJECTS if subjects.present? && subjects > MAX_SUBJECTS
      return FACE_OBSCURED if visibility.present? && visibility < FACE_VISIBLE
      # ORDERED AFTER THE EVIDENCE-BASED REFUSALS ON PURPOSE. A document or a stranger is
      # refused for WHAT IT IS even when nothing classified it, and those are findings about
      # the photograph; "nobody looked" is a weaker and less useful thing to print on a tile
      # that is provably a scanned book.
      return FACE_UNSCORED if visibility.blank?
      return FACE_TOO_SMALL if fill.present? && fill < SHEET_FACE_FILL

      ELIGIBLE
    end

    # MAY THIS BE PAID TO HIGGSFIELD'S TRAINER — everything above, plus a MEASURED face
    # size at or above MINT_FACE_FILL.
    #
    # THE ONE PLACE AN ABSENCE IS A REFUSAL, and the reasoning is the cost asymmetry
    # rather than a belief about the photograph:
    #
    #   · the cached ESPN headshot is proven to mint, so refusing a search hit costs the
    #     operator PHOTOGRAPHS IN A TRAINING SET, never the identity itself;
    #   · an unmeasured set costs real money for a `failed` reference and leaves the look
    #     with no identity at all;
    #   · a photograph the trainer refuses here still reaches the zero-shot sheet
    #     through `.verdict`, whose floor is SHEET_FACE_FILL.
    def self.mint_verdict(candidate, person_name:, visibility: nil, fill: nil, subjects: nil)
      verdict = verdict(candidate, person_name: person_name, visibility: visibility,
                                   fill: fill, subjects: subjects)
      return verdict unless verdict == ELIGIBLE
      return FACE_SIZE_UNMEASURED if fill.blank?
      return FACE_TOO_SMALL if fill < MINT_FACE_FILL

      ELIGIBLE
    end

    # ⚠ NO `eligible?` / `mint_eligible?` PREDICATE LIVES HERE, deliberately. The verdict
    # SYMBOL is the thing every caller needs — Appearances::GatherReferencePhotos stamps it
    # as the rejection reason and AppearancesHelper prints it — so a boolean wrapper would
    # be a second, lossier way to ask the same question, and the reason for a refusal is
    # exactly what this lane keeps losing. AppearanceReferencePhoto carries the booleans
    # because a ROW is the thing callers hold.
  end
end
