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

  Group = Struct.new(:key, :title, :kicker, :summary, :entries, keyword_init: true) do
    def add_ons? = key == "add_ons"
    def custom? = key == "custom"
  end

  Entry = Struct.new(:key, :group, :name, :icon, :blurb, :status, :tier, :tier_note, :price, :price_note, :guide,
                     keyword_init: true) do
    def live? = status == "live"
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
      YAML.safe_load_file(CONFIG).fetch("groups").map do |group|
        entries = group.fetch("entries").map { |attrs| build_entry(group["key"], attrs) }
        Group.new(key: group["key"], title: group["title"], kicker: group["kicker"], summary: group["summary"], entries: entries)
      end
    end

    def entries = groups.flat_map(&:entries)

    def find(key) = entries.find { |entry| entry.key == key.to_s }

    private

    def build_entry(group_key, attrs)
      entry = Entry.new(group: group_key, **attrs.slice(*Entry.members.map(&:to_s).without("group")).symbolize_keys)
      validate!(entry)
      entry
    end

    # Enforced on load: an unknown status, or a tier that is not a package,
    # fails the page instead of rendering something it cannot honestly label.
    def validate!(entry)
      raise ArgumentError, "#{entry.key}: unknown status #{entry.status.inspect}" unless STATUSES.include?(entry.status)
      raise ArgumentError, "#{entry.key}: unknown guide #{entry.guide.inspect}" if entry.guide.present? && !GUIDES.include?(entry.guide)
      raise ArgumentError, "#{entry.key}: unknown tier #{entry.tier.inspect}" if entry.tier.present? && WorkspacePackage.find(entry.tier).nil?
    end
  end
end
