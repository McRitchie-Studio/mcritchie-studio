module Admin
  # Admin in-wallet signing module (v1). Productizes Jasper's proven throwaway
  # cosign tool: build a turf-vault instruction server-side, Borsh-encode + Mason-
  # partial-sign it in Ruby, and serve a Phantom page where the operator's wallet
  # (Alex 7ZDJ) adds the second signature and broadcasts. The server never holds
  # the human key and never broadcasts.
  #
  # v1 surface = turf-vault `update_signers` (the leaked-Alex-Bot rotation). The
  # SigningRequest object is generic; `initialize` (Phase 3) is a TODO factory.
  #
  # Routes (admin-gated):
  #   GET  /admin/signing/:instruction        -> show  (the signing page)
  #   POST /admin/signing/:instruction/build  -> build (fresh partial-signed tx)
  #   POST /admin/signing/:instruction/rpc    -> rpc   (JSON-RPC proxy to Helius)
  class SigningController < ApplicationController
    before_action :require_admin
    before_action :load_signing_request

    # Same-origin JSON endpoints called by the signing page's fetch(). Admin-gated;
    # /rpc is a read proxy and /build returns only a Mason-partial-signed tx that is
    # useless without the operator's Phantom signature. The layout now renders
    # csrf_meta_tags so the page's X-CSRF-Token is populated, but we keep this skip as
    # belt-and-suspenders for these JSON-only admin endpoints (no browser form posts
    # them, and a token-plumbing regression must not break operator signing).
    skip_before_action :verify_authenticity_token, only: %i[build rpc]

    # Whitelist of instructions this module can sign. v1 = update_signers only.
    SUPPORTED = {
      "update_signers" => ->(cluster) { Signing::SigningRequest.update_signers(cluster: cluster) }
      # TODO(v2/Phase 3): "initialize" => ->(cluster) { ... }
    }.freeze

    def show
      @cosigner_configured = Signing::Cosigner.configured?
      @rpc_configured = Signing::Rpc.configured?(cluster)
    end

    # Build a FRESH Mason-partial-signed tx (current blockhash). Returns the
    # half-signed VersionedTransaction base64 — the Phantom (7ZDJ) signature
    # slot is an empty placeholder. Called for both Simulate and Sign.
    def build
      rescue_and_log do
        cosigner_keypair = Signing::Cosigner.load!(@signing_request.cosigner)
        blockhash = latest_blockhash!
        tx_base64 = @signing_request.build_partial_signed_base64(
          cosigner_keypair: cosigner_keypair,
          blockhash: blockhash
        )
        render json: {
          txBase64: tx_base64,
          blockhash: blockhash,
          cluster: cluster,
          programId: @signing_request.program_id,
          expectedSigner: @signing_request.expected_signer
        }
      end
    rescue Signing::Cosigner::MissingKey, Signing::Cosigner::PubkeyMismatch => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue Signing::Rpc::MissingUrl, Signing::Rpc::WrongCluster => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Same-origin JSON-RPC proxy to the cluster's Helius endpoint. The API key
    # stays server-side; the page never sees the upstream URL.
    def rpc
      body = request.body.read
      status, upstream = Signing::Rpc.forward(cluster, body)
      render json: upstream, status: status
    rescue Signing::Rpc::MissingUrl, Signing::Rpc::WrongCluster => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    # Devnet by default; ?cluster=mainnet to target the mainnet program.
    def cluster
      @cluster ||= (params[:cluster].presence || "devnet").to_s
    end

    def load_signing_request
      builder = SUPPORTED[params[:instruction].to_s] or
        return render(plain: "Unsupported instruction: #{params[:instruction]}", status: :not_found)
      @signing_request = builder.call(cluster)
    end

    # Fetch a recent blockhash from the live RPC (through our own proxy logic).
    def latest_blockhash!
      body = { jsonrpc: "2.0", id: 1, method: "getLatestBlockhash",
               params: [{ commitment: "confirmed" }] }.to_json
      status, raw = Signing::Rpc.forward(cluster, body)
      json = JSON.parse(raw)
      bh = json.dig("result", "value", "blockhash")
      raise "getLatestBlockhash failed (status #{status}): #{raw[0, 200]}" if bh.blank?
      bh
    end
  end
end
