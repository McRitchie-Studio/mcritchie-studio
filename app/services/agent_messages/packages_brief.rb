module AgentMessages
  # What Alex knows about the packages (docs/agents/system/agent-message-loop.md,
  # "Packages and upgrade proposals"): the tiers, their prices monthly and
  # annual, and what each card includes, read from WorkspacePackage, the model
  # /packages renders, so the answer and the page cannot drift. No list is copied
  # anywhere: change config/workspace_packages.yml and the next answer follows.
  #
  # MemoryBundle puts it on every answer the soul `alex` gives (packages_json);
  # ContextBuilder#packages_block prints it, in code, outside the untrusted fence.
  # It names prices and inclusions only: the cost basis, client names, and each
  # tier's token and lane caps stay out of a public prompt.
  module PackagesBrief
    SOUL = "alex".freeze
    BUDGET = 4_000

    module_function

    # The brief as lines of text, or nil when the config cannot be read (the
    # answer goes on without it, and the reason is logged).
    def text
      packages = WorkspacePackage.all
      discount = WorkspacePackage.annual_discount_percent
      lines = packages.select(&:card?).map { |package| card_line(package) }
      if (custom = packages.reject(&:card?).last)
        lines << "#{custom.name}: custom pricing, by contract. #{custom.tagline} Adds: #{custom.highlights.join('; ')}."
      end
      intro = "Each tier includes everything in the one before it, as the /packages page says."
      intro += " Annual billing saves #{discount}%." if discount.positive?
      [ intro, *lines ].join("\n").truncate(BUDGET, separator: "\n")
    rescue StandardError => e
      Rails.logger.warn("[agent-messages] packages brief unavailable (#{e.class})")
      nil
    end

    # The tiers an upgrade proposal may name: every tier but the free one, in
    # ladder order (AgentProposals::Upgrade checks a proposal against this).
    def upgrade_tiers = WorkspacePackage.all.reject(&:free?).map(&:key)

    def card_line(package)
      included = package.card_lines.select(&:included?).map { |line| line_text(line) }
      soon = package.card_lines.select(&:soon?).map(&:title)
      parts = [ "#{package.name} (#{package.key}): #{price(package)}. #{package.tagline}" ]
      parts << "Includes: #{included.join('; ')}." if included.any?
      parts << "Coming soon: #{soon.join('; ')}." if soon.any?
      parts.join(" ")
    end

    def dollars(amount) = ActiveSupport::NumberHelper.number_to_currency(amount, precision: 0)

    def line_text(line) = line.sub.present? ? "#{line.title} (#{line.sub})" : line.title

    def price(package)
      return "free, no card needed" if package.free?
      return package.price_label.presence || "pricing coming soon" unless package.priced?

      monthly = "#{dollars(package.price_monthly)}/month"
      package.annual_price ? "#{monthly}, or #{dollars(package.annual_price)}/year billed annually" : monthly
    end
  end
end
