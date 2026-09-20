module Api
  module V1
    # The seam turf-monster pushes a finished game through.
    #
    # `Nfl::LiveScores::PollCycle#finalise` calls this once per game it settles.
    # Games live in turf-monster and Content lives here, so this endpoint is the
    # whole of the crossing — the hub never reads turf-monster's database.
    class GameRecapsController < BaseController
      # A duplicate final is the EXPECTED case, not an error: the poll cycle is
      # safe to re-run and does so. It answers 200 with the recap that already
      # exists, and 201 only when this call is the one that created it, so the
      # caller can tell "already handled" from "just handled" without guessing.
      def create
        result = Content::CreateGameRecap.new(game_params).call

        render_data(serialize(result.content), status: result.created? ? :created : :ok)
      rescue Content::CreateGameRecap::InvalidGame => e
        render_error(e.message, status: :unprocessable_entity, error_code: "INVALID_GAME")
      end

      private

      def game_params
        params.require(:game).permit(
          :game_slug, :home_team_slug, :away_team_slug,
          :home_score, :away_score, :status_detail,
          :season_year, :season_type, :week, :kickoff_at
        )
      end

      def serialize(content)
        {
          slug:       content.slug,
          title:      content.title,
          stage:      content.stage,
          workflow:   content.workflow,
          game_slug:  content.game_slug,
          team_slug:  content.team_slug,
          rival_team_slug: content.rival_team_slug,
          url:        "#{ENV.fetch('STUDIO_BASE_URL', 'https://mcritchie.studio')}/contents/#{content.slug}"
        }
      end
    end
  end
end
