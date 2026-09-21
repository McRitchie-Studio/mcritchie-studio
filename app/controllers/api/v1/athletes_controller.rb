module Api
  module V1
    # The PROVIDER side of the person/athlete projection.
    #
    # McRitchie Studio masters every durable fact about a person, a team or a
    # place; turf-monster masters everything that happened at a time (games,
    # goals, contests). Two one-way flows, and this is the MS → TM half.
    #
    # A consumer PULLS on a cadence and holds a local replica rather than asking
    # at request time, deliberately: turf-monster is a live wagering app, and a
    # runtime dependency on this endpoint would make MS's availability part of
    # TM's correctness. A stale player name is survivable; a 500 on a contest
    # page is not.
    class AthletesController < BaseController
      MAX_PAGE = 500
      DEFAULT_PAGE = 200

      # GET /api/v1/athletes?updated_since=<iso8601>&after_id=<id>&limit=<n>
      #
      # A nil `updated_since` IS the full rebuild — there is no separate mode
      # to get wrong, and a consumer with no watermark simply pages the world.
      def index
        scope = Athlete.includes(:person).order(:updated_at, :id).limit(page_size)
        scope = apply_watermark(scope)

        rows = scope.to_a
        render_data(rows.map { |a| serialize(a) }, meta: cursor_for(rows))
      end

      private

      def page_size
        requested = params[:limit].to_i
        return DEFAULT_PAGE if requested <= 0

        [requested, MAX_PAGE].min
      end

      # THE COMPOUND CURSOR, and it is not decoration.
      #
      # Paging on `updated_at` alone silently DROPS rows: a bulk import stamps
      # thousands of records within the same second, so a page boundary landing
      # mid-second means every later row sharing that timestamp is skipped and
      # never seen again — the consumer's replica is quietly short and nothing
      # reports it. `(updated_at, id)` is unique and totally ordered, so the
      # keyset can always resume exactly where it stopped.
      def apply_watermark(scope)
        since = parse_time(params[:updated_since])
        return scope if since.nil?

        after_id = params[:after_id].to_i
        if after_id.positive?
          scope.where("athletes.updated_at > :t OR (athletes.updated_at = :t AND athletes.id > :id)",
                      t: since, id: after_id)
        else
          scope.where("athletes.updated_at >= ?", since)
        end
      end

      # `>=` on the first page of a window, `>` past the cursor. A consumer that
      # stores the last row's updated_at and re-asks with `>` would lose every
      # row sharing that exact timestamp, so the inclusive first page plus an
      # idempotent upsert on the consumer is the safe pairing.
      def cursor_for(rows)
        last = rows.last
        {
          "count" => rows.length,
          "next_updated_since" => last&.updated_at&.iso8601(6),
          "next_after_id" => last&.id,
          "more" => rows.length == page_size,
          # So a consumer can tell "nothing changed" from "nothing was checked".
          "source_last_imported_at" => ImportRun.last_success_for("nflverse_players")&.finished_at&.iso8601
        }
      end

      def parse_time(raw)
        return nil if raw.blank?

        Time.zone.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      def serialize(athlete)
        person = athlete.person
        {
          # THE SYNC KEY. Not the slug — a slug changes the moment a namesake
          # forces a disambiguator onto it — and not the name, which collides.
          gsis_id: athlete.gsis_id,
          person_slug: person&.slug,
          first_name: person&.first_name,
          last_name: person&.last_name,
          disambiguator: person&.try(:disambiguator),
          athlete_slug: athlete.slug,
          sport: athlete.sport,
          position: athlete.position,
          team_slug: athlete.team_slug,
          height_inches: athlete.height_inches,
          weight_lbs: athlete.weight_lbs,
          espn_headshot_url: athlete.espn_headshot_url,
          espn_id: athlete.espn_id,
          nflverse_id: athlete.nflverse_id,
          pff_id: athlete.pff_id,
          otc_id: athlete.otc_id,
          pfr_id: athlete.pfr_id,
          sleeper_id: athlete.sleeper_id,
          updated_at: athlete.updated_at.iso8601(6)
        }
      end
    end
  end
end
