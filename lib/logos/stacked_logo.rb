# frozen_string_literal: true

module Logos
  # Draws a brand's Stacked Logo: the icon above the name, in one of two PROPORTIONS (task stacked-rule-of-three): the
  # 3-2-1 method (the default) or the rule of three.
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
  # Every form draws in either proportion (`proportion:`), which sets only the icon's size and the gaps; the lines
  # above are the same in both.
  #
  #   three_two_one (default)  as above: the icon's height comes from the small line's width; every gap is 2u.
  #   rule_of_three            three copies of the icon side by side span exactly the big line's ink width W, so the
  #                            icon is W/3 wide (its height follows from its own aspect), centred; every gap is one
  #                            big-line cap height, 3u. Top to bottom: icon, 3u, big line(, 3u, small line).
  #
  # The operator's edits (NavbarLogo#checked_edits) also reach the tagline: its
  # colour, its weight (in place of TAGLINE_WEIGHT; still tracked out to 60%,
  # so it is as wide as before), and `visible: false`, which leaves every band
  # where it was and simply does not draw the tagline.
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
    PROPORTIONS = %i[three_two_one rule_of_three].freeze   # the first is the default
    GAPS = { three_two_one: GAP, rule_of_three: BIG }.freeze   # every gap, in u, per proportion
    THIRDS = 3                                 # rule_of_three: this many icons side by side are as wide as the big line
    # The guide drawing (the reel's ghost-copy grid): a ruler of the small line's copies beside the logo, its numbers
    # between the two, and the small line itself turned on end beside the icon. Distances are in design units.
    GUIDE_PAD = { left: 40, top: 40, right: 40, bottom: 40 }.freeze   # `right` is past the ruler
    GUIDE_FONT = 32                            # the ruler numbers: 0.8u, so the widest drawing (a tagline ruler of tracked copies) fits 1028 px at 9 px labels
    NUMBER_X = 50                              # a ruler number's centre, right of the logo
    RULER_X = 90                               # the ruler's left ink edge, right of the logo
    PROOF_GAP = 0.5 * U                        # the turned line's baseline, left of the icon's box
    BRACKET_GAP = 12                           # the bracket, left of the turned line's cap line
    TICK = 12                                  # the bracket's ticks at the icon's top and foot

    # `edges`: every horizontal boundary, top to bottom. `letters` carry their own baseline and cap. `line` is the
    # small line exactly as the logo sets it (the second word, the tagline, or in the one-line form the whole name),
    # tracking and word gap included, at a cap of 1 with its ink from x = 0, `line_width` wide; each letter carries
    # its glyph's ink edges `l` and `r`. The ruler's ghosts and the icon-height proof are copies of it.
    # `icon_width` is the icon's drawn width, and `proportion` the proportion it was laid out in.
    Layout = Struct.new(:form, :proportion, :width, :height, :icon_width, :icon_height, :icon_left, :edges, :letters, :line, :line_width,
                        keyword_init: true)

    undef_method :examples                     # the Navbar Logo's list: its keys name a rule, which this has none of

    # A name the form cannot set is refused here, with the rest of the brand's data, not at draw time.
    def initialize(...)
      super
      form = @style["stacked"] || FORMS.first
      raise Error, "brand #{brand}: stacked must be one of #{FORMS.join(', ')}, got #{form.inspect}" unless FORMS.include?(form)

      @form = form.to_sym
      @tagline = checked_tagline
      TEXTS.product(TONES, forms) { |text, tone, each| layout(text:, tone:, form: each) }
      TEXTS.product(BAKED, forms) { |text, tone, each| layout(text:, tone:, form: each, colouring: :original) } if original?
    end

    # :two_line or :one_line
    attr_reader :form

    # The brand's tagline as the logo sets it ("BUILD SMARTER"), or nil when the style names none.
    attr_reader :tagline

    # Every form this brand draws, its own first: [:two_line, :tagline], or [:one_line] for a brand with no tagline.
    def forms = [form, (:tagline if tagline)].compact

    # The geometry alone, in design units (x = 0 is the big line's left ink edge, y = 0 the icon's top).
    # A keyword it does not take (the Navbar Logo's `rule:` above all) is refused like any other bad choice.
    def layout(text: :homogeneous, tone: :light, form: self.form, proportion: PROPORTIONS.first, edits: NO_EDITS, colouring: :alt,
               icon_colouring: nil, **unknown)
      check_keywords(unknown, "text, tone, form, proportion, edits, colouring and icon_colouring")
      look = look(tone, icon_colouring || colouring)   # the icon's: only the icon's size depends on the look
      check_text(text)
      check_form(form)
      check_proportion(proportion)
      edits = checked_edits(edits)
      first, second = @words.zip(edited_weights(text, edits)).map { |word, weight| letters(word, weight) }
      cap = BIG * U
      big, width = place(first, cap, 0, 0)
      unless form == :two_line
        rest, width = place(second, cap, width + GAP_CAPS * cap, 1)   # the Navbar Logo's word gap
        big += rest
      end
      icon_width, icon_height = icon_box(look, width, proportion)
      gap = GAPS.fetch(proportion)
      edges = [0, icon_height, icon_height + gap * U, icon_height + (gap + BIG) * U]
      placed = big.map { |letter| letter.merge(baseline: edges.last, cap:) }
      line = [big, first + second, cap]
      unless form == :one_line
        edges += [edges.last + gap * U, edges.last + (gap + 1) * U]
        weight = edits.dig(:tagline, :weight) || TAGLINE_WEIGHT
        small = form == :tagline ? tagline_line(width, weight) : small_line(second, width)
        placed += small.map { |letter| letter.merge(baseline: edges.last, cap: U) } unless form == :tagline && edits.dig(:tagline, :visible) == false
        line = [small, form == :tagline ? tagline_glyphs(weight) : second, U]
      end
      line, line_width = unit_line(*line)
      Layout.new(form:, proportion:, width:, height: edges.last, icon_width:, icon_height:, icon_left: (width - icon_width) / 2,
                 edges:, letters: placed, line:, line_width:)
    end

    def svg(text: :homogeneous, tone: :light, guides: false, form: self.form, proportion: PROPORTIONS.first, edits: NO_EDITS, colouring: :alt,
            icon_colouring: nil, **unknown)
      check_keywords(unknown, "text, tone, form, proportion, guides, edits, colouring and icon_colouring")
      look = look(tone, colouring)
      icon_look = look(tone, icon_colouring || colouring)
      edits = edits_in(look, edits, icon_look)
      box = layout(text:, tone:, form:, proportion:, edits:, colouring:, icon_colouring:)
      render(box, box.height, text, look, guides, edits, icon_look)
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

    def tagline_glyphs(weight = TAGLINE_WEIGHT) = tagline.each_char.map { |char| glyph(char, weight) }

    # Placed letters set at `cap` from their glyphs, brought to a cap of 1 with the first letter's ink at x = 0. Each
    # keeps its glyph's ink edges. Returns them and the run's ink width (at a cap of 1).
    def unit_line(placed, glyphs, cap)
      left = placed.first[:x] + glyphs.first["l"] * cap
      letters = placed.zip(glyphs).map { |letter, g| letter.except(:baseline, :cap).merge(x: (letter[:x] - left) / cap, l: g["l"], r: g["r"]) }
      [letters, letters.last[:x] + letters.last[:r]]
    end

    def check_proportion(proportion)
      return if PROPORTIONS.include?(proportion)

      raise Error, "unknown proportion #{proportion.inspect[0, 40]}: expected one of #{PROPORTIONS.join(', ')}"
    end

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

    # The tagline, set like the small word: Montserrat at TAGLINE_WEIGHT (or its edited weight), every character (a
    # space too) one glyph. Its paths are font outlines, so they keep the font's fill rule whatever the name is set in.
    def tagline_line(width, weight = TAGLINE_WEIGHT)
      tracked(tagline_glyphs(weight), width, 2) do |why|
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
      steps = glyphs[0...-1].sum { |glyph| steps(glyph) }   # a word gap inside a traced ending takes two (NavbarLogo#place)
      if natural > target || gaps.zero?
        raise Error, "brand #{brand}: #{yield(gaps.zero? ? 'it has one letter' : "it is #{(100 * natural / width).round}% already")}"
      end

      place(glyphs, U, (width - target) / 2, index, (target - natural) / (steps * U)).first
    end

    # [each icon layer role's fill, [first word's, second word's, the tagline's fill]]: the tagline is quiet, unless
    # its colour is edited.
    def fills(look, text, edits = NO_EDITS, icon_look = look)
      icon, colours = super
      return [icon, colours + [@watermark["fill"]]] if look == :watermark

      baked = tone_style(look)
      tagline = edits.dig(:tagline, :colour) || baked.fetch("quiet", baked.fetch("text"))
      [icon, colours + [original_look?(look) ? gradient_ref(look, tagline) : tagline]]
    end

    # [the icon's width, its height] over a big line `width` wide. 3-2-1: as tall as the small line is wide (SPAN of the
    # width), refused when that makes it wider than the name. Rule of three: a third of the width, as tall as its aspect makes it.
    def icon_box(look, width, proportion)
      icon = @icons.fetch(look)
      if proportion == :rule_of_three
        wide = width / THIRDS
        return [wide, wide * icon.fetch("h") / icon.fetch("w")]
      end

      height = SPAN * width
      wide = icon.fetch("w") * height / icon.fetch("h")
      raise Error, "brand #{brand}: the icon is too wide to stack (#{f(wide / width)} of the name's width at this height)" if wide > width

      [wide, height]
    end

    def drawing(box, icon_look, icon_fills, colours)
      icon = icon_markup(@icons.fetch(icon_look), icon_fills, box.icon_height)
      %(<g transform="translate(#{f(box.icon_left)},0)">#{icon}</g>) +
        box.letters.map { |l| letter_markup(l, l[:baseline], l[:cap], colours[l[:word]]) }.join
    end

    # The guide drawing: the logo, then the ghosts in one translucent group (all on the plate, beside the logo), then
    # the lines and numbers in their own group. The drawing reaches past the ruler, and left past the turned line's bracket.
    # The rule of three proves its icon instead (#thirds_render).
    def render(box, height, text, look, guides, edits = NO_EDITS, icon_look = look)
      return super unless guides

      body = toned(look, drawing(box, icon_look, *fills(look, text, edits, icon_look)))
      return thirds_render(box, height, body, look, icon_look) if box.proportion == :rule_of_three

      ghosts = ghost_group(look, ruler_markup(box, ghost_fill(look)) + proof_markup(box, ghost_fill(look)))
      left = [GUIDE_PAD[:left], GUIDE_PAD[:left] / 2 - bracket_x(box)].max   # room for the turned line and its bracket
      document(with_defs(def_look(look, icon_look), body + ghosts + line_group(guide_markup(box))), box.width, height, **GUIDE_PAD, left:,
               right: ruler_right(box) - box.width + GUIDE_PAD[:right])
    end

    def ruler_right(box) = box.width + RULER_X + box.line_width * U

    # Each band under the icon as [top, bottom, its size in units].
    def bands(box) = box.edges.drop(1).each_cons(2).map { |top, bottom| [top, bottom, ((bottom - top) / U).round] }

    # The ruler: one copy of the small line per unit, edge to edge, from the icon's foot to the logo's foot. Each copy
    # is the small line exactly as the logo sets it, tracking included, so it is exactly as wide as the real one.
    def ruler_markup(box, fill)
      bands(box).flat_map do |top, _, size|
        (1..size).map { |row| box.line.map { |l| letter_markup(l.merge(x: box.width + RULER_X + l[:x] * U), top + row * U, U, fill) }.join }
      end.join
    end

    # The icon-height proof: the small line, set exactly as the logo sets it, turned a quarter turn to read bottom to
    # top, its baseline PROOF_GAP left of the icon's box and its ink from the icon's foot to the icon's top. It stands on
    # the plate, never on the icon, so it reads wherever the icon is filled. In the two-line and tagline forms it is
    # the small line at its own size (1u): the icon is as tall as the small line is wide, by construction. The one-line
    # form has no small line, so it is the whole name at the size whose width is the icon's height (60% of the name).
    def proof_cap(box) = box.icon_height / box.line_width
    def proof_x(box) = box.icon_left - PROOF_GAP

    def proof_markup(box, fill)
      cap = proof_cap(box)
      letters = box.line.map { |letter| letter_markup(letter.merge(x: letter[:x] * cap), 0, cap, fill) }.join
      %(<g class="guide-proof" transform="translate(#{f(proof_x(box))},#{f(box.icon_height)}) rotate(-90)">#{letters}</g>)
    end

    def bracket_x(box) = proof_x(box) - proof_cap(box) - BRACKET_GAP

    # A bracket beside the turned line, its ticks at the icon's top and foot: the line is as long as the icon is tall.
    def bracket_markup(box)
      x = bracket_x(box)
      [guide_line(x, 0, x, box.icon_height), guide_line(x, 0, x + TICK, 0), guide_line(x, box.icon_height, x + TICK, box.icon_height)]
    end

    # A line at each band boundary, across the logo and the ruler; the icon's centre line; the turned line's bracket;
    # each ruler copy's number; and a 1 at the icon's top.
    def guide_markup(box)
      lines = edge_lines(box) + [guide_line(box.width / 2, -20, box.width / 2, box.height + 20)]
      (lines + bracket_markup(box) + ruler_numbers(box) + [guide_label(box.width / 2 + 10, -10, 1)]).join
    end

    def edge_lines(box) = box.edges.map { |y| guide_line(-20, y, ruler_right(box) + 20, y) }

    def ruler_numbers(box)
      bands(box).flat_map do |top, _, size|
        (1..size).map { |row| guide_label(box.width + NUMBER_X, top + (row - 0.5) * U + GUIDE_FONT * 0.35, row, %( text-anchor="middle")) }
      end
    end

    # THE RULE OF THREE'S GUIDE DRAWING, as the reel draws it: two ghost copies of the icon either side of the real one,
    # the three edge to edge across the name's ink; a vertical line at each third, numbered 1 2 3 above; the ruler of
    # small-line copies beside the logo, which counts each 3u gap; and a line at each band boundary. No turned line:
    # the icon's height is its own aspect's, not the small line's width.
    def thirds_render(box, height, body, look, icon_look)
      fill = ghost_fill(look)
      ghosts = ghost_group(look, thirds_ghosts(box, icon_look, fill) + ruler_markup(box, fill))
      document(with_defs(def_look(look, icon_look), body + ghosts + line_group(thirds_guide_markup(box))), box.width, height, **GUIDE_PAD,
               right: ruler_right(box) - box.width + GUIDE_PAD[:right])
    end

    # The icon, solid in the ghost fill, in the first and the last third (the real icon is the middle one).
    def thirds_ghosts(box, icon_look, fill)
      icon = @icons.fetch(icon_look)
      [box.icon_left - box.icon_width, box.icon_left + box.icon_width].map do |x|
        %(<g class="guide-third" transform="translate(#{f(x)},0)">#{icon_markup(icon, Hash.new(fill), box.icon_height)}</g>)
      end.join
    end

    def thirds_guide_markup(box)
      thirds = (0..THIRDS).map { |i| guide_line(i * box.icon_width, -20, i * box.icon_width, box.height + 20) }
      numbers = (1..THIRDS).map { |i| guide_label((i - 0.5) * box.icon_width, -10, i, %( text-anchor="middle" data-third="#{i}")) }
      (edge_lines(box) + thirds + ruler_numbers(box) + numbers).join
    end
  end
end
