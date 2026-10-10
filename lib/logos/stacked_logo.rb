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
  #   tagline             (a brand whose style has a `tagline`) the name as
  #                       one_line sets it, then 2u, then the tagline at 1u in
  #                       Montserrat 500, tracked out between its characters (a
  #                       space is one) to 60% of the name's ink width; the icon
  #                       is as tall as the tagline is wide. The tagline takes the
  #                       tone's `quiet` fill (`text` without one).
  #
  # A brand's own form (`form`) is the default; `forms` lists every form it can
  # draw. Everything is centred on the big line, whose ink is the logo's width.
  # Rules, forms and guides: docs/topics/logos.md. Outside Rails, require
  # navbar_logo first (the app autoloads both).
  class StackedLogo < NavbarLogo
    U = 40.0                                   # one unit, in design units
    BIG = 3                                    # the big line's capitals, in u
    GAP = 2                                    # every gap, in u
    SPAN = 0.6                                 # the small line's width, and the icon's height, as a share of the big line's width
    FORMS = %w[two_line one_line].freeze       # a style's own form; `tagline` is offered beside it, never named in a style
    TAGLINE_WEIGHT = 500                       # every brand's tagline is Montserrat at this weight
    # The guide drawing (the reel's ghost-copy grid): a ruler of the small line's copies beside the logo, its numbers
    # between the two, and the small line's letters down the icon's axis. Distances are in design units.
    GUIDE_PAD = { left: 40, top: 40, right: 40, bottom: 40 }.freeze   # `right` is past the ruler
    GUIDE_FONT = 28
    GUIDE_STROKE = 1.0
    NUMBER_X = 50                              # a ruler number's centre, right of the logo
    RULER_X = 90                               # the ruler's left ink edge, right of the logo
    AXIS_FILL = 0.8                            # an axis letter is at most this share of the step between letters
    # The ghosts are the logo's own text colour at this opacity: visible, and never mistaken for the logo
    # (test/helpers/logos_helper_test.rb measures their contrast against each plate).
    GHOST_OPACITY = { light: 0.25, dark: 0.22, watermark: 0.22 }.freeze

    # `edges`: every horizontal boundary, top to bottom. `letters` carry their own baseline and cap. `ruler` is the
    # small line as its ghosts copy it: its letters at a cap of 1 with their ink from x = 0, untracked, `ruler_width`
    # wide (the second word, the tagline, or in the one-line form the whole name).
    Layout = Struct.new(:form, :width, :height, :icon_height, :icon_left, :edges, :letters, :ruler, :ruler_width, keyword_init: true)

    undef_method :examples                     # the Navbar Logo's list: its keys name a rule, which this has none of

    # A name the form cannot set is refused here, with the rest of the brand's data, not at draw time.
    def initialize(...)
      super
      form = @style["stacked"] || FORMS.first
      raise Error, "brand #{brand}: stacked must be one of #{FORMS.join(', ')}, got #{form.inspect}" unless FORMS.include?(form)

      @form = form.to_sym
      @tagline = checked_tagline
      TEXTS.product(TONES, forms) { |text, tone, each| layout(text:, tone:, form: each) }
    end

    # :two_line or :one_line
    attr_reader :form

    # The brand's tagline as the logo sets it ("BUILD SMARTER"), or nil when the style names none.
    attr_reader :tagline

    # Every form this brand draws, its own first: [:two_line, :tagline], or [:one_line] for a brand with no tagline.
    def forms = [form, (:tagline if tagline)].compact

    # The geometry alone, in design units (x = 0 is the big line's left ink edge, y = 0 the icon's top).
    # A keyword it does not take (the Navbar Logo's `rule:` above all) is refused like any other bad choice.
    def layout(text: :homogeneous, tone: :light, form: self.form, **unknown)
      check_keywords(unknown, "text, tone and form")
      check_text(text)
      check_form(form)
      first, second = @words.zip(word_weights(text)).map { |word, weight| letters(word, weight) }
      cap = BIG * U
      big, width = place(first, cap, 0, 0)
      unless form == :two_line
        rest, width = place(second, cap, width + space * cap, 1)
        big += rest
      end
      icon_height = SPAN * width
      edges = [0, icon_height, icon_height + GAP * U, icon_height + (GAP + BIG) * U]
      placed = big.map { |letter| letter.merge(baseline: edges.last, cap:) }
      unless form == :one_line
        edges += [edges.last + GAP * U, edges.last + (GAP + 1) * U]
        small = form == :tagline ? tagline_line(width) : small_line(second, width)
        placed += small.map { |letter| letter.merge(baseline: edges.last, cap: U) }
      end
      ruler, ruler_width = ruler(form, first, second)
      Layout.new(form:, width:, height: edges.last, icon_height:, icon_left: (width - icon_width(tone, icon_height, width)) / 2,
                 edges:, letters: placed, ruler:, ruler_width:)
    end

    def svg(text: :homogeneous, tone: :light, guides: false, form: self.form, **unknown)
      check_keywords(unknown, "text, tone, form and guides")
      check_tone(tone)
      box = layout(text:, tone:, form:)
      render(box, box.height, text, tone, guides)
    end

    private

    # The style's optional `tagline`: words of characters the glyph data has at TAGLINE_WEIGHT, or nothing at all.
    def checked_tagline
      line = @style["tagline"]
      return if line.nil?
      unless line.is_a?(String) && line.match?(/\A\S+(?: \S+)*\z/)
        raise Error, "brand #{brand}: tagline must be words separated by single spaces, got #{line.inspect[0, 80]}"
      end

      line.each_char { |char| check_path(glyph(char, TAGLINE_WEIGHT)["d"], "nonzero", "the tagline") }
      line
    end

    def check_keywords(unknown, taken)
      return if unknown.empty?

      raise Error, "a stacked logo takes #{taken}, not #{unknown.keys.join(', ')}: it has no rule"
    end

    # The small line at a cap of 1, untracked, each letter with its glyph's ink edges: the ghosts' copy of it.
    def ruler(form, first, second)
      runs = case form
             when :two_line then [[second, 1, 0]]
             when :tagline then [[tagline_glyphs, 2, 0]]
             else [[first, 0, @tracking], [second, 1, @tracking]]
             end
      right = -space
      letters = runs.flat_map do |glyphs, index, tracking|
        placed, right = place(glyphs, 1.0, right + space, index, tracking)
        placed.zip(glyphs).map { |letter, g| letter.merge(l: g["l"], r: g["r"], fill_rule: (form == :tagline ? "nonzero" : @fill_rule)) }
      end
      [letters, right]
    end

    def tagline_glyphs = tagline.each_char.map { |char| glyph(char, TAGLINE_WEIGHT) }

    def check_form(form)
      return if forms.include?(form)

      why = form == :tagline ? "it has no tagline" : "it draws #{forms.join(' and ')}"
      raise Error, "brand #{brand}: no stacked form #{form.inspect} (#{why})"
    end

    # The small word, centred, with the same computed space added between each pair of letters and none after the last.
    def small_line(word, width)
      tracked(word, width, 1) do |why|
        "the second word #{@words[1].inspect} cannot be tracked out to #{(SPAN * 100).round}% of the first word's width " \
          "(#{why}): set `stacked: one_line` in the brand's style"
      end
    end

    # The tagline, set like the small word: Montserrat at TAGLINE_WEIGHT, every character (a space too) one glyph.
    # Its paths are font outlines, so they keep the font's fill rule whatever the name is set in.
    def tagline_line(width)
      tracked(tagline_glyphs, width, 2) do |why|
        "the tagline #{tagline.inspect} cannot be tracked out to #{(SPAN * 100).round}% of the name's width (#{why}): " \
          "shorten it, or leave it out of the brand's style"
      end.map { |letter| letter.merge(fill_rule: "nonzero") }
    end

    # A run of glyphs at 1u, tracked out between them to SPAN of `width` and centred on it. Never tracked in: the
    # block words the refusal when the run is already wider, or cannot be tracked at all.
    def tracked(glyphs, width, index)
      target = SPAN * width
      natural = place(glyphs, U, 0, index, 0).last   # its ink width: `place` starts the ink at 0
      gaps = glyphs.size - 1
      if natural > target || gaps.zero?
        raise Error, "brand #{brand}: #{yield(gaps.zero? ? 'it has one letter' : "it is #{(100 * natural / width).round}% already")}"
      end

      place(glyphs, U, (width - target) / 2, index, (target - natural) / (gaps * U)).first
    end

    # [each icon layer role's fill, [first word's, second word's, the tagline's fill]]: the tagline is quiet.
    def fills(tone, text)
      icon, colours = super
      return [icon, colours + [@watermark["fill"]]] if tone == :watermark

      baked = @style.fetch("tones").fetch(tone.to_s)
      [icon, colours + [baked.fetch("quiet", baked.fetch("text"))]]
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

    # The guide drawing: the logo, then the ghosts in one translucent group (over the logo, so the letters down the
    # icon's axis show across it), then the lines and numbers in their own group. The drawing reaches past the ruler.
    def render(box, height, text, tone, guides)
      return super unless guides

      body = toned(tone, drawing(box, tone, *fills(tone, text)))
      ghosts = %(<g class="guide-ghosts" opacity="#{format('%g', GHOST_OPACITY.fetch(tone))}">#{ruler_markup(box, ghost_fill(tone))}#{axis_markup(box, ghost_fill(tone))}</g>)
      document(body + ghosts + %(<g class="guide-lines">#{guide_markup(box)}</g>), box.width, height, **GUIDE_PAD, right: ruler_right(box) - box.width + GUIDE_PAD[:right])
    end

    # The logo's own text colour; a watermark's one fill.
    def ghost_fill(tone) = tone == :watermark ? @watermark["fill"] : @style.fetch("tones").fetch(tone.to_s).fetch("text")

    def ruler_right(box) = box.width + RULER_X + box.ruler_width * U

    # Each band under the icon as [top, bottom, its size in units].
    def bands(box) = box.edges.drop(1).each_cons(2).map { |top, bottom| [top, bottom, ((bottom - top) / U).round] }

    # The ruler: one copy of the small line per unit, edge to edge, from the icon's foot to the logo's foot.
    def ruler_markup(box, fill)
      bands(box).flat_map do |top, _, size|
        (1..size).map { |row| box.ruler.map { |l| letter_markup(l.merge(x: box.width + RULER_X + l[:x] * U), top + row * U, U, fill) }.join }
      end.join
    end

    # The small line's letters one under another down the icon's centre line, from its top to its foot: the icon is
    # as tall as the small line is wide. Each letter keeps its place along the line, and is drawn small enough not to
    # touch the next (never above 1u).
    def axis_markup(box, fill)
      inked = box.ruler.reject { |l| l[:d].empty? }
      centres = inked.map { |l| l[:x] + (l[:l] + l[:r]) / 2 }
      length = centres.last - centres.first
      return "" unless length.positive?

      share = centres.each_cons(2).map { |a, b| b - a }.min / length
      cap = [U, AXIS_FILL * share * box.icon_height / (1 + AXIS_FILL * share)].min
      inked.zip(centres).map do |letter, centre|
        middle = cap / 2 + (centre - centres.first) * (box.icon_height - cap) / length
        letter_markup(letter.merge(x: box.width / 2 - (letter[:l] + letter[:r]) / 2 * cap), middle + cap / 2, cap, fill)
      end.join
    end

    # A line at each band boundary, across the logo and the ruler; the icon's centre line; each ruler copy's number;
    # and a 1 at the icon's top.
    def guide_markup(box)
      right = ruler_right(box) + 20
      lines = box.edges.map { |y| guide_line(-20, y, right, y) } + [guide_line(box.width / 2, -20, box.width / 2, box.height + 20)]
      numbers = bands(box).flat_map do |top, _, size|
        (1..size).map { |row| guide_label(box.width + NUMBER_X, top + (row - 0.5) * U + GUIDE_FONT * 0.35, row, %( text-anchor="middle")) }
      end
      (lines + numbers + [guide_label(box.width / 2 + 10, -10, 1)]).join
    end
  end
end
