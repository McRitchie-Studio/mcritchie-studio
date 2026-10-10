# frozen_string_literal: true

module Logos
  # Draws a brand's Stacked Logo: the icon above the name, on the 3-2-1 method.
  # It is the Navbar Logo's brand (the same style, icons, letters, checks, text
  # versions and tones) on another layout, so it inherits all of those.
  #
  #   Logos::StackedLogo.new("studio").svg(text: :first, tone: :dark)
  #
  # Let u be the small word's cap height.
  #
  #   two_line (default)  the first word is the big line (capitals 3u); the
  #                       second is the small line (capitals 1u), tracked out
  #                       between its letters to 60% of the big line's ink
  #                       width; the icon is as tall as the small line is wide.
  #                       Top to bottom: icon, 2u, big line, 2u, small line.
  #   one_line            (style `stacked: one_line`) the whole name on one line
  #                       at 3u, set as the Navbar Logo sets it; the icon is 60%
  #                       of the name's width tall. Top to bottom: icon, 2u, name.
  #
  # Everything is centred on the big line, whose ink is the logo's width.
  # Rules, forms and guides: docs/topics/logos.md. Outside Rails, require
  # navbar_logo first (the app autoloads both).
  class StackedLogo < NavbarLogo
    U = 40.0                                   # one unit, in design units
    BIG = 3                                    # the big line's capitals, in u
    GAP = 2                                    # every gap, in u
    SPAN = 0.6                                 # the small line's width, and the icon's height, as a share of the big line's width
    FORMS = %w[two_line one_line].freeze
    BANDS = %w[2u 3u 2u 1u].freeze             # below the icon, top to bottom (one_line stops after the second)
    GUIDE_PAD = { left: 60, top: 40, right: 90, bottom: 40 }.freeze
    GUIDE_FONT = 30

    # `edges`: every horizontal boundary, top to bottom. `letters` carry their own baseline and cap.
    Layout = Struct.new(:form, :width, :height, :icon_height, :icon_left, :edges, :letters, keyword_init: true)

    undef_method :examples                     # the Navbar Logo's list: its keys name a rule, which this has none of

    # A name the form cannot set is refused here, with the rest of the brand's data, not at draw time.
    def initialize(...)
      super
      form = @style["stacked"] || FORMS.first
      raise Error, "brand #{brand}: stacked must be one of #{FORMS.join(', ')}, got #{form.inspect}" unless FORMS.include?(form)

      @form = form.to_sym
      TEXTS.product(TONES) { |text, tone| layout(text:, tone:) }
    end

    # :two_line or :one_line
    attr_reader :form

    # The geometry alone, in design units (x = 0 is the big line's left ink edge, y = 0 the icon's top).
    # A keyword it does not take (the Navbar Logo's `rule:` above all) is refused like any other bad choice.
    def layout(text: :homogeneous, tone: :light, **unknown)
      check_keywords(unknown, "text and tone")
      check_text(text)
      first, second = @words.zip(word_weights(text)).map { |word, weight| letters(word, weight) }
      cap = BIG * U
      big, width = place(first, cap, 0, 0)
      if form == :one_line
        rest, width = place(second, cap, width + space * cap, 1)
        big += rest
      end
      icon_height = SPAN * width
      edges = [0, icon_height, icon_height + GAP * U, icon_height + (GAP + BIG) * U]
      placed = big.map { |letter| letter.merge(baseline: edges.last, cap:) }
      if form == :two_line
        edges += [edges.last + GAP * U, edges.last + (GAP + 1) * U]
        placed += small_line(second, width).map { |letter| letter.merge(baseline: edges.last, cap: U) }
      end
      Layout.new(form:, width:, height: edges.last, icon_height:, icon_left: (width - icon_width(tone, icon_height, width)) / 2,
                 edges:, letters: placed)
    end

    def svg(text: :homogeneous, tone: :light, guides: false, **unknown)
      check_keywords(unknown, "text, tone and guides")
      check_tone(tone)
      box = layout(text:, tone:)
      render(box, box.height, text, tone, guides)
    end

    private

    def check_keywords(unknown, taken)
      return if unknown.empty?

      raise Error, "a stacked logo takes #{taken}, not #{unknown.keys.join(', ')}: it has no rule"
    end

    # The small word, centred, with the same computed space added between each pair of letters and none after the last.
    def small_line(word, width)
      target = SPAN * width
      natural = place(word, U, 0, 1, 0).last
      gaps = word.size - 1
      if natural > target || gaps.zero?
        why = gaps.zero? ? "it has one letter" : "it is #{(100 * natural / width).round}% already"
        raise Error, "brand #{brand}: the second word #{@words[1].inspect} cannot be tracked out to #{(SPAN * 100).round}% of the first " \
                     "word's width (#{why}): set `stacked: one_line` in the brand's style"
      end
      place(word, U, (width - target) / 2, 1, (target - natural) / (gaps * U)).first
    end

    def icon_width(tone, height, width)
      icon = @icons.fetch(tone)
      wide = icon.fetch("w") * height / icon.fetch("h")
      raise Error, "brand #{brand}: the icon is too wide to stack (#{f(wide / width)} of the name's width at this height)" if wide > width

      wide
    end

    def drawing(box, tone, icon_fills, colours)
      icon = icon_markup(@icons.fetch(tone), icon_fills, box.icon_height)
      %(<g transform="translate(#{f(box.icon_left)},0)">#{icon}</g>) +
        box.letters.map { |l| letter_markup(l, l[:baseline], l[:cap], colours[l[:word]]) }.join
    end

    # The construction drawing: a line at each boundary, each band's size, and the proof that the icon is as tall as
    # the small line is wide: the small word turned on its side beside the icon (one_line: a labelled bracket).
    def guide_markup(box)
      lines = box.edges.map { |y| guide_line(-20, y, box.width + 20, y) }
      sizes = box.edges.drop(1).each_cons(2).zip(BANDS).map do |(top, bottom), size|
        guide_label(box.width + 30, (top + bottom) / 2 + GUIDE_FONT * 0.35, size)
      end
      (lines + sizes).join + icon_height_mark(box, box.icon_left - 1.5 * U)
    end

    def icon_height_mark(box, x)
      turned = %(transform="translate(#{f(x)},#{f(box.icon_height)}) rotate(-90)")
      small = box.letters.select { |letter| letter[:cap] == U }
      if small.empty?
        return guide_line(x, 0, x, box.icon_height) +
               guide_label(box.icon_height / 2, -12, "#{(SPAN * 100).round}% of the name's width", %( #{turned} text-anchor="middle"))
      end

      left = (box.width - box.icon_height) / 2   # the small line's left ink edge: its ink starts where the turned group does
      %(<g #{turned}>#{small.map { |l| letter_markup(l.merge(x: l[:x] - left), 0, U, GUIDE) }.join}</g>)
    end
  end
end
