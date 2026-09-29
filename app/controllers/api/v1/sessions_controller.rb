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
        # A shiny draw announces itself with a ✨ next to the type emoji glyphs.
        app = App.default
        render_data({
          "mascot"       => session_mascot.mascot_slug,
          "mascot_shiny" => session_mascot.shiny?,
          # The session's DISPLAY gender: its roll ("female"/"male"), "genderless"
          # for a gender_rate -1 species, nil for a pre-gender draw
          # (Pokemon#display_gender). bin/statusline turns it into the name's
          # sign — Mawile♂, Magnemite⚥ — and names Nidoran's form by it.
          "mascot_gender" => pokemon ? pokemon.display_gender(session_mascot.gender) : session_mascot.gender,
          "mascot_color" => pokemon&.signature_color,
          "mascot_emoji" => pokemon&.status_emoji(shiny: session_mascot.shiny?),
          "app"          => app&.slug || App::DEFAULT_SLUG,
          "app_name"     => app&.name,
          "app_color"    => app&.color
        })
      end
    end
  end
end
