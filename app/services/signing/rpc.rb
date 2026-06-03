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
