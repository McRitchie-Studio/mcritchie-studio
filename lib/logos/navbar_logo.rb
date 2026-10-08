# frozen_string_literal: true

require "json"
require "yaml"

module Logos
  # Draws a brand's Navbar Logo (the main logo) from an ICON and a two-word
  # NAME as a pure-vector SVG: the icon, then the name on one line, set from
  # pre-extracted Montserrat outlines. No font library, no raster, no database.
  #
  #   Logos::NavbarLogo.new("industries").svg(rule: 4, text: :second, tone: :dark)
  #
  # The icon is H units tall. Rule of 3: the capitals are one of three rows.
  # Rule of 4: the capitals fill the middle two of four rows. Either way the
  # name is centred on the icon. Rules and data: docs/topics/logos.md.
  class NavbarLogo
    class Error < ArgumentError; end

    H = 300.0
    RULES = { 3 => 1, 4 => 2 }.freeze          # rows the icon spans => rows the capitals span
    TEXTS = %i[homogeneous first second].freeze
    TONES = %i[light dark].freeze
    HIGHLIGHTS = %w[weight colour].freeze
    SPACE_WEIGHT = 300                         # the word space is this weight's " " advance
    GUIDE = "#D4189F"
    GUIDE_PAD = { left: 40, top: 40, right: 80, bottom: 40 }.freeze
    HEX = /\A#(?:\h{3}|\h{6})\z/
    ROOT = File.expand_path("../..", __dir__)

    Layout = Struct.new(:count, :row, :cap, :baseline, :icon_width, :gap, :name_left, :letters, :width, keyword_init: true)

    class << self
      def styles = @styles ||= YAML.safe_load_file(File.join(ROOT, "config/logo_brands.yml")).freeze
      def icons = @icons ||= JSON.parse(File.read(File.join(__dir__, "data/brand_icons.json"))).freeze
      def glyphs = @glyphs ||= JSON.parse(File.read(File.join(__dir__, "data/montserrat_glyphs.json"))).fetch("weights").freeze
      def brands = styles.keys
    end

    attr_reader :brand, :words

    # `styles:` and `icons:` default to the shipped data; pass your own to draw a brand that is not in it.
    def initialize(brand, styles: self.class.styles, icons: self.class.icons)
      @brand = brand.to_s
      @style = styles[@brand] or raise Error, "unknown brand #{@brand.inspect}: expected one of #{styles.keys.join(', ')}"
      @icon = icons[@style["icon"].to_s] or raise Error, "brand #{@brand}: no icon #{@style['icon'].inspect} in the icon data"
      @words = @style["name"].to_s.split
      raise Error, "brand #{@brand}: the name must be exactly two words, got #{@words.size} (#{@style['name'].inspect})" unless @words.size == 2
      raise Error, "brand #{@brand}: highlight must be one of #{HIGHLIGHTS.join(', ')}, got #{@style['highlight'].inspect}" unless HIGHLIGHTS.include?(@style["highlight"])
      word_weights(:first).uniq.each { |weight| @words.each { |word| letters(word, weight) } }   # a missing character fails here, not at draw time
      space
    end

    # The geometry alone, in design units (the icon is H tall, x = 0 is its left edge).
    def layout(rule: 3, text: :homogeneous)
      cap_rows = RULES[rule] or raise Error, "unknown rule #{rule.inspect}: expected #{RULES.keys.join(' or ')}"
      raise Error, "unknown text #{text.inspect}: expected one of #{TEXTS.join(', ')}" unless TEXTS.include?(text)

      row = H / rule
      cap = cap_rows * row
      first, second = @words.zip(word_weights(text)).map { |word, weight| letters(word, weight) }
      icon_width = @icon.fetch("w") * H / @icon.fetch("h")
      gap = (first[0]["r"] - first[0]["l"]) * cap / 2                    # half the first letter's ink
      placed1, right1 = place(first, cap, icon_width + gap, 0)
      placed2, right2 = place(second, cap, right1 + space * cap, 1)
      Layout.new(count: rule, row:, cap:, baseline: (H + cap) / 2, icon_width:, gap:, name_left: icon_width + gap,
                 letters: placed1 + placed2, width: right2)
    end

    def svg(rule: 3, text: :homogeneous, tone: :light, guides: false)
      raise Error, "unknown tone #{tone.inspect}: expected one of #{TONES.join(', ')}" unless TONES.include?(tone)

      box = layout(rule:, text:)
      fills = @style.fetch("tones").fetch(tone.to_s)
      colours = word_colours(text, fills)
      body = icon_markup(fills.fetch("icon")) + box.letters.map { |l| letter_markup(l, box, colours[l[:word]]) }.join
      guides ? document(body + guide_markup(box), box.width, **GUIDE_PAD) : document(body, box.width)
    end

    # Every example for the brand: 2 rules x 3 texts x 2 tones, each with its guide drawing.
    def examples
      RULES.keys.product(TEXTS, TONES, [false, true]).map do |rule, text, tone, guides|
        key = [brand, "rule#{rule}", text, tone, ("guides" if guides)].compact.join("-")
        { key:, rule:, text:, tone:, guides:, svg: svg(rule:, text:, tone:, guides:) }
      end
    end

    private

    def by_weight? = @style["highlight"] == "weight"
    def space = glyph(" ", SPACE_WEIGHT)["adv"]

    def word_weights(text)
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

    def letters(word, weight) = word.each_char.map { |char| glyph(char, weight) }

    def glyph(char, weight)
      set = self.class.glyphs[weight.to_s] or raise Error, "brand #{brand}: no Montserrat weight #{weight} in the glyph data"
      set.fetch("glyphs")[char] or raise Error, "brand #{brand}: no glyph for #{char.inspect} at weight #{weight} in the glyph data"
    end

    # Sets a word with its first letter's INK starting at x_ink. Returns the placed letters and the right ink edge.
    def place(word, cap, x_ink, index)
      x = x_ink - word[0]["l"] * cap
      right = x_ink
      placed = word.map do |g|
        letter = { x:, d: g["d"], word: index }
        right = x + g["r"] * cap
        x += g["adv"] * cap
        letter
      end
      [placed, right]
    end

    def letter_markup(letter, box, fill)
      return "" if letter[:d].empty?

      # Font contours overlap, so letters fill nonzero: evenodd would punch holes in them.
      %(<path transform="translate(#{f(letter[:x])},#{f(box.baseline)}) scale(#{f(box.cap, 4)})" d="#{letter[:d]}" fill="#{hex(fill)}" fill-rule="nonzero"/>)
    end

    def icon_markup(fills)
      paths = @icon.fetch("layers").map do |layer|
        fill = fills[layer["role"]] or raise Error, "brand #{brand}: no fill for icon layer #{layer['role'].inspect}"
        %(<path d="#{layer['d']}" fill="#{hex(fill)}" fill-rule="#{layer['fill_rule']}"/>)
      end.join
      paths = %(<g transform="#{@icon['transform']}">#{paths}</g>) if @icon["transform"]
      %(<g transform="scale(#{f(H / @icon.fetch('h'), 5)})">#{paths}</g>)
    end

    # The construction drawing: row edges, the icon's right edge, the name's left ink edge, and row numbers.
    def guide_markup(box)
      line = ->(x1, y1, x2, y2) { %(<line x1="#{f(x1)}" y1="#{f(y1)}" x2="#{f(x2)}" y2="#{f(y2)}" stroke="#{GUIDE}" stroke-width="1.5"/>) }
      rows = (0..box.count).map { |i| line.(-20, i * box.row, box.width + 20, i * box.row) }
      edges = [box.icon_width, box.name_left].map { |x| line.(x, -20, x, H + 20) }
      numbers = (0...box.count).map do |i|
        %(<text x="#{f(box.width + 30)}" y="#{f((i + 0.5) * box.row + 12)}" font-family="Helvetica,Arial,sans-serif" font-size="32" font-weight="700" fill="#{GUIDE}">#{i + 1}</text>)
      end
      (rows + edges + numbers).join
    end

    def document(body, width, left: 0, top: 0, right: 0, bottom: 0)
      w = f(width + left + right)
      h = f(H + top + bottom)
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{-left} #{-top} #{w} #{h}" width="#{w}" height="#{h}">#{body}</svg>\n)
    end

    def hex(colour) = HEX.match?(colour.to_s) ? colour : raise(Error, "brand #{brand}: #{colour.inspect} is not a #hex colour")
    def f(number, places = 2) = format("%.#{places}f", number)
  end
end
