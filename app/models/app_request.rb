# One app someone asked McRitchie Studio to build through /build.
#
# The funnel, in states:
#
#   draft    — the prompt was sent. May have no user yet: the visitor is on the
#              sign-in detour, and the draft is found again by its secret `token`.
#   queued   — signed in and a subdomain claimed. A board task now exists for an
#              agent to pick up (`task_slug`).
#   building — an agent is on it.
#   live     — served at <subdomain>.mcritchie.app.
#   cancelled
#
# Builds are ASYNCHRONOUS and done by agents; nothing here generates an app.
# The claim RESERVES the subdomain. A client app is served on its own registrable
# domain, mcritchie.app (wildcard DNS and certificate since 2026-10-19), by
# ClientAppHost (lib/middleware/client_app_host.rb), never on the hub's
# mcritchie.studio, whose session cookie model-written code must not see.
class AppRequest < ApplicationRecord
  STATUSES = %w[draft queued building live cancelled].freeze
  # A request that holds its subdomain. A cancelled one releases it.
  HOLDING = %w[queued building live].freeze

  # The domain every client app's address is on: <subdomain>.mcritchie.app. It is
  # the PRODUCTION name, ClientAppHost::PRODUCTION_DOMAIN, not ClientAppHost.domain:
  # the address is the promise a visitor keeps, and it is the same whichever
  # environment renders /build (development serves the bundle at
  # <subdomain>.localhost, and QA serves none).
  CLIENT_APP_DOMAIN = "mcritchie.app".freeze
  # The hub's own domain. Client app addresses were spelled <subdomain>.mcritchie.studio
  # until 2026-10-20, so a name pasted with that suffix still cleans to the bare
  # name, and the hub's satellites on it (rantly.mcritchie.studio) stay reserved.
  HUB_DOMAIN = "mcritchie.studio".freeze
  # The suffixes a pasted address may carry, and the domains whose registered
  # hosts reserve their names.
  OUR_DOMAINS = [ CLIENT_APP_DOMAIN, HUB_DOMAIN ].freeze
  PROMPT_LIMIT = 4000

  # 3-30 characters of a-z, 0-9 and hyphens, starting and ending alphanumeric —
  # a valid DNS label that also reads as a name.
  SUBDOMAIN_FORMAT = /\A[a-z0-9][a-z0-9-]{1,28}[a-z0-9]\z/

  # Names that route somewhere of ours, or plausibly will. The satellites'
  # subdomains and slugs are added from config/satellites.yml, so a new
  # satellite is reserved the day it is registered, not the day someone notices.
  # The slug counts too: an app whose production_url is not a subdomain of ours
  # (rolio is a herokuapp host) still keeps its name.
  # A name stays reserved on mcritchie.app because it is ours on mcritchie.studio:
  # rantly.mcritchie.app would pass for our Rantly, and a satellite may move over.
  # `chain` holds chain-ops' planned host, chain.mcritchie.studio, which has no
  # DNS yet, so satellites.yml's production_url (null) cannot reserve it.
  RESERVED = %w[
    www app api admin qa staging dev test demo status docs help support blog
    mail email smtp imap pop ftp ns ns1 ns2 cdn static assets auth login signin
    signup register account billing build stack packages credentials v1
    mcritchie studio team security root
    chain
  ].freeze

  # The names the name field types, one after another, as its placeholder — so
  # the field shows what a good answer looks like instead of saying "yourapp".
  # Cached here rather than generated: every one is a valid, unreserved name.
  EXAMPLE_NAMES = %w[
    pawsome-grooming league-hub taco-truck-map book-club fit-log
    garden-planner band-merch rent-tracker recipe-box tutor-match
    pickup-hoops wedding-rsvp plant-swap budget-buddy dog-walks
    study-sprint yard-sale trivia-night bike-repair pet-sitter
  ].freeze

  # What the board card tells the agent who builds from it, after the
  # requester's prompt. The card is all a builder may read, and the prompt is a
  # customer's words: it never mentions the house rules every new app ships
  # with. So the card names the SOP that carries them, and its acceptance asks
  # for the one a launch has shipped without (`footer_criterion`).
  BUILDER_POINTER = "Work this request by docs/agents/agents/alex/sops/launch-build-queue.md. " \
                    "Every new app ships the site footer, and legal pages when it holds personal data: " \
                    "docs/agents/system/new-app-onboarding-sop.md § 7.".freeze

  # The selector studio-engine's footer partial emits on its root element
  # (`<footer class="ftr" data-site-footer>`); onboarding § 7's DONE line greps
  # for the same attribute.
  FOOTER_SELECTOR = "footer[data-site-footer]".freeze

  belongs_to :user, optional: true

  validates :token, presence: true, uniqueness: true
  validates :prompt, presence: true, length: { maximum: PROMPT_LIMIT }
  validates :status, inclusion: { in: STATUSES }
  validates :tier, inclusion: { in: ->(_) { WorkspacePackage.keys } }
  validates :subdomain, presence: true, unless: :draft?
  # Checked again at the claim (a draft moving to queued), so a name another
  # app took after the visitor tapped it is refused, not double-claimed.
  validate :subdomain_is_claimable, if: -> { subdomain.present? && (new_record? || will_save_change_to_subdomain? || will_save_change_to_status?(from: "draft")) }
  # The tier's apps-per-account limit (config/workspace_packages.yml
  # `apps_per_account`; blank is unlimited, and every tier is today). Admins are
  # exempt: Mr. McRitchie seeds the App Builder with showcase builds (his legacy
  # apps) through the same funnel, and those are not customers.
  validate :apps_per_account_limit, if: -> { user && !user.admin? && HOLDING.include?(status) }
  # The intake fields (/build as a chat with Alex, BuildIntake). Only a visitor's
  # tap writes them (BuildIntake::Choice), and each is held here to the same
  # rules the card was, so no path can store a value a card could not show.
  validates :cto_name, format: { with: BuildIntake::Card::NAME, message: "must be 2 to 24 letters" }, allow_nil: true
  validate :cto_avatar_is_storable, if: -> { cto_avatar.present? }
  validate :palette_is_readable, if: -> { palette.present? }
  validate :answers_are_text

  before_validation :normalize
  before_validation -> { self.token ||= SecureRandom.urlsafe_base64(18) }, on: :create

  scope :holding, -> { where(status: HOLDING) }
  scope :recent, -> { order(created_at: :desc) }

  # The refusal when an account already holds its tier's apps
  # (apps_per_account_limit). BuildController reads the :apps_per_account error
  # detail to offer the app they have and the plans.
  def self.apps_limit_message(plan_name, limit)
    "Your #{plan_name} plan includes #{limit} #{'app'.pluralize(limit)}, and you already have #{limit == 1 ? 'one' : limit}."
  end

  # Read once per process: the preview host checks it on every request
  # (ClientApps::Host), and satellites.yml ships with the code. In development
  # the class reloads with the code, and the memo with it.
  def self.reserved_names
    @reserved_names ||= read_reserved_names
  end

  # Both registries feed it. satellites.yml gives each satellite's slug and host;
  # config/apps.yml (AppCatalog) adds what satellites.yml never lists: every app's
  # slug, its production and QA hosts under ours, and every library's slug and
  # aliases (studio-engine, turf-vault, vault), so a /build app never shares a
  # name with a repo or gem of ours.
  def self.read_reserved_names
    rows = satellite_rows
    hosts = registry_hosts.filter_map do |host|
      domain = OUR_DOMAINS.find { |ours| host.end_with?(".#{ours}") }
      host.delete_suffix(".#{domain}") if domain
    end
    slugs = rows.filter_map { |sat| sat["slug"].presence } +
            AppCatalog.apps.map(&:slug) +
            AppCatalog.libraries.flat_map { |lib| [ lib.slug, *lib.aliases ] }
    (RESERVED + hosts + slugs).uniq.freeze
  end
  private_class_method :read_reserved_names

  # The names the registries serve at <name>.mcritchie.studio: the satellites
  # built before mcritchie.app (rantly, weekly-lock, the showcase rebuilds). A
  # live request holding one (a showcase row, given its subdomain by hand) is
  # served there, so #host names it there. No claim can reach one: each is
  # reserved.
  def self.hub_hosted_names
    @hub_hosted_names ||= registry_hosts.filter_map { |host| host.delete_suffix(".#{HUB_DOMAIN}") if host.end_with?(".#{HUB_DOMAIN}") }.to_set.freeze
  end

  # The address an app named NAME is served at: <name>.mcritchie.app, or, for a
  # satellite built before it (hub_hosted_names), the <name>.mcritchie.studio it
  # is served at. The one spelling #host, the CTO and its handover all use.
  def self.host_for(name)
    return nil if name.blank?

    "#{name}.#{hub_hosted_names.include?(name) ? HUB_DOMAIN : CLIENT_APP_DOMAIN}"
  end

  # Every production and QA host satellites.yml and config/apps.yml name.
  def self.registry_hosts
    urls = satellite_rows.map { |sat| sat["production_url"] } +
           AppCatalog.apps.flat_map { |app| [ app.production_url, app.qa_url ] }
    urls.compact.filter_map do |url|
      URI.parse(url.to_s).host.to_s.presence
    rescue URI::InvalidURIError
      nil
    end
  end
  private_class_method :registry_hosts

  def self.satellite_rows
    YAML.safe_load_file(Rails.root.join("config/satellites.yml")).fetch("satellites", [])
  end
  private_class_method :satellite_rows

  # Why NAME cannot be claimed, or nil when it can. The one answer the live
  # availability check and the model's validation both give.
  def self.unavailable_reason(name, except: nil)
    name = normalize_subdomain(name)
    return "Use 3 to 30 letters, numbers or hyphens, starting and ending with a letter or number." unless name.match?(SUBDOMAIN_FORMAT)
    return "That name is reserved." if reserved_names.include?(name)

    taken = holding.where(subdomain: name)
    taken = taken.where.not(id: except.id) if except&.persisted?
    return "That name is taken." if taken.exists?
    # An app row already holds it (one of ours, or a launched client app).
    return "That name is taken." if App.exists?(slug: name)

    nil
  end

  # unavailable_reason for several names in one pass: { name => reason or nil },
  # keyed by the names as given. One read of the reserved list and one query each
  # for the requests and apps holding any of them, however many names (the
  # domain card checks all of Alex's suggestions on every render).
  def self.unavailable_reasons(names, except: nil)
    normal = Array(names).index_with { |name| normalize_subdomain(name) }
    wanted = normal.values.select { |name| name.match?(SUBDOMAIN_FORMAT) }.uniq
    reserved = wanted.any? ? reserved_names : []
    held = holding.where(subdomain: wanted)
    held = held.where.not(id: except.id) if except&.persisted?
    taken = wanted.empty? ? Set.new : (held.pluck(:subdomain) + App.where(slug: wanted).pluck(:slug)).to_set
    normal.transform_values do |name|
      if !name.match?(SUBDOMAIN_FORMAT) then "Use 3 to 30 letters, numbers or hyphens, starting and ending with a letter or number."
      elsif reserved.include?(name) then "That name is reserved."
      elsif taken.include?(name) then "That name is taken."
      end
    end
  end

  # What the name field does as the user types, done again on the server so the
  # two always agree: lowercase, drop a trailing .mcritchie.app (or the old
  # .mcritchie.studio), turn every run of anything that is not a-z or 0-9 into
  # ONE hyphen, and trim hyphens off both ends. "Uber for Dogs!" becomes
  # "uber-for-dogs"; "Pawsome.mcritchie.app" becomes "pawsome".
  def self.normalize_subdomain(name)
    name = name.to_s.strip.downcase
    domain = OUR_DOMAINS.find { |ours| name.end_with?(".#{ours}") }
    name = name.delete_suffix(".#{domain}") if domain
    name.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def draft? = status == "draft"

  # The checklist beside the /build chat: which of BuildIntake::STEPS are set,
  # in that order. A retired step name (BuildIntake::STEP_ALIASES: "colors")
  # still reads its step's value, but is never one of the keys, so the
  # checklist's values, its JSON and Alex's context carry each step once.
  def intake_checklist
    checklist = Hash.new { |_hash, name| BuildIntake::STEP_ALIASES.key?(name) ? checklist[BuildIntake.step(name)] : nil }
    checklist.merge!("idea" => answers.is_a?(Hash) && answers["idea"].present?,
                     "theme" => palette.present?,
                     "cto" => cto_name.present? && cto_avatar.present?,
                     "address" => subdomain.present?)
  end

  # Build my app lights up only when all four are set.
  def intake_complete? = intake_checklist.values.all?

  # The intake card Alex proposes themes on (BuildIntake::Card "palette"): the
  # theme step's card in the thread.
  THEME_CARD = "palette".freeze

  # Whether the /build page shows the status card yet (build/_status_card):
  # once Alex's THEME card is in this request's thread, or any of the theme, the
  # CTO or the address is set (a draft from before this rule may hold one
  # without a theme card). Locking the idea in (Start App) is not enough: the
  # card waits while Alex is still typing, and pops in on the turn the theme
  # card lands (Alex McRitchie, 2026-10-20; before that, 2026-10-18: no status tiles
  # until Start App). Before then the visitor sees the heading (idea_locked?
  # picks which one).
  def intake_started?
    checklist = intake_checklist
    BuildIntake::STEPS.drop(1).any? { |step| checklist[step] } || theme_card_shown?
  end

  # The visitor tapped Start App on an idea card: the idea is locked in.
  def idea_locked? = intake_checklist["idea"]

  private def theme_card_shown?
    AgentMessage.where(channel: "web", thread_key: BuildIntake.thread_key(token), status: "completed")
                .where("intake_card->>'card' = ?", THEME_CARD).exists?
  end

  # The app's working title on the status card: the title the visitor confirmed
  # (Start App on the idea card), else the newest idea card's proposed title, so
  # the card is named the moment Alex proposes it, else the claimed address in
  # words, else nil.
  def working_title
    confirmed = answers.is_a?(Hash) ? answers["title"].to_s.squish.presence : nil
    confirmed || proposed_title || subdomain&.tr("-", " ")&.titleize
  end

  private def proposed_title
    AgentMessage.where(channel: "web", thread_key: BuildIntake.thread_key(token))
                .where("intake_card->>'card' = 'idea'").order(id: :desc).limit(1)
                .pick(Arel.sql("intake_card->>'title'")).to_s.squish.presence
  end

  # The first unset step, in the order Alex asks, or nil when all are set.
  def next_intake_step = BuildIntake::STEPS.find { |step| !intake_checklist[step] }

  def queued? = status == "queued"

  def url = host && "https://#{host}"

  def host = self.class.host_for(subdomain)

  # Sign-in attaches a draft to whoever finished it. A draft already attached
  # belongs to that user only.
  def claimable_by?(candidate) = user.nil? || user == candidate

  # Claim SUBDOMAIN and queue the build: the request moves to `queued` and a
  # board task opens for an agent, in one transaction, so a queued request
  # always has its task and a task never outlives a failed claim.
  def queue!(name)
    transaction do
      self.subdomain = name
      self.status = "queued"
      self.queued_at = Time.current
      # An admin's request is a showcase build (an example of what the App
      # Builder delivers), never a customer's — kept apart everywhere it shows.
      self.showcase = true if user&.admin?
      save!
      task = Task.create!(
        # Four words whatever the name: the board reads best with a 3-5 word title, and
        # a hyphenated subdomain stays one word.
        title: "Build Launch App #{subdomain}",
        stage: "designed",
        priority: 1,
        description: "#{showcase? ? 'Showcase' : 'Vibe-tier'} app requested through /build by #{user&.email || 'unknown'}.",
        metadata: { "devops" => {
          "kind" => "feature",
          "acceptance" => [ "#{host} serves the app the requester described", footer_criterion ],
          "agent_context" => "Prompt from the requester, verbatim:\n\n#{prompt}\n\n#{intake_context}" \
                             "Subdomain reserved: #{host}. Tier: #{tier}. App request token: #{token}." \
                             "#{showcase? ? ' SHOWCASE build: an example of what the App Builder delivers, submitted by an admin.' : ''}" \
                             "\n\n#{BUILDER_POINTER}"
        } }
      )
      update!(task_slug: task.slug)
    end
    # After the commit, not inside it: the job must never see a request the
    # transaction could still roll back, and a Discord outage must never undo a claim.
    AppRequestDiscordJob.perform_later(id)
    self
  end

  # What the intake chat settled, for the builder's card: empty for a request
  # made before /build became a chat. Read by queue! and AppLaunch.
  def intake_context
    lines = []
    lines << "App: #{answers['title']}" if answers.is_a?(Hash) && answers["title"].present?
    lines << "Sharpened idea: #{answers['idea']}" if answers.is_a?(Hash) && answers["idea"].present?
    lines << "Key features: #{Array(answers['features']).join('; ')}" if answers.is_a?(Hash) && answers["features"].present?
    lines << "For: #{answers['audience']}" if answers.is_a?(Hash) && answers["audience"].present?
    lines << "Day one: #{answers['day_one']}" if answers.is_a?(Hash) && answers["day_one"].present?
    lines << "CTO: #{cto_name} (portrait #{cto_avatar})" if cto_name.present?
    if palette.present?
      lines << "Palette #{palette['name']}: light #{palette['light'].to_json}, dark #{palette['dark'].to_json}"
    end
    lines.empty? ? "" : "#{lines.join("\n")}\n\n"
  end

  # The card's second acceptance bullet: the footer, on the page a visitor
  # lands on. Eight words whatever the name, inside the board's 5-12 word rule.
  def footer_criterion = "#{host}'s home page renders the site footer (#{FOOTER_SELECTOR})"

  private

  def cto_avatar_is_storable
    errors.add(:cto_avatar, "is not a known portrait") unless BuildIntake::Portraits.storable?(cto_avatar)
  end

  def palette_is_readable
    verdict = BuildIntake::Card.palette(palette)
    errors.add(:palette, verdict.reason) unless verdict.ok?
  end

  def answers_are_text
    return errors.add(:answers, "must be a map") unless answers.is_a?(Hash)

    unknown = answers.keys - BuildIntake::Card::TEXT_LIMITS.keys - %w[features]
    errors.add(:answers, "has unknown field(s) #{unknown.join(', ')}") if unknown.any?
    BuildIntake::Card::TEXT_LIMITS.each do |key, limit|
      value = answers[key]
      errors.add(:answers, "#{key} must be text under #{limit} characters") unless value.nil? || (value.is_a?(String) && value.length <= limit)
    end
    features = answers["features"]
    return if features.nil?
    return if features.is_a?(Array) && features.size <= BuildIntake::Card::FEATURES.max &&
              features.all? { |f| f.is_a?(String) && f.length <= BuildIntake::Card::FEATURE_LIMIT }

    errors.add(:answers, "features must be up to #{BuildIntake::Card::FEATURES.max} short lines")
  end

  def normalize
    self.prompt = prompt.to_s.strip.presence
    self.subdomain = self.class.normalize_subdomain(subdomain).presence
  end

  def subdomain_is_claimable
    reason = self.class.unavailable_reason(subdomain, except: self)
    errors.add(:subdomain, reason) if reason
  end

  def apps_per_account_limit
    package = WorkspacePackage.find(tier)
    limit = package&.apps_per_account
    return if limit.nil?

    others = self.class.holding.where(user: user, tier: tier)
    others = others.where.not(id: id) if persisted?
    return if others.count < limit

    errors.add(:base, :apps_per_account, message: self.class.apps_limit_message(package.name, limit))
  end
end
