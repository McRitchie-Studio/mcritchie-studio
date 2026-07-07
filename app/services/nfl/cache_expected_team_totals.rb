require "csv"
require "pathname"

module Nfl
  class CacheExpectedTeamTotals
    DEFAULT_SOURCE_PATH = Rails.root.join("db/seeds/data/nfl/2026_expected_team_totals.csv")
    DEFAULT_SOURCE = "yahoo_sports_2026_lookahead"
    DEFAULT_SOURCE_URL = "https://sports.yahoo.com/nfl/betting/article/2026-nfl-betting-lines-odds-for-every-game-this-season-164646933.html"
    DEFAULT_SOURCE_PUBLISHED_ON = Date.new(2026, 5, 26)

    def self.derive(total:, home_spread:)
      total = BigDecimal(total.to_s)
      home_spread = BigDecimal(home_spread.to_s)

      {
        home: ((total - home_spread) / 2).round(2),
        away: ((total + home_spread) / 2).round(2)
      }
    end

    def initialize(year: 2026, source_path: DEFAULT_SOURCE_PATH, source: DEFAULT_SOURCE, source_url: DEFAULT_SOURCE_URL, source_published_on: DEFAULT_SOURCE_PUBLISHED_ON, strict: true, verbose: true)
      @year = year.to_i
      @source_path = source_path.is_a?(Pathname) ? source_path : Pathname.new(source_path.to_s)
      @source = source
      @source_url = source_url
      @source_published_on = source_published_on
      @strict = strict
      @verbose = verbose
    end

    def call
      season = Season.find_by!(year: @year, league: "nfl")
      rows = read_rows
      cached_at = Time.current
      stats = {
        season: season.slug,
        source: @source,
        source_path: @source_path.to_s,
        games_seen: rows.size,
        games_cached: 0,
        projections_upserted: 0,
        stale_deleted: 0,
        missing_games: [],
        weeks: Hash.new(0)
      }

      touched_ids = []
      rows.each do |row|
        week = integer!(row, "week")
        slate = season.slates.find_by(sequence: week)
        game = find_game(season, week, row)

        unless slate && game
          stats[:missing_games] << missing_game_label(week, row)
          next
        end

        attrs = projection_attributes(season:, slate:, game:, row:, week:, cached_at:)
        touched_ids.concat(upsert_pair(attrs))
        stats[:games_cached] += 1
        stats[:projections_upserted] += 2
        stats[:weeks][week] += 1
      end

      raise_missing_games!(stats[:missing_games]) if @strict && stats[:missing_games].any?

      stale_scope = NflTeamTotalProjection.where(season_slug: season.slug, source: @source)
      stale_scope = stale_scope.where.not(id: touched_ids) if touched_ids.any?
      stats[:stale_deleted] = stale_scope.delete_all
      stats[:weeks] = stats[:weeks].sort.to_h
      stats
    end

    private

    def read_rows
      raise ArgumentError, "source CSV not found: #{@source_path}" unless @source_path.exist?

      CSV.read(@source_path, headers: true).map(&:to_h)
    end

    def find_game(season, week, row)
      Game.joins(:slate)
          .where(slates: { season_slug: season.slug, sequence: week })
          .find_by(away_team_slug: value!(row, "away_team_slug"), home_team_slug: value!(row, "home_team_slug"))
    end

    def projection_attributes(season:, slate:, game:, row:, week:, cached_at:)
      favorite_team_slug = value!(row, "favorite_team_slug")
      favorite_spread = -decimal!(row, "favorite_spread").abs
      total = decimal!(row, "game_total")

      home_spread = if favorite_team_slug == game.home_team_slug
        favorite_spread
      elsif favorite_team_slug == game.away_team_slug
        favorite_spread.abs
      else
        raise ArgumentError, "favorite #{favorite_team_slug.inspect} is not in #{game.slug}"
      end

      expected = self.class.derive(total: total, home_spread: home_spread)
      common = {
        season_slug: season.slug,
        slate_slug: slate.slug,
        game_slug: game.slug,
        week: week,
        game_total: total,
        home_spread: home_spread,
        favorite_team_slug: favorite_team_slug,
        favorite_spread: favorite_spread,
        source: value(row, "source").presence || @source,
        source_url: value(row, "source_url").presence || @source_url,
        source_published_on: value(row, "source_published_on").presence || @source_published_on,
        cached_at: cached_at
      }

      [
        common.merge(team_slug: game.home_team_slug, opponent_team_slug: game.away_team_slug, home: true, expected_points: expected[:home]),
        common.merge(team_slug: game.away_team_slug, opponent_team_slug: game.home_team_slug, home: false, expected_points: expected[:away])
      ]
    end

    def upsert_pair(attributes)
      attributes.map do |attrs|
        projection = NflTeamTotalProjection.find_or_initialize_by(game_slug: attrs[:game_slug], team_slug: attrs[:team_slug])
        projection.update!(attrs)
        projection.id
      end
    end

    def integer!(row, key)
      Integer(value!(row, key))
    rescue ArgumentError
      raise ArgumentError, "invalid integer #{key}=#{row[key].inspect}"
    end

    def decimal!(row, key)
      BigDecimal(value!(row, key).to_s)
    rescue ArgumentError
      raise ArgumentError, "invalid decimal #{key}=#{row[key].inspect}"
    end

    def value!(row, key)
      value(row, key).presence || raise(ArgumentError, "missing required CSV column #{key}")
    end

    def value(row, key)
      row[key] || row[key.to_sym]
    end

    def missing_game_label(week, row)
      "week #{week}: #{value(row, "away_team_slug")} at #{value(row, "home_team_slug")}"
    end

    def raise_missing_games!(missing_games)
      sample = missing_games.first(10).join(", ")
      more = missing_games.size > 10 ? " (+#{missing_games.size - 10} more)" : ""
      raise "Missing games for expected team totals: #{sample}#{more}"
    end
  end
end
