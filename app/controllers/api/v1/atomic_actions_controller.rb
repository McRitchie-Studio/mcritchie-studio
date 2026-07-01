module Api
  module V1
    class AtomicActionsController < BaseController
      # POST /api/v1/atomic_actions
      #
      # Live-capture sink for the forward-only atomic trajectory. The parallel
      # live-capture hook POSTs ONE action per request; we map the body straight
      # onto AtomicAction.capture, which is forward-only AND best-effort: it writes
      # a single row and swallows any failure into an ErrorLog, returning nil.
      #
      # BEST-EFFORT contract — a capture MISS must NEVER 500 the caller. Telemetry
      # cannot be allowed to take down the work it observes, so a nil from capture
      # degrades to 204 No Content (ok, nothing persisted), and even an unexpected
      # mapping hiccup is logged and softened to 204 rather than surfaced as a 500.
      def create
        action = AtomicAction.capture(capture_attributes)
        return head :no_content if action.nil?

        render_data(action, status: :created)
      rescue StandardError => e
        # capture already guards its own write; this is belt-and-suspenders so a
        # param-mapping failure still degrades to a no-op instead of erroring the hook.
        create_error_log(e)
        head :no_content
      end

      private

      # The live-capture request contract. The caller does NOT set cost (capture
      # DERIVES it from model + tokens via MODEL_RATES) or the event/result slugs
      # (those arrive null and are filled by capture's defaults + Current.task_event_*
      # fallbacks). It DOES now carry the transcript-derived usage — model, tokens,
      # and the source_turn_uuid the tokens came from. Blank scalars are dropped so
      # capture's own defaults engage (e.g. a missing occurred_at → Time.current);
      # token counts are coerced to integers.
      def capture_attributes
        attrs = capture_params
                .to_h
                .symbolize_keys
                .transform_values { |value| value.is_a?(String) ? value.presence : value }
                .compact
        attrs[:tokens_in]  = attrs[:tokens_in].to_i  if attrs.key?(:tokens_in)
        attrs[:tokens_out] = attrs[:tokens_out].to_i if attrs.key?(:tokens_out)
        attrs
      end

      def capture_params
        params.permit(
          :session_id,       # required — the session this action belongs to
          :kind,             # required — read | edit | bash | verify | delegate | …
          :task_slug,        # optional slug FK; null for pre-task actions
          :mascot,           # optional session/task Pokémon slug
          :input,            # optional action input (prompt / command / args)
          :output,           # optional action output (result / stdout / diff)
          :outcome,          # optional ok | error | pending (defaults pending)
          :actor,            # optional harness | agent | board | human (defaults agent)
          :model,            # optional session model id (the hook derives it; kills the "—")
          :tokens_in,        # optional input+cache tokens for the source turn
          :tokens_out,       # optional output tokens for the source turn
          :source_turn_uuid, # optional assistant-turn id N actions may share (dedupe key)
          :stage,            # optional coarse task stage at capture time
          :occurred_at,      # optional ISO8601; defaults to capture time
          :duration_ms       # optional wall-clock duration
        )
      end
    end
  end
end
