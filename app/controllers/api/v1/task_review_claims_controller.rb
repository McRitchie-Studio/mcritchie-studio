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
      # GET /api/v1/tasks/:slug/review_claim — the "who (if anyone) is reviewing
      # this task" read (CLI `status`, dashboard). 200 { holder: <info> | null };
      # `holder` is null when no claim row exists yet. Mirrors the DevopsShift index
      # read one granularity down.
      def show
        render_data({ "holder" => TaskReviewClaim.status_for(params[:slug]) })
      end

      # POST /api/v1/tasks/:slug/review_claim { session, nonce, label }
      #
      # Atomic take-or-skip. Always 200 with { acquired, disposition, holder } —
      # `acquired:false` (a live reviewer) is a normal outcome, not an error; the
      # caller branches on the flag. The holder block powers the skip message.
      def acquire
        outcome = TaskReviewClaim.acquire(
          task_slug: params[:slug],
          session:   claim_params[:session],
          nonce:     claim_params[:nonce],
          label:     claim_params[:label]
        )
        render_data({
          "acquired"    => outcome.acquired,
          "disposition" => outcome.disposition.to_s,
          "holder"      => outcome.claim.holder_info
        })
      end

      # POST /api/v1/tasks/:slug/review_claim/renew { session, nonce } — the
      # heartbeat. 200 { renewed: true } when this instance still holds the review;
      # 204 no-op otherwise (lost/expired/never-held — never an error).
      def renew
        ok = TaskReviewClaim.renew(task_slug: params[:slug], session: claim_params[:session], nonce: claim_params[:nonce])
        return head :no_content unless ok

        render_data({ "renewed" => true })
      end

      # POST /api/v1/tasks/:slug/review_claim/release { session, nonce } — the clean
      # review-end drop (frees the task without waiting out the TTL). 200 when the
      # holder released it; 204 no-op when a non-holder asked (never an error).
      def release
        ok = TaskReviewClaim.release(task_slug: params[:slug], session: claim_params[:session], nonce: claim_params[:nonce])
        return head :no_content unless ok

        render_data({ "released" => true })
      end

      private

      def claim_params
        params.permit(:slug, :session, :nonce, :label)
      end
    end
  end
end
