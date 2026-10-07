module Api
  # The tier and scope rules an agent session carries onto the board API
  # (docs/agents/system/agent-sessions-design.md, section 5).
  #
  # A request authenticated with the shared secret's token carries no session and
  # passes every gate here unchanged: that token stays accepted for one release, and
  # BaseController logs each use as legacy. A request with a session is held to its
  # tier and its scope, and its soul is the actor:
  #
  #   require_task_scope    a task write: a studio session scoped to that task, or admin
  #   require_admin_session a release write: admin only
  #
  # Every refusal answers 403 with the reason.
  module AgentSessionGate
    extend ActiveSupport::Concern

    class_methods do
      def require_task_scope(**options)
        before_action :require_task_scope!, **options
      end

      def require_admin_session(**options)
        before_action :require_admin_session!, **options
      end
    end

    private

    def current_agent_session
      Current.agent_session
    end

    # The actor a board write records: the session's soul when a session is
    # present (the param is ignored), else the param as sent.
    def session_actor(param_value)
      current_agent_session ? current_agent_session.soul : param_value.presence
    end

    # The task the request writes. Controllers whose route names it some other way
    # override this.
    def gated_task_slug
      params[:slug].to_s
    end

    def require_task_scope!
      session = current_agent_session
      return if session.nil? || session.covers_task?(gated_task_slug)

      reason = if session.studio?
                 "agent session #{session.slug} is scoped to #{session.task_slug}, not #{gated_task_slug}"
               else
                 "a #{session.tier} session cannot write a task"
               end
      render_session_refusal(reason)
    end

    def require_admin_session!
      session = current_agent_session
      return if session.nil? || session.admin?

      render_session_refusal("this endpoint needs an admin session; #{session.soul} holds a #{session.tier} session")
    end

    def render_session_refusal(reason)
      render json: { error: reason, error_code: "SESSION_FORBIDDEN" }, status: :forbidden
    end
  end
end
