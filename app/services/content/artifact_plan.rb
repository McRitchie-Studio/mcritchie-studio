class Content
  # What the inspection gate shows: the artifact slots a rapper-replace video
  # needs, each with a DECISION about whether we already have it.
  #
  # The decision is the whole value of the screen. Generating every image from
  # scratch each week would be the obvious thing and the wrong one — a person's
  # face does not change, only what they are wearing does. So each slot answers:
  # reuse it, re-skin it, or make it.
  class ArtifactPlan
    Slot = Struct.new(:kind, :label, :subjects, :decision, :artifact, keyword_init: true) do
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

      # Why this slot needs work, in the words the operator needs. A re-skin
      # names the look we DO have, because that is the thing being changed.
      def detail
        case decision
        when :reuse  then artifact&.approved? ? "approved artifact on file" : "attached, not yet approved"
        when :reskin then "have #{artifact.subjects.ordered.map { |s| s.effective_appearance&.descriptor }.compact.uniq.join(' / ')} — recolor for this game"
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
      exact = Artifact.matching(pairs, kind: kind, approved_only: false)
      return [:reuse, exact] if exact

      # Same cast, ANY looks — the face work is done and only the wardrobe is
      # wrong, which is a recolor rather than a fresh generation.
      other = Artifact.live.where(kind: kind).includes(subjects: :appearance).find do |a|
        a.subjects.map(&:person_slug).sort == rows.map { |r| r[:slug] }.sort
      end
      return [:reskin, other] if other

      [:generate, nil]
    end

    def pair_slot
      return nil if cast.length < 2

      rows = subject_rows(cast)
      decision, artifact = decide(rows, "pair")
      Slot.new(kind: "pair", label: "Both players", subjects: rows,
               decision: decision, artifact: artifact)
    end

    def sheet_slot(slug, role)
      rows = subject_rows([[slug, role]])
      decision, artifact = decide(rows, "character_sheet")
      Slot.new(kind: "character_sheet", label: role == "qb" ? "Quarterback" : "Skill player",
               subjects: rows, decision: decision, artifact: artifact)
    end
  end
end
