module Signing
  # Program-agnostic IDL registry: maps a program key + cluster to its committed,
  # pinned Anchor IDL. This is the v2 generalization of the single-program v1
  # `Signing::Idl` — any future contract/multisig drops in by adding an entry
  # here + committing its IDL under config/idl/, with no other code change.
  #
  # The byte-match safety gate (encode in Ruby, assert == a known-good reference)
  # still guards each NEW instruction encoder before it's trusted — see the
  # signing_request_test.
  class IdlRegistry
    class UnknownProgram < StandardError; end

    # program key => { cluster => committed IDL filename (under config/idl/) }
    PROGRAMS = {
      "turf_vault" => {
        "devnet"  => "turf_vault.devnet.json",
        "mainnet" => "turf_vault.mainnet.json"
      }
    }.freeze

    # All registered program keys.
    def self.programs
      PROGRAMS.keys
    end

    # Clusters a program is registered for.
    def self.clusters_for(program)
      PROGRAMS.fetch(program.to_s) { raise UnknownProgram, "unknown program #{program.inspect}" }.keys
    end

    def self.registered?(program, cluster)
      PROGRAMS.dig(program.to_s, cluster.to_s).present?
    end

    # Returns a Signing::Idl loaded for the (program, cluster).
    def self.idl(program:, cluster:)
      Idl.for(cluster, program: program)
    end
  end
end
