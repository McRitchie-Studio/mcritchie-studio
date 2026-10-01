# The client matrix /stack/matrix draws: every client across the top, every
# piece of software any of them runs down the side, grouped by category, and a
# summary band (tier, price, hosting, domain, Google users, Resend) over it.
#
# Nothing here is typed per client. Each cell is read from the same derived
# stack /stack draws, StackClient#software_keys (tier + live credential records
# + extra_software), and its hosting (StackClient#hosting_for): `ms` (McRitchie
# Studio runs it on our account, drawn with the Studio chest), `own` (the
# client's account, drawn as a check) or nil (not in that stack, a dash).
#
# CATEGORY is the one thing config/workspace_icons.yml does not carry, so it
# lives here. A software key it does not name falls into "Other" rather than
# off the page: a new key shows up the moment a stack has it.
class StackMatrix
  CATEGORIES = {
    "Hosting" => %w[heroku],
    "Data" => %w[postgres redis],
    "Domain" => %w[squarespace],
    "Email" => %w[google resend zerobounce ses],
    "Auth" => %w[phantom],
    "Storage & backup" => %w[cloudflare r2 aws],
    "Payments & crypto" => %w[stripe coinbase coinflow moonpay solana squads helius],
    "AI" => %w[anthropic openai fal higgsfield],
    "Data feeds" => %w[espn sleeper serper fred ipinfo],
    "Marketing & social" => %w[x tiktok instagram youtube],
    "Messaging" => %w[discord slack],
    "Observability" => %w[sentry logrocket],
    "Secrets" => %w[1password dashlane],
    "Documents" => %w[egnyte],
    "Platform" => %w[github rails rubygems mcritchie-studio turf-monster]
  }.freeze
  OTHER = "Other".freeze

  Group = Struct.new(:category, :software, keyword_init: true)

  attr_reader :clients

  # `records_by_entity` is the credential census grouped by served entity, read
  # once for the whole page rather than once per client.
  def initialize(clients, records_by_entity = {})
    @clients = clients
    @stacks = clients.to_h { |client| [ client.slug, client.software_keys(records_by_entity.fetch(client.slug, [])) ] }
  end

  def self.category_for(software) = CATEGORIES.find { |_, keys| keys.include?(software.to_s) }&.first || OTHER

  # The software any client runs, in categories (CATEGORIES order, Other last),
  # each in config/workspace_icons.yml's software order. A category no client
  # touches is left out.
  def groups
    order = WorkspaceIconConfig.softwares.keys
    present = @stacks.values.flatten.uniq.sort_by { |key| [ order.index(key) || order.size, key ] }
    names = CATEGORIES.keys + [ OTHER ]
    present.group_by { |key| self.class.category_for(key) }
           .sort_by { |category, _| names.index(category) }
           .map { |category, software| Group.new(category: category, software: software) }
  end

  # Configured software no client's stack has yet — named under the table so a
  # missing row reads as "nobody runs it", not as a bug.
  def unused_software = WorkspaceIconConfig.softwares.keys - @stacks.values.flatten

  # "ms", "own", or nil when the software is not in this client's stack.
  def cell(client, software)
    return nil unless @stacks.fetch(client.slug, []).include?(software)

    client.hosting_for(software)
  end

  # The client's app hosting, read off its Heroku: MS-hosted on our account,
  # white label on theirs, or nil where the stack runs no app.
  def hosting_mode(client)
    return nil unless @stacks.fetch(client.slug, []).include?("heroku")

    client.ms_hosted?("heroku") ? "MS-hosted" : "White label"
  end

  # "Internal" for Studio and Industries, "Free" or "$100/mo" for a priced
  # tier, "Custom" for a tier with no list price.
  def price_label(client)
    return "Internal" if client.internal?

    package = client.package
    return "Custom" unless package&.priced?
    return "Free" if package.free?

    "$#{package.price_monthly.to_i.to_fs(:delimited)}/mo"
  end

  # Monthly recurring revenue at list price: the sum over clients whose tier
  # carries a price. Internal and custom-priced clients add nothing.
  def mrr = paying_clients.sum { |client| client.package.price_monthly }

  def paying_clients = clients.reject(&:internal?).select { |client| client.package&.priced? && !client.package.free? }
end
