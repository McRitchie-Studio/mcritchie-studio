# Who may see which app and its CTO, and what the owner's sidebar says
# (docs/agents/system/app-owners.md; plan: Phase 6a of .agents/epics/domain-agents.md).
#
#   AppOwnership.visible_apps(user)          # admins: every app; owners: theirs
#   AppOwnership.manage_app?(user, "cyvasse")
#   AppOwnership.cto_for_app("turf-monster") # => Cto(domain: "turf_monster", soul: "turf_monster", …)
#   AppOwnership.cto_for_app("pawsome")      # a client app => Cto(soul: "client_cto", app_cto: AppCto, …)
#   AppOwnership.cto_for_agent("turf-monster")
#   AppOwnership.sidebar_links(user)         # [] for a user who owns nothing
#
# THE CTO MAP is config/cto_reports.yml (domain => app, soul): the one file that
# names every app's CTO, Cyvasse's included. Its display name is the domain's
# reply_name in config/agent_domains.yml ("Turf"), else the Agent row's name,
# else the soul titleized. The Agent row is keyed by the soul hyphenated
# (`turf_monster` → `turf-monster`, config/souls.yml).
#
# THE SIDEBAR RULE counts the user's OWN memberships, admins included: at most two
# apps, each by name with its CTO's portrait, and with three or more an "All N Apps"
# link third (Alex McRitchie, 2026-11-04). N is what /applications lists for that
# viewer (visible_apps, the page's own scope), so an admin's N is every app. Each app's page links its own pipeline
# (docs/agents/system/client-pipeline.md) and CTO. A user who owns nothing gets no
# links, admin or not; an admin reaches every app at /applications anyway.
#
# A CLIENT APP's CTO is data, not a soul on disk (AppCto, docs/agents/system/client-cto.md):
# when config/cto_reports.yml names no CTO for an app, its AppCto row does, and
# the CTO is the one `client_cto` soul wearing that row's name and portrait. A
# client CTO has no report and no settings page (`settings?` is false), and it is
# never in `ctos`, which lists the configured ones only.
#
# Nothing here grants a CTO a tool or a capability. The only setting it reaches is
# the CTO's report destination (`cto_report:<domain>`), written by
# AgentSettingsController.
module AppOwnership
  DOMAINS_PATH = Rails.root.join("config/agent_domains.yml")

  Cto = Struct.new(:domain, :app_slug, :soul, :agent, :display_name, :app_cto, keyword_init: true) do
    def report_key = "#{CtoReport::KEY_PREFIX}:#{domain}"
    # A client app's CTO (an AppCto row), as opposed to one of our own souls.
    def client? = !app_cto.nil?
    # Whether /agents/:slug/settings serves it: only a configured CTO has a report to set.
    def settings? = !client? && domain.present?
    # The URL slug: the Agent row's, which is the soul hyphenated.
    def slug = agent&.slug || AppOwnership.agent_slug_for(soul)
  end

  Link = Struct.new(:label, :href, :emoji, :kind, :cto, keyword_init: true)

  SIDEBAR_APPS = 2

  module_function

  def admin?(user) = user.respond_to?(:admin?) && user.admin?

  def owned_app_slugs(user)
    return [] unless user&.slug

    AppMembership.owners.where(user_slug: user.slug).order(:app_slug).pluck(:app_slug)
  end

  def manage_app?(user, app_slug)
    return false if user.nil? || app_slug.blank?

    admin?(user) || AppMembership.owners.exists?(user_slug: user.slug, app_slug: app_slug.to_s)
  end

  def visible_apps(user)
    return App.none if user.nil?

    scope = admin?(user) ? App.all : App.where(slug: AppMembership.owners.where(user_slug: user.slug).select(:app_slug))
    scope.order(:position, :name)
  end

  def agent_slug_for(soul) = soul.to_s.tr("_", "-")

  # Every configured CTO, in config order. One Agent query.
  def ctos(config: CtoReport.config, domains: domain_config)
    rows = config.select { |_domain, row| row.is_a?(Hash) && row["app"].present? && row["soul"].present? }
    agents = Agent.where(slug: rows.values.map { |row| agent_slug_for(row["soul"]) }).index_by(&:slug)
    rows.map do |domain, row|
      agent = agents[agent_slug_for(row["soul"])]
      name = domains.dig(domain.to_s, "reply_name").presence || agent&.name || row["soul"].to_s.titleize
      Cto.new(domain: domain.to_s, app_slug: row["app"].to_s, soul: row["soul"].to_s, agent: agent, display_name: name)
    end
  end

  # The app's CTO: the configured one, else its AppCto row's client CTO, else nil.
  # `client_ctos` is AppCto.for_apps(...) when a list page has preloaded them.
  def cto_for_app(app_slug, ctos: self.ctos, client_ctos: nil)
    ctos.find { |cto| cto.app_slug == app_slug.to_s } || client_cto_for(app_slug, rows: client_ctos)
  end

  def client_cto_for(app_slug, rows: nil)
    row = rows ? rows[app_slug.to_s] : AppCto.find_by(app_slug: app_slug.to_s)
    return nil unless row

    Cto.new(domain: nil, app_slug: row.app_slug, soul: AppCto::SOUL, agent: nil, display_name: row.name, app_cto: row)
  end

  def cto_for_agent(agent_slug, ctos: self.ctos) = ctos.find { |cto| cto.slug == agent_slug.to_s }

  # The CTOs of the apps `user` may see (admins: all of them).
  def visible_ctos(user, ctos: self.ctos)
    return [] if user.nil?
    return ctos if admin?(user)

    owned = owned_app_slugs(user)
    ctos.select { |cto| owned.include?(cto.app_slug) }
  end

  # The owner's sidebar links, counted from the user's own memberships (see THE
  # SIDEBAR RULE above). Each app carries its CTO, for the row's portrait.
  def sidebar_links(user, routes: Rails.application.routes.url_helpers)
    owned = owned_app_slugs(user)
    return [] if owned.empty?

    apps = App.where(slug: owned).order(:position, :name).to_a
    return [] if apps.empty?

    configured = ctos
    clients = AppCto.for_apps(apps.first(SIDEBAR_APPS).map(&:slug))
    links = apps.first(SIDEBAR_APPS).map do |app|
      Link.new(label: app.name, href: routes.application_path(app.slug), emoji: app.emoji.presence || "📱", kind: "app",
               cto: cto_for_app(app.slug, ctos: configured, client_ctos: clients))
    end
    if apps.size > SIDEBAR_APPS
      links << Link.new(label: "All #{visible_apps(user).count} Apps", href: routes.applications_path, emoji: "📱", kind: "apps")
    end
    links
  end

  # The bot a CTO's report posts as (AgentMessages::BotSelector::Choice): its own
  # when DISCORD_BOT_TOKEN_<SOUL> is set, else the shared bot. Never the token.
  def report_bot(cto) = AgentMessages::BotSelector.choice(cto.soul)

  # The channels an owner may pick for a CTO's report, from the synced directory
  # (no Discord call): with the CTO's own bot, those it can post an embed in
  # (DiscordChannel#postable_souls, DiscordDirectory::Sync); without, the shared
  # bot's postable channels. Either way only selectable ones, since
  # ReportDestination holds a pick to that set.
  def report_channels(cto, bot: report_bot(cto))
    scope = DiscordChannel.selectable.directory_order
    bot.soul_bot? ? scope.where("? = ANY(postable_souls)", cto.soul) : scope
  end

  def domain_config(path = DOMAINS_PATH)
    (YAML.safe_load_file(path) || {}).fetch("domains", {}) || {}
  end
end
