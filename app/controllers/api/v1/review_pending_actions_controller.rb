module Api
  module V1
    # The ARMED MERGE sink — where a reviewer writes down a merge-ready verdict it
    # has already recorded, so the merge can finish executing after the reviewer's
    # process is gone. See ReviewPendingAction for the failure this exists for.
    #
    # Nothing here decides anything. `create` refuses outright unless a
    # `merge-ready` scout report is already on the task (ReviewPendingAction.arm!
    # raises Unauthorised), and `execute` runs the same fail-closed executor the
    # webhook runs. A caller cannot talk this endpoint into a merge no reviewer
    # authorised. Authed like the rest of the API (Bearer).
    class ReviewPendingActionsController < BaseController
      # GET /api/v1/review_pending_actions[?state=pending&task_slug=…]
      #
      # The operator's read: what is armed right now, pinned to what, expiring
      # when. Defaults to the live ones — the question anyone actually asks.
      def index
        scope = ReviewPendingAction.all
        scope = scope.where(state: params[:state].presence || ReviewPendingAction::PENDING) unless params[:state] == "all"
        scope = scope.where(task_slug: params[:task_slug]) if params[:task_slug].present?
        render_data(scope.recent_first.limit(100).map { |action| action_json(action) })
      end

      # POST /api/v1/tasks/:slug/review_pending_action
      #   { head_sha, pr_number, repo, pr_url, base_branch, merge_method, agent, ttl_hours }
      #
      # ARM. 201 with the recorded action, and the retry chain started. 422 when no
      # merge-ready verdict is on the record — the "never invent a verdict" rule,
      # answered as a refusal rather than a silently-created row.
      def create
        task = Task.find_by(slug: params[:slug])
        return render_error("task not found: #{params[:slug]}", status: :not_found) unless task

        head_sha = arm_params[:head_sha].to_s.strip
        return render_error("head_sha is required — the verdict pins a tree", status: :unprocessable_entity) if head_sha.blank?

        pr_number = resolve_pr_number(task)
        return render_error("could not resolve a PR number for #{task.slug}", status: :unprocessable_entity) if pr_number.blank?

        repo = arm_params[:repo].presence || Array(task.devops_repositories).first
        if repo.blank?
          return render_error("could not resolve a repo for #{task.slug} — pass repo explicitly",
                              status: :unprocessable_entity)
        end

        # THE "never invent a verdict" REFUSAL, answered before the write path so a
        # routine unauthorised arm is a clean 422 and not an ErrorLog entry.
        unless ReviewPendingAction.authorising_verdict_for(task)
          return render_error(
            "no recorded #{ReviewPendingAction::AUTHORISING_VERDICT} scout report on #{task.slug} — " \
            "record the review verdict before arming its merge",
            status: :unprocessable_entity
          )
        end

        action = nil
        rescue_and_log(target: task) do
          action = ReviewPendingAction.arm!(
            task:          task,
            repo:          repo,
            pr_number:     pr_number,
            head_sha:      head_sha,
            pr_url:        arm_params[:pr_url].presence || task.devops_url("pr"),
            base_branch:   arm_params[:base_branch].presence || "accepted",
            merge_method:  arm_params[:merge_method].presence || "merge",
            authorized_by: arm_params[:agent].presence,
            ttl:           resolved_ttl
          )
        end

        # Start the ONE retry chain. Also covers the ordering the webhook cannot:
        # CI that settled green BEFORE the arm will never deliver again, so this
        # first run is the only thing that will ever notice it.
        ReviewPendingActionExecutionJob.perform_later(action.id, recheck: true)

        render_data(action_json(action), status: :created)
      rescue ReviewPendingAction::Unauthorised => e
        render_error(e.message, status: :unprocessable_entity)
      end

      # POST /api/v1/tasks/:slug/review_pending_action/execute
      #
      # The MANUAL executor — "run the recorded decision now". One command for an
      # operator or a passing agent, and the same guards as every other path: it
      # can only do what the reviewer already authorised.
      def execute
        action = live_action
        return render_error("no armed merge for #{params[:slug]}", status: :not_found) unless action

        result = Review::PendingActionExecutor.call(action)
        render_data(action_json(action.reload).merge(
                      "result" => result.status.to_s,
                      "reason" => result.reason
                    ))
      end

      # DELETE /api/v1/tasks/:slug/review_pending_action — DISARM. The withdraw
      # path: a reviewer or operator who changes their mind cancels the standing
      # order rather than racing the executor to it.
      def destroy
        action = live_action
        return render_error("no armed merge for #{params[:slug]}", status: :not_found) unless action

        rescue_and_log(target: action) do
          action.settle!(state: ReviewPendingAction::DISARMED,
                         reason: disarm_reason)
        end
        render_data(action_json(action))
      end

      private

      def live_action
        ReviewPendingAction.pending.where(task_slug: params[:slug]).recent_first.first
      end

      def disarm_reason
        arm_params[:reason].presence || "disarmed via the API"
      end

      # The PR number, from an explicit param or parsed off the task's recorded PR
      # URL. Never guessed from anything else — an action aimed at the wrong PR is
      # the one mistake the SHA pin cannot catch.
      def resolve_pr_number(task)
        explicit = arm_params[:pr_number].to_s.strip
        return explicit.to_i if explicit.match?(/\A\d+\z/)

        task.devops_url("pr").to_s[%r{/pull/(\d+)}, 1]&.to_i
      end

      def resolved_ttl
        hours = arm_params[:ttl_hours].to_f
        return ReviewPendingAction::DEFAULT_TTL unless hours.positive?

        [hours, 24].min.hours
      end

      def action_json(action)
        {
          "id"            => action.id,
          "task_slug"     => action.task_slug,
          "action"        => action.action,
          "repo"          => action.repo,
          "pr_number"     => action.pr_number,
          "pr_url"        => action.pr_url,
          "head_sha"      => action.head_sha,
          "base_branch"   => action.base_branch,
          "verdict"       => action.verdict,
          "authorized_by" => action.authorized_by,
          "state"         => action.state,
          "expires_at"    => action.expires_at&.utc&.iso8601,
          "executed_at"   => action.executed_at&.utc&.iso8601,
          "attempts"      => action.attempts,
          "merge_sha"     => action.merge_sha,
          "reason"        => action.outcome_reason
        }
      end

      def arm_params
        params.permit(:slug, :head_sha, :pr_number, :repo, :pr_url, :base_branch,
                      :merge_method, :agent, :ttl_hours, :reason)
      end
    end
  end
end
