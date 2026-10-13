# A McRitchie Studio package tier (Vibe, Builder, Pro, Team, Enterprise) and the
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
  # The feature row /stack holds each client's live DNS host to: the Cloudflare
  # move Pro sells (it was the "Cloudflare DNS" row until 2026-10-12). Its cells
  # read "Protected Domain" since 2026-10-13; the row keeps this name, which
  # StackClient matches on.
  CLOUDFLARE_DNS = "Fast, protected domain".freeze
  # A card's lanes are grouped under these headings, in this order.
  CARD_GROUPS = %w[Application Platform Agents Marketing].freeze
  # included: a check. missing: a muted cross, "In <first tier that has it>".
  # soon: not delivered yet (Coming soon).
  CARD_STATUSES = %w[included missing soon].freeze

  # One swim lane every card lists (config `card_lanes`): its group, its key and
  # its title, which may name the tier ("%{tier} Host").
  Lane = Struct.new(:group, :key, :title, keyword_init: true)

  # One lane as one card draws it: the title for this tier, one muted line,
  # the status, and for a missing lane the tier that has it (`in_tier`).
  CardLine = Struct.new(:lane, :title, :sub, :status, :in_tier, keyword_init: true) do
    def included? = status == "included"
    def missing? = status == "missing"
    def soon? = status == "soon"
    def key = lane.key
    def group = lane.group
  end
  # The value a row carries for a tier that sells it per contract.
  ADD_ON = "Add-on".freeze
  # An icon written "glyph:<name>" is drawn as an inline SVG mark, not an emoji.
  GLYPH_PREFIX = "glyph:".freeze
  GLYPHS = %w[app domain].freeze

  Feature = Struct.new(:name, :category, :icon, :blurb, :values, :sop, :section, :you_do, :status, :software, :shows,
                       :brand_from, keyword_init: true) do
    def live? = status == "live"

    def planned? = status == "planned"

    # Delivered today, by an SOP or by the platform itself.
    def delivered? = !planned?

    # The software keys (config/workspace_icons.yml) this feature puts in a
    # client's stack. A planned feature provisions nothing: it is a promise. A
    # tier below `brand_from` gets the row but not the software (Vibe's web
    # address is a mcritchie.studio subdomain, so no Squarespace domain).
    def software_keys(package_key = nil)
      return [] unless delivered?
      return [] if below_brand_from?(package_key)

      Array(software)
    end

    def below_brand_from?(package_key)
      return false unless package_key && brand_from

      WorkspacePackage.keys.index(package_key.to_s) < WorkspacePackage.keys.index(brand_from)
    end

    # Every software drawn beside the row on the full-stack page: what it
    # provisions (or will), plus add-ons it only shows.
    def display_software = (Array(software) + Array(shows)).uniq

    # The one brand the row is about, when its `icon` is a software key from
    # config/workspace_icons.yml: the row leads with that brand's logo. Any
    # other icon is an emoji, the neutral lead of a row no single brand owns.
    def brand = WorkspaceIconConfig.software?(icon) ? icon.to_s : nil
    def brand? = !brand.nil?

    # A drawn mark ("glyph:app" names app/views/packages/_glyph.html.erb's `app`)
    # for a row no brand owns but an emoji would undersell: the custom app.
    def glyph = icon.to_s.start_with?(GLYPH_PREFIX) ? icon.to_s.delete_prefix(GLYPH_PREFIX) : nil

    # The logo strip under the row: every brand the row shows, less the one it
    # already leads with.
    def strip_brands = display_software - [ brand ]

    # The brands a package card names for this row: the lead brand and every
    # software it shows. A planned row is a promise, so it names none, and a
    # tier below `brand_from` gets the row but not the brand (Vibe's web
    # address is a mcritchie.studio subdomain, not a Squarespace domain).
    def card_brands(package_key = nil)
      return [] if planned?
      return [] if below_brand_from?(package_key)

      ([ brand ].compact + display_software).uniq
    end

    # The package's value for this row: a string ("Basic dyno"), true
    # (included, nothing to quantify), or nil (not included).
    def value_for(package_key)
      value = values[package_key.to_s]
      value == false ? nil : value
    end

    def included_in?(package_key) = !value_for(package_key).nil?

    # A row whose value changes between packages — the page highlights it.
    def varies? = values.values.uniq.size > 1

    # Every SOP that delivers the row: one, or a list (Storage names both the
    # Postgres and the R2 bucket SOPs).
    def sops = Array(sop)

    # "agents/steffon/sops/domain-dns" — the docs route's path for the row's
    # first SOP, or nil when it names none or the file is gone.
    def doc_path = doc_path_for(sops.first)

    def doc_path_for(name) = name.blank? ? nil : WorkspacePackage.sop_paths[name]
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
    @card = attrs["talk_to_us"] != true
    @card_group_names = Array(attrs["card_groups"])
    @lanes = (attrs["lanes"] || {}).transform_values { |value| value || {} }
    @annual_discount_percent = annual_discount_percent.to_i
  end

  def self.config = YAML.safe_load_file(CONFIG)

  def self.all
    discount = annual_discount_percent
    config.fetch("packages").map { |attrs| new(attrs, annual_discount_percent: discount) }
  end

  def self.find(key) = all.find { |package| package.key == key.to_s }

  # The tiers /packages draws as cards, in ladder order.
  def self.cards = all.select(&:card?)

  # The tier drawn as the "Talk to us" line under the cards (Enterprise), or nil.
  def self.talk_to_us = all.reject(&:card?).last

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

  # The tier a /packages/stack group starts at ("From Builder"), or nil.
  def self.category_from(category)
    key = config.fetch("category_from", {})[category.to_s]
    key && find(key)
  end

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

  # false for the tier drawn as the "Talk to us" line instead of a card.
  def card? = @card

  # Every lane, in group then config order: [[group, [Lane, ...]], ...].
  def self.card_lanes
    lanes = config.fetch("card_lanes", []).map { |attrs| Lane.new(**attrs.slice("group", "key", "title").symbolize_keys) }
    CARD_GROUPS.filter_map do |group|
      in_group = lanes.select { |lane| lane.group == group }
      [ group, in_group ] if in_group.any?
    end
  end

  # The groups this card shows, in CARD_GROUPS order.
  def card_group_names = CARD_GROUPS & @card_group_names

  def shows_group?(group) = card_group_names.include?(group)

  # The status this tier gives a lane: included unless its `lanes` entry says
  # otherwise; a lane it does not list is missing.
  def lane_status(lane_key)
    entry = @lanes[lane_key.to_s]
    entry ? entry.fetch("status", "included") : "missing"
  end

  # The lane as this card draws it. A missing lane names the first card that
  # has it (included or Coming soon), computed from the ladder. A tier's
  # `lanes` entry may rename the lane for its own card (Pro and Team draw the
  # domain lane as "Protected Domain"); every other card keeps the lane's title.
  def card_line(lane)
    status = lane_status(lane.key)
    in_tier = status == "missing" ? self.class.cards.find { |card| card.lane_status(lane.key) != "missing" } : nil
    title = @lanes.dig(lane.key.to_s, "title").presence || lane.title
    CardLine.new(lane: lane, title: format(title, tier: name), sub: @lanes.dig(lane.key.to_s, "sub"),
                 status: status, in_tier: in_tier)
  end

  # [[group, [CardLine, ...]], ...] for the groups this card shows.
  def card_groups
    self.class.card_lanes.filter_map do |group, lanes|
      [ group, lanes.map { |lane| card_line(lane) } ] if shows_group?(group)
    end
  end

  def card_lines = card_groups.flat_map(&:last)

  def priced? = price_monthly.present?

  def free? = priced? && price_monthly.zero?

  # Every software this tier provisions, in feature order — what /stack draws
  # for a client on it.
  def software_keys = features.flat_map { |feature| feature.software_keys(key) }.uniq

  # The brands of the rows this tier sells as add-ons, priced per contract
  # (Payments, Crypto and wallets, AI features): what the "Talk to us" line
  # draws, labelled as add-ons so no logo reads as included.
  def add_on_brands
    features.select { |feature| feature.value_for(key) == ADD_ON }.flat_map { |feature| feature.card_brands(key) }.uniq
  end

  # Every brand this tier's delivered features put in front of the customer, in
  # row order: what its card's "Powered by" row draws.
  def brand_keys = features.flat_map { |feature| feature.card_brands(key) }.uniq

  # The brands a card draws: all of them on the first tier, and on every later
  # tier only those it adds, since each tier includes the one before it.
  def card_brands(previous = nil) = previous ? brand_keys - previous.brand_keys : brand_keys

  # Billed annually: the discount applies to the whole year.
  # $100/mo at 10% off is $1,080/yr, which reads as $90/mo.
  def annual_price
    return nil unless priced? && !free?

    (price_monthly * 12 * (100 - @annual_discount_percent) / 100.0).round
  end

  def annual_monthly_equivalent = annual_price ? (annual_price / 12.0).round(2) : nil
end
