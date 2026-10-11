# frozen_string_literal: true

module Logos
  # One logo as the gallery (LogosController) names it: a brand, a TYPE (the icon
  # alone, the Navbar Logo or the Stacked Logo) and the rule, form, text, tone and
  # guides picked by URL params. A type takes only its own choices: an icon has
  # a tone and nothing else, only a Navbar Logo has a rule, and only a Stacked
  # Logo has a form (two lines, one line or with tagline). Every type has a
  # COLOURING (task logo-original-and-alt): Original, the brand's own art, or
  # Alt, one solid colour per part; a watermark has neither (it is one colour),
  # and a brand with no original draws Alt only. A page's CONTEXT
  # is the one tone every logo on it is shown in. It turns request strings
  # into the library's arguments, refuses anything it does not know with
  # Logos::NavbarLogo::Error, and gives the logo its words: an accessible
  # label and a download filename. Nothing here draws; NavbarLogo and
  # StackedLogo do. Outside Rails, require navbar_logo and stacked_logo first
  # (the app autoloads all three).
  class Variant
    TYPES = { icon: "Icon", navbar: "Navbar Logo", stacked: "Stacked Logo" }.freeze
    CHOICES = { icon: %i[tone colouring], navbar: %i[rule text tone colouring guides], stacked: %i[form text tone colouring guides] }.freeze
    COLOURINGS = { original: "Original", alt: "Alt" }.freeze
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
    # The operator's edits (task logo-part-editor) as URL params: each names a part and a setting of
    # NavbarLogo::PARTS. A colour is a palette hex without its "#" (?first_colour=635BB2), a weight a number, and
    # ?tagline_visible=0 hides the tagline. A blank param is no edit (the edit form sends one for "as styled").
    EDIT_PARAMS = { icon_colour: %i[icon colour], first_colour: %i[first colour], first_weight: %i[first weight],
                    ending_colour: %i[ending colour], ending_weight: %i[ending weight], tagline_colour: %i[tagline colour],
                    tagline_weight: %i[tagline weight], tagline_visible: %i[tagline visible] }.freeze
    # The parts each type's logo shows an edit on (the icon tab has none); the tagline only in the tagline form.
    EDITED_PARTS = { icon: [], navbar: %i[icon first ending], stacked: %i[icon first ending tagline] }.freeze

    attr_reader :logo, :type, :rule, :form, :text, :tone, :colouring, :guides, :edits

    # The library object that draws a brand's logos of one type.
    def self.logo(brand, type = :navbar) = (type == :stacked ? StackedLogo : NavbarLogo).new(brand)

    # A brand page's logos of one type in one tone: the icon, or the three text versions (a Navbar Logo's on `rule`),
    # every one with the same edits.
    def self.all(logo, type: :navbar, rule: 4, form: nil, tone: :light, colouring: :alt, guides: false, edits: NavbarLogo::NO_EDITS)
      return [new(logo, type:, tone:, colouring:)] if type == :icon

      TEXTS.keys.map { |text| new(logo, type:, rule:, form:, text:, tone:, colouring:, guides:, edits:) }
    end

    # The edit params (EDIT_PARAMS) as the library's edits, unchecked: the logo checks them (NavbarLogo#checked_edits).
    # A colour must be a hex, a weight a number and a visibility 0 or 1; anything else is refused here.
    def self.edits(params)
      EDIT_PARAMS.each_with_object({}) do |(name, (part, setting)), edits|
        value = params[name].to_s
        next if value.empty?

        (edits[part] ||= {})[setting] = edit_value(setting, value, name)
      end
    end

    def self.edit_value(setting, value, name)
      case setting
      when :colour then value.match?(/\A#?\h{6}\z/) ? "##{value.delete_prefix('#').upcase}" : refuse_edit(name, value, "a six-digit hex")
      when :weight then value.match?(/\A\d{3}\z/) ? value.to_i : refuse_edit(name, value, "a weight such as 300")
      else flag(value, name)
      end
    end

    def self.refuse_edit(name, value, expected) = raise(NavbarLogo::Error, "unknown #{name} #{value.inspect[0, 40]}: expected #{expected}")

    # Edits (checked) back as URL params, in EDIT_PARAMS order: the inverse of `edits`.
    def self.edit_params(edits)
      EDIT_PARAMS.each_with_object({}) do |(name, path), params|
        value = edits.dig(*path)
        params[name] = case value
                       when String then value.delete_prefix("#")
                       when false then 0
                       else value
                       end
        params.delete(name) if value.nil?
      end
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
    # A ?colouring= as a colouring, or nil when absent (a page then takes the brand's own default; an SVG route, Alt).
    def self.colouring(value) = pick(value, COLOURINGS.keys.to_h { |colouring| [colouring.to_s, colouring] }, nil, "colouring")
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
        colouring: -> { colouring(params[:colouring]) || :alt },
        guides: -> { flag(params[:guides], "guides") }
      }
      new(logo, type:, edits: edits(params), **CHOICES.fetch(type).to_h { |choice| [choice, read.fetch(choice).call] })
    end

    def self.pick(value, known, default, name)
      return default if value.nil?

      known.fetch(value) { raise NavbarLogo::Error, "unknown #{name} #{value.inspect}: expected one of #{known.keys.join(', ')}" }
    end
    private_class_method :pick, :tones_by_name, :rules_by_name, :edit_value, :refuse_edit

    # A choice the type does not take is dropped, so two variants that draw the same thing are named the same. So is an
    # edit the logo does not show (#shown_edits): every edit is checked first all the same.
    # An Original of a brand with none is refused; a watermark's colouring is always Alt (it is one colour).
    def initialize(logo, type: :navbar, rule: 3, form: nil, text: :homogeneous, tone: :light, colouring: :alt, guides: false, edits: NavbarLogo::NO_EDITS)
      choices = CHOICES.fetch(type) { raise NavbarLogo::Error, "unknown type #{type.inspect}: expected one of #{TYPES.keys.join(', ')}" }
      raise ArgumentError, "a #{type} variant of #{logo.brand} was given a #{logo.class}" unless logo.is_a?(StackedLogo) == (type == :stacked)

      @logo = logo
      @type = type
      @tone = tone
      @colouring = tone == :watermark ? :alt : checked_colouring(colouring)
      @rule = rule if choices.include?(:rule)
      @form = form || logo.form if choices.include?(:form)
      @text = text if choices.include?(:text)
      @guides = guides && choices.include?(:guides)
      @edits = shown_edits(logo.checked_edits(edits))
    end

    def svg
      @svg ||= case type
               when :icon then logo.icon_svg(tone:, colouring:)
               when :navbar then logo.svg(rule:, text:, tone:, guides:, edits:, colouring:)
               else logo.svg(form:, text:, tone:, guides:, edits:, colouring:)
               end
    end

    def edited? = edits.any?
    def original? = colouring == :original

    # A guide drawing's own measures, in its design units: how wide the drawing is and how tall its labels are.
    def guide_width = svg[/viewBox="\S+ \S+ (\S+) /, 1].to_f
    def guide_font = logo.guide_font(rule)

    # The type's own choices, as its SVG route's params. Alt is the route's default, so only an Original says its colouring.
    def params
      { rule:, form:, text:, tone:, colouring: (colouring if original?), guides: guides ? 1 : 0 }.compact.slice(*CHOICES.fetch(type))
                                                                                                  .merge(self.class.edit_params(edits))
    end

    # An edited logo's file says so: studio-stacked-tagline-first-light-custom.svg; an Original's says that:
    # welding-navbar-rule3-first-dark-original.svg.
    def filename
      [logo.brand, type, ("rule#{rule}" if rule), form&.to_s&.sub("_", "-"), text, tone, ("original" if original?), ("guides" if guides),
       ("custom" if edited?)].compact.join("-") + ".svg"
    end

    private

    # The edits this logo shows: none on the icon, a watermark (one colour by definition) or an original (the brand's own
    # art), and the tagline's only in the tagline form.
    def shown_edits(checked)
      return NavbarLogo::NO_EDITS if tone == :watermark || original?

      parts = EDITED_PARTS.fetch(type) - (form == :tagline ? [] : %i[tagline])
      checked.slice(*parts).freeze
    end

    public

    # "McRITCHIE INDUSTRIES" as a reader says it: "McRitchie Industries"; or the style's own `title` where it gives
    # one, so two versions of a brand ("Commercial Welding v1", "Commercial Welding v2") are told apart.
    def self.brand_name(logo)
      return logo.title if logo.title

      logo.words.join(" ").split.map { |word| word.sub(/\A(Mc)?(.)(.*)\z/) { "#{$1}#{$2.upcase}#{$3.downcase}" } }.join(" ")
    end

    # The accessible name: "McRitchie Industries navbar logo, rule of 4, second word leads, light",
    # "McRitchie Industries stacked logo, with tagline, first word leads, dark" or "McRitchie Industries icon, watermark".
    # The tagline form with its tagline hidden draws no tagline, so it says "tagline hidden", not "with tagline".
    def label
      ["#{self.class.brand_name(logo)} #{TYPES.fetch(type).downcase}", (RULES.fetch(rule).downcase if rule), form_words,
       (TEXTS.fetch(text).downcase if text),
       tone.to_s, colouring_words, ("construction guides" if guides), ("edited" if edited?)].compact.join(", ")
    end

    private

    def checked_colouring(colouring)
      unless COLOURINGS.key?(colouring)
        raise NavbarLogo::Error, "unknown colouring #{colouring.inspect}: expected one of #{COLOURINGS.keys.join(', ')}"
      end
      return colouring if logo.colourings.include?(colouring)

      raise NavbarLogo::Error, "brand #{logo.brand}: it has no original colouring (its logo is solid colour), so only alt"
    end

    # The colouring in words, for a brand that has both ("original colouring", "alt colouring"); nothing for a brand
    # that has only Alt, or a watermark.
    def colouring_words = ("#{colouring} colouring" if logo.original? && tone != :watermark)

    def form_words
      return unless form
      return "tagline hidden" if form == :tagline && edits.dig(:tagline, :visible) == false

      FORMS.fetch(form).downcase
    end
  end
end
