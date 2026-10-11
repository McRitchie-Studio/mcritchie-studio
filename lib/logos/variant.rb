# frozen_string_literal: true

module Logos
  # One logo as the gallery (LogosController) names it: a brand, a TYPE (the icon
  # alone, the Navbar Logo or the Stacked Logo) and the rule, form, text, tone and
  # guides picked by URL params. A type takes only its own choices: an icon has
  # a tone and nothing else, only a Navbar Logo has a rule, and only a Stacked
  # Logo has a form (two lines, one line or with tagline). A page's CONTEXT
  # is the one tone every logo on it is shown in. It turns request strings
  # into the library's arguments, refuses anything it does not know with
  # Logos::NavbarLogo::Error, and gives the logo its words: an accessible
  # label and a download filename. Nothing here draws; NavbarLogo and
  # StackedLogo do. Outside Rails, require navbar_logo and stacked_logo first
  # (the app autoloads all three).
  class Variant
    TYPES = { icon: "Icon", navbar: "Navbar Logo", stacked: "Stacked Logo" }.freeze
    CHOICES = { icon: %i[tone], navbar: %i[rule text tone guides], stacked: %i[form text tone guides] }.freeze
    # The Stacked Logo's forms, as the Form control names them; a brand offers only its own (StackedLogo#forms).
    FORMS = { two_line: "Two lines", one_line: "One line", tagline: "With tagline" }.freeze
    RULES = { 3 => "Rule of 3", 4 => "Rule of 4", 6 => "Rule of 6" }.freeze
    RULE_SENTENCES = {
      3 => "The icon is three rows tall. The capitals are one row, a third of the icon, and the name sits in the middle row.",
      4 => "The icon is four rows tall. The capitals are two rows, half the icon, and the name fills the middle two rows.",
      6 => "The icon is six rows tall. The capitals are four rows, two thirds of the icon, and the name fills the middle four rows."
    }.freeze
    # The Stacked Logo's 3-2-1 method in plain words, then which form the brand uses.
    METHOD_SENTENCE = "The 3-2-1 method: take the small word's capitals as one unit. The big word's capitals are 3 units tall, " \
                      "every gap is 2 units, and the small word, 1 unit tall, is spaced out to 60% of the big word's width. " \
                      "The icon is as tall as the small word is wide."
    FORM_SENTENCES = {
      two_line: "This brand uses the two-line form.",
      one_line: "This brand uses the one-line form, because its second word is too wide to sit under its first: the whole name is on " \
                "one line, 3 units tall, 2 units under an icon 60% as tall as the name is wide.",
      tagline: "With tagline: the whole name on one line, 3 units tall, then 2 units, then the tagline, 1 unit tall, set in " \
               "Montserrat and spaced out to 60% of the name's width. The tagline is the small line, so the icon is as tall as it is wide."
    }.freeze
    TEXTS = { homogeneous: "Homogeneous", first: "First word leads", second: "Second word leads" }.freeze
    TONES = NavbarLogo::TONES
    CONTEXTS = { light: "Light", dark: "Dark", watermark: "Watermark" }.freeze
    FLAGS = { nil => false, "0" => false, "1" => true }.freeze

    attr_reader :logo, :type, :rule, :form, :text, :tone, :guides

    # The library object that draws a brand's logos of one type.
    def self.logo(brand, type = :navbar) = (type == :stacked ? StackedLogo : NavbarLogo).new(brand)

    # A brand page's logos of one type in one tone: the icon, or the three text versions (a Navbar Logo's on `rule`).
    def self.all(logo, type: :navbar, rule: 4, form: nil, tone: :light, guides: false)
      return [new(logo, type:, tone:)] if type == :icon

      TEXTS.keys.map { |text| new(logo, type:, rule:, form:, text:, tone:, guides:) }
    end

    # A ?form= as a stacked form. Given the Stacked Logo, only a form it draws is taken, and absent is its own form;
    # without one (a page on another tab carries the param) any form name is taken, and absent is nil.
    def self.form(value, logo = nil)
      known = logo ? logo.forms : FORMS.keys
      pick(value, known.to_h { |form| [form.to_s, form] }, logo&.form, "form")
    end

    # A page's ?context= as a tone, ?type= as a logo type and ?rule= as a rule: absent is light, the Navbar Logo and
    # the rule of 4, and one it does not know is refused.
    def self.context(value) = pick(value, tones_by_name, :light, "context")
    def self.type(value) = pick(value, TYPES.keys.to_h { |type| [type.to_s, type] }, :navbar, "type")
    def self.rule(value) = pick(value, rules_by_name, 4, "rule")
    def self.tones_by_name = TONES.to_h { |tone| [tone.to_s, tone] }
    def self.rules_by_name = RULES.keys.to_h { |rule| [rule.to_s, rule] }

    # "1" and "0" (or absent) only: "true", "yes" and "2" are refused, not guessed at.
    def self.flag(value, name)
      FLAGS.fetch(value) { raise NavbarLogo::Error, "unknown #{name} #{value.inspect}: expected 0 or 1" }
    end

    # From request params (strings). An absent param takes the library's default; one the type does not take is not read.
    def self.parse(logo, params, type: :navbar)
      read = {
        rule: -> { pick(params[:rule], rules_by_name, 3, "rule") },
        form: -> { form(params[:form], logo) },
        text: -> { pick(params[:text], TEXTS.keys.to_h { |text| [text.to_s, text] }, :homogeneous, "text") },
        tone: -> { pick(params[:tone], tones_by_name, :light, "tone") },
        guides: -> { flag(params[:guides], "guides") }
      }
      new(logo, type:, **CHOICES.fetch(type).to_h { |choice| [choice, read.fetch(choice).call] })
    end

    def self.pick(value, known, default, name)
      return default if value.nil?

      known.fetch(value) { raise NavbarLogo::Error, "unknown #{name} #{value.inspect}: expected one of #{known.keys.join(', ')}" }
    end
    private_class_method :pick, :tones_by_name, :rules_by_name

    # A choice the type does not take is dropped, so two variants that draw the same thing are named the same.
    def initialize(logo, type: :navbar, rule: 3, form: nil, text: :homogeneous, tone: :light, guides: false)
      choices = CHOICES.fetch(type) { raise NavbarLogo::Error, "unknown type #{type.inspect}: expected one of #{TYPES.keys.join(', ')}" }
      raise ArgumentError, "a #{type} variant of #{logo.brand} was given a #{logo.class}" unless logo.is_a?(StackedLogo) == (type == :stacked)

      @logo = logo
      @type = type
      @tone = tone
      @rule = rule if choices.include?(:rule)
      @form = form || logo.form if choices.include?(:form)
      @text = text if choices.include?(:text)
      @guides = guides && choices.include?(:guides)
    end

    def svg
      @svg ||= case type
               when :icon then logo.icon_svg(tone:)
               when :navbar then logo.svg(rule:, text:, tone:, guides:)
               else logo.svg(form:, text:, tone:, guides:)
               end
    end

    # A guide drawing's own measures, in its design units: how wide the drawing is and how tall its labels are.
    def guide_width = svg[/viewBox="\S+ \S+ (\S+) /, 1].to_f
    def guide_font = logo.guide_font(rule)

    # The type's own choices, as its SVG route's params.
    def params = { rule:, form:, text:, tone:, guides: guides ? 1 : 0 }.slice(*CHOICES.fetch(type))
    def filename = [logo.brand, type, ("rule#{rule}" if rule), form&.to_s&.sub("_", "-"), text, tone, ("guides" if guides)].compact.join("-") + ".svg"

    # "McRITCHIE INDUSTRIES" as a reader says it: "McRitchie Industries"; or the style's own `title` where it gives
    # one, so two versions of a brand ("Commercial Welding v1", "Commercial Welding v2") are told apart.
    def self.brand_name(logo)
      return logo.title if logo.title

      logo.words.join(" ").split.map { |word| word.sub(/\A(Mc)?(.)(.*)\z/) { "#{$1}#{$2.upcase}#{$3.downcase}" } }.join(" ")
    end

    # The accessible name: "McRitchie Industries navbar logo, rule of 4, second word leads, light",
    # "McRitchie Industries stacked logo, with tagline, first word leads, dark" or "McRitchie Industries icon, watermark".
    def label
      ["#{self.class.brand_name(logo)} #{TYPES.fetch(type).downcase}", (RULES.fetch(rule).downcase if rule), (FORMS.fetch(form).downcase if form),
       (TEXTS.fetch(text).downcase if text),
       tone.to_s, ("construction guides" if guides)].compact.join(", ")
    end
  end
end
