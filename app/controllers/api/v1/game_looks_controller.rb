module Api
  module V1
    # The filing seam of the game-character-models SOP: bin/game-model posts a
    # sheet it built and uploaded to R2, and the hub files it on the player's look
    # for that game (and the look's iced twin for an iced sheet).
    #
    #   POST /api/v1/game_looks
    #        { espn_id, descriptor, jersey_number?, generation_notes?,
    #          sheets: [{ variant: "base"|"iced", object_key }] }
    class GameLooksController < BaseController
      KEYS = %w[espn_id descriptor jersey_number generation_notes sheets].freeze
      SHEET_KEYS = %w[variant object_key].freeze
      ROUTING_KEYS = %w[controller action format game_look].freeze

      def create
        body = params.to_unsafe_h.except(*ROUTING_KEYS)
        extra = (body.keys - KEYS) + Array(body["sheets"]).flat_map { |s| s.respond_to?(:keys) ? s.keys - SHEET_KEYS : ["(not an object)"] }
        return render_error("unpermitted keys: #{extra.uniq.join(', ')}", error_code: "UNPERMITTED_KEYS") if extra.any?

        filing = Appearances::FileGameLook.new(body)
        filing.check! # a refusal is an answer, not an ErrorLog
        outcome = rescue_and_log { filing.call }
        render_data(serialize(outcome), status: outcome.created ? :created : :ok)
      rescue Appearances::FileGameLook::Refused => e
        status = e.code == "NO_ATHLETE" ? :not_found : :unprocessable_entity
        render_error(e.message, status: status, error_code: e.code)
      end

      private

      def serialize(outcome)
        {
          look: outcome.look.slug,
          person: outcome.look.person_slug,
          iced_twin: outcome.twin&.slug,
          artifacts: outcome.artifacts.map { |a| { slug: a.slug, url: a.image_url, look: a.subjects.first&.appearance_slug } }
        }
      end
    end
  end
end
