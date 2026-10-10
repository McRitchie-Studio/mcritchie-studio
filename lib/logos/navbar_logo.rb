# frozen_string_literal: true

require "json"
require "yaml"

module Logos
  # Draws a brand's Navbar Logo (the main logo) from an ICON and a two-word
  # NAME as a pure-vector SVG: the icon, then the name on one line, set from
  # pre-extracted Montserrat outlines or, for a brand that names a `lettering`,
  # from that brand's own traced letters. No font library, no raster, no database.
  #
  #   Logos::NavbarLogo.new("industries").svg(rule: 4, text: :second, tone: :dark)
  #
  # A logo has no background: the SVG is transparent wherever it draws nothing.
  # `tone: :watermark` is the whole logo in ONE fill inside one translucent
  # group, for placing over a photograph.
  #
  # The icon is H units tall. Rule of 3: the capitals are one of three rows.
  # Rule of 4: the capitals fill the middle two of four rows. Either way the
  # name is centred on the icon. Rules and data: docs/topics/logos.md.
  class NavbarLogo
    class Error < ArgumentError; end

    H = 300.0
    RULES = { 3 => 1, 4 => 2 }.freeze          # rows the icon spans => rows the capitals span
    TEXTS = %i[homogeneous first second].freeze
    TONES = %i[light dark watermark].freeze
    BAKED = %i[light dark].freeze               # the tones whose fills a style lists; `examples` draws these
    WATERMARK = { "fill" => "#FFFFFF", "opacity" => 0.6 }.freeze
    WATERMARK_KEYS = %w[fill opacity icon_key].freeze
    HIGHLIGHTS = %w[weight colour].freeze
    SPACE_WEIGHT = 300                         # the word space is this weight's " " advance
    GUIDE = "#D4189F"
    GUIDE_PAD = { left: 40, top: 40, right: 80, bottom: 40 }.freeze
    GUIDE_FONT = 30                            # the guide labels' size, in design units
    GUIDE_STROKE = 1.0                         # the guide lines' width, in design units
    # A guide drawing's ghosts (faint copies of the name that show how it measures) are the logo's own text colour at
    # this opacity: visible, never mistaken for the logo (test/helpers/logos_helper_test.rb measures them on each plate).
    GHOST_OPACITY = { light: 0.25, dark: 0.22, watermark: 0.22 }.freeze
    HEX = /\A#(?:\h{3}|\h{6})\z/
    # Icon, glyph and lettering data is written into markup as it stands, so it is checked first.
    PATH = /\A[MLHVCSQTAZmlhvcsqtazeE0-9 ,.+-]*\z/
    FILL_RULES = %w[nonzero evenodd].freeze
    NUMBER = /[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/
    CALL = /(?:translate|scale|rotate|matrix)\(#{NUMBER}(?:[ ,]#{NUMBER})*\)/
    TRANSFORM = /\A#{CALL}(?: #{CALL})*\z/
    ICON_FILES = %w[brand_icons.json brand_icons_turf_welding.json brand_icons_turf_mono.json].freeze
    ROOT = File.expand_path("../..", __dir__)

    Layout = Struct.new(:count, :row, :cap, :baseline, :icon_width, :gap, :name_left, :letters, :width, keyword_init: true)

    class << self
      def styles = @styles ||= YAML.safe_load_file(File.join(ROOT, "config/logo_brands.yml")).freeze
      def icons = @icons ||= ICON_FILES.map { |file| data(file) }.reduce(:merge).freeze
      def letterings = @letterings ||= data("brand_lettering.json").freeze
      def glyphs = @glyphs ||= JSON.parse(File.read(File.join(__dir__, "data/montserrat_glyphs.json"))).fetch("weights").freeze
      def brands = styles.keys

      private

      def data(file) = JSON.parse(File.read(File.join(__dir__, "data", file)))
    end

    attr_reader :brand, :words

    # `styles:`, `icons:` and `letterings:` default to the shipped data; pass your own to draw a brand that is not in it.
    # Everything this brand will write into markup is checked here, so bad data fails before anything is drawn.
    def initialize(brand, styles: self.class.styles, icons: self.class.icons, letterings: self.class.letterings)
      @brand = brand.to_s
      @style = styles[@brand] or raise Error, "unknown brand #{@brand.inspect}: expected one of #{styles.keys.join(', ')}"
      @watermark = checked_watermark
      @icons = TONES.to_h { |tone| [tone, checked_icon(icon_key(tone), icons)] }
      @words = @style["name"].to_s.split
      raise Error, "brand #{@brand}: the name must be exactly two words, got #{@words.size} (#{@style['name'].inspect})" unless @words.size == 2
      raise Error, "brand #{@brand}: highlight must be one of #{HIGHLIGHTS.join(', ')}, got #{@style['highlight'].inspect}" unless HIGHLIGHTS.include?(@style["highlight"])
      @lettering = own_lettering(letterings)
      @fill_rule = @lettering ? @lettering["fill_rule"] : "nonzero"   # font contours overlap: evenodd would punch holes in them
      @tracking = tracking_in_cap_heights
      word_weights(:first).uniq.each { |weight| @words.each { |word| letters(word, weight) } }   # a missing character fails here, not at draw time
      space
    end

    # What the brand's page says about where its art came from (optional).
    def note = @style["note"]

    # "weight" or "colour": how one word leads the other. A watermark has one colour, so only weight shows in it.
    def highlight = @style["highlight"]

    # The geometry alone, in design units (the icon is H tall, x = 0 is its left edge).
    # `tone:` matters only to a brand whose tones name different icons.
    def layout(rule: 3, text: :homogeneous, tone: :light)
      cap_rows = RULES[rule] or raise Error, "unknown rule #{rule.inspect}: expected #{RULES.keys.join(' or ')}"
      check_text(text)
      row = H / rule
      cap = cap_rows * row
      first, second = @words.zip(word_weights(text)).map { |word, weight| letters(word, weight) }
      icon = @icons.fetch(tone)
      icon_width = icon.fetch("w") * H / icon.fetch("h")
      gap = (first[0]["r"] - first[0]["l"]) * cap / 2                    # half the first letter's ink
      placed1, right1 = place(first, cap, icon_width + gap, 0)
      placed2, right2 = place(second, cap, right1 + space * cap, 1)
      Layout.new(count: rule, row:, cap:, baseline: (H + cap) / 2, icon_width:, gap:, name_left: icon_width + gap,
                 letters: placed1 + placed2, width: right2)
    end

    def svg(rule: 3, text: :homogeneous, tone: :light, guides: false)
      check_tone(tone)
      render(layout(rule:, text:, tone:), H, text, tone, guides)
    end

    # The brand's icon alone, in its own box (`0 0 <w> <h>` of the icon data), with the tone's fills and the
    # tone's icon: the icon exactly as the Navbar Logo draws it, without the name.
    def icon_svg(tone: :light)
      check_tone(tone)
      icon = @icons.fetch(tone)
      height = icon.fetch("h")
      document(toned(tone, icon_markup(icon, fills(tone, :homogeneous).first, height)), icon.fetch("w"), height)
    end

    # The watermark's checked settings: { "fill" => "#FFFFFF", "opacity" => 0.6 }, and "icon_key" when the style names one.
    def watermark = @watermark.dup

    # Every light and dark example for the brand: 2 rules x 3 texts x 2 tones, each with its guide drawing.
    def examples
      RULES.keys.product(TEXTS, BAKED, [false, true]).map do |rule, text, tone, guides|
        key = [brand, "rule#{rule}", text, tone, ("guides" if guides)].compact.join("-")
        { key:, rule:, text:, tone:, guides:, svg: svg(rule:, text:, tone:, guides:) }
      end
    end

    private

    def by_weight? = highlight == "weight"

    def check_tone(tone)
      raise Error, "unknown tone #{tone.inspect}: expected one of #{TONES.join(', ')}" unless TONES.include?(tone)
    end

    def check_text(text)
      raise Error, "unknown text #{text.inspect}: expected one of #{TEXTS.join(', ')}" unless TEXTS.include?(text)
    end

    # A laid-out logo as a document: the drawing in its tone, or the guide drawing around it: the ghosts BEHIND the logo
    # (in the rule of 4 they cross the real name), the logo, then the lines and numbers.
    def render(box, height, text, tone, guides)
      body = toned(tone, drawing(box, tone, *fills(tone, text)))
      return document(body, box.width, height) unless guides

      document(ghost_group(tone, ghost_markup(box, ghost_fill(tone))) + body + line_group(guide_markup(box)), box.width, height, **self.class::GUIDE_PAD)
    end

    # The logo's own text colour; a watermark's one fill.
    def ghost_fill(tone) = tone == :watermark ? @watermark["fill"] : @style.fetch("tones").fetch(tone.to_s).fetch("text")

    # The ghosts in ONE translucent group (opacity on each path would compound where copies overlap), the lines in another.
    def ghost_group(tone, markup) = %(<g class="guide-ghosts" opacity="#{format('%g', GHOST_OPACITY.fetch(tone))}">#{markup}</g>)
    def line_group(markup) = %(<g class="guide-lines">#{markup}</g>)

    def icon_key(tone)
      (tone == :watermark ? @watermark["icon_key"] : @style.dig("tones", tone.to_s, "icon_key")) || @style["icon"]
    end

    # The style's optional `watermark:` map over the defaults, checked: a #hex fill and an opacity in (0, 1].
    def checked_watermark
      given = @style["watermark"] || {}
      unless given.is_a?(Hash) && (given.keys - WATERMARK_KEYS).empty?
        raise Error, "brand #{brand}: watermark must be a map of #{WATERMARK_KEYS.join(', ')}, got #{given.inspect[0, 80]}"
      end
      mark = WATERMARK.merge(given)
      hex(mark["fill"])
      opacity = mark["opacity"]
      unless (opacity.is_a?(Integer) || opacity.is_a?(Float)) && opacity.positive? && opacity <= 1
        raise Error, "brand #{brand}: watermark opacity must be a number greater than 0 and at most 1, got #{opacity.inspect}"
      end
      mark
    end

    # [each icon layer role's fill, [first word's fill, second word's fill]]. A watermark has one fill for everything.
    def fills(tone, text)
      return [Hash.new(@watermark["fill"]), [@watermark["fill"]] * 2] if tone == :watermark

      baked = @style.fetch("tones").fetch(tone.to_s)
      [baked.fetch("icon"), word_colours(text, baked)]
    end

    def drawing(box, tone, icon_fills, colours)
      icon_markup(@icons.fetch(tone), icon_fills) + box.letters.map { |l| letter_markup(l, box.baseline, box.cap, colours[l[:word]]) }.join
    end

    # A watermark sits inside ONE translucent group: opacity on each path would compound where layers overlap.
    def toned(tone, markup)
      tone == :watermark ? %(<g opacity="#{format('%g', @watermark['opacity'])}">#{markup}</g>) : markup
    end

    def space = @lettering ? @lettering.fetch("space") : glyph(" ", SPACE_WEIGHT)["adv"]

    # A brand's own traced lettering (style `lettering:`), or nil when it is set in Montserrat.
    def own_lettering(letterings)
      key = @style["lettering"] or return
      lettering = letterings[key.to_s] or raise Error, "brand #{brand}: no lettering #{key.inspect} in the lettering data"
      raise Error, "brand #{brand}: a lettering source has one weight, so highlight must be colour, not weight" if by_weight?
      raise Error, "brand #{brand}: tracking is in em, which a lettering source does not have" if @style["tracking"]

      lettering
    end

    # The style's `tracking` is in em; the letters are in cap heights.
    def tracking_in_cap_heights
      em = @style["tracking"] or return 0.0
      raise Error, "brand #{brand}: tracking must be a number of em, got #{em.inspect}" unless em.is_a?(Numeric)

      em / weight_set(@style.fetch("heavy")).fetch("cap_height_em")
    end

    def word_weights(text)
      return [nil, nil] if @lettering

      heavy = @style.fetch("heavy")
      return [heavy, heavy] if text == :homogeneous || !by_weight?

      light = @style.fetch("light")
      text == :first ? [heavy, light] : [light, heavy]
    end

    # [first word's fill, second word's fill]
    def word_colours(text, fills)
      base = fills.fetch("text")
      return [base, base] if text == :homogeneous

      lead, other = by_weight? ? [base, fills.fetch("quiet", base)] : [fills.fetch("accent"), base]
      text == :first ? [lead, other] : [other, lead]
    end

    def letters(word, weight)
      found = @lettering ? traced(word) : word.each_char.map { |char| glyph(char, weight) }
      found.each { |letter| check_path(letter["d"], @fill_rule, "a letter of #{word.inspect}") }
    end

    def traced(word)
      words = @lettering.fetch("words")
      words[word] or raise Error, "brand #{brand}: no word #{word.inspect} in the #{@style['lettering']} lettering (it has #{words.keys.join(', ')})"
    end

    def weight_set(weight)
      self.class.glyphs[weight.to_s] or raise Error, "brand #{brand}: no Montserrat weight #{weight} in the glyph data"
    end

    def glyph(char, weight)
      weight_set(weight).fetch("glyphs")[char] or raise Error, "brand #{brand}: no glyph for #{char.inspect} at weight #{weight} in the glyph data"
    end

    def checked_icon(key, icons)
      icon = icons[key.to_s] or raise Error, "brand #{brand}: no icon #{key.inspect} in the icon data"
      transform = icon["transform"]
      unless transform.nil? || (transform.is_a?(String) && TRANSFORM.match?(transform))
        raise Error, "brand #{brand}: icon #{key} has a transform that is not a list of translate, scale, rotate or matrix calls: #{transform.inspect[0, 80]}"
      end
      icon.fetch("layers").each { |layer| check_path(layer["d"], layer["fill_rule"], "icon #{key} layer #{layer['role'].inspect}") }
      icon
    end

    def check_path(d, fill_rule, where)
      raise Error, "brand #{brand}: #{where} has a path that is not SVG path data: #{d.inspect[0, 80]}" unless d.is_a?(String) && PATH.match?(d)
      raise Error, "brand #{brand}: #{where} has fill rule #{fill_rule.inspect}: expected #{FILL_RULES.join(' or ')}" unless FILL_RULES.include?(fill_rule)
    end

    # Sets a word with its first letter's INK starting at x_ink. Returns the placed letters and the right ink edge.
    # `tracking` (in cap heights) is the brand's own unless the caller computes one.
    def place(word, cap, x_ink, index, tracking = @tracking)
      x = x_ink - word[0]["l"] * cap
      right = x_ink
      placed = word.map do |g|
        letter = { x:, d: g["d"], word: index }
        right = x + g["r"] * cap
        x += (g["adv"] + tracking) * cap   # after `right`: the ink edge takes no trailing tracking step
        letter
      end
      [placed, right]
    end

    def letter_markup(letter, baseline, cap, fill)
      return "" if letter[:d].empty?

      %(<path transform="translate(#{f(letter[:x])},#{f(baseline)}) scale(#{f(cap, 4)})" d="#{letter[:d]}" fill="#{hex(fill)}" fill-rule="#{letter.fetch(:fill_rule, @fill_rule)}"/>)
    end

    def icon_markup(icon, fills, height = H)
      paths = icon.fetch("layers").map do |layer|
        fill = fills[layer["role"]] or raise Error, "brand #{brand}: no fill for icon layer #{layer['role'].inspect}"
        %(<path d="#{layer['d']}" fill="#{hex(fill)}" fill-rule="#{layer['fill_rule']}"/>)
      end.join
      paths = %(<g transform="#{icon['transform']}">#{paths}</g>) if icon["transform"]
      %(<g transform="scale(#{f(height.to_f / icon.fetch('h'), 5)})">#{paths}</g>)
    end

    # The ruler, as the rule-of-thirds reel draws it: a copy of the name, one row tall, in every row the real name does
    # not fill. Rule of 3: the copies above and below the name make three. Rule of 4: four copies at half the name's
    # size, two of them behind it. Each copy starts where the name's ink does.
    def ghost_markup(box, fill)
      scale = box.row / box.cap
      (1..box.count).filter_map do |row|
        next if scale == 1 && (row * box.row - box.baseline).abs < 1e-6

        box.letters.map { |l| letter_markup(l.merge(x: box.name_left + (l[:x] - box.name_left) * scale), row * box.row, box.row, fill) }.join
      end.join
    end

    # The construction drawing: row edges, the icon's right edge, the name's left ink edge, and row numbers.
    def guide_markup(box)
      rows = (0..box.count).map { |i| guide_line(-20, i * box.row, box.width + 20, i * box.row) }
      edges = [box.icon_width, box.name_left].map { |x| guide_line(x, -20, x, H + 20) }
      numbers = (0...box.count).map { |i| guide_label(box.width + 30, (i + 0.5) * box.row + 12, i + 1) }
      (rows + edges + numbers).join
    end

    def guide_line(x1, y1, x2, y2)
      %(<line x1="#{f(x1)}" y1="#{f(y1)}" x2="#{f(x2)}" y2="#{f(y2)}" stroke="#{GUIDE}" stroke-width="#{self.class::GUIDE_STROKE}"/>)
    end

    # `words` is the library's own (a row number, a band's size): never a name or a style value. `attributes` likewise.
    def guide_label(x, y, words, attributes = "")
      %(<text x="#{f(x)}" y="#{f(y)}"#{attributes} font-family="Helvetica,Arial,sans-serif" font-size="#{self.class::GUIDE_FONT}" font-weight="700" fill="#{GUIDE}">#{words}</text>)
    end

    def document(body, width, height = H, left: 0, top: 0, right: 0, bottom: 0)
      w = f(width + left + right)
      h = f(height + top + bottom)
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{-left} #{-top} #{w} #{h}" width="#{w}" height="#{h}">#{body}</svg>\n)
    end

    def hex(colour) = HEX.match?(colour.to_s) ? colour : raise(Error, "brand #{brand}: #{colour.inspect} is not a #hex colour")
    def f(number, places = 2) = format("%.#{places}f", number)
  end
end
