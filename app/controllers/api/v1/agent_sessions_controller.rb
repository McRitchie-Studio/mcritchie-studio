module Api
  module V1
    # Agent logins (docs/agents/system/agent-sessions-design.md).
    #
    #   POST   /api/v1/agent_sessions          studio login at a task claim
    #   GET    /api/v1/agent_sessions/current  who this bearer is logged in as
    #   DELETE /api/v1/agent_sessions/current  log out (revoke this session)
    #
    # A studio login is presented with the machine credential, which today is the
    # shared secret's token: a session cannot mint another session. The login names
    # the soul the desk commits as and the task it claimed; the task must be building
    # (task_claim) or submitted (review_claim), and the task record must entitle the
    # soul to it (AgentSession.studio_login_refusal): the builder the claim stamped,
    # or a reviewer the task names. Any other soul answers 403 with the reason. Admin
    # sessions are granted by the operator, not here.
    class AgentSessionsController < BaseController
      # The stage a task must be in for each kind of studio login.
      CLAIM_STAGES = { "task_claim" => "building", "review_claim" => "submitted" }.freeze

      def create
        if current_agent_session
          return render_session_refusal("a session cannot mint a session; log in with the machine credential")
        end

        tier = params[:tier].presence || "studio"
        unless tier == "studio"
          return render_session_refusal("#{tier} sessions are granted by the operator, not by this endpoint")
        end

        task = Task.find_by(slug: params[:task_slug].to_s)
        return render_error("task not found", status: :not_found, error_code: "NOT_FOUND") unless task

        issued_by = params[:issued_by].presence || "task_claim"
        refusal = claim_refusal(task, issued_by)
        return render_error(refusal, status: :conflict, error_code: "NOT_CLAIMABLE") if refusal

        # A soul that is no soul falls through to the model's 422; any other soul must
        # be one the task record entitles to this login.
        if AgentSession.tier_for_soul(params[:soul])
          entitlement = AgentSession.studio_login_refusal(soul: params[:soul], task: task, issued_by: issued_by)
          return render_session_refusal(entitlement) if entitlement
        end

        session = AgentSession.issue_studio!(
          soul: params[:soul].to_s, task: task, issued_by: issued_by,
          harness_session_id: params[:harness_session_id].presence
        )
        render_data(session.summary.merge("token" => session.token), status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render_error(e.record.errors.full_messages.to_sentence, status: :unprocessable_entity,
                                                                error_code: "VALIDATION_FAILED")
      end

      def show
        session = current_agent_session
        return render_data({ "session" => nil, "auth" => "legacy" }) unless session

        render_data({ "session" => session.summary, "auth" => "agent_session" })
      end

      def destroy
        session = current_agent_session
        return render_error("no agent session to log out of", status: :unprocessable_entity, error_code: "NO_SESSION") unless session

        session.revoke!(by: session.soul)
        render_data({ "session" => session.summary })
      end

      private

      def claim_refusal(task, issued_by)
        stage = CLAIM_STAGES[issued_by]
        return "issued_by must be one of #{CLAIM_STAGES.keys.join(", ")}" unless stage
        return nil if task.stage == stage

        "a #{issued_by} login needs #{task.slug} in #{stage}; it is #{task.stage}"
      end
    end
  end
end
