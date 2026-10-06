# frozen_string_literal: true

require "yaml"

# AppCatalog — the one loader for config/apps.yml, the record of every app's
# identity, tier and status. It parses the file once, validates it whole, and
# hands out frozen values; everything that draws an app (the board's glyphs, the
# release notes, the App seed, /stack) derives from it rather than keeping its
# own list.
#
# Pure Ruby (only yaml), so bin/ scripts can require it without booting Rails.
#
# A malformed catalog raises AppCatalog::Invalid naming every problem at once,
# at boot, rather than drawing a wrong badge later.
module AppCatalog
  PATH = File.expand_path("../config/apps.yml", __dir__)
  TIERS = %w[studio product basic].freeze
  STATUSES = %w[active delinquent showcase archived].freeze
  # Statuses whose app is running for someone today.
  LIVE_STATUSES = %w[active delinquent showcase].freeze
  # Each app owns a block of this many ports, starting at its primary port.
  PORT_BLOCK = 100

  APP_FIELDS = %i[slug name emoji color tier status port repo heroku_app production_url qa_url
                  engine hosted workspace description].freeze
  LIBRARY_FIELDS = %i[slug name emoji color aliases description].freeze

  class Invalid < StandardError; end

  Entry = Data.define(*APP_FIELDS) do
    def live? = LIVE_STATUSES.include?(status)
    def archived? = status == "archived"
    def port_range = port && (port...(port + PORT_BLOCK))
    def tier_label = tier&.capitalize
    def status_label = status.capitalize
  end

  Library = Data.define(*LIBRARY_FIELDS)

  Catalog = Data.define(:apps, :libraries)

  module_function

  def catalog
    @catalog ||= parse(File.read(PATH))
  end

  # Drop the memo; a test that rewrites nothing never needs it.
  def reload!
    @catalog = nil
    catalog
  end

  def apps = catalog.apps
  def libraries = catalog.libraries

  def app(slug) = apps.find { |entry| entry.slug == slug.to_s }

  # The app a /stack client stands for, by its workspace slug.
  def for_workspace(workspace) = apps.find { |entry| entry.workspace && entry.workspace == workspace.to_s }

  # slug (and library alias) => glyph, for every app and library.
  def emoji_map
    @emoji_map ||= begin
      map = apps.to_h { |entry| [entry.slug, entry.emoji] }
      libraries.each do |library|
        ([library.slug] + library.aliases).each { |name| map[name] = library.emoji }
      end
      map.freeze
    end
  end

  # One release-notes group per app, then per library, in catalog order.
  def release_groups
    @release_groups ||= (apps.map { |entry| group(entry.slug, entry.name, entry.emoji, [entry.slug]) } +
                         libraries.map { |lib| group(lib.slug, lib.name, lib.emoji, [lib.slug] + lib.aliases) }).freeze
  end

  # The App rows db/seeds/00_apps.rb upserts: every app, then every library.
  def seed_rows
    rows = apps.map { |entry| { slug: entry.slug, name: entry.name, color: entry.color, emoji: entry.emoji,
                                description: entry.description, status: entry.status } }
    rows += libraries.map { |lib| { slug: lib.slug, name: lib.name, color: lib.color, emoji: lib.emoji,
                                    description: lib.description, status: "active" } }
    rows.each_with_index.map { |row, index| row.merge(position: index).freeze }.freeze
  end

  def group(key, label, emoji, aliases)
    { key: key, label: label, emoji: emoji, aliases: aliases.freeze }.freeze
  end

  # Parse and validate catalog YAML text into a frozen Catalog.
  def parse(text)
    raw = YAML.safe_load(text.to_s) || {}
    raise Invalid, "config/apps.yml must be a mapping with apps: and libraries:" unless raw.is_a?(Hash)

    errors = []
    apps = build(Entry, APP_FIELDS, raw["apps"], "app", errors)
    libraries = build(Library, LIBRARY_FIELDS, raw["libraries"], "library", errors)
    errors.concat(problems(apps, libraries)) if errors.empty?
    raise Invalid, "config/apps.yml is invalid:\n  #{errors.join("\n  ")}" if errors.any?

    Catalog.new(apps: apps.freeze, libraries: libraries.freeze)
  rescue Psych::Exception => e
    raise Invalid, "config/apps.yml does not parse: #{e.message}"
  end

  # Records into Data values. Every field is required on every record, so the
  # shape of a record is visible in the file; null is how a field says "none".
  def build(klass, fields, rows, kind, errors)
    Array(rows).each_with_index.filter_map do |row, index|
      unless row.is_a?(Hash)
        errors << "#{kind} ##{index + 1} is not a mapping"
        next
      end
      keys = row.keys.map(&:to_s)
      label = row["slug"] || "##{index + 1}"
      missing = fields.map(&:to_s) - keys
      unknown = keys - fields.map(&:to_s)
      errors << "#{kind} #{label} is missing #{missing.join(', ')}" if missing.any?
      errors << "#{kind} #{label} has unknown #{unknown.join(', ')}" if unknown.any?
      next if missing.any? || unknown.any?

      values = fields.to_h { |field| [field, deep_freeze(row[field.to_s])] }
      klass.new(**values)
    end
  end

  def problems(apps, libraries)
    errors = []
    apps.each { |entry| errors.concat(entry_problems(entry)) }
    libraries.each do |lib|
      errors << "library #{lib.slug}: aliases must be a list" unless lib.aliases.is_a?(Array)
      errors << "library #{lib.slug}: color must be #RRGGBB" unless color?(lib.color)
      errors << "library #{lib.slug}: name and emoji are required" if blank?(lib.name) || blank?(lib.emoji)
    end
    return errors if errors.any?

    names = apps.map(&:slug) + libraries.flat_map { |lib| [lib.slug] + lib.aliases }
    errors.concat(duplicates(names).map { |slug| "slug #{slug} appears more than once" })
    errors.concat(duplicates(apps.filter_map(&:port)).map { |port| "port #{port} belongs to more than one app" })
    errors.concat(duplicates((apps + libraries).map(&:emoji)).map { |emoji| "emoji #{emoji} belongs to more than one app" })
    errors.concat(duplicates(apps.filter_map(&:workspace)).map { |ws| "workspace #{ws} belongs to more than one app" })
    errors
  end

  def entry_problems(entry)
    errors = []
    tag = "app #{entry.slug.inspect}"
    errors << "#{tag}: slug must be lowercase letters, digits and dashes" unless entry.slug.to_s.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    errors << "#{tag}: name and emoji are required" if blank?(entry.name) || blank?(entry.emoji)
    errors << "#{tag}: color must be #RRGGBB" unless color?(entry.color)
    errors << "#{tag}: status #{entry.status.inspect} is not one of #{STATUSES.join(', ')}" unless STATUSES.include?(entry.status)
    unless TIERS.include?(entry.tier) || (entry.tier.nil? && entry.status == "archived")
      errors << "#{tag}: tier #{entry.tier.inspect} is not one of #{TIERS.join(', ')} (null only when archived)"
    end
    unless entry.port.nil? || (entry.port.is_a?(Integer) && (entry.port % PORT_BLOCK).zero?)
      errors << "#{tag}: port must be null or a multiple of #{PORT_BLOCK}"
    end
    %i[engine hosted].each do |flag|
      errors << "#{tag}: #{flag} must be true or false" unless [true, false].include?(entry.public_send(flag))
    end
    %i[production_url qa_url].each do |field|
      value = entry.public_send(field)
      errors << "#{tag}: #{field} must be null or an https URL" unless value.nil? || value.to_s.start_with?("https://")
    end
    errors
  end

  def duplicates(values) = values.tally.select { |_, count| count > 1 }.keys
  def color?(value) = value.to_s.match?(/\A#\h{6}\z/)
  def blank?(value) = value.nil? || value.to_s.strip.empty?

  def deep_freeze(value)
    case value
    when Array then value.map { |item| deep_freeze(item) }.freeze
    when String then value.dup.freeze
    else value
    end
  end
end
