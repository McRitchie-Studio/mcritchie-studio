module Api
  module V1
    # The `backend_migration` exclusive-lane sink — "one Dev writes a migration at
    # a time" (docs/agents/system/exclusive-lanes.md).
    #
    # A SINGLETON resource, not nested under a task: the lane is global, and which
    # task holds it is a property OF the claim rather than the route. A backend Dev
    # who realizes mid-task that they need a migration acquires here before creating
    # anything in db/migrate/; a refused Dev queues and chats the holder the SOP
    # names in the response.
    #
    # Authed like the rest of the API (Bearer). The mutual exclusion itself lives in
    # MigrationLaneClaim under a unique index + row lock — this controller only
    # carries identity in and the verdict out.
    class MigrationLaneClaimsController < BaseController
      # GET /api/v1/migration_lane — "who (if anyone) holds the lane?"
      # 200 { holder: <info> | null }; `holder` is null when no claim row exists.
      # A row whose lease has LAPSED still renders, with "live" => false — the
      # caller reads `live`, not mere presence.
      def show
        render_data({ "holder" => MigrationLaneClaim.status_for })
      end

      # POST /api/v1/migration_lane { session, nonce, task_slug, agent, label }
      #
      # Atomic take-or-queue. Always 200 with { acquired, disposition, holder } —
      # `acquired:false` (a live holder) is a NORMAL outcome, not an error; the
      # caller branches on the flag and the holder block powers the queue message.
      # Wrapped in rescue_and_log (backend discipline): a failure lands in ErrorLog
      # before the Layer-1 500 rather than escaping unlogged.
      def acquire
        outcome = nil
        rescue_and_log do
          outcome = MigrationLaneClaim.acquire(
            task_slug: claim_params[:task_slug],
            session:   claim_params[:session],
            nonce:     claim_params[:nonce],
            label:     claim_params[:label],
            agent:     claim_params[:agent]
          )
        end

        render_data({
          "acquired"    => outcome.acquired,
          "disposition" => outcome.disposition.to_s,
          "holder"      => outcome.claim.holder_info
        })
      end

      # POST /api/v1/migration_lane/release { session, nonce } — the clean drop,
      # freeing the lane immediately instead of waiting out the TTL.
      #
      # 200 { released: <bool> } either way. A release by a non-holder — including
      # a task that never acquired — is a harmless `false`, because the SOP's
      # belt-and-suspenders release on shipped/blocked/archived fires whether or
      # not the lane was ever taken. Only the holder can actually free it, so a
      # queued Dev can never release a live migration out from under its author.
      def release
        released = nil
        rescue_and_log do
          released = MigrationLaneClaim.release(
            session: claim_params[:session],
            nonce:   claim_params[:nonce]
          )
        end

        render_data({ "released" => released, "holder" => MigrationLaneClaim.status_for })
      end

      private

      def claim_params
        params.permit(:session, :nonce, :task_slug, :agent, :label)
      end
    end
  end
end
