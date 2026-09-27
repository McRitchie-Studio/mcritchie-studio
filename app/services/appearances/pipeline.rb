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
    # rather than silently omitted from the define step's checks: he described the step
    # as "name, height, and for athletes number and team", and a jersey-number column
    # exists on NO table (measured 2026-09-26, re-checked 2026-09-27: no `jersey_number`,
    # no `number`). ESPN's API returns it as `athlete.jersey`; we do not store it, and
    # every character-sheet prompt substitutes a <NUMBER>. So it is genuinely missing
    # rather than merely unshown.
    #
    # A GATE OVER A MISSING COLUMN would fail every look for a reason nobody can act on,
    # so the gap is SURFACED instead — here for the board, and as a `no #` cell in every
    # athlete card's sports row, which is where a reader looks for the number and would
    # otherwise read its absence as completeness.
    DEFINITION_GAP_NOTE =
      "Jersey number has no column on any table yet, so Defined cannot assert it and " \
      "every card's sports row reads \"no #\". ESPN returns it; we do not store it.".freeze

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
        # A look naming a person who is not on file. `appearances.person_slug` carries no
        # foreign key, so nothing else in the app would ever notice one.
        orphan_count: readings.count(&:orphan?),
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
      # PRELOADED IMAGE CACHES, so `Athlete#headshot_url` — which `detect`s over the
      # association — answers from memory. Two queries for the whole board, the same
      # shape PeopleController#index uses for the same reason. And it is the STORED
      # `s3_key` that answers, never a rebuilt path: `Athlete#headshot_key_prefix`
      # derives a folder from the CURRENT team, and a re-key means a derived path names
      # objects that have moved. people/show hotlinks a.espncdn.com instead; that is the
      # copy not to follow.
      athletes = Athlete.where(person_slug: person_slugs).includes(:image_caches).index_by(&:person_slug)

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
        avatar = avatar_url_for(athlete)

        LookReading.new(
          appearance: look,
          person_name: person&.full_name,
          person_slug: look.person_slug,
          person_present: person.present?,
          athlete: athlete.present?,
          athlete_team_slug: athlete&.team_slug,
          athlete_position: athlete&.position,
          headshot: avatar.present?,
          avatar_url: avatar,
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

    # THE CACHED HEADSHOT'S URL, WIDEST FIRST — and the same value answers two questions,
    # which is deliberate: it is both the card's avatar and the proof there is a
    # photograph to build from. Splitting them would let a card show a face while its
    # lane claimed no reference existed.
    #
    # Every variant counts, not just "400". Athlete::HEADSHOT_WIDTHS is a PREFERENCE
    # list, so a look holding only the 100px crop still has a photograph — keying the
    # lane on the widest alone would report no reference for a look that has one.
    #
    # Reads through Athlete#headshot_url, which resolves Studio::S3.url off the row's
    # STORED s3_key. No query here: `readings_for` preloads :image_caches.
    def self.avatar_url_for(athlete)
      return nil if athlete.nil?

      ReferenceImages::HEADSHOT_VARIANTS.filter_map { |width| athlete.headshot_url(width: width) }.first
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
