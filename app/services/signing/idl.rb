module Signing
  # Loads + caches a pinned turf-vault Anchor IDL by cluster, and exposes the
  # bits the encoder needs: program address, an instruction's discriminator,
  # its arg schema, and its account schema.
  #
  # The IDL JSON files are committed under config/idl/ (one per cluster). This
  # is the v1 stand-in for the "registry vs upload" open decision in the spec —
  # turf-vault is the only program we sign for right now, so we bundle its IDL.
  #
  # TODO(v2): generic registry / per-request IDL upload so other programs can
  # drive a SigningRequest without shipping their IDL into this repo.
  class Idl
    class UnknownCluster < StandardError; end
    class UnknownInstruction < StandardError; end

    # Cluster => committed IDL path. Mainnet variant is the same IDL with the
    # mainnet program address patched in (the on-chain surface is identical).
    PATHS = {
      "devnet"  => "turf_vault.devnet.json",
      "mainnet" => "turf_vault.mainnet.json"
    }.freeze

    def self.for(cluster)
      @cache ||= {}
      @cache[cluster.to_s] ||= new(cluster.to_s)
    end

    attr_reader :cluster, :raw

    def initialize(cluster)
      raise UnknownCluster, "unknown cluster #{cluster.inspect}" unless PATHS.key?(cluster)

      @cluster = cluster
      path = Rails.root.join("config", "idl", PATHS.fetch(cluster))
      @raw = JSON.parse(File.read(path))
    end

    # Program address (base58) as pinned in the IDL.
    def program_id
      @raw.fetch("address")
    end

    # Returns the IDL instruction node for a name, e.g. "update_signers".
    def instruction(name)
      @raw.fetch("instructions").find { |ix| ix["name"] == name.to_s } ||
        raise(UnknownInstruction, "instruction #{name.inspect} not in #{cluster} IDL")
    end

    # 8-byte Anchor discriminator (binary string) for an instruction.
    # Sourced from the IDL itself (the array of bytes Anchor emits) — NOT
    # recomputed — so the encoded ix is bound to the pinned IDL.
    def discriminator(name)
      instruction(name).fetch("discriminator").pack("C*").b
    end

    # The instruction's declared arg schema (array of {name,type}).
    def args(name)
      instruction(name).fetch("args")
    end

    # The instruction's declared account schema (array of {name,writable,signer,...}).
    def accounts(name)
      instruction(name).fetch("accounts")
    end
  end
end
