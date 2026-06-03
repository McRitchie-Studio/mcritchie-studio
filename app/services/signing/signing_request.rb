module Signing
  # Describes ONE on-chain instruction to be signed by a human's Phantom key,
  # and builds + server-partial-signs the transaction for it. Generic by design:
  #
  #   SigningRequest.new(
  #     cluster:           "devnet",
  #     instruction_name:  "update_signers",
  #     args:              { "new_signers" => [pk1, pk2, pk3] },
  #     accounts:          { "admin" => MASON, "cosigner" => ALEX_7ZDJ, "vault_state" => :pda },
  #     expected_signer:   ALEX_7ZDJ,   # the Phantom wallet that signs in-browser
  #     cosigner:          MASON,       # the key the SERVER partial-signs with
  #     fee_payer:         MASON        # who pays the SOL fee (defaults to cosigner)
  #   )
  #
  # The instruction data is Borsh-encoded in Ruby (ArgEncoder, IDL-driven), the
  # account metas are resolved from the IDL (PDAs derived here), and the tx is
  # partial-signed server-side leaving the expected_signer's slot empty for
  # Phantom. The client fetches a FRESH partial-signed tx (current blockhash)
  # for both Simulate and Sign — exactly the throwaway server's /build behavior.
  #
  # v1 ships two factories: .update_signers (the immediate dogfood) and
  # .initialize_vault (ready for Phase 3 re-init). Both just populate this
  # generic object.
  class SigningRequest
    # --- Known turf-vault pubkeys (devnet rotation) ----------------------------
    ALEX_7ZDJ = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze # Alex (human, Phantom)
    MASON_CYT = "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR".freeze # Mason (server cosigner)
    # New signer set for the leaked-Alex-Bot rotation: F6f8 -> 8K81.
    NEW_SIGNERS = [
      "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd", # new Alex Bot
      "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr", # Alex
      "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR"  # Mason
    ].freeze

    attr_reader :cluster, :instruction_name, :args, :accounts,
                :expected_signer, :cosigner, :fee_payer, :title

    def initialize(cluster:, instruction_name:, args:, accounts:,
                   expected_signer:, cosigner:, fee_payer: nil, title: nil)
      @cluster          = cluster.to_s
      @instruction_name = instruction_name.to_s
      @args             = args
      @accounts         = accounts
      @expected_signer  = expected_signer
      @cosigner         = cosigner
      @fee_payer        = fee_payer || cosigner
      @title            = title || instruction_name.to_s
    end

    def idl
      @idl ||= Idl.for(cluster)
    end

    def program_id
      idl.program_id
    end

    # The Borsh-encoded instruction data (discriminator + args). This is the
    # byte sequence the correctness gate asserts against the proven JS bytes.
    def instruction_data
      idl.discriminator(instruction_name) +
        ArgEncoder.encode(idl.args(instruction_name), args)
    end

    # Resolve the IDL account schema into ordered { pubkey, is_signer,
    # is_writable } metas. A caller value of :pda means "derive the PDA from the
    # IDL's declared const seeds for this account".
    def account_metas
      program_bytes = Solana::Keypair.decode_base58(program_id)
      idl.accounts(instruction_name).map do |acct|
        name = acct.fetch("name")
        supplied = accounts.fetch(name.to_sym) { accounts.fetch(name, nil) }
        pubkey =
          if supplied == :pda || supplied.nil?
            derive_pda(acct, program_bytes)
          else
            supplied
          end
        {
          pubkey: pubkey,
          is_signer: !!acct["signer"],
          is_writable: !!acct["writable"]
        }
      end
    end

    # Derive a PDA from the IDL's declared const seeds (e.g. vault_state's
    # [b"vault"]). Only const seeds are supported in v1 (covers vault_state).
    def derive_pda(acct, program_bytes)
      pda_node = acct["pda"] or
        raise ArgumentError, "account #{acct['name']} has no value supplied and no PDA seeds in the IDL"
      seeds = pda_node.fetch("seeds").map do |seed|
        case seed["kind"]
        when "const" then seed.fetch("value").pack("C*").b
        else
          raise ArgumentError, "unsupported PDA seed kind #{seed['kind'].inspect} for #{acct['name']}"
        end
      end
      address_bytes, _bump = Solana::Transaction.find_pda(seeds, program_bytes)
      Solana::Keypair.encode_base58(address_bytes)
    end

    # Build the transaction, partial-sign with the co-signer key, and return the
    # base64 of the half-signed VersionedTransaction (the expected_signer slot
    # is a zero placeholder for Phantom). blockhash is fetched fresh from the RPC.
    #
    # cosigner_keypair: a Solana::Keypair whose address == self.cosigner
    #                   (loaded by Signing::Cosigner — never held here).
    # blockhash:        recent blockhash (base58) from the live RPC.
    def build_partial_signed_base64(cosigner_keypair:, blockhash:)
      metas = account_metas

      tx = Solana::Transaction.new
      tx.set_recent_blockhash(blockhash)
      # Fee payer MUST be @signers.first. For update_signers that's Mason
      # (the cosigner). Phantom (expected_signer) is the additional signer.
      tx.add_signer(cosigner_keypair)
      tx.add_instruction(
        program_id: program_id,
        accounts: metas,
        data: instruction_data
      )
      tx.serialize_partial_base64(additional_signers: [expected_signer])
    end

    # ---- Factories ------------------------------------------------------------

    # The immediate dogfood: rotate the devnet 2-of-3 signer set in place.
    #   admin (fee payer + server partial-sign) = Mason
    #   cosigner (Phantom, signs in browser)     = Alex 7ZDJ
    def self.update_signers(cluster: "devnet")
      new(
        cluster: cluster,
        instruction_name: "update_signers",
        args: { "new_signers" => NEW_SIGNERS },
        accounts: {
          "admin"       => MASON_CYT,  # signer + writable (fee payer)
          "cosigner"    => ALEX_7ZDJ,  # signer (Phantom)
          "vault_state" => :pda        # derived [b"vault"]
        },
        expected_signer: ALEX_7ZDJ,
        cosigner: MASON_CYT,
        fee_payer: MASON_CYT,
        title: "turf-vault · update_signers · #{cluster}"
      )
    end

    # TODO(Phase 3): initialize / re-init the vault on the new program.
    #   initialize requires INIT_AUTHORITY = a Phantom key as the expected
    #   signer (a Squads multisig can't substitute). Wire the accounts +
    #   args once the v0.20 re-init account list is finalized; the generic
    #   build path above already handles it.
    # def self.initialize_vault(cluster:, signers:, threshold:) ... end
  end
end
