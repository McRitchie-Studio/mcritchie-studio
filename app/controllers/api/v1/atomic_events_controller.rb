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
      def create
        event = AtomicEvent.open_event!(
          session_id:  open_params[:session_id],
          category:    open_params[:category],
          reason_slug: open_params[:reason],
          task_slug:   open_params[:task_slug],
          mascot:      open_params[:mascot],
          stage:       open_params[:stage]
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
          session_id:   close_params[:session_id],
          outcome_slug: close_params[:outcome]
        )
        return head :no_content if event.nil?

        render_data(event, status: :ok)
      end

      private

      def open_params
        params.permit(
          :session_id, # required — the session this span belongs to
          :category,   # required — Explore | Edit | Verify | … (AtomicEvent::CATEGORIES)
          :reason,     # required — "what am I doing" (stored as reason_slug)
          :task_slug,  # optional slug FK; null for pre-task spans
          :mascot,     # optional session/task Pokémon slug
          :stage       # optional coarse task stage at open time
        )
      end

      def close_params
        params.permit(
          :session_id, # required — the session whose open span to close
          :outcome     # optional — "what happened" (stored as outcome_slug)
        )
      end
    end
  end
end
