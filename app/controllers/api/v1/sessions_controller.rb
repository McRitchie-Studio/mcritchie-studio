module Api
  module V1
    class SessionsController < BaseController
      # POST /api/v1/sessions/:session_id/mascot
      # Draw (or return) the session's Pokémon mascot eagerly, so a SessionStart
      # hook can paint the status line before any task exists. Idempotent: the same
      # session always resolves to the same mascot, and the board task adopts it.
      def mascot
        parent_session_id = params[:parent_session_id].presence || params[:parentSessionId].presence
        session_mascot = SessionMascot.for(params[:session_id], parent_session_id: parent_session_id)
        unless session_mascot
          return render_error("Could not assign a mascot", status: :unprocessable_entity,
                                                            error_code: "NO_MASCOT")
        end

        pokemon = session_mascot.pokemon
        # Also hand back the DEFAULT app so a brand-new session (no task yet) paints
        # "<Pokémon> · mcritchie-studio" — bin/task session-mascot seeds these into
        # the marker only when it has no app, never clobbering a task-set app.
        app = App.default
        render_data({
          "mascot"       => session_mascot.mascot_slug,
          "mascot_color" => pokemon&.signature_color,
          "mascot_emoji" => pokemon&.type_emoji.presence,
          "app"          => app&.slug || App::DEFAULT_SLUG,
          "app_name"     => app&.name,
          "app_color"    => app&.color
        })
      end
    end
  end
end
