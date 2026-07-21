module Api
  module V1
    # The per-RELEASE conductor claim sink — at most one live conductor per (release,
    # role). A launching `bin/release prepare` acquires the `assembler` claim for the
    # release it is assembling; a launching `bin/release ship` acquires the `deployer`
    # claim for the current release. If a DIFFERENT live instance already holds the
    # (release, role), the response says so and the caller STANDS DOWN. `renew` is the
    # run's heartbeat, `release` the clean drop on completion. This replaces the
    # per-ROLE DevOps shift (DevopsShiftsController) for the two release-lifecycle acts:
    # the lock now lives on the RELEASE record, which turns over each release, so a
    # stale claim can never strand a global lane. Role travels in the body/param.
    # Authed like the rest of the API (Bearer).
    class ReleaseConductorClaimsController < BaseController
      # GET /api/v1/releases/:slug/conductor_claim?role=assembler — the "who (if
      # anyone) is assembling/deploying this release" read (CLI `status`, dashboard).
      # 200 { holder: <info> | null }; `holder` is null when no claim row exists yet.
      def show
        render_data({ "holder" => ReleaseConductorClaim.status_for(params[:slug], claim_params[:role]) })
      end

      # POST /api/v1/releases/:slug/conductor_claim { role, session, nonce, label }
      #
      # Atomic take-or-stand-down. Always 200 with { acquired, disposition, holder } —
      # `acquired:false` (a live holder) is a normal outcome, not an error; the caller
      # branches on the flag. A same-instance re-acquire returns acquired:true with a
      # `same_instance` disposition (an interrupted ship re-run resuming). The holder
      # block powers the stand-down message.
      def acquire
        outcome = ReleaseConductorClaim.acquire(
          release_slug: params[:slug],
          role:         claim_params[:role],
          session:      claim_params[:session],
          nonce:        claim_params[:nonce],
          label:        claim_params[:label]
        )
        render_data({
          "acquired"    => outcome.acquired,
          "disposition" => outcome.disposition.to_s,
          "holder"      => outcome.claim.holder_info
        })
      end

      # POST /api/v1/releases/:slug/conductor_claim/renew { role, session, nonce } —
      # the heartbeat. 200 { renewed: true } when this instance still holds the
      # (release, role); 204 no-op otherwise (lost/expired/never-held — never an error).
      def renew
        ok = ReleaseConductorClaim.renew(
          release_slug: params[:slug], role: claim_params[:role],
          session: claim_params[:session], nonce: claim_params[:nonce]
        )
        return head :no_content unless ok

        render_data({ "renewed" => true })
      end

      # POST /api/v1/releases/:slug/conductor_claim/release { role, session, nonce } —
      # the clean completion drop (frees the (release, role) without waiting out the
      # TTL). 200 when the holder released it; 204 no-op when a non-holder asked (never
      # an error).
      def release
        ok = ReleaseConductorClaim.release(
          release_slug: params[:slug], role: claim_params[:role],
          session: claim_params[:session], nonce: claim_params[:nonce]
        )
        return head :no_content unless ok

        render_data({ "released" => true })
      end

      private

      def claim_params
        params.permit(:slug, :role, :session, :nonce, :label)
      end
    end
  end
end
