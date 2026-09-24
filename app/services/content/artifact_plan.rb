class Content
  # What the inspection gate shows: the artifact slots a rapper-replace video
  # needs, each with a DECISION about whether we already have it.
  #
  # The decision is the whole value of the screen. Generating every image from
  # scratch each week would be the obvious thing and the wrong one — a person's
  # face does not change, only what they are wearing does. So each slot answers:
  # reuse it, re-skin it, or make it.
  class ArtifactPlan
    # A cell in the gate, and the TWO ARTIFACTS it can hold. They are named for
    # what they ARE, not for what any one reader wants from them:
    #
    #   `occupant` — THE ROW FILED IN THIS CELL: the live artifact already
    #   carrying this slot's exact reuse key. What the card renders, what
    #   #ready? counts, what the gate approves, and what the next attach
    #   retires.
    #   `artifact` — THE RECOLOR SOURCE: on a :reskin, the OTHER-colorway asset
    #   we would recolor FROM. It belongs to a different game and must stay
    #   live. On a :reuse the two are the same row; on a :reskin they routinely
    #   are not, and a mixed cast keeps them apart indefinitely.
    #
    # EVERY DEFECT THIS CLASS HAS HAD WAS A CONSUMER READING THE OTHER ONE.
    # First the retire was gated on `#reuse?`, so tightening what the LOOKUP
    # matched silently changed what the mutation DESTROYED and Replace filed a
    # second artifact under the same key. Then the submit label was gated on the
    # same predicate and inverted from the other side. Then the card, #ready?
    # and #approve_artifacts were found reading `artifact` — the recolor source
    # — as though it were the row on file, so a freshly attached image was
    # invisible and approval landed on the other colorway's artifact.
    #
    # THE RULE THE THREE SHARE: gate a mutation, a picture or a sign-off on the
    # row it actually acts on, never on a predicate that merely correlates with
    # it. `decision` is a LABEL and may gate nothing but words.
    Slot = Struct.new(:kind, :label, :subjects, :decision, :artifact, :occupant, keyword_init: true) do
      def reuse?    = decision == :reuse
      def reskin?   = decision == :reskin
      def generate? = decision == :generate

      # IS ANYTHING FILED FOR THIS CELL? The gate's one question, and the only
      # thing that may unlock approval. Asking it of `artifact` counted the
      # recolor source: on a :reskin that row's image_url IS present, so a slot
      # with nothing on file for this game read as ready and the gate closed
      # over a jersey from another week. Measured 2026-09-23.
      def filled? = occupant&.image_url.present?

      # DOES THE NEXT ATTACH DESTROY A ROW? The submit label's promise about
      # what the click costs, read by the Attach/Replace word on the card.
      #
      # It deliberately does NOT test `image_url`. The question is which ROW
      # dies, and an artifact filed without an image still occupies the cell and
      # is still destroyed. `occupant&.image_url.present?` is the tempting
      # shorter form and tells the operator that nothing is lost.
      #
      # IT USED TO CARRY A SECOND CLAUSE — `occupant.id == artifact&.id`, the
      # "is the picture on screen the one about to be retired?" test — because
      # the card rendered `artifact` and the retire named `occupant`, so the two
      # could disagree. The card now renders `occupant` itself, which makes that
      # disagreement unreachable rather than merely untested; keeping the
      # comparison would assert a row against itself. The case that still
      # separates this from the shorter form is an occupant with no image.
      def replaces_filed_artifact? = occupant.present?

      def status_label
        case decision
        when :reuse  then "Reuse"
        when :reskin then "Re-skin"
        else              "Generate"
        end
      end

      def cast_label = subjects.map { |s| s[:name] }.join(" + ")

      # WHAT WE HAVE, or the honest admission that we do not know. A re-skin over
      # an artifact whose looks were never recorded used to render
      # "have  — recolor for this game" — the descriptors compact away to an
      # empty list and the sentence loses its object. That state is now REACHABLE
      # FROM THE COMMON PATH rather than exotic: a named colorway that resolves to
      # no look no longer counts as reuse, so it falls here instead.
      # THE PARTIAL CAST IS THE THIRD CASE, and dropping the nils collapsed it into
      # the first. A mixed cast carries a look per person, so one recorded and one
      # not is the ordinary state while a person's looks are being filed — and
      # `filter_map` deleted the unrecorded one from the sentence, leaving "have
      # Bengals white" over a two-person artifact whose second look nobody knows.
      # That is the same defect as the empty list losing its object, one case
      # short: an ABSENT look reading as an absent PERSON rather than as a gap.
      def reskin_detail
        looks = artifact.subjects.ordered.map { |s| s.effective_appearance&.descriptor }
        have = looks.compact.uniq
        return "have an artifact for this cast with no look recorded — recolor for this game" if have.empty?

        missing = looks.count(&:nil?)
        return "have #{have.join(' / ')} — recolor for this game" if missing.zero?

        "have #{have.join(' / ')}, plus #{missing} look#{'s' if missing > 1} never recorded " \
          "— recolor for this game"
      end

      # Why this slot needs work, in the words the operator needs. A re-skin
      # names the look we DO have, because that is the thing being changed.
      def detail
        case decision
        # `artifact` IS the occupant on a :reuse — #decide returns the one row
        # for both — so this sentence describes what is filed. It is the only
        # branch where the two may be used interchangeably.
        when :reuse  then artifact&.approved? ? "approved artifact on file" : "attached, not yet approved"
        when :reskin then reskin_detail
        else              "nothing on file for this cast"
        end
      end
    end

    def initialize(content)
      @content = content
    end

    def colorway = @content.effective_colorway

    # True when the operator has not confirmed a colorway and we are running on
    # the home/away guess. The screen says so out loud — an unconfirmed guess
    # that looks confirmed is how a wrong jersey ships.
    def colorway_guessed?
      @content.colorway.blank? && @content.guessed_colorway.present?
    end

    def cast
      [[@content.qb_player_slug, "qb"], [@content.skill_player_slug, "skill"]]
        .reject { |slug, _| slug.blank? }
    end

    def slots
      return [] if cast.empty?

      [pair_slot, *cast.map { |slug, role| sheet_slot(slug, role) }].compact
    end

    # THE GATE OPENS ONLY ON WHAT IS FILED. Every slot must hold an image of
    # its own; a :reskin slot pointing at another colorway's asset holds nothing
    # for THIS game, however present that asset's image_url is.
    def ready? = slots.any? && slots.all?(&:filled?)

    private

    # The look each person should be wearing for THIS content.
    #
    # WHEN THE CONTENT NAMES A COLORWAY, only a look in that colorway will do —
    # and nil is the honest answer when they have none. Falling back to the
    # person's default here would silently substitute the jersey they happen to
    # have for the one the game was played in, so a black-uniform game would
    # match a white artifact and the gate would say "reuse". That is exactly how
    # a wrong-jersey video ships, and it is the thing this screen exists to stop.
    #
    # With no colorway named there is nothing to contradict, so the default is
    # right. Appearance lives per-subject so a mixed cast can carry different
    # looks in one frame.
    def appearance_for(person_slug)
      person = Person.find_by(slug: person_slug)
      return nil unless person
      return person.default_appearance if colorway.blank?

      person.appearances.live.find_by(colorway: colorway)
    end

    def subject_rows(pairs)
      pairs.map do |slug, role|
        person = Person.find_by(slug: slug)
        { slug: slug, role: role,
          name: person&.full_name.presence || slug.to_s.titleize,
          appearance: appearance_for(slug) }
      end
    end

    def decide(rows, kind)
      pairs = rows.map { |r| [r[:slug], r[:appearance]&.slug] }

      # UNAPPROVED counts here. The gate is where approval HAPPENS, so an image
      # attached a moment ago must be visible to the slot that owns it.
      # THE COLORWAY GOES WITH THE PAIRS. #appearance_for returns nil for a named
      # colorway the person has no look in, and Artifact#subject_key emits the
      # same empty string for an artifact whose look was never recorded — so
      # without this argument the two nils compare equal and this line answers
      # REUSE over an artifact nobody has described. See Artifact.matching.
      exact = Artifact.matching(pairs, kind: kind, approved_only: false, colorway: colorway)
      return [:reuse, exact, exact] if exact

      # THE CELL OCCUPANT — the live artifact already carrying this exact reuse
      # key, asked WITHOUT the refusal above. The refusal decides what we are
      # willing to CALL a reuse; it cannot change which row a new artifact
      # shadows, and two live artifacts sharing one key is a shadowed duplicate
      # the lookups resolve by whichever the database hands back first.
      #
      # It is the same lookup, so it returns `exact` whenever `exact` is present
      # — which is why it is asked only down here, after that early return. The
      # reuse path pays no second query.
      occupant = Artifact.matching(pairs, kind: kind, approved_only: false)

      # Same cast, ANY looks — the face work is done and only the wardrobe is
      # wrong, which is a recolor rather than a fresh generation.
      #
      # ORDERED, because a cast routinely has SEVERAL live artifacts — one per
      # jersey is the whole point of the library — and `find` takes the first
      # row the query hands back. Unordered that is the heap's business, so the
      # recolor source changed between runs of the same data: a review measured
      # this reddening roughly one seed in fourteen. Which row is picked is not
      # arbitrary in its effects — `artifact` is what the re-skin sentence
      # describes and what a reader compares against `occupant` — so the choice
      # has to be STABLE, whichever it is. Oldest-first: any live artifact for
      # the cast is an equally good thing to recolor from, and the oldest is the
      # one already on file longest.
      other = Artifact.live.where(kind: kind).order(:id).includes(subjects: :appearance).find do |a|
        a.subjects.map(&:person_slug).sort == rows.map { |r| r[:slug] }.sort
      end
      return [:reskin, other, occupant] if other

      [:generate, nil, occupant]
    end

    def pair_slot
      return nil if cast.length < 2

      rows = subject_rows(cast)
      decision, artifact, occupant = decide(rows, "pair")
      Slot.new(kind: "pair", label: "Both players", subjects: rows,
               decision: decision, artifact: artifact, occupant: occupant)
    end

    def sheet_slot(slug, role)
      rows = subject_rows([[slug, role]])
      decision, artifact, occupant = decide(rows, "character_sheet")
      Slot.new(kind: "character_sheet", label: role == "qb" ? "Quarterback" : "Skill player",
               subjects: rows, decision: decision, artifact: artifact, occupant: occupant)
    end
  end
end
