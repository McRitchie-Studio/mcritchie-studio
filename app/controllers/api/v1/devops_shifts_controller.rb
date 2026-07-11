module Api
  module V1
    # The DevOps SHIFT lease sink — at most one live conductor per role lane
    # (avi/steffon/alex). A launching devops session `acquire`s its lane; if a
    # DIFFERENT live instance already holds it, the response says so and the SOP tells
    # the caller to stand down. `renew` is the heartbeat, `release` the clean drop,
    # `index` the "who's on shift" read. Authed like the rest of the API (Bearer).
    class DevopsShiftsController < BaseController
      # GET /api/v1/devops_shifts — every lane's current holder (dashboard + CLI status).
      def index
        render_data(DevopsShift.status)
      end

      # POST /api/v1/devops_shifts/acquire { lane, session, nonce, label }
      #
      # Atomic take-or-stand-down. Always 200 with { acquired, disposition, holder } —
      # `acquired:false` (a live holder) is a normal outcome, not an error; the caller
      # branches on the flag. The holder block powers the step-down message.
      def acquire
        outcome = DevopsShift.acquire(
          lane:    shift_params[:lane],
          session: shift_params[:session],
          nonce:   shift_params[:nonce],
          label:   shift_params[:label]
        )
        render_data({
          "acquired"    => outcome.acquired,
          "disposition" => outcome.disposition.to_s,
          "holder"      => outcome.shift.holder_info
        })
      end

      # POST /api/v1/devops_shifts/renew { lane, session, nonce } — the heartbeat.
      # 200 { renewed: true } when this instance still holds the lane; 204 no-op
      # otherwise (lost/expired/never-held — never an error).
      def renew
        ok = DevopsShift.renew(lane: shift_params[:lane], session: shift_params[:session], nonce: shift_params[:nonce])
        return head :no_content unless ok

        render_data({ "renewed" => true })
      end

      # POST /api/v1/devops_shifts/release { lane, session, nonce } — the clean
      # session-end drop (frees the lane without waiting out the TTL). 200 when the
      # holder released it; 204 no-op when a non-holder asked (never an error).
      def release
        ok = DevopsShift.release(lane: shift_params[:lane], session: shift_params[:session], nonce: shift_params[:nonce])
        return head :no_content unless ok

        render_data({ "released" => true })
      end

      private

      def shift_params
        params.permit(:lane, :session, :nonce, :label)
      end
    end
  end
end
