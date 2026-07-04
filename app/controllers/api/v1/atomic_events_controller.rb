module Api
  module V1
    class AtomicEventsController < BaseController
      # The agent-narration sink. The agent self-declares meaningful SPANS of its
      # trajectory (via `bin/atomic-event`): it OPENs a span with a category +
      # reason ("what am I doing"), the raw tool-calls attribute server-side to
      # that open span (see AtomicAction.capture), and it CLOSEs the span with an
      # outcome ("what happened"). One span is open per session at a time.
      #
      # Authed exactly like AtomicActionsController — a Bearer api_auth token.

      # POST /api/v1/atomic_events
      #
      # Open a new span for the session, auto-closing any prior open span. Returns
      # 201 with the opened span. An invalid span (unknown category / blank reason)
      # is a 422 (VALIDATION_FAILED) via BaseController — the agent used a bad
      # category and should see it. `reason` maps to reason_slug on the record.
      #
      # BOUNDARY transition: `prior_outcome` (from `bin/atomic-event next` /
      # `start --outcome`) stamps the auto-closed prior span's outcome_slug as the
      # agent crosses into this one — resolving "what happened" in the SAME call
      # that opens "what's next", so spans stop hanging half-narrated.
      def create
        event = AtomicEvent.open_event!(
          session_id:         open_params[:session_id],
          category:           open_params[:category],
          reason_slug:        open_params[:reason],
          task_slug:          open_params[:task_slug],
          mascot:             open_params[:mascot],
          stage:              open_params[:stage],
          agent:              open_params[:agent],
          prior_outcome_slug: open_params[:prior_outcome],
          prior_key_method:      open_params[:prior_key_method],
          prior_key_method_lang: open_params[:prior_key_method_lang]
        )
        render_data(event, status: :created)
      end

      # POST /api/v1/atomic_events/close
      #
      # Close the session's current open span, stamping the narrated outcome
      # (`outcome` maps to outcome_slug). A stray close with no open span is a
      # best-effort no-op → 204 (never an error — telemetry must not surface as a
      # failure to the caller).
      def close
        event = AtomicEvent.close_event!(
          session_id:      close_params[:session_id],
          agent:           close_params[:agent],
          outcome_slug:    close_params[:outcome],
          key_method:      close_params[:key_method],
          key_method_lang: close_params[:key_method_lang]
        )
        return head :no_content if event.nil?

        render_data(event, status: :ok)
      end

      # POST /api/v1/atomic_events/close_all
      #
      # Session-end teardown (behind `bin/atomic-event close-open` + the Claude Code
      # SessionEnd hook): close EVERY still-open span for the session with a shared
      # generic outcome, so a session's last span never hangs open forever. Returns
      # 200 with the count closed, or a 204 no-op when nothing was open (never an
      # error — a session teardown must not surface as a failure to the caller).
      def close_all
        count = AtomicEvent.close_all_open!(
          session_id:   close_all_params[:session_id],
          outcome_slug: close_all_params[:outcome]
        )
        return head :no_content if count.zero?

        render_data({ closed: count }, status: :ok)
      end

      private

      def open_params
        params.permit(
          :session_id,     # required — the session this span belongs to
          :category,       # required — Explore | Edit | Verify | … (AtomicEvent::CATEGORIES)
          :reason,         # required — "what am I doing" (stored as reason_slug)
          :task_slug,      # optional slug FK; null for pre-task spans
          :mascot,         # optional STABLE base session Pokémon slug
          :stage,          # optional coarse task stage at open time
          :agent,          # optional acting soul (AtomicEvent::SOULS); unknown → nil
          :prior_outcome,  # optional — "what happened" on the auto-closed prior span
          :prior_key_method,      # optional — the completed span's load-bearing call
          :prior_key_method_lang  # optional badge language; inferred when blank
        )
      end

      def close_params
        params.permit(
          :session_id, # required — the session whose open span to close
          :agent,      # optional acting soul — selects the LANE to close (unknown → nil lane)
          :outcome,    # optional — "what happened" (stored as outcome_slug)
          :key_method,      # optional — the span's load-bearing call
          :key_method_lang  # optional badge language; inferred when blank
        )
      end

      def close_all_params
        params.permit(
          :session_id, # required — the session whose open spans to close
          :outcome     # optional — shared teardown outcome (e.g. "session ended")
        )
      end
    end
  end
end
