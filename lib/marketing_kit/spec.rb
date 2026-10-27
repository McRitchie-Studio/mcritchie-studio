# frozen_string_literal: true

require "yaml"
require "date"

module MarketingKit
  # One brand's marketing kit, read from a YAML spec and checked on load, so bad
  # data fails here and not halfway through a Drive publish. The spec is the
  # kit's single source: every renderer reads it and nothing else. A brand's own
  # spec does not live in this (public) repo; it travels with its kit in Drive
  # (see the marketing-kit SOP). test/fixtures/files/marketing_kit/example.yml
  # is the worked example.
  #
  #   spec = MarketingKit::Spec.load("kit.yml")
  #   spec.colour(:primary)   # => "#2D5E8E"
  #   spec.logo_png(:full, :dark)  # => "/abs/logos/png/full_dark.png"
  class Spec
    HEX = /\A#[0-9A-F]{6}\z/i
    # The palette keys every renderer draws with. Anything else in the palette is
    # shown in the guidelines but never drawn with.
    REQUIRED_COLOURS = %i[primary accent dark].freeze
    # An optional colour a brand leaves out falls back to the one it deepens.
    COLOUR_FALLBACK = { accent_on_dark: :accent, primary_deep: :primary, accent_deep: :accent }.freeze
    OPTIONAL_COLOURS = COLOUR_FALLBACK.keys.freeze
    MAX_SWATCHES = 8
    LOGO_TYPES = %i[full horizontal icon].freeze
    REQUIRED_PNGS = [[:full, :light], [:full, :dark], [:horizontal, :light], [:horizontal, :dark], [:icon, :light]].freeze
    PHOTO_SLOTS = %i[cover guidelines_cover template_hero template_band proposal_cover proposal_about proposal_why
                     slide_cover slide_half slide_full slide_spot slide_quote].freeze

    attr_reader :path, :data, :root

    def self.load(path)
      path = File.expand_path(path)
      raise Error, "no kit spec at #{path}" unless File.file?(path)

      data = YAML.safe_load_file(path, permitted_classes: [Date], aliases: false)
      raise Error, "#{path}: the spec must be a YAML mapping" unless data.is_a?(Hash)

      new(data, root: File.dirname(path), path: path)
    end

    def initialize(data, root:, path: nil)
      @data = deep_symbolize(data)
      @root = root
      @path = path
      validate!
    end

    def name = data.fetch(:name)
    def short = data.fetch(:short)
    def legal_name = data[:legal_name] || name
    def tagline = data.fetch(:tagline)
    def owner = data.fetch(:owner)
    def updated = data[:updated].to_s.presence || Date.today.iso8601
    def lines = Array(data[:lines])
    def one_sentence = data.fetch(:one_sentence)
    def pitch = data.fetch(:pitch)
    def voice = data.fetch(:voice)
    def ideas = Array(data[:ideas])
    def contact = data.fetch(:contact)
    def fonts = { family: "Montserrat", fallback: "Arial", heading: 800, subhead: 700, body: 400 }.merge(data[:fonts] || {})
    def drive = data.fetch(:drive)
    def slides = data[:slides] || {}
    def general_template = data[:general_template] || {}
    def proposal = data[:proposal] || {}
    def tracker = data[:tracker] || {}
    def start_here = data[:start_here] || {}
    def brand_guide = data[:brand_guide] || {}

    def root_name = drive[:root_name] || "#{name} — Marketing Kit"

    def palette = data.fetch(:palette)

    def colour(key)
      hit = palette.find { |c| c[:key]&.to_sym == key }
      return hit[:hex].upcase if hit

      colour(COLOUR_FALLBACK.fetch(key) { raise Error, "no #{key} colour" })
    end

    def logo_png(type, tone) = logo_file(:png, "#{type}_#{tone}.png")
    def logo_svg(type, tone) = logo_file(:svg, "#{type}_#{tone}.svg")
    def icon_512 = logo_file(:png, "icon_512.png")

    # Every logo file the kit carries: [absolute path, drive file name]. PNGs are
    # required where REQUIRED_PNGS says; everything else is carried when present.
    def logo_files
      Dir[File.join(logos_dir, "{svg,png}", "*.{svg,png}")].sort.map { |p| [p, "#{short}_logo_#{File.basename(p)}"] }
    end

    def logos_dir = absolute(data.dig(:logos, :dir) || "logos")
    def photos_dir = absolute(data.dig(:photos, :dir) || "photos")
    def photos = Array(data.dig(:photos, :items))
    def photo_style = data.dig(:photos, :style)
    def favourite_photos = Array(data.dig(:photos, :favourites))
    def guideline_photos = Array(data.dig(:photos, :guidelines_grid)).first(6)

    def photo_path(file) = File.join(photos_dir, file)
    def photo_name(file) = "#{short}_photo_#{file}"

    # A named photo slot (slide_cover, proposal_about, …) falls back to the cover.
    def slot(name)
      file = data.dig(:photos, :slots, name) || data.dig(:photos, :slots, :cover)
      photo_path(file)
    end

    def quick_grab_logos
      Array(data[:quick_grab_logos] || %w[full_light.png full_dark.png horizontal_light.png horizontal_dark.png icon_512.png])
    end

    private

    def logo_file(kind, base) = File.join(logos_dir, kind.to_s, base)

    def absolute(p) = File.expand_path(p, root)

    def validate!
      missing = %i[name short tagline owner one_sentence pitch voice contact palette drive].reject { |k| data[k].present? }
      raise Error, "#{label}: missing #{missing.join(', ')}" if missing.any?
      raise Error, "#{label}: short must be 1-6 letters or digits" unless short.to_s.match?(/\A[A-Za-z0-9]{1,6}\z/)
      raise Error, "#{label}: drive.subject is required" if drive[:subject].blank?

      validate_palette!
      validate_logos!
      validate_photos!
    end

    def validate_palette!
      raise Error, "#{label}: palette must be a list" unless palette.is_a?(Array)
      raise Error, "#{label}: at most #{MAX_SWATCHES} swatches" if palette.size > MAX_SWATCHES

      palette.each do |c|
        raise Error, "#{label}: swatch #{c[:name].inspect} needs a name and a #RRGGBB hex" unless c[:name].present? && c[:hex].to_s.match?(HEX)
      end
      keys = palette.filter_map { |c| c[:key]&.to_sym }
      unknown = keys - REQUIRED_COLOURS - OPTIONAL_COLOURS
      raise Error, "#{label}: unknown palette key #{unknown.join(', ')}" if unknown.any?
      raise Error, "#{label}: palette key used twice" if keys.uniq.size != keys.size

      absent = REQUIRED_COLOURS - keys
      raise Error, "#{label}: palette needs #{absent.join(', ')} keys" if absent.any?
    end

    def validate_logos!
      absent = REQUIRED_PNGS.map { |t, tone| logo_png(t, tone) }.reject { |p| File.file?(p) }
      raise Error, "#{label}: missing logo files #{absent.map { |p| p.delete_prefix("#{root}/") }.join(', ')}" if absent.any?
    end

    def validate_photos!
      named = photos.map { |p| p[:file] }
      raise Error, "#{label}: every photo needs a file and a subject" unless photos.all? { |p| p[:file].present? && p[:subject].present? }

      refs = favourite_photos + guideline_photos + (data.dig(:photos, :slots) || {}).values
      stray = refs.uniq - named
      raise Error, "#{label}: photos named but not listed in photos.items: #{stray.join(', ')}" if stray.any?
      raise Error, "#{label}: photos.slots.cover is required" if data.dig(:photos, :slots, :cover).blank?

      unknown = (data.dig(:photos, :slots) || {}).keys - PHOTO_SLOTS
      raise Error, "#{label}: unknown photo slot #{unknown.join(', ')}" if unknown.any?

      absent = named.reject { |f| File.file?(photo_path(f)) }
      raise Error, "#{label}: missing photo files #{absent.join(', ')}" if absent.any?
    end

    def label = path ? File.basename(path) : "kit spec"

    def deep_symbolize(v)
      case v
      when Hash then v.to_h { |k, x| [k.to_sym, deep_symbolize(x)] }
      when Array then v.map { |x| deep_symbolize(x) }
      else v
      end
    end
  end
end
