module BuildIntake
  # The intake card one of Ray's answers offers, checked in CODE before anything
  # shows it (the ProposalBlock pattern: the model proposes, code decides). Ray
  # writes it as a PROPOSAL block of kind "intake":
  #
  #   ===PROPOSAL===
  #   {"kind": "intake", "card": "cto", "names": ["Nova", "Max", "Juno"], "portrait": "harbor"}
  #
  # The cards, and what each may carry (any other key refuses the card):
  #
  #   idea     title (required, the app's name in a few words, at most
  #            TITLE_WORDS), features (2 to 3 short bullets, required), idea
  #            (an optional one-sentence description): what the visitor taps
  #            Start App on, or "Build something else"
  #   palette  palettes (1 to 3), each { name, light, dark }, each mode exactly
  #            { primary, accent, surface, text } as hex colours, the text
  #            readable on the surface (WCAG AA, 4.5:1) in BOTH modes
  #   cto      names (1 to 3), portrait (a BuildIntake::Portraits key or an
  #            "animal:<id>"; the card starts on an animal either way)
  #   address  names (1 to 3): domain suggestions, each a valid, unreserved name
  #   summary  nothing: the app as the request now stands, drawn by the page from
  #            the request's own fields, with Build My App. Code also attaches
  #            it to any answer that completes once every step is set and the
  #            answer offered no other card (record_from!), so the visitor is
  #            never left without the button
  #
  # A list item that fails (a bad name, an unreadable palette) is dropped and
  # counted; a card left with no items, or with a malformed shape, is refused.
  # The verdict's card is the normalized copy, the only one ever stored or shown.
  module Card
    KINDS = %w[idea cto palette address summary].freeze
    KEYS = {
      "idea" => %w[title features idea],
      "cto" => %w[names portrait],
      "palette" => %w[palettes],
      "address" => %w[names],
      "summary" => []
    }.freeze
    BASE_KEYS = %w[kind card].freeze
    MAX_ITEMS = 3
    MODES = %w[light dark].freeze
    ROLES = %w[primary accent surface text].freeze
    PALETTE_KEYS = %w[name light dark].freeze

    # A CTO's name: 2 to 24 characters, letters first, then letters, spaces,
    # apostrophes, hyphens or periods; never two separators in a row.
    NAME = /\A\p{L}(?:[\p{L}]|[ '.-](?=\p{L})){1,23}\.?\z/u
    PALETTE_NAME = /\A[\p{L}\p{N}][\p{L}\p{N} &'-]{0,23}\z/u
    # The idea card's free text. audience and day_one are the v1 card's fields:
    # no longer offered, still readable on a draft that confirmed one.
    TEXT_LIMITS = { "idea" => 280, "title" => 60, "audience" => 160, "day_one" => 160 }.freeze
    # The idea's title: Ray is asked for 4 to 6 words; code holds 2 to 8, so a
    # near miss still shows the card instead of leaving the visitor stuck.
    TITLE_WORDS = (2..8)
    FEATURES = (2..3)
    FEATURE_LIMIT = 80

    Verdict = Struct.new(:card, :reason, keyword_init: true) do
      def ok? = reason.nil?
    end

    module_function

    # The proposal block a completed answer on a build thread carried, checked
    # and stored on the message (intake_card), or refused as an event. Called
    # by AgentMessage#complete! in its transaction, in place of
    # AgentProposal.record_from!: a build thread takes intake cards ONLY, so a
    # catalog proposal (an ask, a change) is refused here, whoever sent it.
    def record_from!(message, raw)
      verdict = raw.nil? ? nil : validate(raw)
      if verdict && !verdict.ok?
        message.record!("intake_refused", actor: "board", detail: { "reason" => verdict.reason.to_s[0, 300],
                                                                    "card" => (raw["card"].to_s[0, 20] if raw.is_a?(Hash)) }.compact)
      end
      card = verdict&.ok? ? verdict.card : summary_due(message)
      return nil unless card

      message.update!(intake_card: card)
      message.record!("intake_card", actor: "board", detail: { "card" => card["card"], "by" => ("code" unless verdict&.ok?) }.compact)
      card
    end

    # The summary card, when the answer offered none and the request is ready to
    # build: every step set, still a draft. Code's call, not the model's.
    def summary_due(message)
      request = BuildIntake.request_for(message)
      request&.draft? && request.intake_complete? ? { "card" => "summary" } : nil
    end

    def validate(raw)
      return refuse("not an object") unless raw.is_a?(Hash)

      raw = raw.transform_keys(&:to_s)
      return refuse("kind must be intake") unless raw["kind"] == "intake"

      kind = raw["card"].to_s
      return refuse("unknown card #{kind[0, 20].inspect}") unless KINDS.include?(kind)

      unknown = raw.keys - BASE_KEYS - KEYS.fetch(kind)
      return refuse("unknown field(s) #{unknown.first(3).join(', ')}") if unknown.any?

      send(:"#{kind}_card", raw)
    end

    # The idea, as an app: a short title and two or three key features. Plain
    # text, bounded; a feature that fails is dropped, as a bad name is.
    def idea_card(raw)
      out = { "card" => "idea" }
      %w[title idea].each do |key|
        next if raw[key].nil?
        return refuse("#{key} must be text") unless raw[key].is_a?(String)

        value = plain(raw[key])
        return refuse("#{key} is over #{TEXT_LIMITS[key]} characters") if value.length > TEXT_LIMITS[key]

        out[key] = value if value.present?
      end
      return refuse("title is required") if out["title"].blank?

      words = out["title"].split.size
      return refuse("title is #{words} words; use #{TITLE_WORDS.min} to #{TITLE_WORDS.max}") unless TITLE_WORDS.cover?(words)

      features, dropped = items(raw["features"]) { |f| feature(f) }
      return refuse("features must be a list") if features.nil?
      return refuse("needs #{FEATURES.min} to #{FEATURES.max} key features, got #{features.size}") if features.size < FEATURES.min

      out["features"] = features
      out["dropped"] = dropped if dropped
      Verdict.new(card: out)
    end

    def summary_card(_raw) = Verdict.new(card: { "card" => "summary" })

    # One key feature, cleaned, or nil when it is not one.
    def feature(value)
      return nil unless value.is_a?(String)

      text = plain(value)
      text.present? && text.length <= FEATURE_LIMIT ? text : nil
    end

    def cto_card(raw)
      names, dropped = items(raw["names"]) { |n| cto_name(n) }
      return refuse("names must be a list") if names.nil?
      return refuse("no valid name") if names.empty?

      portrait = raw["portrait"]
      return refuse("unknown portrait #{portrait.to_s[0, 20].inspect}") unless portrait.nil? || Portraits.choosable?(portrait)

      Verdict.new(card: { "card" => "cto", "names" => names.uniq(&:downcase), "portrait" => portrait,
                          "dropped" => dropped }.compact)
    end

    def palette_card(raw)
      list = raw["palettes"]
      return refuse("palettes must be a list") unless list.is_a?(Array)

      kept = []
      reasons = []
      list.first(MAX_ITEMS).each do |item|
        verdict = palette(item)
        verdict.ok? ? kept << verdict.card : reasons << verdict.reason
      end
      return refuse("no valid palette (#{reasons.first})") if kept.empty?

      dropped = (list.size - kept.size)
      Verdict.new(card: { "card" => "palette", "palettes" => kept, "dropped" => (dropped if dropped.positive?) }.compact)
    end

    def address_card(raw)
      names, dropped = items(raw["names"]) { |n| address(n) }
      return refuse("names must be a list") if names.nil?
      return refuse("no valid address") if names.empty?

      Verdict.new(card: { "card" => "address", "names" => names.uniq, "dropped" => dropped }.compact)
    end

    # ONE palette, as the visitor's tap also checks it (BuildIntake::Choice).
    def palette(item)
      return refuse("a palette must be an object") unless item.is_a?(Hash)

      item = item.transform_keys(&:to_s)
      unknown = item.keys - PALETTE_KEYS
      return refuse("unknown palette field(s) #{unknown.first(3).join(', ')}") if unknown.any?

      name = plain(item["name"].to_s)
      return refuse("palette name #{name[0, 30].inspect} is not allowed") unless name.match?(PALETTE_NAME)

      out = { "name" => name }
      MODES.each do |mode|
        colors = item[mode]
        return refuse("#{mode} must be an object") unless colors.is_a?(Hash)

        colors = colors.transform_keys(&:to_s)
        return refuse("#{mode} needs exactly #{ROLES.join(', ')}") unless colors.keys.sort == ROLES.sort

        hex = ROLES.to_h { |role| [ role, Contrast.normalize(colors[role]) ] }
        bad = hex.find { |_, v| v.nil? }
        return refuse("#{mode} #{bad.first} is not a hex colour") if bad

        ratio = Contrast.ratio(hex["text"], hex["surface"])
        return refuse("#{mode} text on surface is #{ratio}:1, under #{Contrast::MIN_TEXT_RATIO}:1") if ratio < Contrast::MIN_TEXT_RATIO

        out[mode] = hex
      end
      Verdict.new(card: out)
    end

    # A CTO name, cleaned, or nil when it is not one.
    def cto_name(value)
      return nil unless value.is_a?(String)

      name = plain(value)
      name.match?(NAME) ? name : nil
    end

    # A subdomain suggestion, normalized, or nil when it could never be claimed.
    def address(value)
      return nil unless value.is_a?(String)

      name = AppRequest.normalize_subdomain(value)
      return nil unless name.match?(AppRequest::SUBDOMAIN_FORMAT)
      return nil if AppRequest.reserved_names.include?(name)

      name
    end

    # [kept values, dropped count or nil], or [nil, nil] when `list` is not a list.
    def items(list)
      return [ nil, nil ] unless list.is_a?(Array)

      kept = list.first(MAX_ITEMS).filter_map { |item| yield(item) }
      dropped = list.size - kept.size
      [ kept, (dropped if dropped.positive?) ]
    end

    # Text without control characters or runs of whitespace.
    def plain(text) = text.to_s.gsub(/[[:cntrl:]]/, " ").squish

    def refuse(reason) = Verdict.new(reason: reason)
  end
end
