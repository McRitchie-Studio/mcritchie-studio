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
      # 200 { holder: <info> | null, release_state: <state> | null }; `holder` is null
      # when no claim row exists yet.
      #
      # `release_state` is here because the DETACHED RENEWER needs it and there is no
      # GET /api/v1/releases/:slug to ask — releases are routed `only: []`, so this
      # nested claim endpoint is the only slug-addressed release read the standalone
      # CLI has. The renewer's stop condition is "is this candidate finished", which it
      # cannot answer from the claim row alone: a claim looks identical whether the
      # release is mid-assembly or shipped an hour ago. Serving the release's own
      # lifecycle state alongside the holder lets it answer without a second endpoint.
      #
      # NULL when no release carries the slug — notably the `__forming__` sentinel, a
      # claim held while a candidate is still being created. A renewer must read that
      # as NOT finished (ReleaseClaimCli fails open on a nil/unknown state), because a
      # release that does not exist yet has certainly not ended.
      def show
        render_data({
          "holder"        => ReleaseConductorClaim.status_for(params[:slug], claim_params[:role]),
          "release_state" => Release.find_by(slug: params[:slug])&.state
        })
      end

      # GET /api/v1/release_conductor_claims/live?role=deployer — the CROSS-RELEASE "is
      # ANY claim for this role live?" read (NOT nested under a slug). bin/agent-worktree's
      # `_ship`/`_gate` reclaim guard asks this: a live `deployer` claim = a ship is in
      # progress, so those fixed-path workspaces must not be reclaimed. 200 { live: bool,
      # holder: <info>|null }.
      def live
        role = claim_params[:role]
        render_data({
          "live"   => ReleaseConductorClaim.any_live?(role: role),
          "holder" => ReleaseConductorClaim.live_holder(role: role)
        })
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

      # POST /api/v1/releases/:slug/conductor_claim/reassign
      #   { role, session, nonce, label, operator_secret }
      #
      # OPERATOR-GATED force-reassign — the escape hatch from "only a TTL lapse frees a
      # LIVE claim." Hands the (release, role) to the session asking (its session +
      # nonce) even over a live holder, so a stuck/ghost claim never strands the lane
      # for a full TTL and the next prepare/ship resumes immediately. This is NOT a
      # normal agent steal: `acquire` stands down on a live holder and always will.
      # Beyond the shared agent bearer (every agent has one), it requires the OPERATOR
      # secret — `Rails.application.credentials.operator_api_secret ||
      # ENV["OPERATOR_API_SECRET"]`. Fail-closed: with no operator secret configured the
      # override is INERT (503), so it can never be bypassed by leaving it unset. 200
      # { reassigned: true, disposition, holder } on success.
      def reassign
        unless operator_secret.present?
          return render_error("Operator override is not configured", status: :service_unavailable,
                                                                     error_code: "OPERATOR_OVERRIDE_UNCONFIGURED")
        end
        unless operator_authorized?
          return render_error("Operator authorization required", status: :forbidden,
                                                                 error_code: "OPERATOR_FORBIDDEN")
        end
        if claim_params[:session].blank? || claim_params[:nonce].blank?
          return render_error("session and nonce are required", status: :unprocessable_entity,
                                                                error_code: "VALIDATION_FAILED")
        end

        outcome = ReleaseConductorClaim.reassign(
          release_slug: params[:slug], role: claim_params[:role],
          session: claim_params[:session], nonce: claim_params[:nonce], label: claim_params[:label]
        )
        render_data({
          "reassigned"  => outcome.acquired,
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
        params.permit(:slug, :role, :session, :nonce, :label, :operator_secret)
      end

      # The operator-elevation secret — the one credential a normal agent bearer does
      # NOT carry, so it is what makes `reassign` an operator act rather than an agent
      # steal. Read from credentials first, then ENV (mirrors AuthController's
      # agent_api_secret). Blank ⇒ the override is unconfigured (the action fails closed).
      def operator_secret
        @operator_secret ||= (Rails.application.credentials.operator_api_secret.presence ||
                              ENV["OPERATOR_API_SECRET"].presence).to_s
      end

      # Constant-time compare of the provided secret against the configured one — the
      # same idiom AuthController uses for the agent secret. Never true when either side
      # is blank.
      def operator_authorized?
        provided = params[:operator_secret].to_s
        provided.present? && operator_secret.present? &&
          ActiveSupport::SecurityUtils.secure_compare(provided, operator_secret)
      end
    end
  end
end
