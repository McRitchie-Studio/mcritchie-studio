# One entry on /integrations, read from config/integrations.yml: a free
# integration with an account the client owns, or an add-on service we run.
# A config file, not a table, for the same reason as WorkspacePackage: the
# contents are still being decided, and a YAML edit reviews cleanly in a PR.
class Integration
  CONFIG = Rails.root.join("config/integrations.yml")
  # live: delivered today. soon: not delivered ("Coming soon"). on_request:
  # delivered per contract after a call.
  STATUSES = %w[live soon on_request].freeze
  CTAS = %w[connect talk].freeze
  CTA_LABELS = { "connect" => "Connect", "talk" => "Talk to us" }.freeze

  Group = Struct.new(:key, :title, :kicker, :summary, :entries, keyword_init: true) do
    def add_ons? = key == "add_ons"
  end

  Entry = Struct.new(:key, :group, :name, :icon, :blurb, :status, :tier, :tier_note, :price, :price_note, :cta,
                     keyword_init: true) do
    def live? = status == "live"
    def soon? = status == "soon"
    def on_request? = status == "on_request"

    # The entry leads with a brand logo when its icon is a software key in
    # config/workspace_icons.yml; otherwise the icon is an emoji.
    def brand = WorkspaceIconConfig.software?(icon) ? icon.to_s : nil

    def cta_label = CTA_LABELS.fetch(cta)

    # "Every plan" from the first tier, "From Pro" above it, nil with no gate.
    def availability
      return if tier.blank?

      first = WorkspacePackage.keys.first
      tier == first ? "Every plan" : "From #{WorkspacePackage.find(tier).name}"
    end

    # Integrations are free; an add-on shows its price, or "Quote".
    def price_label = group == "add_ons" ? (price.presence || "Quote") : "Free"
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

    # The honesty rule, enforced on load: an unknown status or CTA, a tier that
    # is not a package, or a Connect button on anything not live, fails the
    # page instead of rendering a promise as a feature.
    def validate!(entry)
      raise ArgumentError, "#{entry.key}: unknown status #{entry.status.inspect}" unless STATUSES.include?(entry.status)
      raise ArgumentError, "#{entry.key}: unknown cta #{entry.cta.inspect}" unless CTAS.include?(entry.cta)
      raise ArgumentError, "#{entry.key}: Connect is for live entries only" if entry.cta == "connect" && !entry.live?
      raise ArgumentError, "#{entry.key}: unknown tier #{entry.tier.inspect}" if entry.tier.present? && WorkspacePackage.find(entry.tier).nil?
    end
  end
end
