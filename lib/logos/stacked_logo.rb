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
  # Every form draws in either proportion (`proportion:`), which sets only the icon's size; the lines and the 2u
  # gaps above are the same in both (Alex McRitchie 2026-10-14 12:07: "space of 2 vertically between").
  #
  #   three_two_one (default)  as above: the icon's height comes from the small line's width; every gap is 2u.
  #   rule_of_three            three copies of the icon side by side span exactly the big line's ink width W, so the
  #                            icon is W/3 wide (its height follows from its own aspect), centred. Top to bottom:
  #                            icon, 2u, big line(, 2u, small line).
  #
  # Two more settings (task stacked-line-width-and-spacing), each with today's drawing as its default:
  #
  #   small_line      three_two_one (default)  the small line (the second word, or the tagline) as above: tracked out to
  #                                            SPAN of the big line, or at its own width when it is already wider.
  #                   match                    tracked out until its ink spans exactly the big line's ink width. The
  #                                            3-2-1 icon keeps the height 3-2-1 gives it (as tall as the 3-2-1 small
  #                                            line is wide), so Match never makes the icon grow; the guide drawing's
  #                                            turned line is that 3-2-1 line, which is what sized the icon. The rule
  #                                            of three sizes the icon from the name, so Match does not touch it.
  #   letter_spacing  as_styled (default)      the big line at the brand's own `tracking`.
  #                   open                     the big line tracked out just enough that no two adjacent letters' ink
  #                                            comes within OPEN_GAP of each other (#open_tracking). A brand whose
  #                                            letters are already that far apart draws exactly as styled.
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
    THIRDS = 3                                 # rule_of_three: this many icons side by side are as wide as the big line
    SMALL_LINES = %i[three_two_one match].freeze   # the first is the default
    LETTER_SPACINGS = %i[as_styled open].freeze    # the first is the default
    # Open's least ink-to-ink gap between adjacent letters of the big line, in cap heights. Montserrat untracked sets
    # its own tightest pairs in these brands' names about this far apart (A to L in COMMERCIAL: 0.040; C to H in
    # McRITCHIE: 0.054), so Open never sets a pair tighter than the typeface sets one by itself. Turf Monster's
    # -0.025 em puts r and f of "Turf" 0.002 cap heights INTO each other; Open lifts the whole word by the one amount
    # that brings that, its tightest pair, to 0.040 (from -0.036 to +0.007 cap heights of tracking).
    OPEN_GAP = 0.04
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
    # `proof` and `proof_width` are the line the icon-height proof turns on end: `line` itself, except under Match,
    # where it is the small line as 3-2-1 sets it (the icon's height comes from that line's width).
    Layout = Struct.new(:form, :proportion, :small_line, :letter_spacing, :width, :height, :icon_width, :icon_height, :icon_left, :edges,
                        :letters, :line, :line_width, :proof, :proof_width, keyword_init: true)

    undef_method :examples                     # the Navbar Logo's list: its keys name a rule, which this has none of

    # A name the form cannot set is refused here, with the rest of the brand's data, not at draw time.
    def initialize(...)
      super
      form = @style["stacked"] || FORMS.first
      raise Error, "brand #{brand}: stacked must be one of #{FORMS.join(', ')}, got #{form.inspect}" unless FORMS.include?(form)

      @form = form.to_sym
      @tagline = checked_tagline
      @forms = [@form, (:two_line if @form == :one_line), (:tagline if @tagline)].compact
      @forms.delete(:two_line) unless @form == :two_line || two_line_draws?
      TEXTS.product(TONES, forms) { |text, tone, each| layout(text:, tone:, form: each) }
      TEXTS.product(BAKED, forms) { |text, tone, each| layout(text:, tone:, form: each, colouring: :original) } if original?
    end

    # :two_line or :one_line
    attr_reader :form

    # The brand's tagline as the logo sets it ("BUILD SMARTER"), or nil when the style names none.
    attr_reader :tagline

    # Every form this brand draws, its own first: [:two_line, :tagline], or [:one_line] for a brand with no tagline. A
    # one-line brand also draws two lines when its second word fits under its first (Turf Monster: [:one_line, :two_line]).
    attr_reader :forms

    # The geometry alone, in design units (x = 0 is the big line's left ink edge, y = 0 the icon's top).
    # A keyword it does not take (the Navbar Logo's `rule:` above all) is refused like any other bad choice.
    def layout(text: :homogeneous, tone: :light, form: self.form, proportion: PROPORTIONS.first, small_line: SMALL_LINES.first,
               letter_spacing: LETTER_SPACINGS.first, edits: NO_EDITS, colouring: :alt, icon_colouring: nil, **unknown)
      check_keywords(unknown, "text, tone, form, proportion, small_line, letter_spacing, edits, colouring and icon_colouring")
      look = look(tone, icon_colouring || colouring)   # the icon's: only the icon's size depends on the look
      check_text(text)
      check_form(form)
      check_proportion(proportion)
      check_setting(small_line, SMALL_LINES, "small line")
      check_setting(letter_spacing, LETTER_SPACINGS, "letter spacing")
      edits = checked_edits(edits)
      first, second = @words.zip(edited_weights(text, edits)).map { |word, weight| letters(word, weight) }
      tracking = letter_spacing == :open ? open_tracking(form == :two_line ? [first] : [first, second]) : @tracking
      cap = BIG * U
      big, width = place(first, cap, 0, 0, tracking)
      unless form == :two_line
        rest, width = place(second, cap, width + GAP_CAPS * cap, 1, tracking)   # the Navbar Logo's word gap
        big += rest
      end
      weight = edits.dig(:tagline, :weight) || TAGLINE_WEIGHT
      set_small = lambda do |span|
        { tagline: -> { tagline_line(width, weight, span) }, two_line: -> { second_line(second, width, span) } }[form]&.call
      end
      small = set_small.call(small_line == :match ? 1.0 : SPAN)
      icon_width, icon_height = icon_box(look, width, proportion, form == :two_line ? [SPAN * width, place(second, U, 0, 1, 0).last].max : SPAN * width)
      edges = [0, icon_height, icon_height + GAP * U, icon_height + (GAP + BIG) * U]
      placed = big.map { |letter| letter.merge(baseline: edges.last, cap:) }
      line = [big, first + second, cap]
      proof = nil
      if small
        edges += [edges.last + GAP * U, edges.last + (GAP + 1) * U]
        placed += small.map { |letter| letter.merge(baseline: edges.last, cap: U) } unless form == :tagline && edits.dig(:tagline, :visible) == false
        glyphs = form == :tagline ? tagline_glyphs(weight) : second
        line = [small, glyphs, U]
        proof = unit_line(set_small.call(SPAN), glyphs, U) if small_line == :match
      end
      line, line_width = unit_line(*line)
      proof, proof_width = proof || [line, line_width]
      Layout.new(form:, proportion:, small_line:, letter_spacing:, width:, height: edges.last, icon_width:, icon_height:,
                 icon_left: (width - icon_width) / 2, edges:, letters: placed, line:, line_width:, proof:, proof_width:)
    end

    def svg(text: :homogeneous, tone: :light, guides: false, form: self.form, proportion: PROPORTIONS.first, small_line: SMALL_LINES.first,
            letter_spacing: LETTER_SPACINGS.first, edits: NO_EDITS, colouring: :alt, icon_colouring: nil, **unknown)
      check_keywords(unknown, "text, tone, form, proportion, small_line, letter_spacing, guides, edits, colouring and icon_colouring")
      look = look(tone, colouring)
      icon_look = look(tone, icon_colouring || colouring)
      edits = edits_in(look, edits, icon_look)
      box = layout(text:, tone:, form:, proportion:, small_line:, letter_spacing:, edits:, colouring:, icon_colouring:)
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

    def check_setting(value, known, name)
      return if known.include?(value)

      raise Error, "unknown #{name} #{value.inspect[0, 40]}: expected one of #{known.join(', ')}"
    end

    # OPEN LETTER SPACING: the least tracking (in cap heights, never less than the brand's own) at which every adjacent
    # pair of letters within each word has at least OPEN_GAP between its ink. A pair's ink gap is the first letter's
    # advance past its right ink edge, plus the next letter's left side bearing, plus the tracking once per step
    # (twice at a traced word gap, NavbarLogo#steps): solving that for the gap OPEN_GAP gives the pair's own least
    # tracking, and the word takes the largest. The boxes are each letter's horizontal ink extent, so a pair whose boxes
    # clear OPEN_GAP cannot touch however its shapes interlock.
    def open_tracking(words)
      needed = words.flat_map do |word|
        word.each_cons(2).map { |left, right| (OPEN_GAP - (left["adv"] - left["r"] + right["l"])) / steps(left) }
      end
      [@tracking, *needed].max
    end

    def check_form(form)
      return if forms.include?(form)

      why = form == :tagline ? "it has no tagline" : "it draws #{forms.join(' and ')}"
      raise Error, "brand #{brand}: no stacked form #{form.inspect} (#{why})"
    end

    # The small word, centred, with the same computed space added between each pair of letters and none after the last.
    # A word already wider than SPAN of the first is set at its own width instead, never tracked in (Turf Monster's
    # "Monster" is 68% of "Turf"; Alex McRitchie 2026-10-28 chose this over spreading it to the first word's width). A
    # word wider than the first word itself cannot sit under it.
    # Under Match (`span` 1) it is tracked out to the first word's whole width instead.
    def second_line(word, width, span = SPAN)
      tracked(word, width, 1, span:, natural_over: true) do |why|
        "the second word #{@words[1].inspect} cannot sit under the first word (#{why}): set `stacked: one_line` in the brand's style"
      end
    end

    # Whether the two-line form draws for this brand: its second word fits under its first, and the icon over it, in
    # every text and tone the constructor checks.
    def two_line_draws?
      TEXTS.product(TONES) { |text, tone| layout(text:, tone:, form: :two_line) }
      TEXTS.product(BAKED) { |text, tone| layout(text:, tone:, form: :two_line, colouring: :original) } if original?
      true
    rescue Error
      false
    end

    # The tagline, set like the small word: Montserrat at TAGLINE_WEIGHT (or its edited weight), every character (a
    # space too) one glyph. Its paths are font outlines, so they keep the font's fill rule whatever the name is set in.
    def tagline_line(width, weight = TAGLINE_WEIGHT, span = SPAN)
      tracked(tagline_glyphs(weight), width, 2, span:) do |why|
        "the tagline #{tagline.inspect} cannot be tracked out to #{(span * 100).round}% of the name's width (#{why}): " \
          "shorten it, or leave it out of the brand's style"
      end.map { |letter| letter.merge(fill_rule: "nonzero") }
    end

    # A run of glyphs at 1u, tracked out between them to `span` (SPAN unless Match) of `width` and centred on it. Never
    # tracked in: the block words the refusal when the run is already wider, or cannot be tracked at all. With
    # `natural_over`, a run already wider than the span (but no wider than `width`) is set at its own width, centred.
    def tracked(glyphs, width, index, span: SPAN, natural_over: false)
      target = span * width
      natural = place(glyphs, U, 0, index, 0).last   # its ink width: `place` starts the ink at 0
      gaps = glyphs.size - 1
      steps = glyphs[0...-1].sum { |glyph| steps(glyph) }   # a word gap inside a traced ending takes two (NavbarLogo#place)
      return place(glyphs, U, (width - natural) / 2, index, 0).first if natural_over && natural > target && natural <= width && gaps.positive?
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

    # [the icon's width, its height] over a big line `width` wide. 3-2-1: as tall as the small line is wide (`small`:
    # SPAN of the width, or a small word set at its own wider width), refused when that makes it wider than the name.
    # Rule of three: a third of the width, as tall as its aspect makes it.
    def icon_box(look, width, proportion, small = SPAN * width)
      icon = @icons.fetch(look)
      if proportion == :rule_of_three
        wide = width / THIRDS
        return [wide, wide * icon.fetch("h") / icon.fetch("w")]
      end

      height = small
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
    # Under Match it is the small line as 3-2-1 would set it (Layout#proof), which is what sized the icon.
    def proof_cap(box) = box.icon_height / box.proof_width
    def proof_x(box) = box.icon_left - PROOF_GAP

    def proof_markup(box, fill)
      cap = proof_cap(box)
      letters = box.proof.map { |letter| letter_markup(letter.merge(x: letter[:x] * cap), 0, cap, fill) }.join
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
    # small-line copies beside the logo, which counts each 2u gap; and a line at each band boundary. No turned line:
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
