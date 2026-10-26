module Api
  module V1
    # The agent mailbox over the board API (docs/agents/system/agent-message-loop.md):
    # what `bin/dispatcher` and `bin/heartbeat` claim, renew and complete, and what
    # `bin/agent-inbox` reads.
    #
    #   GET  /api/v1/agent_messages            list (soul, status, channel, since, limit)
    #   GET  /api/v1/agent_messages/next       the message a claim would take now; writes nothing
    #   GET  /api/v1/agent_messages/:id        one message with its event timeline
    #   POST /api/v1/agent_messages/claim      { soul | souls[], worker, channel?, wait? } -> the claimed message or null
    #   GET  /api/v1/agent_messages/:id/context?worker=W  the holder's context bundle (AgentMessages::MemoryBundle),
    #                                             with the message's files as expiring URLs (`attachments`)
    #   POST /api/v1/agent_messages/:id/complete { worker, response_text, action_summary?,
    #                                             claude_session_id?, claude_cwd?, reasoning?, run_meta?,
    #                                             notes? }  notes: facts about the sender, filed under the message's author
    #   POST /api/v1/agent_messages/:id/release  { worker, reason?, code? }   code usage_limit refunds the attempt
    #   POST /api/v1/agent_messages/:id/renew    { worker }                   the holder extends its lease
    #   POST /api/v1/agent_messages/:id/typing   { worker }                   the holder asks for one "typing…" pulse
    #
    # LONG POLL. A claim with `wait` (seconds, capped at WAIT_CAP) holds the
    # request until a claimable message exists, retrying the claim every
    # POLL_INTERVAL, and answers data null at the deadline. THREAD COST: the
    # request occupies one puma thread for up to WAIT_CAP. Production runs
    # WEB_CONCURRENCY 2 x RAILS_MAX_THREADS 3 = 6 threads, and one bin/dispatcher
    # holds one of them nearly always, so a second dispatcher is the most this
    # should carry. Each tick is one short claim transaction; nothing is held
    # between ticks but the request thread. WAIT_CAP stays well under Heroku's
    # 30-second router timeout.
    #
    # AUTH is the board's, unchanged (BaseController): an agent session or the
    # shared secret's token. A SESSION acts only for its own soul: an admin session
    # (Steffon, Alex) may act for any soul, any other session only for the soul it
    # names. A client session and a harness key reach none of this. The shared
    # token carries no soul, so the `soul` it sends is the actor, exactly as every
    # other board write records it (session_actor).
    class AgentMessagesController < BaseController
      # The context bundle's file URLs (AgentMessages::Attachments.for_worker) on a
      # Disk service need the request's host; R2 URLs do not.
      include ActiveStorage::SetCurrent

      before_action :load_message, only: [ :show, :context, :complete, :release, :renew, :typing ]
      before_action :require_soul_scope!, only: [ :next_message, :claim, :context, :complete, :release, :renew, :typing ]

      LIST_LIMIT = 200
      WAIT_CAP = 20
      POLL_INTERVAL = 1
      # Tests replace this to make arrival and timeout deterministic.
      class_attribute :long_poll_sleeper, default: ->(seconds) { sleep(seconds) }

      def index
        scope = AgentMessage.newest_first
        scope = scope.for_soul(params[:soul]) if params[:soul].present?
        scope = scope.with_status(params[:status]) if params[:status].present?
        scope = scope.on_channel(params[:channel]) if params[:channel].present?
        scope = scope.where("updated_at > ?", Time.zone.parse(params[:since])) if params[:since].present?
        limit = params[:limit].to_i.clamp(1, LIST_LIMIT) if params[:limit].present?
        render_data(scope.limit(limit || 50).map(&:as_api_json))
      end

      def show
        render_data(@message.as_api_json(events: true))
      end

      def next_message
        message = AgentMessage.claimable(soul: acting_soul, channel: params[:channel].presence).first
        render_data(message&.as_api_json)
      end

      # Always 200: an empty claim (data null, reason nothing_waiting) is the
      # normal idle answer, so a polling worker never mistakes it for an error.
      def claim
        wait = params[:wait].to_f.clamp(0, WAIT_CAP)
        # A standby dispatcher claims nothing while a primary is live, and then
        # only its standby domains' souls (AgentDispatcher.claim_scope). Its
        # empty answer is immediate: a standby never holds a long poll.
        souls, standby_reason = AgentDispatcher.claim_scope(params[:worker], acting_souls)
        if standby_reason
          return render_data(nil, meta: { reason: standby_reason, waited: false })
        end

        deadline = Time.current + wait
        result = nil
        loop do
          result = guarded do
            AgentMessage.claim!(soul: souls, worker: params[:worker], channel: params[:channel].presence,
                                actor: claim_actor)
          end
          return if performed?
          break if result.message || Time.current >= deadline

          long_poll_sleeper.call([ POLL_INTERVAL, deadline - Time.current ].min)
        end

        render_data(result.message&.as_api_json, meta: { reason: result.reason, waited: wait.positive? })
      end

      def renew
        guarded(target: @message) do
          @message.renew!(worker: params[:worker], actor: session_actor(acting_soul))
        end
        return if performed?

        render_data(@message.reload.as_api_json)
      end

      # One "typing…" pulse in the message's channel, as the bot that will reply
      # (AgentMessageTypingJob). HOLDER-ONLY (409 NOT_HOLDER). Otherwise always
      # 200: meta.typing is "queued", or why no pulse was sent ("not_typing_channel",
      # "not_answered", "capped"), and bin/dispatcher stops pulsing that run on
      # anything but "queued". The Discord call runs on the job, so a slow
      # Discord never holds the dispatcher's main loop. `phase` (optional) is a
      # web chat run's thinking or typing; anything else, or none, is typing
      # (AgentMessage.typing_phase).
      def typing
        refusal = @message.typing_refusal(worker: params[:worker])
        if refusal == "not_holder"
          return render_refusal(AgentMessage::Refused.new(
            "message #{@message.id} is #{@message.status}; only the worker holding the claim may show typing for it",
            code: "NOT_HOLDER"
          ))
        end

        if refusal.nil?
          AgentMessageTypingJob.perform_later(@message.id, params[:worker].to_s.strip,
                                              AgentMessage.typing_phase(params[:phase]))
        end
        render_data({ "id" => @message.id }, meta: { typing: refusal || "queued" })
      end

      # The memory the holder answers from: the sender's exchanges with this soul
      # on every channel, the thread being answered, the summary of older turns and
      # the notes about the sender. HOLDER-ONLY (409 otherwise): the bundle carries other messages'
      # text, so only the worker answering this one may read it.
      def context
        unless @message.claimed? && @message.claimed_by.present? && @message.claimed_by == params[:worker].to_s.strip
          return render_refusal(AgentMessage::Refused.new(
            "message #{@message.id} is #{@message.status}; only the worker holding the claim may read its context",
            code: "NOT_HOLDER"
          ))
        end

        render_data(AgentMessages::MemoryBundle.new(@message).bundle)
      end

      def complete
        outcome = guarded(target: @message) do
          @message.complete!(worker: params[:worker], response_text: params[:response_text],
                             action_summary: params[:action_summary], actor: session_actor(acting_soul),
                             run: run_params, notes: notes_param, proposal: proposal_param)
        end
        return if performed?

        render_data(@message.reload.as_api_json, meta: { outcome: outcome.to_s })
      end

      def release
        guarded(target: @message) do
          @message.release!(worker: params[:worker], reason: params[:reason], code: params[:code],
                            actor: session_actor(acting_soul))
        end
        return if performed?

        render_data(@message.reload.as_api_json)
      end

      private

      # What the answering Claude run reported (AgentMailbox::ClaudeRun): all optional.
      def run_params
        meta = params[:run_meta]
        meta = meta.respond_to?(:to_unsafe_h) ? meta.to_unsafe_h : {}
        { claude_session_id: params[:claude_session_id], claude_cwd: params[:claude_cwd],
          reasoning: params[:reasoning], run_meta: meta }
      end

      # The facts the run returned about the sender: strings only, at most
      # NOTES_PARAM_CAP of them before the model's own cap and checks.
      NOTES_PARAM_CAP = 10

      def notes_param
        raw = params[:notes]
        raw.is_a?(Array) ? raw.select { |n| n.is_a?(String) }.first(NOTES_PARAM_CAP) : []
      end

      # The proposal the worker split off (AgentMailbox::ProposalBlock), a plain
      # object, or nil. Only parsed here: AgentProposal.record_from! validates it.
      def proposal_param
        raw = params[:proposal]
        raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.deep_stringify_keys : nil
      end

      def load_message
        @message = AgentMessage.find(params[:id])
      end

      # The soul this call acts for: the message's own on a member route, else the
      # `soul` param.
      def acting_soul
        @message ? @message.soul_slug.to_s : Task.canonical_soul(params[:soul])
      end

      # Every soul this call acts for: the message's own on a member route, else
      # `souls` (an array, or one comma-separated string) plus `soul`.
      def acting_souls
        return [ acting_soul ].reject(&:empty?) if @message

        listed = params[:souls].is_a?(Array) ? params[:souls] : params[:souls].to_s.split(",")
        # A retired slug claims for its successor (Task::SOUL_ALIASES): a
        # dispatcher still running a pre-rename config asks for `xan` and is
        # handed the `alex` rows, so no message waits on a soul nobody serves.
        (listed.map { |s| Task.canonical_soul(s) } + [ Task.canonical_soul(params[:soul]) ]).reject(&:empty?).uniq
      end

      # A single-soul claim keeps its actor as before; a multi-soul claim records
      # each message's own soul (AgentMessage.claim!) unless a session names one.
      def claim_actor
        souls = acting_souls
        souls.one? ? session_actor(souls.first) : current_agent_session&.soul
      end

      def require_soul_scope!
        souls = acting_souls
        if souls.empty?
          return render_error("soul is required", status: :unprocessable_entity, error_code: "SOUL_REQUIRED")
        end

        session = current_agent_session
        return if session.nil? || session.admin?

        foreign = souls.reject { |soul| Task.canonical_soul(session.soul) == Task.canonical_soul(soul) }
        return if foreign.empty?

        render_session_refusal("#{session.soul}'s #{session.tier} session cannot act for #{foreign.join(', ')}; " \
                               "a session acts only for its own soul (an admin session for any)")
      end

      # A write under rescue_and_log, with the model's REFUSALS (not the holder,
      # nothing to say) answered as 409/422 and kept out of the error log: a
      # refusal is the guard working, not a fault. rescue_and_log re-raises
      # anything else for the base controller to answer.
      def guarded(target: nil)
        refusal = nil
        value = rescue_and_log(target: target) do
          yield
        rescue AgentMessage::Refused => e
          refusal = e
          nil
        end
        render_refusal(refusal) if refusal
        value
      end

      def render_refusal(error)
        status = error.code == "NOT_HOLDER" ? :conflict : :unprocessable_entity
        render_error(error.message, status: status, error_code: error.code)
      end
    end
  end
end
