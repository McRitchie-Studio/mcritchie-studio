module Admin
  # v2 admin signing console — a KEYLESS coordinator. The server builds an
  # unsigned transaction, persists it as a SigningRequest, and serves a per-signer
  # page where each member signs in THEIR OWN browser/Phantom. It only ever holds
  # the unsigned message + the PUBLIC signatures, never a key, and broadcasts the
  # assembled fully-signed tx (which needs no key). Admin-gated; safe on prod.
  #
  # Two topologies, one console (see SigningRequest):
  #   single — one human wallet (e.g. turf-vault `initialize`); fresh blockhash.
  #   multi  — N wallets across separate sessions; durable nonce so the half-signed
  #            tx doesn't expire between signers.
  #
  # Supersedes the v1 Admin::SigningController (server-held Mason cosigner), which
  # can be retired once this is dogfooded on devnet.
  class SigningRequestsController < ApplicationController
    before_action :require_admin
    before_action :load_request, only: %i[show sign submit_signature broadcast rpc]
    # JSON-only endpoints called by the signer page's fetch(); admin-gated, and
    # neither mutates a key. (submit_signature only stores a PUBLIC signature.)
    skip_before_action :verify_authenticity_token, only: %i[submit_signature rpc]

    # Supported instruction templates. Each lambda builds a Signing::SigningRequest
    # (the PORO builder) from operator-supplied params. Adding a program/instruction
    # is one entry here + its IDL in the registry.
    TEMPLATES = {
      "initialize" => :build_initialize,
      "update_signers" => :build_update_signers
    }.freeze

    def index
      @requests = SigningRequest.recent.limit(100)
    end

    def new
      @templates = TEMPLATES.keys
      @clusters  = Signing::IdlRegistry.clusters_for("turf_vault")
    end

    def create
      builder = build_from_template
      cluster = builder.cluster

      blockhash =
        if builder.durable_nonce
          Signing::Rpc.nonce_value(cluster, builder.durable_nonce.fetch(:pubkey))
        else
          Signing::Rpc.latest_blockhash(cluster)
        end

      unsigned = builder.build_unsigned_message_base64(blockhash: blockhash)

      sr = SigningRequest.create!(
        title:                builder.title,
        program:              builder.program,
        program_id:           builder.program_id,
        cluster:              cluster,
        instruction_name:     builder.instruction_name,
        args:                 builder.args,
        accounts:             stringify(builder.accounts),
        coordination:         builder.coordination,
        threshold:            builder.threshold,
        expected_signers:     builder.expected_signers,
        fee_payer:            builder.fee_payer,
        durable_nonce_pubkey: builder.durable_nonce&.fetch(:pubkey),
        nonce_authority:      builder.durable_nonce&.fetch(:authority),
        unsigned_message_base64: unsigned
      )
      redirect_to admin_signing_request_path(sr), notice: "Signing request created — share a sign link with each signer."
    rescue Signing::Rpc::MissingUrl, Signing::Rpc::WrongCluster => e
      redirect_to new_admin_signing_request_path, alert: "RPC not configured: #{e.message}"
    rescue StandardError => e
      create_error_log(e)
      redirect_to new_admin_signing_request_path, alert: "Could not build request: #{e.message}"
    end

    def show
      @signers = @signing_request.expected_signers
    end

    # The per-signer Phantom page. ?signer=<pubkey> identifies which member this
    # link is for; the page refuses to proceed unless the connected wallet matches.
    def sign
      @signer = params[:signer].to_s
      unless @signing_request.expected_signers.include?(@signer)
        return redirect_to admin_signing_request_path(@signing_request), alert: "Unknown signer for this request."
      end
      @already_signed = @signing_request.signed_by?(@signer)
      @unsigned_base64 = @signing_request.unsigned_message_base64
      # The exact bytes the signer signs (a raw ed25519 sig over the tx message
      # IS a valid tx signature — proven by Signing::Assembler's round-trip test).
      @message_base64 = Base64.strict_encode64(
        Signing::Assembler.message_for(@signing_request.unsigned_message_base64)
      )
    end

    # Store ONE signer's public signature (base64). Verified ed25519 against the
    # exact message before it's trusted.
    def submit_signature
      signer = params[:signer].to_s
      sig_b64 = params[:signature].to_s

      unless valid_signature?(signer, sig_b64)
        return render json: { error: "signature does not verify for #{signer}" }, status: :unprocessable_entity
      end

      @signing_request.record_signature!(pubkey: signer, signature_b64: sig_b64)
      render json: {
        ok: true,
        signed: @signing_request.signers_signed,
        needed: @signing_request.signatures_needed,
        status: @signing_request.status
      }
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Assemble the collected public signatures into the final tx and submit it.
    # No key involved — broadcasting a fully-signed public tx is keyless.
    def broadcast
      unless @signing_request.threshold_met?
        return redirect_to admin_signing_request_path(@signing_request),
                           alert: "Not enough signatures yet (#{@signing_request.signers_signed.length}/#{@signing_request.threshold})."
      end

      signed_b64 = Signing::Assembler.assemble(
        @signing_request.unsigned_message_base64,
        @signing_request.collected_signatures
      )
      body = { jsonrpc: "2.0", id: 1, method: "sendTransaction",
               params: [signed_b64, { encoding: "base64", skipPreflight: false }] }.to_json
      status, raw = Signing::Rpc.forward(@signing_request.cluster, body)
      parsed = JSON.parse(raw) rescue {}

      if (sig = parsed["result"])
        @signing_request.mark_broadcast!(sig)
        redirect_to admin_signing_request_path(@signing_request), notice: "Broadcast! Signature #{sig}"
      else
        msg = parsed.dig("error", "message") || "RPC status #{status}"
        @signing_request.mark_failed!(msg)
        redirect_to admin_signing_request_path(@signing_request), alert: "Broadcast failed: #{msg}"
      end
    rescue StandardError => e
      create_error_log(e)
      @signing_request.mark_failed!(e.message)
      redirect_to admin_signing_request_path(@signing_request), alert: "Broadcast error: #{e.message}"
    end

    # Same-origin keyless JSON-RPC proxy (for the signer page's Simulate). The
    # Helius API key stays server-side.
    def rpc
      status, upstream = Signing::Rpc.forward(@signing_request.cluster, request.body.read)
      render json: upstream, status: status
    rescue Signing::Rpc::MissingUrl, Signing::Rpc::WrongCluster => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def load_request
      @signing_request = SigningRequest.find_by!(slug: params[:slug])
    end

    def build_from_template
      method = TEMPLATES.fetch(params[:template].to_s) do
        raise ArgumentError, "unsupported instruction template #{params[:template].inspect}"
      end
      send(method)
    end

    def build_initialize
      Signing::SigningRequest.initialize_vault(
        cluster:              cluster_param,
        admin:                params.require(:admin),
        signers:              Array(params[:signers]).map(&:to_s).reject(&:blank?),
        threshold:            params.require(:threshold).to_i,
        treasury_authority:   params.require(:treasury_authority),
        payout_mint:          params.require(:payout_mint),
        second_currency_mint: params.require(:second_currency_mint)
      )
    end

    def build_update_signers
      Signing::SigningRequest.update_signers_keyless(
        cluster: cluster_param,
        durable_nonce: {
          pubkey:    params.require(:nonce_pubkey),
          authority: params.require(:nonce_authority)
        },
        admin:    params[:admin].presence || Signing::SigningRequest::MASON_CYT,
        cosigner: params[:cosigner].presence || Signing::SigningRequest::ALEX_7ZDJ
      )
    end

    def cluster_param
      (params[:cluster].presence || "devnet").to_s
    end

    def stringify(hash)
      hash.transform_keys(&:to_s).transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }
    end

    # ed25519 verify the submitted signature against the exact message the signer
    # was asked to sign. Defense-in-depth: a bad sig would also be rejected by the
    # cluster at broadcast, but we never want to store an invalid one.
    def valid_signature?(signer_b58, sig_b64)
      require "ed25519"
      message = Signing::Assembler.message_for(@signing_request.unsigned_message_base64)
      vk = Ed25519::VerifyKey.new(Solana::Keypair.decode_base58(signer_b58))
      vk.verify(Base64.strict_decode64(sig_b64), message)
      true
    rescue StandardError
      false
    end
  end
end
