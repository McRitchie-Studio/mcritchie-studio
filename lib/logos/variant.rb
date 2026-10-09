# frozen_string_literal: true

module Logos
  # One Navbar Logo as the gallery (LogosController) names it: a brand plus the
  # rule, text, tone and guides picked by URL params. It turns request strings
  # into the library's arguments, refuses anything it does not know with
  # Logos::NavbarLogo::Error, and gives the logo its words: an accessible
  # label and a download filename. Nothing here draws; NavbarLogo does. Outside
  # Rails, require navbar_logo first (the app autoloads both).
  class Variant
    RULES = { 3 => "Rule of 3", 4 => "Rule of 4" }.freeze
    RULE_SENTENCES = {
      3 => "The icon is three rows tall. The capitals are one row, a third of the icon, and the name sits in the middle row.",
      4 => "The icon is four rows tall. The capitals are two rows, half the icon, and the name fills the middle two rows."
    }.freeze
    TEXTS = { homogeneous: "Homogeneous", first: "First word leads", second: "Second word leads" }.freeze
    TONES = NavbarLogo::TONES
    FLAGS = { nil => false, "0" => false, "1" => true }.freeze

    attr_reader :logo, :rule, :text, :tone, :guides

    # Every logo of a brand in page order: rule, then text, then tone.
    def self.all(logo, guides: false)
      RULES.keys.product(TEXTS.keys, TONES).map { |rule, text, tone| new(logo, rule:, text:, tone:, guides:) }
    end

    # "1" and "0" (or absent) only: "true", "yes" and "2" are refused, not guessed at.
    def self.flag(value, name)
      FLAGS.fetch(value) { raise NavbarLogo::Error, "unknown #{name} #{value.inspect}: expected 0 or 1" }
    end

    # From request params (strings). An absent param takes the library's default.
    def self.parse(logo, params)
      new(logo,
          rule: pick(params[:rule], RULES.keys.to_h { |rule| [rule.to_s, rule] }, 3, "rule"),
          text: pick(params[:text], TEXTS.keys.to_h { |text| [text.to_s, text] }, :homogeneous, "text"),
          tone: pick(params[:tone], TONES.to_h { |tone| [tone.to_s, tone] }, :light, "tone"),
          guides: flag(params[:guides], "guides"))
    end

    def self.pick(value, known, default, name)
      return default if value.nil?

      known.fetch(value) { raise NavbarLogo::Error, "unknown #{name} #{value.inspect}: expected one of #{known.keys.join(', ')}" }
    end
    private_class_method :pick

    def initialize(logo, rule:, text:, tone:, guides: false)
      @logo = logo
      @rule = rule
      @text = text
      @tone = tone
      @guides = guides
    end

    def svg = logo.svg(rule:, text:, tone:, guides:)
    def params = { rule:, text:, tone:, guides: guides ? 1 : 0 }
    def filename = [logo.brand, "navbar", "rule#{rule}", text, tone, ("guides" if guides)].compact.join("-") + ".svg"

    # "McRITCHIE INDUSTRIES" as a reader says it: "McRitchie Industries".
    def self.brand_name(logo)
      logo.words.map { |word| word.sub(/\A(Mc)?(.)(.*)\z/) { "#{$1}#{$2.upcase}#{$3.downcase}" } }.join(" ")
    end

    # The accessible name: "McRitchie Industries navbar logo, rule of 4, second word leads, light".
    def label
      parts = ["#{self.class.brand_name(logo)} navbar logo", RULES.fetch(rule).downcase, TEXTS.fetch(text).downcase, tone.to_s]
      parts << "construction guides" if guides
      parts.join(", ")
    end
  end
end
