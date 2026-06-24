module Api
  module V1
    class SessionsController < BaseController
      # POST /api/v1/sessions/:session_id/mascot
      # Draw (or return) the session's Pokémon mascot eagerly, so a SessionStart
      # hook can paint the status line before any task exists. Idempotent: the same
      # session always resolves to the same mascot, and the board task adopts it.
      def mascot
        session_mascot = SessionMascot.for(params[:session_id])
        unless session_mascot
          return render_error("Could not assign a mascot", status: :unprocessable_entity,
                                                            error_code: "NO_MASCOT")
        end

        pokemon = session_mascot.pokemon
        render_data({
          "mascot"       => session_mascot.mascot_slug,
          "mascot_color" => pokemon&.signature_color,
          "mascot_emoji" => pokemon&.type_emoji.presence
        })
      end
    end
  end
end
