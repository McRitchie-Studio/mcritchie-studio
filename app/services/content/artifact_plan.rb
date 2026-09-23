class Content
  # What the inspection gate shows: the artifact slots a rapper-replace video
  # needs, each with a DECISION about whether we already have it.
  #
  # The decision is the whole value of the screen. Generating every image from
  # scratch each week would be the obvious thing and the wrong one — a person's
  # face does not change, only what they are wearing does. So each slot answers:
  # reuse it, re-skin it, or make it.
  class ArtifactPlan
    Slot = Struct.new(:kind, :label, :subjects, :decision, :artifact, :supersedes, keyword_init: true) do
      # `decision` and `supersedes` answer DIFFERENT QUESTIONS and must not share
      # a predicate.
      #
      #   #reuse? — "may we use this artifact as it stands?" A LABEL, read by the
      #   badge on the gate card.
      #   #supersedes — "which live artifact would the image I am about to file
      #   shadow?" A MUTATION, read by the retire in
      #   ContentsController#attach_artifact.
      #
      # They came apart the moment a lookless artifact under a named colorway
      # stopped counting as a reuse. The label became right and the RETIRE went
      # with it, so Replace filed a second artifact carrying the SAME reuse key
      # and the gate kept rendering the first one — a wrong label became a wrong
      # picture. Gating a mutation on a lookup's predicate means every change to
      # what the lookup MATCHES silently changes what the mutation DESTROYS.
      #
      # NOTE ALSO that on a re-skin `artifact` and `supersedes` are not the same
      # row: `artifact` is the other-look asset we are recoloring FROM, which
      # must stay live. Retiring by `decision` could only ever name `artifact`.
      def reuse?    = decision == :reuse
      def reskin?   = decision == :reskin
      def generate? = decision == :generate

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
      def reskin_detail
        have = artifact.subjects.ordered.filter_map { |s| s.effective_appearance&.descriptor }.uniq
        return "have an artifact for this cast with no look recorded — recolor for this game" if have.empty?

        "have #{have.join(' / ')} — recolor for this game"
      end

      # Why this slot needs work, in the words the operator needs. A re-skin
      # names the look we DO have, because that is the thing being changed.
      def detail
        case decision
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

    def ready? = slots.any? && slots.all? { |s| s.artifact&.image_url.present? }

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
      other = Artifact.live.where(kind: kind).includes(subjects: :appearance).find do |a|
        a.subjects.map(&:person_slug).sort == rows.map { |r| r[:slug] }.sort
      end
      return [:reskin, other, occupant] if other

      [:generate, nil, occupant]
    end

    def pair_slot
      return nil if cast.length < 2

      rows = subject_rows(cast)
      decision, artifact, supersedes = decide(rows, "pair")
      Slot.new(kind: "pair", label: "Both players", subjects: rows,
               decision: decision, artifact: artifact, supersedes: supersedes)
    end

    def sheet_slot(slug, role)
      rows = subject_rows([[slug, role]])
      decision, artifact, supersedes = decide(rows, "character_sheet")
      Slot.new(kind: "character_sheet", label: role == "qb" ? "Quarterback" : "Skill player",
               subjects: rows, decision: decision, artifact: artifact, supersedes: supersedes)
    end
  end
end
