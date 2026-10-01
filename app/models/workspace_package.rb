# A McRitchie Studio package tier (Vibe, Pro, Growth, Enterprise) and the
# features it includes, read from config/workspace_packages.yml — the one place
# package contents live.
#
# The config is shaped as FEATURE ROWS, each carrying every package's value,
# because the full-stack page compares packages in columns on the same row
# ("Eco dyno" vs "Basic dyno"). Not a database table on purpose: contents are
# still being decided, and a config file is an edit anyone can review in a PR,
# with the SOP each feature names checked by the suite against the files on disk.
class WorkspacePackage
  CONFIG = Rails.root.join("config/workspace_packages.yml")
  SOPS_GLOB = Rails.root.join("docs/agents/agents/*/sops/*.md")
  # live: an SOP delivers it today. builtin: part of the app template or the
  # service, nothing to provision. planned: not delivered yet ("Coming soon").
  STATUSES = %w[live builtin planned].freeze
  CTA_ACTIONS = %w[build schedule enterprise_booking].freeze

  # The tier keys of 2026-09-25, and the v2 tier each one became on 2026-09-30.
  # Migration RemapPackageTiers applied it to stored rows; kept here so the
  # mapping has one spelling the migration's test can hold it to.
  LEGACY_TIERS = { "launch" => "vibe", "host" => "pro", "workspace" => "growth", "agentic" => "growth" }.freeze

  # Brand logos with a partial in app/views/packages/logos/. Any other `icon`
  # value is an emoji rendered as text.
  LOGOS = %w[google tiktok instagram].freeze

  Feature = Struct.new(:name, :category, :icon, :blurb, :values, :sop, :section, :you_do, :status, :software, :shows,
                       keyword_init: true) do
    def live? = status == "live"

    def planned? = status == "planned"

    # Delivered today, by an SOP or by the platform itself.
    def delivered? = !planned?

    # The software keys (config/workspace_icons.yml) this feature puts in a
    # client's stack. A planned feature provisions nothing: it is a promise.
    def software_keys = delivered? ? Array(software) : []

    # Every software drawn beside the row on the full-stack page: what it
    # provisions (or will), plus add-ons it only shows.
    def display_software = (Array(software) + Array(shows)).uniq

    # One logo key, or a list of them shown side by side.
    def logos = Array(icon).select { |key| LOGOS.include?(key) }
    def logo? = logos.any? && logos.size == Array(icon).size

    # The package's value for this row: a string ("Basic dyno"), true
    # (included, nothing to quantify), or nil (not included).
    def value_for(package_key)
      value = values[package_key.to_s]
      value == false ? nil : value
    end

    def included_in?(package_key) = !value_for(package_key).nil?

    # A row whose value changes between packages — the page highlights it.
    def varies? = values.values.uniq.size > 1

    # "agents/steffon/sops/domain-dns" — the docs route's path for this row's
    # SOP, or nil when it names none or the file is gone.
    def doc_path
      return nil if sop.blank?

      WorkspacePackage.sop_paths[sop]
    end
  end

  attr_reader :key, :name, :tagline, :price_monthly, :price_label, :comp, :highlights, :cta

  def initialize(attrs, annual_discount_percent: 0)
    @key = attrs.fetch("key")
    @name = attrs.fetch("name")
    @tagline = attrs["tagline"]
    @price_monthly = attrs["price_monthly"].presence
    @price_label = attrs["price_label"].presence
    @comp = attrs["comp"]
    @highlights = Array(attrs["highlights"])
    @cta = (attrs["cta"] || {}).slice("label", "action")
    @featured = attrs["featured"] == true
    @annual_discount_percent = annual_discount_percent.to_i
  end

  def self.config = YAML.safe_load_file(CONFIG)

  def self.all
    discount = annual_discount_percent
    config.fetch("packages").map { |attrs| new(attrs, annual_discount_percent: discount) }
  end

  def self.find(key) = all.find { |package| package.key == key.to_s }

  def self.keys = config.fetch("packages").map { |attrs| attrs.fetch("key") }

  def self.annual_discount_percent = config.dig("billing", "annual_discount_percent").to_i

  # The Enterprise booking page, or nil while the config leaves it blank (the
  # CTA then falls back to the studio's own booking calendar). Only an
  # https URL counts, so a typo can never render a javascript: or relative link.
  def self.enterprise_booking_url
    url = config["enterprise_booking_url"].to_s.strip
    url.match?(%r{\Ahttps://\S+\z}) ? url : nil
  end

  # category key => heading, in page order.
  def self.categories = config.fetch("categories")

  def self.features
    package_keys = keys
    config.fetch("features").map do |attrs|
      Feature.new(**attrs.except(*package_keys).symbolize_keys, values: attrs.slice(*package_keys))
    end
  end

  # [[category key, heading, [features]], ...] in the config's category order.
  def self.features_by_category
    grouped = features.group_by(&:category)
    categories.filter_map { |key, heading| [ key, heading, grouped[key] ] if grouped[key] }
  end

  # sop invocation => docs path, built from the files on disk so a renamed or
  # deleted SOP reads as missing rather than as a broken link.
  def self.sop_paths
    Dir.glob(SOPS_GLOB).to_h do |file|
      relative = Pathname.new(file).relative_path_from(Rails.root.join("docs/agents")).to_s.delete_suffix(".md")
      [ File.basename(file, ".md"), relative ]
    end
  end

  # The features this package includes, in row order.
  def features = self.class.features.select { |feature| feature.included_in?(key) }

  def featured? = @featured

  def priced? = price_monthly.present?

  def free? = priced? && price_monthly.zero?

  # Every software this tier provisions, in feature order — what /stack draws
  # for a client on it.
  def software_keys = features.flat_map(&:software_keys).uniq

  # Billed annually: the discount applies to the whole year.
  # $100/mo at 10% off is $1,080/yr, which reads as $90/mo.
  def annual_price
    return nil unless priced? && !free?

    (price_monthly * 12 * (100 - @annual_discount_percent) / 100.0).round
  end

  def annual_monthly_equivalent = annual_price ? (annual_price / 12.0).round(2) : nil
end
