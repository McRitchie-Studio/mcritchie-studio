module Signing
  # Loads the co-signer keypair that the SERVER partial-signs with (NOT the
  # human's Phantom key — that never leaves the wallet). For the update_signers
  # dogfood the co-signer is Mason (Cyt…qWjrR).
  #
  # Key source (in order):
  #   1. SOLANA_COSIGNER_KEY env var  — base58 secret key.
  #   2. SOLANA_COSIGNER_OP_REF env var — an `op://...` reference resolved via
  #      `op read` at request time (so the secret is never persisted in .env).
  #
  # The secret is NEVER logged and NEVER returned to the client. Only the
  # derived public key is ever surfaced, and only after asserting it matches the
  # SigningRequest's declared cosigner.
  class Cosigner
    class MissingKey < StandardError; end
    class PubkeyMismatch < StandardError; end

    # Returns a Solana::Keypair, asserting its public address == expected_b58.
    def self.load!(expected_b58)
      secret = read_secret!
      keypair = Solana::Keypair.from_base58(secret)
      actual = keypair.to_base58
      if actual != expected_b58
        # Do not include the secret; the addresses are public.
        raise PubkeyMismatch,
              "co-signer key resolved to #{actual}, but the signing request " \
              "expects #{expected_b58}. Wrong SOLANA_COSIGNER_KEY for this rotation."
      end
      keypair
    ensure
      # Best-effort scrub of the local base58 string.
      secret&.clear if secret.respond_to?(:clear)
    end

    # Resolve the secret without constructing a keypair (used by the resolved?
    # readiness check). Returns the base58 string or raises MissingKey.
    def self.read_secret!
      if ENV["SOLANA_COSIGNER_KEY"].present?
        ENV["SOLANA_COSIGNER_KEY"].dup
      elsif ENV["SOLANA_COSIGNER_OP_REF"].present?
        op_read(ENV["SOLANA_COSIGNER_OP_REF"])
      else
        raise MissingKey,
              "No co-signer key configured. Set SOLANA_COSIGNER_KEY (base58 secret) " \
              "or SOLANA_COSIGNER_OP_REF (an op:// reference) in the environment."
      end
    end

    # `op read <ref>` — relies on OP_SERVICE_ACCOUNT_TOKEN being present in the
    # shell that launched the server (see house-burn-down recovery doc).
    def self.op_read(ref)
      require "open3"
      out, err, status = Open3.capture3("op", "read", ref)
      raise MissingKey, "op read failed: #{err.strip}" unless status.success?
      out.strip
    end

    # True if a co-signer key is configured at all (cheap; does not resolve op).
    def self.configured?
      ENV["SOLANA_COSIGNER_KEY"].present? || ENV["SOLANA_COSIGNER_OP_REF"].present?
    end
  end
end
