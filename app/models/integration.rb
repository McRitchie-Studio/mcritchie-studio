# One entry on /integrations, read from config/integrations.yml: a free
# integration with an account the client owns, or an add-on service we run.
# A config file, not a table, for the same reason as WorkspacePackage: the
# contents are still being decided, and a YAML edit reviews cleanly in a PR.
class Integration
  CONFIG = Rails.root.join("config/integrations.yml")
  # live: delivered today. soon: not delivered ("Coming soon"). on_request:
  # delivered per contract after a call.
  STATUSES = %w[live soon on_request].freeze
  # Every button opens the /contact form prefilled; the intent rides along in
  # the submission's `source`. It follows from the group and the status, never
  # from config, so a Coming soon entry can never say Connect.
  INTENTS = %w[connect notify add_on custom].freeze
  CTA_LABELS = { "connect" => "Connect", "notify" => "Get notified", "add_on" => "Talk to us", "custom" => "Talk to us" }.freeze
  PAGE = "integrations".freeze
  # Entries with a guide page at /integrations/<guide> (IntegrationsController).
  GUIDES = %w[discord].freeze
  # An ability is delivered today (live) or not yet (soon), like an entry.
  ABILITY_STATUSES = %w[live soon].freeze

  # One way a client's account is connected (config `connection_methods`):
  # who it covers, the setup it takes, and the upkeep it leaves. Two ways can
  # unlock the same ability with very different upkeep: a person's sign-in may
  # ask again, an admin's grant does not.
  ConnectionMethod = Struct.new(:key, :label, :covers, :setup, :upkeep, keyword_init: true)

  # One thing an entry can do once connected, and the ways that unlock it.
  Ability = Struct.new(:key, :name, :via, :status, keyword_init: true) do
    def soon? = status == "soon"
  end

  Group = Struct.new(:key, :title, :kicker, :summary, :entries, keyword_init: true) do
    def add_ons? = key == "add_ons"
    def custom? = key == "custom"
  end

  Entry = Struct.new(:key, :group, :name, :icon, :blurb, :status, :tier, :tier_note, :price, :price_note, :guide,
                     :connects, :abilities, :connection_methods, keyword_init: true) do
    def live? = status == "live"

    # Is every ability this method unlocks still Coming soon? Then the way is
    # offered but not delivered, and the card says so. A method no ability
    # names is judged by the entry's own status.
    def method_soon?(key)
      using = Array(abilities).select { |ability| ability.via.include?(key) }
      using.empty? ? soon? : using.all?(&:soon?)
    end
    def soon? = status == "soon"
    def on_request? = status == "on_request"

    # The entry leads with a brand logo when its icon is a software key in
    # config/workspace_icons.yml; otherwise the icon is an emoji.
    def brand = WorkspaceIconConfig.software?(icon) ? icon.to_s : nil

    # connect: request a connection (an integration, live or on request).
    # notify: hear when a Coming soon integration ships. add_on: talk about a
    # standard service. custom: scope a rarer need.
    def intent
      return "add_on" if group == "add_ons"
      return "custom" if group == "custom"

      soon? ? "notify" : "connect"
    end

    def cta_label = CTA_LABELS.fetch(intent)

    # What the card link carries into ContactSubmission#source.
    def contact_source = { page: PAGE, item: key, intent: intent }

    # The source a guide page's own button carries ("integrations/discord").
    def guide_contact_source = { page: "#{PAGE}/#{guide}", item: key, intent: intent }

    # The one line the /contact form's message starts with.
    def contact_message
      case intent
      when "connect" then "I'd like to connect #{name}."
      when "notify" then "Please let me know when #{name} is available."
      else "I'd like to talk about #{name}."
      end
    end

    # "Every plan" from the first tier, "From Pro" above it, nil with no gate.
    def availability
      return if tier.blank?

      first = WorkspacePackage.keys.first
      tier == first ? "Every plan" : "From #{WorkspacePackage.find(tier).name}"
    end

    # Integrations are free; an add-on shows its price, or "Quote"; a custom
    # entry shows no price line at all (nil).
    def price_label
      case group
      when "integrations" then "Free"
      when "add_ons" then price.presence || "Quote"
      end
    end
  end

  class << self
    def groups
      methods = connection_methods
      config.fetch("groups").map do |group|
        entries = group.fetch("entries").map { |attrs| build_entry(group["key"], attrs, methods) }
        Group.new(key: group["key"], title: group["title"], kicker: group["kicker"], summary: group["summary"], entries: entries)
      end
    end

    def entries = groups.flat_map(&:entries)

    # Every connection method the config defines, keyed by its key.
    def connection_methods
      config.fetch("connection_methods").to_h do |key, attrs|
        [ key, ConnectionMethod.new(key: key, **attrs.slice(*ConnectionMethod.members.map(&:to_s).without("key")).symbolize_keys) ]
      end
    end

    def connection_method(key) = connection_methods.fetch(key.to_s)

    def find(key) = entries.find { |entry| entry.key == key.to_s }

    private

    def config = YAML.safe_load_file(CONFIG)

    def build_entry(group_key, attrs, methods = connection_methods)
      entry = Entry.new(group: group_key, **attrs.slice(*Entry.members.map(&:to_s).without("group", "connection_methods")).symbolize_keys)
      entry.connects = Array(entry.connects).map(&:to_s)
      entry.abilities = Array(entry.abilities).map do |ability|
        Ability.new(key: ability["key"].to_s, name: ability["name"], via: Array(ability["via"]).map(&:to_s),
                    status: ability["status"] || "live")
      end
      validate!(entry)
      validate_connections!(entry, methods)
      # The ways this entry connects, as ConnectionMethod rows, in the entry's order.
      entry.connection_methods = entry.connects.map { |key| methods.fetch(key) }
      entry
    end

    # Enforced on load: an unknown status, or a tier that is not a package,
    # fails the page instead of rendering something it cannot honestly label.
    def validate!(entry)
      raise ArgumentError, "#{entry.key}: unknown status #{entry.status.inspect}" unless STATUSES.include?(entry.status)
      raise ArgumentError, "#{entry.key}: unknown guide #{entry.guide.inspect}" if entry.guide.present? && !GUIDES.include?(entry.guide)
      raise ArgumentError, "#{entry.key}: unknown tier #{entry.tier.inspect}" if entry.tier.present? && WorkspacePackage.find(entry.tier).nil?
    end

    # An ability can never promise a way in the entry does not offer: every
    # method an entry names is defined, and every ability names at least one
    # of the entry's own methods and nothing else.
    def validate_connections!(entry, methods)
      unknown = entry.connects - methods.keys
      raise ArgumentError, "#{entry.key}: unknown connection method #{unknown.join(', ')}" if unknown.any?

      keys = entry.abilities.map(&:key)
      raise ArgumentError, "#{entry.key}: duplicate ability keys" unless keys.uniq.size == keys.size

      entry.abilities.each do |ability|
        raise ArgumentError, "#{entry.key}.#{ability.key}: unknown status #{ability.status.inspect}" unless ABILITY_STATUSES.include?(ability.status)
        raise ArgumentError, "#{entry.key}.#{ability.key}: names no connection method" if ability.via.empty?

        missing = ability.via - entry.connects
        raise ArgumentError, "#{entry.key}.#{ability.key}: #{missing.join(', ')} is not a way #{entry.key} connects" if missing.any?
      end
    end
  end
end
