module ImageGeneration
  # THE GENERATOR ROWS, read from config/image_generators.yml.
  #
  # THE CHOOSER NEVER NAMES A VENDOR. Callers ask for a CAPABILITY —
  # `Registry.for(:zero_shot_identity)` — and get back the first available row
  # that claims it. That is the whole point of the operator's "we should be able
  # to transition between generators as model capacities change": swapping which
  # model serves identity is an edit to the YAML, not a change to any caller.
  #
  # `available?` IS THE ROW'S OWN QUESTION, asked of the row, following
  # Appearances::ImageSearch, where the same decision is written up at length. The
  # obvious alternative — this module checking ENV["FAL_KEY"] before dispatching —
  # bakes one vendor's credential into the layer above the rows, and the first
  # keyless generator then has to fight the registry to be usable. A row with no
  # `credential_env` is available unconditionally.
  #
  # LOADING FOLLOWS Devops::Vocabulary rather than Release::Repos: safe_load_file
  # with no permitted classes, deep-symbolized keys, memoized everywhere EXCEPT
  # development, where editing the YAML should show up without a restart.
  module Registry
    PATH = Rails.root.join("config", "image_generators.yml")

    # ONE GENERATOR. A Struct rather than a raw Hash so a typo in a caller is a
    # NoMethodError naming the member, instead of a silent nil that reads as
    # "this row does not declare that" — the two are indistinguishable on a Hash
    # and only one of them is a bug.
    Row = Struct.new(:key, :label, :adapter, :endpoint, :api_version, :credential_env,
                     :reference_field, :reference_arity, :capabilities, :docs_url,
                     :unit_price_usd, keyword_init: true) do
      # NO credential_env MEANS KEYLESS, not misconfigured. Nothing ships that way
      # today; the branch exists so adding one is a row rather than an argument
      # with this file.
      def available? = credential_env.blank? || ENV[credential_env.to_s].present?

      def capable_of?(capability) = capabilities.include?(capability.to_s)

      # TURN A MEASURED UNIT COUNT INTO A PRICE, or answer nil.
      #
      # nil MEANS "WE CANNOT PRICE THIS", never "free". A row with no declared
      # rate, or a call the vendor billed silently, both land here, and the page
      # renders the absence rather than a zero.
      def price_for(units)
        return nil if units.blank? || unit_price_usd.blank?

        (BigDecimal(units.to_s) * BigDecimal(unit_price_usd.to_s)).round(4)
      end

      # THE VERSION STAMPED ON EVERY ARTIFACT THIS ROW PRODUCES. Endpoint plus
      # contract version, because neither alone identifies what ran: the endpoint
      # can be reshaped under a stable path, and a version with no endpoint does
      # not say which model it versions.
      def provenance_version = [endpoint, api_version].compact_blank.join("@")

      # WHAT AN OPERATOR IS TOLD WHEN THE ROW IS OFF. It names the variable on
      # purpose — the person reading it is the person who will go and set it, and
      # "not configured" without the name sends them to ask someone.
      def unconfigured_message
        return "#{label} is not configured." if credential_env.blank?

        "#{label} is not configured, so nothing was generated and nothing was " \
          "spent. Set #{credential_env} to turn it on."
      end
    end

    class << self
      def rows
        return load_rows if Rails.env.development?

        @rows ||= load_rows
      end

      def reload!
        @rows = nil
        rows
      end

      def all = rows

      def find(key) = rows.find { |row| row.key == key.to_s }

      # STRICT SIBLING OF #find, for the callers that cannot carry on without one.
      # A nil row from #find becomes a NoMethodError three frames later, naming a
      # member instead of the key that was missing.
      def find!(key)
        find(key) || raise(KeyError, "No image generator row #{key.inspect} in #{PATH}")
      end

      def with_capability(capability) = rows.select { |row| row.capable_of?(capability) }

      def available = rows.select(&:available?)

      # THE ONE CALL EVERY CONSUMER SHOULD USE: the first AVAILABLE row that can do
      # the thing asked for, or nil.
      #
      # nil IS A NORMAL ANSWER, exactly as in Appearances::ImageSearch. With no
      # credential on the machine the page must still render and say honestly that
      # generation is off. An exception here would turn "we have not set FAL_KEY on
      # this desk" into a 500 on a page whose only job is to show what we have.
      #
      # ORDER IS THE PREFERENCE and it is the YAML's order, which is why the file
      # leads with the row that claims full_body and back_view.
      def for(capability) = with_capability(capability).find(&:available?)

      # THE ROW THAT WOULD SERVE, IGNORING CREDENTIALS. What the page needs to say
      # "Ideogram V3 Character is the generator, and it is switched off" rather
      # than the much less useful "generation is off".
      def preferred(capability) = with_capability(capability).first

      private

      def load_rows
        raw = YAML.safe_load_file(PATH, permitted_classes: [], aliases: false) || {}
        (raw["generators"] || {}).map do |key, attrs|
          attrs = (attrs || {}).deep_symbolize_keys
          Row.new(
            key: key.to_s,
            label: attrs[:label].to_s,
            adapter: attrs[:adapter].to_s,
            endpoint: attrs[:endpoint].to_s,
            api_version: attrs[:api_version]&.to_s,
            credential_env: attrs[:credential_env]&.to_s,
            reference_field: attrs[:reference_field]&.to_s,
            reference_arity: attrs[:reference_arity]&.to_s,
            capabilities: Array(attrs[:capabilities]).map(&:to_s),
            docs_url: attrs[:docs_url]&.to_s,
            unit_price_usd: attrs[:unit_price_usd]
          )
        end
      end
    end
  end
end
