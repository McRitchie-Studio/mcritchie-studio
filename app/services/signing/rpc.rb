module Signing
  # Resolves the cluster's Helius JSON-RPC URL (server-side only) and forwards a
  # JSON-RPC request body to it. The URL — which carries the Helius API key — is
  # NEVER sent to the browser; the signing page talks only to our same-origin
  # proxy action, which calls #forward.
  #
  # Env (set in mcritchie-studio/.env; Helius URLs live in 1Password agent.helius):
  #   SOLANA_DEVNET_RPC_URL   — https://devnet.helius-rpc.com/?api-key=...
  #   SOLANA_MAINNET_RPC_URL  — https://mainnet.helius-rpc.com/?api-key=...
  class Rpc
    class MissingUrl < StandardError; end
    class WrongCluster < StandardError; end

    ENV_KEYS = {
      "devnet"  => "SOLANA_DEVNET_RPC_URL",
      "mainnet" => "SOLANA_MAINNET_RPC_URL"
    }.freeze

    def self.url_for(cluster)
      cluster = cluster.to_s
      key = ENV_KEYS.fetch(cluster) { raise MissingUrl, "unknown cluster #{cluster.inspect}" }
      url = ENV[key].presence or
        raise MissingUrl, "#{key} not set — cannot reach #{cluster} RPC."
      # Defence-in-depth: refuse to use a URL that doesn't name the expected
      # cluster (mirrors the throwaway server's devnet guard) — stops a mainnet
      # URL ever being hit from a devnet signing request.
      unless url.downcase.include?(cluster)
        raise WrongCluster, "#{key} does not look like a #{cluster} URL — refusing."
      end
      url
    end

    def self.configured?(cluster)
      ENV[ENV_KEYS[cluster.to_s].to_s].present?
    rescue StandardError
      false
    end

    # A fresh recent blockhash (base58) — used for SINGLE-signer requests where
    # the one human signs + broadcasts promptly (no durable nonce needed).
    def self.latest_blockhash(cluster)
      body = { jsonrpc: "2.0", id: 1, method: "getLatestBlockhash",
               params: [{ commitment: "confirmed" }] }.to_json
      status, raw = forward(cluster, body)
      bh = (JSON.parse(raw).dig("result", "value", "blockhash") rescue nil)
      raise "getLatestBlockhash failed (status #{status}): #{raw.to_s[0, 200]}" if bh.blank?
      bh
    end

    # Raw account data (binary) for a pubkey, or nil if the account doesn't exist.
    def self.account_data(cluster, pubkey)
      body = { jsonrpc: "2.0", id: 1, method: "getAccountInfo",
               params: [pubkey, { encoding: "base64", commitment: "confirmed" }] }.to_json
      status, raw = forward(cluster, body)
      b64 = (JSON.parse(raw).dig("result", "value", "data", 0) rescue nil)
      raise "getAccountInfo(#{pubkey}) failed (status #{status})" if b64.blank?
      Base64.decode64(b64).b
    end

    # The stored durable-nonce value (base58) a tx anchored on this account must
    # use, via the gem's NonceAccount parser. Verifies the account is initialized
    # and (optionally) owned by the expected authority before trusting it — so a
    # MULTI-signer half-signed tx never expires between signers.
    def self.nonce_value(cluster, nonce_pubkey, expected_authority: nil)
      na = Solana::NonceAccount.parse(account_data(cluster, nonce_pubkey))
      raise "nonce account #{nonce_pubkey} is not initialized" unless na.initialized?
      if expected_authority && !na.authority?(expected_authority)
        raise "nonce account #{nonce_pubkey} authority is #{na.authority}, expected #{expected_authority}"
      end
      na.nonce
    end

    # Minimum lamports for a rent-exempt account of `space` bytes.
    def self.min_balance_for_rent_exemption(cluster, space)
      body = { jsonrpc: "2.0", id: 1, method: "getMinimumBalanceForRentExemption", params: [space] }.to_json
      status, raw = forward(cluster, body)
      lamports = (JSON.parse(raw)["result"] rescue nil)
      raise "getMinimumBalanceForRentExemption failed (status #{status})" if lamports.nil?
      lamports.to_i
    end

    # Submit a fully-signed base64 tx. Returns the signature, or raises with the
    # RPC error message.
    def self.send_transaction(cluster, signed_base64)
      body = { jsonrpc: "2.0", id: 1, method: "sendTransaction",
               params: [signed_base64, { encoding: "base64", skipPreflight: false }] }.to_json
      status, raw = forward(cluster, body)
      parsed = JSON.parse(raw) rescue {}
      return parsed["result"] if parsed["result"]
      raise "sendTransaction failed: #{parsed.dig("error", "message") || "status #{status}"}"
    end

    # Forward a raw JSON-RPC body string to the cluster RPC. Returns
    # [status, body_string]. The API key stays server-side.
    def self.forward(cluster, body)
      require "net/http"
      require "uri"
      uri = URI.parse(url_for(cluster))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 20
      req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      req.body = body
      resp = http.request(req)
      [resp.code.to_i, resp.body.to_s]
    end
  end
end
