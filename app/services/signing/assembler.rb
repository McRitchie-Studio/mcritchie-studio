module Signing
  # Keyless signature assembly for the v2 multi-party flow. Given the UNSIGNED
  # transaction (built by Signing::SigningRequest#build_unsigned_message_base64,
  # all signature slots zeroed) and the PUBLIC signatures collected from each
  # signer's own browser, produce the broadcast-ready signed transaction.
  #
  # The server never signs and never holds a key — it only slots already-made
  # public signatures into the correct positions. Slot order is derived from the
  # transaction MESSAGE itself (the first `num_required_signatures` account keys),
  # so it's independent of the order signatures arrive in.
  #
  # Wire format (legacy tx): compact-u16(sig_count) ++ sig_count*64-byte sigs ++ message
  # Message: [numReqSigs, numRoSigned, numRoUnsigned] ++ compact-u16(keyCount) ++ keyCount*32 ++ ...
  module Assembler
    module_function

    SIG_LEN = 64

    # Returns { message: <binary>, signer_pubkeys: [base58, ...] (in slot order),
    #           sig_count: Integer }.
    def parse(unsigned_tx_base64)
      bytes = Base64.strict_decode64(unsigned_tx_base64).b
      sig_count, off = read_compact_u16(bytes, 0)
      message = bytes[(off + sig_count * SIG_LEN)..] or
        raise ArgumentError, "truncated transaction (no message after #{sig_count} signature slots)"

      num_required = message.getbyte(0)
      key_count, koff = read_compact_u16(message, 3)
      pubkeys = Array.new(key_count) do |i|
        start = koff + i * 32
        Solana::Keypair.encode_base58(message.byteslice(start, 32))
      end

      { message: message, signer_pubkeys: pubkeys.first(num_required), sig_count: sig_count }
    end

    # signatures_by_pubkey: { base58_pubkey => base64_signature }. Every required
    # signer slot must be present, or assembly raises (no zero-sig broadcast).
    def assemble(unsigned_tx_base64, signatures_by_pubkey)
      parsed  = parse(unsigned_tx_base64)
      message = parsed[:message]

      sigs = parsed[:signer_pubkeys].map do |pubkey|
        b64 = signatures_by_pubkey[pubkey] or
          raise ArgumentError, "missing signature for required signer #{pubkey}"
        sig = Base64.strict_decode64(b64).b
        raise ArgumentError, "signature for #{pubkey} is #{sig.bytesize} bytes, expected #{SIG_LEN}" unless sig.bytesize == SIG_LEN
        sig
      end

      wire = compact_u16(sigs.length) + sigs.join.b + message
      Base64.strict_encode64(wire)
    end

    # The raw message bytes a signer signs — used to verify a submitted signature
    # before trusting it (ed25519 verify against the claimed pubkey).
    def message_for(unsigned_tx_base64)
      parse(unsigned_tx_base64)[:message]
    end

    # --- compact-u16 (shortvec) codec ----------------------------------------

    def read_compact_u16(bytes, offset)
      val = 0
      shift = 0
      loop do
        byte = bytes.getbyte(offset) or raise ArgumentError, "unexpected end of buffer reading compact-u16"
        offset += 1
        val |= (byte & 0x7f) << shift
        break if (byte & 0x80).zero?
        shift += 7
      end
      [val, offset]
    end

    def compact_u16(value)
      out = +"".b
      v = value
      loop do
        if v < 0x80
          out << v
          break
        else
          out << ((v & 0x7f) | 0x80)
          v >>= 7
        end
      end
      out
    end
  end
end
