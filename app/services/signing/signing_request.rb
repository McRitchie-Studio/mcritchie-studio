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

    attr_reader :cluster, :program, :instruction_name, :args, :accounts,
                :expected_signer, :cosigner, :fee_payer, :title,
                :coordination, :threshold, :durable_nonce, :expected_signers

    # v1 params (expected_signer / cosigner / build_partial_signed_base64) are
    # preserved for back-compat. v2 adds:
    #   program:         IDL registry key (default "turf_vault")
    #   coordination:    "single" | "multi"  (default inferred from threshold)
    #   threshold:       signatures required (default 1)
    #   expected_signers: array of signer pubkeys (defaults to [expected_signer])
    #   durable_nonce:   { pubkey:, authority: } for the multi-party keyless flow
    def initialize(cluster:, instruction_name:, args:, accounts:,
                   expected_signer: nil, cosigner: nil, fee_payer: nil, title: nil,
                   program: "turf_vault", coordination: nil, threshold: nil,
                   expected_signers: nil, durable_nonce: nil)
      @cluster          = cluster.to_s
      @program          = program.to_s
      @instruction_name = instruction_name.to_s
      @args             = args
      @accounts         = accounts
      @expected_signer  = expected_signer
      @cosigner         = cosigner
      @expected_signers = (expected_signers || [expected_signer]).compact
      @threshold        = threshold || @expected_signers.length.clamp(1, Float::INFINITY).to_i
      @coordination     = (coordination || (@threshold > 1 ? "multi" : "single")).to_s
      @fee_payer        = fee_payer || @expected_signers.first || cosigner
      @durable_nonce    = durable_nonce
      @title            = title || instruction_name.to_s
    end

    def idl
      @idl ||= Idl.for(cluster, program: program)
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
      resolved = {} # account name => resolved pubkey (base58), for account-path PDA seeds
      idl.accounts(instruction_name).map do |acct|
        name = acct.fetch("name")
        supplied = accounts.fetch(name.to_sym) { accounts.fetch(name, nil) }
        pubkey =
          if supplied && supplied != :pda
            supplied
          elsif acct["address"].present?
            # Fixed program address pinned in the IDL (token_program, system_program, rent).
            acct["address"]
          elsif acct["pda"]
            derive_pda(acct, program_bytes, resolved)
          else
            raise ArgumentError, "account #{name.inspect} has no supplied value, no fixed address, and no PDA seeds — supply it in accounts:"
          end
        resolved[name] = pubkey
        {
          pubkey: pubkey,
          is_signer: !!acct["signer"],
          is_writable: !!acct["writable"]
        }
      end
    end

    # Derive a PDA from the IDL's declared seeds. Supports:
    #   const   — literal bytes (e.g. vault_state's [b"vault"])
    #   account — the 32-byte pubkey of an EARLIER account in the list (e.g.
    #             initialize's op_rev ATAs, seeded by the resolved payout_mint).
    # `resolved` is the name=>pubkey map built so far by account_metas.
    def derive_pda(acct, program_bytes, resolved = {})
      pda_node = acct["pda"] or
        raise ArgumentError, "account #{acct['name']} has no value supplied and no PDA seeds in the IDL"
      seeds = pda_node.fetch("seeds").map do |seed|
        case seed["kind"]
        when "const"
          seed.fetch("value").pack("C*").b
        when "account"
          path = seed.fetch("path")
          ref = resolved[path] or
            raise ArgumentError, "account-path PDA seed #{path.inspect} for #{acct['name']} not yet resolved — it must appear earlier in the account list"
          Solana::Keypair.decode_base58(ref)
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

    # v2 KEYLESS build: produce the UNSIGNED transaction (all signer slots are
    # zero placeholders) for external signing — no server key is ever used. Each
    # expected signer signs this in their own browser/Phantom; the coordinator
    # then assembles the collected public signatures (Signing::Assembler).
    #
    # For `multi` coordination over a durable nonce, the first instruction is the
    # System AdvanceNonceAccount, and `blockhash` is the nonce account's stored
    # nonce value (so the tx never expires between signers). For `single` /
    # fresh-blockhash, pass a recent blockhash and omit durable_nonce.
    SYSTEM_PROGRAM_ID    = "11111111111111111111111111111111".freeze
    RECENT_BLOCKHASHES   = "SysvarRecentB1ockHashes11111111111111111111".freeze
    ADVANCE_NONCE_IX_TAG = [4, 0, 0, 0].pack("C*").b # u32 LE = 4 (AdvanceNonceAccount)

    def build_unsigned_message_base64(blockhash:)
      tx = Solana::Transaction.new
      tx.set_recent_blockhash(blockhash)
      add_advance_nonce_instruction!(tx) if durable_nonce
      tx.add_instruction(
        program_id: program_id,
        accounts: account_metas,
        data: instruction_data
      )
      # No @signers — every required signature is an external (additional) signer,
      # fee payer first.
      tx.serialize_partial_base64(additional_signers: ordered_signers)
    end

    # Fee payer must be the first signer slot.
    def ordered_signers
      ([fee_payer] + expected_signers).compact.uniq
    end

    # Prepend the System AdvanceNonceAccount instruction (durable-nonce txs MUST
    # advance the nonce as their first instruction; the nonce authority signs it).
    def add_advance_nonce_instruction!(tx)
      tx.add_instruction(
        program_id: SYSTEM_PROGRAM_ID,
        accounts: [
          { pubkey: durable_nonce.fetch(:pubkey),    is_signer: false, is_writable: true },
          { pubkey: RECENT_BLOCKHASHES,              is_signer: false, is_writable: false },
          { pubkey: durable_nonce.fetch(:authority), is_signer: true,  is_writable: false }
        ],
        data: ADVANCE_NONCE_IX_TAG
      )
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

    # v2 KEYLESS rotation: same 2-of-3 update_signers, but NO server cosigner.
    # Both signer accounts (admin + cosigner) sign in their OWN browsers; the
    # coordinator assembles over a durable nonce. expected_signers = both.
    def self.update_signers_keyless(cluster: "devnet", durable_nonce:,
                                    admin: MASON_CYT, cosigner: ALEX_7ZDJ, new_signers: NEW_SIGNERS)
      new(
        cluster: cluster,
        instruction_name: "update_signers",
        args: { "new_signers" => new_signers },
        accounts: {
          "admin"       => admin,    # signer + writable (fee payer)
          "cosigner"    => cosigner, # signer (Phantom)
          "vault_state" => :pda
        },
        expected_signers: [admin, cosigner],
        threshold: 2,
        coordination: "multi",
        fee_payer: admin,
        durable_nonce: durable_nonce, # { pubkey:, authority: } (authority is one of the signers)
        title: "turf-vault · update_signers (keyless 2-of-3) · #{cluster}"
      )
    end

    # SINGLE-signer "bring up a contract": turf-vault `initialize`. Signed by ONE
    # human wallet (the INIT_AUTHORITY = admin) — a Squads multisig can't
    # substitute, since the program needs the member's own signature. Fresh
    # blockhash, no durable nonce, threshold 1. The caller supplies the two mint
    # addresses + the initial signer set / threshold / treasury authority (these
    # vary per deployment and aren't derivable).
    #
    #   admin            — INIT_AUTHORITY (signer + fee payer; also a vault signer)
    #   signers          — initial [pubkey;3] multisig set
    #   threshold        — initial multisig threshold (u8)
    #   treasury_authority, payout_mint, second_currency_mint — pubkeys
    def self.initialize_vault(cluster:, admin:, signers:, threshold:, treasury_authority:,
                              payout_mint:, second_currency_mint:)
      new(
        cluster: cluster,
        instruction_name: "initialize",
        args: {
          "signers"            => signers,
          "threshold"          => threshold,
          "treasury_authority" => treasury_authority
        },
        accounts: {
          "admin"                => admin,                # signer + writable
          "vault_state"          => :pda,                 # [b"vault"]
          "payout_mint"          => payout_mint,
          "second_currency_mint" => second_currency_mint,
          "payout_op_rev_ata"    => :pda,                 # [b"op_rev", payout_mint]
          "second_op_rev_ata"    => :pda                  # [b"op_rev", second_currency_mint]
          # token_program / system_program / rent resolve from the IDL's fixed addresses
        },
        expected_signers: [admin],
        threshold: 1,
        coordination: "single",
        fee_payer: admin,
        title: "turf-vault · initialize (single-signer) · #{cluster}"
      )
    end
  end
end
