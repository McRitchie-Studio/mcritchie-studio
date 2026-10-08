module Api
  module V1
    # The per-TASK REVIEW claim sink — at most one live pr-review session per
    # submitted task. A launching pr-review session `acquire`s the task it picked
    # (from GET /api/v1/tasks?stage=submitted&reviewable=1); if a DIFFERENT live
    # instance already holds it, the response says so and the caller SKIPS to the
    # next task. `renew` is the review's heartbeat, `release` the clean drop when the
    # review lands. The role-lease (DevopsShiftsController) one level down: lane →
    # task. Authed like the rest of the API (Bearer).
    class TaskReviewClaimsController < BaseController
      require_task_scope only: [:acquire, :renew, :release]

      # GET /api/v1/tasks/:slug/review_claim — the "who (if anyone) is reviewing
      # this task" read (CLI `status`, dashboard). 200 { holder: <info> | null };
      # `holder` is null when no claim row exists yet. Mirrors the DevopsShift index
      # read one granularity down.
      def show
        render_data({ "holder" => TaskReviewClaim.status_for(params[:slug]) })
      end

      # POST /api/v1/tasks/:slug/review_claim { session, nonce, label, reviewer }
      #
      # Atomic take-or-skip. Always 200 with { acquired, disposition, holder } —
      # `acquired:false` (a live reviewer) is a normal outcome, not an error; the
      # caller branches on the flag. The holder block powers the skip message.
      #
      # A claim taken with the machine credential also logs the reviewer in:
      # `agent_session` carries the review_claim session and its token, or null when
      # the reviewer has no review login to the task. A caller that already holds a
      # session gets no login: a session cannot mint a session.
      def acquire
        outcome = TaskReviewClaim.acquire(
          task_slug: params[:slug],
          session:   claim_params[:session],
          nonce:     claim_params[:nonce],
          label:     claim_params[:label],
          reviewer:  claim_params[:reviewer],
          mint_session: current_agent_session.nil?
        )
        render_data({
          "acquired"    => outcome.acquired,
          "disposition" => outcome.disposition.to_s,
          "holder"      => outcome.claim.holder_info,
          "agent_session" => login_json(outcome)
        })
      end

      # POST /api/v1/tasks/claim_next_review { session, nonce, label }
      #
      # The ATOMIC review pop (relocate-review-selection-to-server) — a COLLECTION
      # action (no slug: the SERVER picks WHICH task). Claims the single
      # highest-ranked reviewable task whose PR CI has concluded GREEN and stamps the
      # review lease on it, one authoritative server decision replacing bin/pr-review's
      # client-side reviewable-list → per-PR `gh` CI read → per-task acquire loop.
      #
      # Always 200. On a claim: { claimed: <task>, disposition, holder }. When nothing
      # is eligible (no reviewable task, or none green): { claimed: null, reason }. An
      # empty pop is a NORMAL outcome, not an error — the caller idles, it does not
      # retry-storm. The write is wrapped in rescue_and_log (backend discipline): a
      # failure lands in ErrorLog before the Layer-1 500, rather than escaping unlogged.
      def claim_next
        result = nil
        rescue_and_log do
          result = Task.claim_next_review(
            session:  claim_params[:session],
            nonce:    claim_params[:nonce],
            label:    claim_params[:label],
            reviewer: claim_params[:reviewer],
            mint_session: current_agent_session.nil?
          )
        end

        if result.claimed?
          render_data({
            "claimed"     => claimed_task_json(result.task),
            "disposition" => result.outcome.disposition.to_s,
            "holder"      => result.outcome.claim.holder_info,
            "agent_session" => login_json(result.outcome)
          })
        else
          # `blind_repos` rides the empty pop so the caller can tell a WIRING GAP
          # from a red build: these repos deliver no Actions runs to the board at
          # all, so their PRs can never read green here no matter what GitHub says.
          render_data({ "claimed" => nil, "reason" => result.reason.to_s,
                        "blind_repos" => result.blind_repo_list,
                        "skipped_ci" => result.skipped_ci_list })
        end
      end

      # POST /api/v1/tasks/:slug/review_claim/renew { session, nonce } — the
      # heartbeat. 200 { renewed: true, state: "renewed"|"reacquired", holder: … } when
      # this instance holds the review after the call. A lapse the caller can heal
      # re-acquires and answers 200. Otherwise 409 with the reason
      # (#render_claim_refusal), which is the detached renewer's stop signal.
      def renew
        outcome = TaskReviewClaim.renew(task_slug: params[:slug], session: claim_params[:session],
                                        nonce: claim_params[:nonce])
        return render_claim_refusal("renewed", outcome) unless outcome.renewed?

        render_data({ "renewed" => true, "state" => outcome.state.to_s,
                      "holder" => outcome.claim&.holder_info })
      end

      # POST /api/v1/tasks/:slug/review_claim/release { session, nonce } — the clean
      # review-end drop (frees the task without waiting out the TTL). 200 with the
      # state when the holder released it: "released", or "released_lapsed" when the
      # lease had already lapsed and the task was free for a window. Otherwise 409
      # with the reason (#render_claim_refusal); nothing is written.
      def release
        outcome = TaskReviewClaim.release(task_slug: params[:slug], session: claim_params[:session],
                                          nonce: claim_params[:nonce])
        return render_claim_refusal("released", outcome) unless outcome.released?

        render_data({ "released" => true, "state" => outcome.state.to_s })
      end

      private

      # A renew or release that changed nothing: 409 saying which of the two cases
      # it is, with the claim's holder block (null when the task has no claim row).
      # `held_by_other` has somebody to ask; `no_lease` means the caller holds
      # nothing here, whoever held it last.
      def render_claim_refusal(verb, outcome)
        held = outcome.state == :held_by_other
        reason = held ? "another live session holds this task's review" : "this session holds no review lease on this task"
        render json: {
          error: "review lease not #{verb}: #{reason}",
          error_code: held ? "REVIEW_CLAIM_HELD_BY_OTHER" : "REVIEW_CLAIM_NO_LEASE",
          state: outcome.state.to_s,
          holder: outcome.claim&.holder_info
        }, status: :conflict
      end

      # The login a claim minted, with its token; nil when it minted none.
      def login_json(outcome)
        session = outcome.agent_session
        session && session.summary.merge("token" => session.token)
      end

      # The claimed task's identity + review handles for the CLI/UI — the slug the
      # caller reviews next, plus the PR/branch it lands on.
      def claimed_task_json(task)
        {
          "slug"   => task.slug,
          "title"  => task.title,
          "stage"  => task.stage,
          "pr_url" => task.devops_url("pr"),
          "branch" => task.devops_field("branch")
        }
      end

      def claim_params
        params.permit(:slug, :session, :nonce, :label, :reviewer)
      end
    end
  end
end
