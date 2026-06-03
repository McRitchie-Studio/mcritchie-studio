module Signing
  # Borsh-encodes an instruction's args against its IDL arg schema, using the
  # solana-studio Borsh primitives. The schema drives the byte layout, so the
  # SAME encoder serves update_signers (a fixed [pubkey;3] array) and the future
  # initialize call (signers array + threshold u8), without per-instruction code.
  #
  # CRITICAL CORRECTNESS GATE: for update_signers the bytes this produces are
  # asserted byte-for-byte against Jasper's proven JS tx (see the test +
  # SigningRequest.update_signers). A wrong encoding signs a wrong rotation, so
  # the supported-type set here is deliberately small + explicit. An unsupported
  # type raises rather than guessing.
  class ArgEncoder
    class UnsupportedType < StandardError; end

    B = Solana::Borsh

    # schema: the IDL "args" array ([{ "name" => ..., "type" => ... }, ...]).
    # values: a hash of arg name (String/Symbol) => Ruby value.
    def self.encode(schema, values)
      values = values.transform_keys(&:to_s)
      schema.map { |arg|
        name = arg.fetch("name")
        unless values.key?(name)
          raise ArgumentError, "missing arg #{name.inspect} (have: #{values.keys.inspect})"
        end
        encode_type(arg.fetch("type"), values.fetch(name))
      }.join.b
    end

    # Encode a single value per its IDL type node. Anchor IDL types are either a
    # primitive String ("pubkey", "u64", ...) or a Hash for compound types
    # ({ "array" => ["pubkey", 3] }, { "vec" => "pubkey" }).
    def self.encode_type(type, value)
      case type
      when String
        encode_primitive(type, value)
      when Hash
        if (arr = type["array"])
          inner, len = arr
          unless value.is_a?(Array) && value.length == len
            raise ArgumentError, "expected #{len}-element array, got #{value.inspect}"
          end
          # Fixed-length array: NO length prefix — just the elements (Borsh spec).
          value.map { |v| encode_type(inner, v) }.join.b
        elsif (inner = type["vec"])
          # Dynamic vec: u32 length prefix then elements.
          (B.encode_u32(value.length) + value.map { |v| encode_type(inner, v) }.join).b
        else
          raise UnsupportedType, "unsupported compound IDL type #{type.inspect}"
        end
      else
        raise UnsupportedType, "unsupported IDL type node #{type.inspect}"
      end
    end

    def self.encode_primitive(type, value)
      case type
      when "pubkey" then B.encode_pubkey(value)
      when "u8"     then B.encode_u8(value)
      when "u16"    then B.encode_u16(value)
      when "u32"    then B.encode_u32(value)
      when "u64"    then B.encode_u64(value)
      when "i64"    then B.encode_i64(value)
      when "bool"   then B.encode_bool(value)
      else
        raise UnsupportedType, "unsupported primitive IDL type #{type.inspect}"
      end
    end
  end
end
