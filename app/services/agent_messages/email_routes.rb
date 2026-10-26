module AgentMessages
  # The `email:` half of config/agent_routes.yml: which CTO an email to team@ is
  # for, and the addresses that are ours (docs/agents/system/agent-message-loop.md,
  # "Email"). Pure: it reads headers and text and touches nothing.
  #
  # THE ROUTING RULE, in order (the first that matches wins):
  #   1. ALIAS. A To or Cc address is a CTO's own address (`avi@mcritchie.studio`
  #      → avi). The souls' addresses are Google groups that redirect into
  #      team@, so the original To survives the hop. The first such address in
  #      To, then Cc, wins.
  #   2. NAME. The mail is to team@ (To or Cc) and its subject (after any Re:/Fwd:
  #      prefixes) or the first non-blank line of its NEW text starts with a
  #      CTO's name as an address: `Avi, …`, `Avi: …`, `Hi Avi, …`, `@Avi …`.
  #      A name merely appearing in a sentence ("Turf scores look off") is not one.
  #   3. THREAD. A reply whose In-Reply-To or References names an email the
  #      mailbox holds continues that thread's soul (EmailIngest decides this,
  #      since it needs the database).
  # Anything else is not for an agent: it stays a plain desk capture.
  class EmailRoutes
    PATH = Rails.root.join("config/agent_routes.yml")
    GREETING = /(?:(?:hi|hey|hello|dear)\s+)?/i
    SUBJECT_PREFIX = /\A(?:\s*(?:re|fwd?|aw)\s*:\s*)+/i

    Soul = Struct.new(:slug, :addresses, :names, :from, keyword_init: true)
    Result = Struct.new(:soul, :routed_by, :detail, keyword_init: true) do
      def routed? = soul.present?
    end

    attr_reader :team_address, :souls, :agent_addresses, :pinned_dkim

    def self.load(path = PATH)
      new((YAML.safe_load_file(path, aliases: false) || {})["email"] || {})
    end

    def self.current = @current ||= load

    class << self
      attr_writer :current

      def reset! = @current = nil
    end

    def initialize(config)
      config ||= {}
      @team_address = config["team_address"].to_s.strip.downcase.presence
      @souls = (config["souls"] || {}).map do |slug, spec|
        spec ||= {}
        Soul.new(slug: slug.to_s, addresses: Array(spec["addresses"]).map { |a| a.to_s.strip.downcase },
                 names: Array(spec["names"]).map { |n| n.to_s.strip }.reject(&:empty?),
                 from: spec["from"].to_s.strip.presence)
      end
      # { domain => [selectors] }: a From in that domain is verified only when
      # every aligned DKIM-Signature names one of them (EmailTrust, "PINNED SELECTORS").
      @pinned_dkim = (config["pinned_dkim"] || {}).to_h do |domain, selectors|
        [ domain.to_s.strip.downcase, Array(selectors).map { |sel| sel.to_s.strip.downcase }.reject(&:empty?) ]
      end
      @agent_addresses = (Array(config["agent_addresses"]).map { |a| a.to_s.strip.downcase } +
                          [ @team_address ].compact + @souls.flat_map(&:addresses)).uniq
    end

    # Raised at boot in production when the pins are missing or empty
    # (config/initializers/agent_email_pins.rb).
    class PinsMissing < StandardError; end

    # Why these routes cannot pin the owner's domain, or [] when they can. The
    # team address's domain is the one whose mail is trusted as Alex McRitchie, so it must
    # be pinned to at least one selector: a missing or misspelled `pinned_dkim`
    # would otherwise turn the pin off without a word, and any DKIM that passes
    # for the domain (a Resend send, say) would be trusted as him.
    def pin_problems
      problems = []
      problems << "email.pinned_dkim is missing or empty" if @pinned_dkim.empty?
      @pinned_dkim.each { |domain, selectors| problems << "email.pinned_dkim.#{domain} names no selector" if selectors.empty? }
      team_domain = @team_address.to_s.split("@", 2).last
      if team_domain.present? && @pinned_dkim[team_domain].blank?
        problems << "email.pinned_dkim does not pin #{team_domain}, the team address's domain"
      end
      problems
    end

    # Production refuses to boot on pin_problems; other environments boot (a
    # desk or a test may run without pins). Returns the routes it checked.
    def self.verify_pins!(routes = current, production: Rails.env.production?)
      return routes unless production

      problems = routes.pin_problems
      return routes if problems.empty?

      raise PinsMissing, "config/agent_routes.yml: #{problems.join('; ')}. Owner trust on email needs the " \
                         "pinned DKIM selector (docs/agents/system/agent-message-loop.md, \"Email\")."
    end

    def soul(slug) = @souls.find { |s| s.slug == slug.to_s }

    # The From line a soul's reply is sent with ("Avi <avi@mcritchie.studio>").
    def from_for(slug) = soul(slug)&.from

    # The address a soul's email thread is filed under (its channel_ref): its own
    # alias, else team@.
    def address_for(slug) = soul(slug)&.addresses&.first || @team_address

    # True for any address the fleet itself sends or receives as: the CTO aliases,
    # team@, and every other soul's address. Mail FROM one of these is never answered.
    def agent_address?(addr) = @agent_addresses.include?(addr.to_s.strip.downcase)

    # Rules 1 and 2. `to` and `cc` are address lists; `text` is the NEW text of the
    # mail (EmailBody.new_text), never the quoted history.
    def route(to:, cc:, subject:, text:)
      recipients = (Array(to) + Array(cc)).map { |a| a.to_s.strip.downcase }
      recipients.each do |addr|
        hit = @souls.find { |s| s.addresses.include?(addr) }
        return Result.new(soul: hit.slug, routed_by: "alias", detail: { "matched" => "alias:#{addr}" }) if hit
      end

      if @team_address && recipients.include?(@team_address)
        line = text.to_s.lines.map(&:strip).find(&:present?)
        { "subject" => subject.to_s.sub(SUBJECT_PREFIX, "").strip, "first line" => line.to_s }.each do |where, value|
          hit = named(value)
          return Result.new(soul: hit.slug, routed_by: "name", detail: { "matched" => "name:#{where}" }) if hit
        end
      end

      Result.new(soul: nil, routed_by: "none", detail: { "reason" => "not to a CTO alias and no CTO named" })
    end

    private

    def named(value)
      @souls.find do |s|
        s.names.any? do |name|
          n = Regexp.escape(name)
          value.match?(/\A@#{n}\b/i) || value.match?(/\A#{GREETING}#{n}\s*[,:]/i)
        end
      end
    end
  end
end
