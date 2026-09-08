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

      # POST /api/v1/tasks/:slug/review_claim { session, nonce, label, reviewer }
      #
      # Atomic take-or-skip. Always 200 with { acquired, disposition, holder } —
      # `acquired:false` (a live reviewer) is a normal outcome, not an error; the
      # caller branches on the flag. The holder block powers the skip message.
      def acquire
        outcome = TaskReviewClaim.acquire(
          task_slug: params[:slug],
          session:   claim_params[:session],
          nonce:     claim_params[:nonce],
          label:     claim_params[:label],
          reviewer:  claim_params[:reviewer]
        )
        render_data({
          "acquired"    => outcome.acquired,
          "disposition" => outcome.disposition.to_s,
          "holder"      => outcome.claim.holder_info
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
            reviewer: claim_params[:reviewer]
          )
        end

        if result.claimed?
          render_data({
            "claimed"     => claimed_task_json(result.task),
            "disposition" => result.outcome.disposition.to_s,
            "holder"      => result.outcome.claim.holder_info
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
      # this instance holds the review after the call; 204 no-op when it does not
      # (held by another, or nothing of ours to renew — never an error).
      #
      # THE 204 IS THE DETACHED RENEWER'S STOP SIGNAL and is kept exactly where it was
      # on purpose (ReviewClaimCli#renewed? reads the code, and renewers already
      # running out in the fleet were spawned from older checkouts). What CHANGED is
      # which states reach it: a lapse the caller can heal now re-acquires and answers
      # 200, so a renewer no longer exits `:lease_lost` on its own slow beat. The two
      # states that still 204 are the two where stopping is correct.
      #
      # A bodiless 204 cannot say WHICH refusal it is, so the CLI resolves that with
      # the holder read (GET review_claim) it already owns, rather than this endpoint
      # inventing a body a 204 is not allowed to carry.
      def renew
        outcome = TaskReviewClaim.renew(task_slug: params[:slug], session: claim_params[:session],
                                        nonce: claim_params[:nonce])
        return head :no_content unless outcome.renewed?

        render_data({ "renewed" => true, "state" => outcome.state.to_s,
                      "holder" => outcome.claim&.holder_info })
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
