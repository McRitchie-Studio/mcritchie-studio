module Appearances
  # THE MODEL PIPELINE BOARD'S READ MODEL — every character model in flight, in five
  # lanes, in a FIXED number of queries.
  #
  # Fixed by construction, not by care: every fact a card needs is fetched as one
  # grouped query over the whole board and handed to Appearances::LookReading, which
  # reads no database at all. That is the property to preserve when a card gains a
  # field — add a grouped query here, never a lookup inside the reading. The
  # alternative was measured on the person page's own gallery: Appearances::ReferenceSet
  # re-reads the athlete's ImageCache rows per look, which is correct for one look and
  # N+1 for a board of them.
  #
  # NOTHING HERE SPENDS. Every read is a SELECT over rows we already hold. The
  # derived reference floor is asked as "does a cached headshot row exist" rather than
  # through Appearances::ReferenceImages, which would be the same answer at the cost
  # of instantiating and URL-checking every one of them on a page render.
  class Pipeline
    STAGES = LookReading::STAGES

    # HOW MANY CARDS ONE LANE RENDERS. The column's count chip always shows the TRUE
    # total, so the cap hides cards and never a number — a lane of two thousand cards
    # is not a 1000-foot view, it is a scroll marathon that answers nothing.
    LANE_LIMIT = 60

    # THE FIELD THE OPERATOR NAMED THAT THE SCHEMA DOES NOT HAVE. Stated on the board
    # rather than silently omitted from the define step's checks: he described the
    # step as "name, height, and for athletes number and team", and a jersey-number
    # column exists on no table (measured 2026-09-26). The character-sheet recipe
    # substitutes a <NUMBER>, so this is a gap in the step and not a nicety. A gate
    # over a missing column would fail every look for a reason nobody can act on; a
    # sentence in the open is honest and actionable.
    DEFINITION_GAP_NOTE =
      "Jersey number has no column on any table yet, so Defined cannot assert it — " \
      "the colorway is the only uniform fact on file.".freeze

    Lane = Struct.new(:key, :label, :blurb, :cards, :total, :overflow, keyword_init: true)

    def self.build(...) = new(...).build

    def initialize(scope: nil)
      @scope = scope || Appearance.live
    end

    def build
      readings = self.class.readings_for(looks)
      grouped = readings.group_by(&:board_stage)

      {
        lanes: STAGES.map { |stage| lane_for(stage, grouped.fetch(stage, [])) },
        total: readings.length,
        stale_count: readings.count(&:stale?),
        hand_placed_count: readings.count(&:hand_placed?)
      }
    end

    # ONE LOOK'S READING, for a caller that holds a single record (a detail page, a
    # test). Deliberately the SAME code path as the board — it builds a one-element
    # board — so the two can never give different answers about the same look.
    def self.reading_for(appearance) = readings_for([appearance]).first

    # THE GATHER. Every query below is grouped over the whole set; none of them runs
    # per look.
    def self.readings_for(looks)
      looks = Array(looks)
      return [] if looks.empty?

      slugs = looks.map(&:slug)
      person_slugs = looks.map(&:person_slug).compact.uniq

      people = Person.where(slug: person_slugs).index_by(&:slug)
      athletes = Athlete.where(person_slug: person_slugs).index_by(&:person_slug)
      headshot_owner_ids = headshot_athlete_ids(athletes.values)

      candidates = AppearanceReferencePhoto.where(appearance_slug: slugs).group(:appearance_slug).count
      chosen = AppearanceReferencePhoto.where(appearance_slug: slugs, chosen: true)
                                       .group(:appearance_slug).count
      judged = AppearanceReferencePhoto.where(appearance_slug: slugs)
                                       .where.not(operator_verdict: nil)
                                       .group(:appearance_slug).count
      artifacts = artifact_counts(slugs)
      sources = artifact_sources(slugs)

      looks.map do |look|
        person = people[look.person_slug]
        athlete = athletes[look.person_slug]

        LookReading.new(
          appearance: look,
          person_name: person&.full_name,
          person_slug: look.person_slug,
          athlete: athlete.present?,
          athlete_team_slug: athlete&.team_slug,
          headshot: athlete.present? && headshot_owner_ids.include?(athlete.id),
          physique_described: athlete.present? && athlete.physical_brief.present?,
          height_inches: athlete&.height_inches,
          weight_lbs: athlete&.weight_lbs,
          candidate_count: candidates.fetch(look.slug, 0),
          chosen_count: chosen.fetch(look.slug, 0),
          judged_count: judged.fetch(look.slug, 0),
          artifact_count: artifacts.fetch(look.slug, 0),
          artifact_source: sources[look.slug]
        )
      end
    end

    # WHICH ATHLETES HAVE A CACHED HEADSHOT AT ALL. Asked by PURPOSE and not by
    # variant: Athlete::HEADSHOT_WIDTHS is a preference list and a look with only the
    # 100px crop still has a photograph to build from, so keying on "400" would report
    # no reference for a look that has one.
    def self.headshot_athlete_ids(athletes)
      ids = athletes.map(&:id)
      return Set.new if ids.empty?

      ImageCache.where(owner_type: "Athlete", owner_id: ids,
                       purpose: ReferenceImages::HEADSHOT_PURPOSE)
                .distinct.pluck(:owner_id).to_set
    end

    # LIVE images filed against each look. Retired artifacts are excluded for the same
    # reason the board only renders live looks: a retired image is not a delivery, and
    # counting it would leave a card sitting in Generation with nothing to show.
    def self.artifact_counts(slugs)
      ArtifactSubject.joins(:artifact)
                     .where(appearance_slug: slugs, artifacts: { retired_at: nil })
                     .group(:appearance_slug)
                     .count
    end

    # WHICH GENERATOR PRODUCED THE NEWEST IMAGE — the DATA the look carries, never a
    # vendor this board knows the name of. The operator's constraint (2026-09-26): the
    # generator is swappable, so the lane names a STAGE and a card may report its
    # provenance. `artifacts.source` is already that column; a library will hold images
    # from several generators and each row says which made it.
    def self.artifact_sources(slugs)
      rows = ArtifactSubject.joins(:artifact)
                            .where(appearance_slug: slugs, artifacts: { retired_at: nil })
                            .order("artifacts.created_at DESC")
                            .pluck(:appearance_slug, "artifacts.source")
      rows.each_with_object({}) { |(slug, source), memo| memo[slug] ||= source }
    end

    private

    # BOARD ORDER, from studio-engine's Studio::Board::Rankable: rank DESC with NULLS
    # LAST, then newest first. A look nobody has dragged has no rank and falls through
    # to created_at, so an untouched board still has a stable order.
    def looks
      @looks ||= @scope.board_ordered.to_a
    end

    def lane_for(stage, readings)
      shown = readings.first(LANE_LIMIT)
      Lane.new(
        key: stage,
        label: LookReading::LABELS.fetch(stage, stage.titleize),
        blurb: LookReading::BLURBS.fetch(stage, nil),
        cards: shown,
        total: readings.length,
        overflow: readings.length - shown.length
      )
    end
  end
end
