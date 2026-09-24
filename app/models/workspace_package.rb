# A McRitchie Studio workspace package (Basic, Pro) read from
# config/workspace_packages.yml — the one place package contents live.
#
# Not a database table on purpose: contents are still being decided, and a
# config file is an edit anyone can review in a PR, with the SOP each item names
# checked by the suite against the files on disk.
class WorkspacePackage
  CONFIG = Rails.root.join("config/workspace_packages.yml")
  SOPS_GLOB = Rails.root.join("docs/agents/agents/*/sops/*.md")
  STATUSES = %w[live planned].freeze

  # Brand logos with a partial in app/views/packages/logos/. Any other `icon`
  # value is an emoji rendered as text.
  LOGOS = %w[google tiktok instagram].freeze

  Item = Struct.new(:name, :blurb, :sop, :section, :you_do, :status, :icon, :detail, :package_key,
                    keyword_init: true) do
    # One logo key, or a list of them shown side by side.
    def logos = Array(icon).select { |key| LOGOS.include?(key) }
    def logo? = logos.any? && logos.size == Array(icon).size

    def live? = status == "live"

    # "agents/steffon/sops/domain-dns" — the docs route's path for this item's
    # SOP, or nil when the item names none (a planned item) or the file is gone.
    def doc_path
      return nil if sop.blank?

      WorkspacePackage.sop_paths[sop]
    end
  end

  attr_reader :key, :name, :tagline, :price_monthly, :includes

  def initialize(attrs, annual_discount_percent: 0)
    @key = attrs.fetch("key")
    @name = attrs.fetch("name")
    @tagline = attrs["tagline"]
    @price_monthly = attrs["price_monthly"].presence
    @annual_discount_percent = annual_discount_percent.to_i
    @includes = attrs["includes"].presence
    @own_items = Array(attrs["items"]).map do |item|
      Item.new(**item.slice(*Item.members.map(&:to_s)).symbolize_keys, package_key: @key)
    end
  end

  def self.all
    config = YAML.safe_load_file(CONFIG)
    discount = config.dig("billing", "annual_discount_percent")
    config.fetch("packages").map { |attrs| new(attrs, annual_discount_percent: discount) }
  end

  def self.annual_discount_percent
    YAML.safe_load_file(CONFIG).dig("billing", "annual_discount_percent").to_i
  end

  def priced? = price_monthly.present?

  # Billed annually: the discount applies to the whole year.
  # $100/mo at 10% off is $1,080/yr, which reads as $90/mo.
  def annual_price
    return nil unless priced?

    (price_monthly * 12 * (100 - @annual_discount_percent) / 100.0).round
  end

  def annual_monthly_equivalent = priced? ? (annual_price / 12.0).round(2) : nil

  def self.find(key) = all.find { |package| package.key == key.to_s }

  # sop invocation => docs path, built from the files on disk so a renamed or
  # deleted SOP reads as missing rather than as a broken link.
  def self.sop_paths
    Dir.glob(SOPS_GLOB).to_h do |file|
      relative = Pathname.new(file).relative_path_from(Rails.root.join("docs/agents")).to_s.delete_suffix(".md")
      [ File.basename(file, ".md"), relative ]
    end
  end

  # Items this package adds on top of the one it includes.
  def own_items = @own_items

  # Everything the package delivers, the included package's items first. An own
  # item with the same name as an included one REPLACES it in place (an upgrade),
  # so Pro lists Google Workspace once, at 10 users.
  def items
    base = includes ? self.class.find(includes)&.items.to_a : []
    upgrades = own_items.index_by(&:name)
    merged = base.map { |item| upgrades.delete(item.name) || item }
    merged + own_items.select { |item| upgrades.key?(item.name) }
  end

  def included_package = includes && self.class.find(includes)
end
