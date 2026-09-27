module ImageGeneration
  # WHICH CLASS SPEAKS A ROW'S PROTOCOL.
  #
  # A METHOD RATHER THAN A FROZEN CONSTANT HASH, following
  # Appearances::ImageSearch.providers for the same two reasons: it keeps the
  # adapter classes out of this file's load-time graph, and it gives the suite a
  # seam to stub without constant surgery.
  module Adapter
    class Unsupported < StandardError; end

    def self.registered = { "fal" => Fal, "openai" => OpenAI }

    # RAISES RATHER THAN RETURNING nil, because by the time a row has been chosen
    # the caller has already decided to generate. A nil here would surface as a
    # NoMethodError on the vendor call, naming a method instead of the row.
    #
    # `higgsfield` ROWS LAND HERE DELIBERATELY. They are registered so the file
    # describes the whole estate — and so the Kling video job stays visible as a
    # capability we own rather than disappearing — but nothing routes generation
    # to them: neither claims `zero_shot_identity`, and the identity path asks for
    # that capability by name. Higgsfield's own lane still runs through
    # Higgsfield::Client and Appearances::CreateCharacterReference, untouched.
    def self.for(row)
      registered.fetch(row.adapter.to_s) do
        raise Unsupported,
              "No ImageGeneration adapter for #{row.adapter.inspect} (row #{row.key}). " \
              "Registered: #{registered.keys.join(', ')}."
      end
    end

    def self.supported?(row) = registered.key?(row.adapter.to_s)
  end
end
