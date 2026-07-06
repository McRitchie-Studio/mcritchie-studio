module Api
  module V1
    class AgentActionsController < BaseController
      # POST /api/v1/agent_actions
      #
      # Live-capture sink for the forward-only action log. The parallel
      # live-capture hook POSTs ONE action per request; we map the body straight
      # onto AgentAction.capture, which is forward-only AND best-effort: it writes
      # a single row and swallows any failure into an ErrorLog, returning nil.
      #
      # BEST-EFFORT contract — a capture MISS must NEVER 500 the caller. Telemetry
      # cannot be allowed to take down the work it observes, so a nil from capture
      # degrades to 204 No Content (ok, nothing persisted), and even an unexpected
      # mapping hiccup is logged and softened to 204 rather than surfaced as a 500.
      def create
        action = AgentAction.capture(capture_attributes)
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
      # DERIVES it from model + tokens + cache_read via MODEL_RATES). The generic
      # tool-call hook also leaves the event/result slugs null; the test-scope
      # telemetry path (bin/release run_test_scope → bin/atomic-event action) DOES
      # send :event_slug (the scope key) + :result_slug (pass|fail) on the verdict
      # action, so a release test run is a gradeable unit. It DOES now carry the transcript-derived
      # usage — model, the FRESH tokens (in/out), the RE-USED cache_read_tokens (for
      # cost only), and the source_turn_uuid the tokens came from. Blank scalars are
      # dropped so capture's own defaults engage (e.g. a missing occurred_at →
      # Time.current); token counts are coerced to integers.
      def capture_attributes
        attrs = capture_params
                .to_h
                .symbolize_keys
                .transform_values { |value| value.is_a?(String) ? value.presence : value }
                .compact
        %i[tokens_in tokens_out cache_read_tokens].each do |key|
          attrs[key] = attrs[key].to_i if attrs.key?(key)
        end
        attrs
      end

      def capture_params
        params.permit(
          :session_id,       # required — the session this action belongs to
          :kind,             # required — read | edit | bash | verify | delegate | test_scope | …
          :event_slug,       # optional test-scope key on a release verdict action
          :result_slug,      # optional pass | fail verdict on a test-scope run
          :task_slug,        # optional slug FK; null for pre-task actions
          :agent_activity_id, # optional deterministic activity pin from the local hook marker
          :atomic_event_id,   # compatibility alias for pre-taxonomy capture clients
          :mascot,           # optional session/task Pokémon slug
          :input,            # optional action input (prompt / command / args)
          :output,           # optional action output (result / stdout / diff)
          :summary,          # optional GOAL slug for the action (outcome-free)
          :key_method,       # optional load-bearing call (bash command / ruby call)
          :key_method_lang,  # optional badge language; inferred when blank
          :outcome,          # optional ok | error | pending (defaults pending)
          :actor,            # optional harness | agent | board | human (defaults agent)
          :model,            # optional session model id (the hook derives it; kills the "—")
          :tokens_in,        # optional FRESH input tokens (input+cache_creation) for the turn
          :tokens_out,       # optional output tokens for the source turn
          :cache_read_tokens, # optional re-used cache-read tokens (for cost only, not display)
          :source_turn_uuid, # optional assistant-turn id N actions may share (dedupe key)
          :stage,            # optional coarse task stage at capture time
          :occurred_at,      # optional ISO8601; defaults to capture time
          :duration_ms       # optional wall-clock duration
        )
      end
    end
  end
end
