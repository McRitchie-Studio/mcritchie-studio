module Api
  module V1
    class AgentActivitiesController < BaseController
      # The agent-narration sink. The agent self-declares meaningful activities
      # (via `bin/agent-activity`, with `bin/atomic-event` kept as a compatibility
      # command): it OPENs an activity with a category + reason, raw tool-calls
      # attribute server-side to that open activity (see AgentAction.capture), and
      # it CLOSEs the activity with a result. One activity is open per session lane.
      #
      # Authed exactly like AgentActionsController — a Bearer api_auth token.

      # POST /api/v1/agent_activities
      #
      # Open a new activity for the session, auto-closing any prior open activity.
      # Returns 201 with the opened activity. An invalid category / blank reason is
      # a 422 (VALIDATION_FAILED) via BaseController.
      #
      # BOUNDARY transition: `prior_outcome` (from `bin/agent-activity next` /
      # `start --outcome`) stamps the auto-closed prior activity's outcome_slug as
      # the agent crosses into this one, so activities stop hanging half-narrated.
      def create
        activity = AgentActivity.open_activity!(
          session_id:         open_params[:session_id],
          category:           open_params[:category],
          reason_slug:        open_params[:reason],
          task_slug:          open_params[:task_slug],
          mascot:             open_params[:mascot],
          stage:              open_params[:stage],
          agent:              open_params[:agent],
          supervisor_agent:   open_params[:supervisor].presence || open_params[:supervisor_agent],
          prior_outcome_slug: open_params[:prior_outcome],
          prior_key_method:      open_params[:prior_key_method],
          prior_key_method_lang: open_params[:prior_key_method_lang],
          prior_model:           open_params[:prior_model],
          prior_tokens_in:       open_params[:prior_tokens_in],
          prior_tokens_out:      open_params[:prior_tokens_out],
          prior_cache_creation_tokens: open_params[:prior_cache_creation_tokens],
          prior_cache_read_tokens: open_params[:prior_cache_read_tokens],
          prior_cost:            open_params[:prior_cost]
        )
        render_data(activity, status: :created)
      end

      # POST /api/v1/agent_activities/close
      #
      # Close the session's current open activity, stamping the narrated result
      # (`outcome` maps to outcome_slug). A stray close with no open activity is a
      # best-effort no-op → 204 (never an error — telemetry must not surface as a
      # failure to the caller).
      def close
        activity = AgentActivity.close_activity!(
          session_id:      close_params[:session_id],
          agent:           close_params[:agent],
          outcome_slug:    close_params[:outcome],
          key_method:      close_params[:key_method],
          key_method_lang: close_params[:key_method_lang],
          model:           close_params[:model],
          tokens_in:       close_params[:tokens_in],
          tokens_out:      close_params[:tokens_out],
          cache_creation_tokens: close_params[:cache_creation_tokens],
          cache_read_tokens: close_params[:cache_read_tokens],
          cost:            close_params[:cost]
        )
        return head :no_content if activity.nil?

        render_data(activity, status: :ok)
      end

      # POST /api/v1/agent_activities/close_all
      #
      # Session-end teardown (behind `bin/agent-activity close-open` + the Claude Code
      # SessionEnd hook): close EVERY still-open activity for the session with a shared
      # generic result, so a session's last activity never hangs open forever. Returns
      # 200 with the count closed, or a 204 no-op when nothing was open (never an
      # error — a session teardown must not surface as a failure to the caller).
      def close_all
        count = AgentActivity.close_all_open!(
          session_id:   close_all_params[:session_id],
          outcome_slug: close_all_params[:outcome]
        )
        return head :no_content if count.zero?

        render_data({ closed: count }, status: :ok)
      end

      # POST /api/v1/agent_activities/turn_open
      #
      # NEUTRALIZED (retire-turn-auto-open-spans) — always 204, opens NO span. The
      # PreToolUse auto-open produced only noise, so agent-authored narration is the
      # primary path now; the hook + open_for_turn! + turn_open_params seam is kept
      # intact for the follow-up measure-only meter. Full why/revert in the body.
      def turn_open
        # NEUTRALIZED (retire-turn-auto-open-spans): agent-AUTHORED narration is the
        # primary path; auto-scraped preambles produced only noise ("(working)", chat
        # filler, 0 actions — see prod session 39736e86). This endpoint no longer OPENS
        # a span. The PreToolUse hook stays wired, and AgentActivity.open_for_turn! +
        # turn_open_params are left intact, so the follow-up MEASURE-ONLY compliance
        # meter can repurpose this seam to DETECT orphans (tool calls with no open
        # AUTHORED unit) instead of creating spans. Revert: restore the open_for_turn!
        # call (see git history).
        head :no_content
      end

      # GET /api/v1/agent_activities/windows?session_id=X
      #
      # The session's activity windows (id, agent lane, opened_at, closed_at, seq)
      # in chronological order — the input the local fan-out reconciler needs to
      # attribute each CHILD subagent transcript's spend to the activity that
      # authored it. Read-only; empty list for an unknown session (never an error).
      def windows
        render_data(AgentActivity.usage_windows(windows_params[:session_id]))
      end

      # POST /api/v1/agent_activities/reconcile
      #
      # Stamp the fan-out reconciler's computed per-activity usage. Body:
      #   { session_id, usages: [ { activity_id, model, tokens_in, tokens_out,
      #                             cache_creation_tokens, cache_read_tokens, cost }, … ] }
      # Each usage is applied to its activity ONLY within this session (a token can
      # never patch another session's rows). Returns the count stamped; a 204 no-op
      # when nothing matched (telemetry must not surface as a failure).
      def reconcile
        count = AgentActivity.apply_reconciled_usage!(
          session_id: reconcile_params[:session_id],
          usages:     reconcile_params[:usages] || []
        )
        return head :no_content if count.zero?

        render_data({ reconciled: count }, status: :ok)
      end

      private

      def windows_params
        params.permit(:session_id)
      end

      def reconcile_params
        params.permit(:session_id,
                      usages: %i[activity_id model tokens_in tokens_out
                                 cache_creation_tokens cache_read_tokens cost])
      end

      def turn_open_params
        params.permit(
          :session_id,    # required — the session this turn belongs to
          :turn_uuid,     # required — the assistant turn id (the idempotency key)
          :preamble,      # the turn's assistant text; split into prior outcome + reason
          :reason,        # optional explicit reason (wins over the preamble split)
          :prior_outcome, # optional explicit prior outcome (wins over the split)
          :category,      # optional category; defaults to Explore
          :mascot,        # optional STABLE base session Pokémon slug (the genesis reason)
          :task_slug,     # optional slug FK
          :stage,         # optional coarse task stage
          :agent,          # optional acting soul (the lane)
          :parent_span_id, # optional — the delegating span, for a nested subagent
          :transcript_path # the turn's transcript — the subagent-lineage key
        )
      end

      def open_params
        params.permit(
          :session_id,     # required — the session this activity belongs to
          :category,       # required — Explore | Edit | Verify | … (AgentActivity::CATEGORIES)
          :reason,         # required — "what am I doing" (stored as reason_slug)
          :task_slug,      # optional slug FK; null for pre-task activities
          :mascot,         # optional STABLE base session Pokémon slug
          :stage,          # optional coarse task stage at open time
          :agent,          # optional acting soul (AgentActivity::SOULS); unknown → nil
          :supervisor,      # optional supervisor soul (pr-review has none — Carl is primary AND owner)
          :supervisor_agent, # optional canonical supervisor field name
          :prior_outcome,  # optional — "what happened" on the auto-closed prior activity
          :prior_key_method,      # optional — the completed activity's load-bearing call
          :prior_key_method_lang, # optional badge language; inferred when blank
          :prior_model,           # optional measured model for the auto-closed prior activity
          :prior_tokens_in,       # optional fresh input tokens for the auto-closed prior activity
          :prior_tokens_out,      # optional output tokens for the auto-closed prior activity
          :prior_cache_creation_tokens, # un-folded cache WRITES — lets the server re-derive cost
          :prior_cache_read_tokens, # optional cache-read tokens for cost only
          :prior_cost             # LIST-price fallback; server re-derives when the buckets are sent
        )
      end

      def close_params
        params.permit(
          :session_id, # required — the session whose open activity to close
          :agent,      # optional acting soul — selects the LANE to close (unknown → nil lane)
          :outcome,    # optional — "what happened" (stored as outcome_slug)
          :key_method,      # optional — the activity's load-bearing call
          :key_method_lang, # optional badge language; inferred when blank
          :model,           # optional measured model for this activity
          :tokens_in,       # optional fresh input tokens for this activity
          :tokens_out,      # optional output tokens for this activity
          :cache_creation_tokens, # un-folded cache WRITES — lets the server re-derive cost
          :cache_read_tokens, # optional cache-read tokens for cost only
          :cost             # LIST-price fallback; server re-derives when the buckets are sent
        )
      end

      def close_all_params
        params.permit(
          :session_id, # required — the session whose open activities to close
          :outcome     # optional — shared teardown result (e.g. "session ended")
        )
      end
    end
  end
end
