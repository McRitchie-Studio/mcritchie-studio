class Content
  # Turns ONE finished game into a Content at stage=idea.
  #
  # The caller is turf-monster: `Nfl::LiveScores::PollCycle#finalise` posts the
  # final here. That poll cycle is deliberately safe to re-run — every scoring
  # event is keyed on ESPN's own play id, so a repeated cycle writes nothing —
  # which means the SAME final is expected to arrive here more than once. This
  # service is therefore idempotent by construction, not as a courtesy.
  class CreateGameRecap
    class InvalidGame < StandardError; end

    Result = Struct.new(:content, :created, keyword_init: true) do
      def created? = created
    end

    REQUIRED_KEYS = %i[game_slug home_team_slug away_team_slug home_score away_score].freeze

    def initialize(payload)
      @payload = normalize(payload)
    end

    def call
      validate!

      existing = find_existing
      return Result.new(content: existing, created: false) if existing

      Result.new(content: create_content, created: true)
    rescue ActiveRecord::RecordNotUnique
      # Two finals for the same game raced each other to the unique index. The
      # index is the arbiter and one of them won; re-read rather than re-raise,
      # so a duplicate POST still answers with the recap that exists.
      existing = find_existing
      raise if existing.nil?

      Result.new(content: existing, created: false)
    end

    private

    attr_reader :payload

    def normalize(raw)
      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      hash.to_h.symbolize_keys
    end

    def validate!
      missing = REQUIRED_KEYS.select { |k| payload[k].nil? || payload[k].to_s.strip.empty? }
      raise InvalidGame, "missing: #{missing.join(', ')}" if missing.any?

      raise InvalidGame, "scores must be whole numbers" unless integerish?(payload[:home_score]) && integerish?(payload[:away_score])
      raise InvalidGame, "scores cannot be negative" if home_score.negative? || away_score.negative?
      raise InvalidGame, "a game cannot be played against itself" if payload[:home_team_slug] == payload[:away_team_slug]
      raise InvalidGame, "unknown team: #{payload[:home_team_slug]}" if home_team.nil?
      raise InvalidGame, "unknown team: #{payload[:away_team_slug]}" if away_team.nil?
    end

    # `"24"` is fine (it arrives over JSON), `"24.5"` and `"final"` are not.
    # `Integer()` is the check because `to_i` answers 0 for both of those and
    # would silently invent a shutout.
    def integerish?(value)
      Integer(value.to_s, exception: false).present?
    end

    def home_score = Integer(payload[:home_score].to_s)
    def away_score = Integer(payload[:away_score].to_s)

    def home_team = @home_team ||= Team.find_by(slug: payload[:home_team_slug])
    def away_team = @away_team ||= Team.find_by(slug: payload[:away_team_slug])

    def tie? = home_score == away_score

    def winner = home_score > away_score ? home_team : away_team
    def loser  = home_score > away_score ? away_team : home_team

    def winning_score = [home_score, away_score].max
    def losing_score  = [home_score, away_score].min

    def find_existing
      Content.find_by(game_slug: payload[:game_slug], workflow: Content::GAME_RECAP_WORKFLOW)
    end

    # "Broncos Beat Jaguars 24-17", or "Broncos And Jaguars Tie 17-17".
    # A tie is rare but real in the NFL, and "beat" would be a lie — the phrase
    # has to change, not just the numbers.
    def title
      if tie?
        "#{home_team.mascot} And #{away_team.mascot} Tie #{home_score}-#{away_score}"
      else
        "#{winner.mascot} Beat #{loser.mascot} #{winning_score}-#{losing_score}"
      end
    end

    def description
      "Final — #{away_team.name} #{away_score}, #{home_team.name} #{home_score}."
    end

    def create_content
      Content.create!(
        workflow:    Content::GAME_RECAP_WORKFLOW,
        stage:       "idea",
        source_type: "game",
        game_slug:   payload[:game_slug],
        game_facts:  game_facts,
        # On a tie there is no winner, so the pair is stored in the feed's own
        # home/away order rather than inventing a ranking between them.
        team_slug:       (tie? ? home_team.slug : winner.slug),
        rival_team_slug: (tie? ? away_team.slug : loser.slug),
        title:       title,
        description: description
      )
    end

    def game_facts
      {
        "game_slug"       => payload[:game_slug],
        "home_team_slug"  => home_team.slug,
        "away_team_slug"  => away_team.slug,
        "home_score"      => home_score,
        "away_score"      => away_score,
        "tie"             => tie?,
        "winner_slug"     => (tie? ? nil : winner.slug),
        "loser_slug"      => (tie? ? nil : loser.slug),
        "status_detail"   => payload[:status_detail],
        "season_year"     => payload[:season_year],
        "season_type"     => payload[:season_type],
        "week"            => payload[:week],
        "kickoff_at"      => payload[:kickoff_at],
        "recorded_at"     => Time.current.iso8601
      }.compact
    end
  end
end
