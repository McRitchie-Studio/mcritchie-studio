# frozen_string_literal: true

require_relative "navbar_logo"

module Logos
  # A brand's KIT as the gallery shows it beside its logos: its colour PALETTE
  # (one ordered list of named colours) and its TYPEFACE hierarchy (at most three
  # levels, the most prominent first). Both are read from the brand's `palette:`
  # and `typefaces:` in config/logo_brands.yml and checked on load, so bad data
  # fails here and not in a page. Nothing here draws a logo: a logo's own fills
  # stay per tone in the style's `tones` (Logos::NavbarLogo).
  #
  #   kit = Logos::BrandKit.new("studio")
  #   kit.palette.first     # => #<data Swatch name="Ink", hex="#1A1535">
  #   kit.typefaces.first   # => #<data Typeface role="Display", family="Montserrat", weight=800, label=nil>
  #   kit.typefaces.first.name  # => "Montserrat ExtraBold"
  class BrandKit
    Error = NavbarLogo::Error

    Swatch = Data.define(:name, :hex)

    # One level of the hierarchy. A level set in a served font has a family and a weight and is named by them; a
    # level set in the brand's own traced lettering has neither, only a label that says so.
    Typeface = Data.define(:role, :family, :weight, :label) do
      def traced? = family.nil?
      def name = traced? ? label : "#{family} #{WEIGHT_NAMES.fetch(weight)}"
    end

    MAX_LEVELS = 3
    # The only face the hub serves (studio-engine vendors Montserrat as a variable font, every weight from 100 to
    # 900). A family the page cannot render in its own face is refused, not shown in a fallback.
    FAMILIES = %w[Montserrat].freeze
    WEIGHT_NAMES = { 100 => "Thin", 200 => "ExtraLight", 300 => "Light", 400 => "Regular", 500 => "Medium",
                     600 => "SemiBold", 700 => "Bold", 800 => "ExtraBold", 900 => "Black" }.freeze
    SWATCH_KEYS = %w[hex name].freeze
    TYPEFACE_KEYS = %w[role family weight label].freeze

    attr_reader :brand, :palette, :typefaces

    def self.all = NavbarLogo.brands.map { |brand| new(brand) }

    def initialize(brand, styles: NavbarLogo.styles)
      @brand = brand.to_s
      style = styles[@brand] or raise Error, "unknown brand #{@brand.inspect}: expected one of #{styles.keys.join(', ')}"
      @palette = checked_palette(style["palette"]).freeze
      @typefaces = checked_typefaces(style["typefaces"]).freeze
    end

    private

    def checked_palette(given)
      refuse("palette must be a list of at least one {name, hex}, got #{given.inspect[0, 80]}") unless given.is_a?(Array) && given.any?
      given.map do |entry|
        refuse("each palette colour must be a map of name and hex, got #{entry.inspect[0, 80]}") unless entry.is_a?(Hash) && entry.keys.sort == SWATCH_KEYS
        Swatch.new(name: word(entry["name"], "palette colour name"), hex: hex(entry["hex"]))
      end
    end

    def checked_typefaces(given)
      unless given.is_a?(Array) && given.size.between?(1, MAX_LEVELS)
        refuse("typefaces must be a list of 1 to #{MAX_LEVELS} levels, got #{given.inspect[0, 80]}")
      end
      given.map { |entry| typeface(entry) }
    end

    def typeface(entry)
      unless entry.is_a?(Hash) && (entry.keys - TYPEFACE_KEYS).empty? && entry.key?("role")
        refuse("each typeface must be a map of #{TYPEFACE_KEYS.join(', ')} with a role, got #{entry.inspect[0, 80]}")
      end
      role = word(entry["role"], "typeface role")
      return traced(role, entry) if entry["family"].nil?

      refuse("typeface #{role}: family must be one of #{FAMILIES.join(', ')}, got #{entry['family'].inspect}") unless FAMILIES.include?(entry["family"])
      refuse("typeface #{role}: weight must be one of #{WEIGHT_NAMES.keys.join(', ')}, got #{entry['weight'].inspect}") unless WEIGHT_NAMES.key?(entry["weight"])
      refuse("typeface #{role}: a level in a font takes no label") if entry.key?("label")
      Typeface.new(role:, family: entry["family"], weight: entry["weight"], label: nil)
    end

    # A level with no font is the brand's own traced lettering: it says so in its label and has no weight.
    def traced(role, entry)
      refuse("typeface #{role}: a level with no family is traced lettering, so it takes no weight") if entry.key?("weight")
      Typeface.new(role:, family: nil, weight: nil, label: word(entry["label"], "typeface #{role} label"))
    end

    def word(value, what)
      value.is_a?(String) && value.match?(/\A[^\s<>&"'][^<>&"\n]*\z/) ? value : refuse("#{what} must be plain words, got #{value.inspect[0, 80]}")
    end

    def hex(value) = NavbarLogo::HEX.match?(value.to_s) && value.is_a?(String) ? value : refuse("#{value.inspect} is not a #hex colour")

    def refuse(message) = raise(Error, "brand #{brand}: #{message}")
  end
end
