# frozen_string_literal: true

require_relative "navbar_logo"

module Logos
  # A brand's KIT as the gallery shows it beside its logos: its colour PALETTE
  # (one ordered list of named colours). It is read from the brand's `palette:`
  # in config/logo_brands.yml and checked on load, so bad data
  # fails here and not in a page. Nothing here draws a logo: a logo's own fills
  # stay per tone in the style's `tones` (Logos::NavbarLogo).
  #
  #   kit = Logos::BrandKit.new("studio")
  #   kit.palette.first     # => #<data Swatch name="Ink", hex="#1A1535">
  class BrandKit
    Error = NavbarLogo::Error

    Swatch = Data.define(:name, :hex)

    SWATCH_KEYS = %w[hex name].freeze

    attr_reader :brand, :palette

    def self.all = NavbarLogo.brands.map { |brand| new(brand) }

    def initialize(brand, styles: NavbarLogo.styles)
      @brand = brand.to_s
      style = styles[@brand] or raise Error, "unknown brand #{@brand.inspect}: expected one of #{styles.keys.join(', ')}"
      @palette = checked_palette(style["palette"]).freeze
    end

    private

    def checked_palette(given)
      refuse("palette must be a list of at least one {name, hex}, got #{given.inspect[0, 80]}") unless given.is_a?(Array) && given.any?
      given.map do |entry|
        refuse("each palette colour must be a map of name and hex, got #{entry.inspect[0, 80]}") unless entry.is_a?(Hash) && entry.keys.sort == SWATCH_KEYS
        Swatch.new(name: word(entry["name"], "palette colour name"), hex: hex(entry["hex"]))
      end
    end

    def word(value, what)
      value.is_a?(String) && value.match?(/\A[^\s<>&"'][^<>&"\n]*\z/) ? value : refuse("#{what} must be plain words, got #{value.inspect[0, 80]}")
    end

    def hex(value) = NavbarLogo::HEX.match?(value.to_s) && value.is_a?(String) ? value : refuse("#{value.inspect} is not a #hex colour")

    def refuse(message) = raise(Error, "brand #{brand}: #{message}")
  end
end
