# frozen_string_literal: true

require "digest"
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
  # Rule of 4: the capitals fill the middle two of four rows. Rule of 6: the
  # capitals fill the middle four of six rows. Every way, the name is centred
  # on the icon. The gap after the icon and the gap between
  # the words are equal: each is half a cap height. Rules and data:
  # docs/topics/logos.md.
  #
  # The operator's EDITS (task logo-part-editor) recolour or reweigh a part and
  # never move the geometry, except that a heavier word is wider and the layout
  # reflows by the same rules:
  #
  #   logo.svg(rule: 4, edits: { first: { colour: "#635BB2", weight: 600 }, icon: { colour: "#8E82FE" } })
  #
  # A colour must be one of the brand's palette hexes; a weight one of
  # EDIT_WEIGHTS, and never for a name set in traced lettering. No edits draws
  # exactly what it drew before, byte for byte.
  #
  # Every logo has a COLOURING (task logo-original-and-alt): `colouring: :alt`
  # (the default) is the style's `tones`, one solid colour per part, exactly as
  # drawn before; `colouring: :original` is the brand's true art, from the
  # style's `original:` (per tone: its own icon, fills and name colours). A
  # brand whose logo is solid colour (Studio) has no original. The watermark is
  # always the single-colour version, so colouring does not apply to it, and
  # edits apply to Alt only: an original is the brand's own art.
  #
  #   logo.svg(rule: 3, tone: :dark, colouring: :original)
  #
  # THE ICON IS AN ATOMIC UNIT (task kit-icon-atomic-unit): a logo's icon may be
  # drawn in a colouring of its own, `icon_colouring:`, while `colouring:`
  # governs the words. Left out, the icon takes the words' colouring, which is
  # every drawing as it was. The icon colour edit follows the icon's colouring
  # (Alt only); the word edits follow the words'.
  #
  #   logo.svg(rule: 4, tone: :light, colouring: :alt, icon_colouring: :original)
  class NavbarLogo
    class Error < ArgumentError; end

    H = 300.0
    RULES = { 3 => 1, 4 => 2, 6 => 4 }.freeze  # rows the icon spans => rows the capitals span
    TEXTS = %i[homogeneous first second].freeze
    TONES = %i[light dark watermark].freeze
    BAKED = %i[light dark].freeze               # the tones whose fills a style lists; `examples` draws these
    WATERMARK = { "fill" => "#FFFFFF", "opacity" => 0.6 }.freeze
    WATERMARK_KEYS = %w[fill opacity icon_key].freeze
    HIGHLIGHTS = %w[weight colour].freeze
    COLOURINGS = %i[original alt].freeze      # the brand's own art, or one solid colour per part (the style's `tones`)
    ORIGINAL_KEYS = %w[icon_key text quiet accent icon].freeze   # what an original's tone may set
    # An original's fill may name a GRADIENT its own icon data declares in `defs` (the Industries kit's steel): a
    # linearGradient with numeric coordinates and #hex stops, nothing else. The id is the data's own; the drawing
    # writes it namespaced by the icon and by a digest of the drawing (#with_defs), so two logos on a page never share
    # one. Every other fill stays a #hex.
    DEF_ID = /\A[a-z][a-z0-9_]*\z/
    URL = /\Aurl\(#([a-z][a-z0-9_]*)\)\z/
    DEF_TOKEN = "__LOGO_DEF__"                 # stands for the namespace in markup until the drawing is whole
    # A checked reference to one of an original's gradients (#gradient_ref): never a string, so no style value can
    # pose as one.
    GradientRef = Data.define(:id) do
      def to_s = "url(##{DEF_TOKEN}#{id})"
    end
    GRADIENT_KEYS = %w[id units x1 y1 x2 y2 stops].freeze
    GRADIENT_UNITS = %w[userSpaceOnUse objectBoundingBox].freeze
    STOP_KEYS = %w[colour offset].freeze
    PAINTS = %w[fill stroke].freeze           # a layer is filled (the default), or stroked (the kit's ruler ticks)
    # What the operator may edit on each part (task logo-part-editor). The tagline is the Stacked Logo's; the icon's
    # colour recolours one layer (#icon_role). Geometry is never an edit.
    PARTS = { icon: %i[colour], first: %i[colour weight], ending: %i[colour weight], tagline: %i[colour weight visible] }.freeze
    EDIT_WEIGHTS = [300, 400, 500, 600, 700, 800].freeze
    NO_EDITS = {}.freeze
    GAP_CAPS = 0.5                             # the icon gap and the word gap, ink to ink, in cap heights: equal by rule
    GUIDE = "#D4189F"
    GUIDE_PAD = { left: 40, top: 70, right: 80, bottom: 40 }.freeze   # `top` holds the gap brackets and their labels
    GUIDE_FONT = 30                            # the guide labels' size, in design units
    # A rule's own label size where it needs a larger one: the rule of 6's capitals are twice the rule of 3's, so its
    # drawing is the widest, and its labels are larger so it still fits a 1280 px page's plate at 9 px labels.
    GUIDE_FONTS = { 6 => 40 }.freeze
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
    ICON_FILES = %w[brand_icons.json brand_icons_turf_welding.json brand_icons_turf_mono.json brand_icons_originals.json brand_icons_welding_v2.json].freeze
    ROOT = File.expand_path("../..", __dir__)

    # `gap` is both the icon gap (icon_width to name_left) and the word gap (word_left - gap to word_left).
    Layout = Struct.new(:count, :row, :cap, :baseline, :icon_width, :gap, :name_left, :word_left, :letters, :width, keyword_init: true)

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
      original_looks.each { |look| check_original_shape(look) }
      @icons.merge!(original_looks.to_h { |look| [look, checked_icon(icon_key(look), icons)] })
      @words = name_parts
      raise Error, "brand #{@brand}: highlight must be one of #{HIGHLIGHTS.join(', ')}, got #{@style['highlight'].inspect}" unless HIGHLIGHTS.include?(@style["highlight"])
      @lettering = own_lettering(letterings)
      @fill_rule = @lettering ? @lettering["fill_rule"] : "nonzero"   # font contours overlap: evenodd would punch holes in them
      @tracking = tracking_in_cap_heights
      word_weights(:first).uniq.each { |weight| @words.each { |word| letters(word, weight) } }   # a missing character fails here, not at draw time
      original_looks.each { |look| check_original(look) }
    end

    # True when the style declares the brand's ORIGINAL colouring (its true art); a solid-colour brand has none.
    def original? = !@style["original"].nil?

    # The colourings this brand draws: [:original, :alt], or [:alt] for a brand with no original.
    def colourings = original? ? COLOURINGS : %i[alt]

    # What the brand's page says about where its art came from (optional).
    def note = @style["note"]

    # The brand's palette hexes (style `palette:`), in its order: the only colours an edit may pick.
    def palette = Array(@style["palette"]).map { |swatch| swatch["hex"] }

    # True when the name is set in the brand's own traced letters, which have one weight.
    def traced? = !@lettering.nil?

    # The icon layer an icon colour edit recolours: the tone's icon's `primary` layer, or, for an icon with none (Turf
    # Monster's head: outline, body, light), its first layer. Every other layer keeps its styled fill.
    def icon_role(tone = :light)
      roles = icon_roles(tone)
      roles.include?("primary") ? "primary" : roles.first
    end

    # The tone's icon's layer roles, in drawing order: ["primary", "edge"].
    def icon_roles(tone = :light) = @icons.fetch(tone).fetch("layers").map { |layer| layer["role"] }

    # `given` checked: { part => { setting => value } } with parts and settings from PARTS, a colour from the palette
    # (any case; answered in the palette's spelling), a weight from EDIT_WEIGHTS (refused for traced lettering) and a
    # visibility of true or false. A setting that changes nothing (a visible tagline) and an empty part are dropped, so
    # equal edits are equal hashes. Anything else is an Error.
    def checked_edits(given)
      return NO_EDITS if given.nil? || given == NO_EDITS
      raise Error, "brand #{brand}: edits must be a map of parts, got #{given.inspect[0, 80]}" unless given.is_a?(Hash)

      given.each_with_object({}) do |(part, settings), out|
        takes = PARTS.fetch(part) { raise Error, "brand #{brand}: no part #{part.inspect} to edit: expected one of #{PARTS.keys.join(', ')}" }
        unless settings.is_a?(Hash) && (settings.keys - takes).empty?
          raise Error, "brand #{brand}: the #{part} takes #{takes.join(', ')}, got #{settings.inspect[0, 80]}"
        end
        raise Error, "brand #{brand}: it has no tagline to edit" if part == :tagline && @style["tagline"].nil?

        checked = settings.to_h { |setting, value| [setting, send(:"edit_#{setting}", part, value)] }.reject { |setting, value| setting == :visible && value }
        out[part] = checked.freeze if checked.any?
      end.freeze
    end

    # Why these edits cannot be drawn with these choices (a rule, or a stacked form), or nil when every text version in
    # every baked tone draws: a heavier word can be too wide to sit where the rules put it.
    def refusal(edits, **choices)
      TEXTS.product(BAKED) { |text, tone| layout(text:, tone:, edits:, **choices) }
      nil
    rescue Error => e
      e.message
    end

    # The brand's name as the gallery says it ("Commercial Welding v1"), when the style gives one (optional).
    def title = @style["title"]

    # "weight" or "colour": how one word leads the other. A watermark has one colour, so only weight shows in it.
    def highlight = @style["highlight"]

    # The geometry alone, in design units (the icon is H tall, x = 0 is its left edge).
    # `tone:` matters only to a brand whose tones name different icons.
    def layout(rule: 3, text: :homogeneous, tone: :light, edits: NO_EDITS, colouring: :alt, icon_colouring: nil)
      cap_rows = RULES[rule] or raise Error, "unknown rule #{rule.inspect}: expected one of #{RULES.keys.join(', ')}"
      check_text(text)
      row = H / rule
      cap = cap_rows * row
      first, second = @words.zip(edited_weights(text, checked_edits(edits))).map { |word, weight| letters(word, weight) }
      icon = @icons.fetch(look(tone, icon_colouring || colouring))
      icon_width = icon.fetch("w") * H / icon.fetch("h")
      gap = GAP_CAPS * cap
      placed1, right1 = place(first, cap, icon_width + gap, 0)
      placed2, right2 = place(second, cap, right1 + gap, 1)
      Layout.new(count: rule, row:, cap:, baseline: (H + cap) / 2, icon_width:, gap:, name_left: icon_width + gap, word_left: right1 + gap,
                 letters: placed1 + placed2, width: right2)
    end

    def svg(rule: 3, text: :homogeneous, tone: :light, guides: false, edits: NO_EDITS, colouring: :alt, icon_colouring: nil)
      look = look(tone, colouring)
      icon_look = look(tone, icon_colouring || colouring)
      edits = edits_in(look, edits, icon_look)
      render(layout(rule:, text:, tone:, edits:, colouring:, icon_colouring:), H, text, look, guides, edits, icon_look)
    end

    # The brand's icon alone, in its own box (`0 0 <w> <h>` of the icon data), with the tone's fills and the
    # tone's icon: the icon exactly as the Navbar Logo draws it, without the name. `edits` may carry the icon's colour
    # edit (Alt only), the kit icon's (task kit-icon-atomic-unit); any other part is refused.
    def icon_svg(tone: :light, colouring: :alt, edits: NO_EDITS)
      look = look(tone, colouring)
      edits = edits_in(look, edits)
      raise Error, "brand #{brand}: an icon takes only the icon's colour edit, not #{(edits.keys - %i[icon]).join(', ')}" if (edits.keys - %i[icon]).any?

      icon = @icons.fetch(look)
      height = icon.fetch("h")
      document(with_defs(look, toned(look, icon_markup(icon, fills(look, :homogeneous, edits).first, height))), icon.fetch("w"), height)
    end

    # The guide labels' size, in design units, on a rule's drawing (the stacked logo, which has no rule, takes none).
    def guide_font(rule = nil) = self.class::GUIDE_FONTS.fetch(rule, self.class::GUIDE_FONT)

    # The watermark's checked settings: { "fill" => "#FFFFFF", "opacity" => 0.6 }, and "icon_key" when the style names one.
    def watermark = @watermark.dup

    # Every light and dark example for the brand: 3 rules x 3 texts x 2 tones, each with its guide drawing.
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

    # What one drawing is drawn in: its LOOK, the key of its icon and fills. Alt is the tone itself (:light, :dark,
    # :watermark), so an Alt drawing reads exactly what it read before colourings; an original is :original_light or
    # :original_dark. A watermark is one colour, so colouring does not apply to it.
    def look(tone, colouring)
      check_tone(tone)
      raise Error, "unknown colouring #{colouring.inspect}: expected one of #{COLOURINGS.join(', ')}" unless COLOURINGS.include?(colouring)
      return tone if colouring == :alt || tone == :watermark
      raise Error, "brand #{brand}: it has no original colouring (its logo is solid colour), so only alt" unless original?

      :"original_#{tone}"
    end

    def original_looks = original? ? BAKED.map { |tone| :"original_#{tone}" } : []
    def original_look?(look) = look.to_s.start_with?("original_")
    def base_tone(look) = look.to_s.delete_prefix("original_").to_sym

    # A look's fills: the style's `tones` entry, or its `original:` entry for an original.
    def tone_style(look)
      original_look?(look) ? @style.fetch("original").fetch(base_tone(look).to_s) : @style.fetch("tones").fetch(look.to_s)
    end

    # An original's tone, checked when the brand is loaded: a map of ORIGINAL_KEYS with a `text` and an `icon` map
    # (shape first, before its icon is looked up), that fills every layer of its icon (and an `accent` when one word
    # leads by colour), every fill a #hex.
    def check_original_shape(look)
      given = @style["original"]
      unless given.is_a?(Hash) && given.keys.sort == BAKED.map(&:to_s).sort
        raise Error, "brand #{brand}: original must be a map of light and dark, got #{given.inspect[0, 80]}"
      end
      tone = tone_style(look)
      unless tone.is_a?(Hash) && (tone.keys - ORIGINAL_KEYS).empty? && tone["icon"].is_a?(Hash) && tone.key?("text")
        raise Error, "brand #{brand}: original #{base_tone(look)} must be a map of #{ORIGINAL_KEYS.join(', ')} with a text and an icon, got #{tone.inspect[0, 80]}"
      end
    end

    def check_original(look)
      tone = tone_style(look)
      raise Error, "brand #{brand}: original #{base_tone(look)} needs an accent, because one word leads by colour" if !by_weight? && !tone.key?("accent")

      missing = @icons.fetch(look).fetch("layers").map { |layer| layer["role"] } - tone["icon"].keys
      raise Error, "brand #{brand}: original #{base_tone(look)} has no fill for icon layer #{missing.first.inspect}" if missing.any?

      TEXTS.each { |text| fills(look, text).flatten.each { |fill| fill.is_a?(Hash) ? fill.each_value { |each| paint(each) } : paint(fill) } }
    end

    def check_text(text)
      raise Error, "unknown text #{text.inspect}: expected one of #{TEXTS.join(', ')}" unless TEXTS.include?(text)
    end

    # Checked edits for a drawing whose words are in `look` and whose icon is in `icon_look`. A watermark is one colour
    # by definition, and an original is the brand's own art, so no edit applies to either: the word edits follow the
    # words' look, the icon's colour edit the icon's.
    def edits_in(look, given, icon_look = look)
      edits = checked_edits(given)
      raise Error, "brand #{brand}: a watermark is one colour, so edits do not apply to it" if look == :watermark && edits.any?

      original = (original_look?(look) && edits.except(:icon).any?) || (original_look?(icon_look) && edits.key?(:icon))
      raise Error, "brand #{brand}: an original is the brand's own art, so edits apply to alt only" if original

      edits
    end

    def edit_colour(part, value)
      found = palette.find { |hex| hex.casecmp?(value.to_s) }
      return found if found && HEX.match?(found)

      raise Error, "brand #{brand}: the #{part}'s colour must be one of the brand's palette (#{palette.join(', ')}), got #{value.inspect[0, 40]}"
    end

    def edit_weight(part, value)
      raise Error, "brand #{brand}: the name is traced lettering, which has one weight, so the #{part}'s weight cannot change" if part != :tagline && traced?
      return value if EDIT_WEIGHTS.include?(value)

      raise Error, "brand #{brand}: the #{part}'s weight must be one of #{EDIT_WEIGHTS.join(', ')}, got #{value.inspect[0, 40]}"
    end

    def edit_visible(part, value)
      return value if [true, false].include?(value)

      raise Error, "brand #{brand}: the #{part}'s visibility must be true or false, got #{value.inspect[0, 40]}"
    end

    # A laid-out logo as a document: the drawing in its tone, or the guide drawing around it: the ghosts BEHIND the logo
    # (in the rule of 4 they cross the real name), the logo, then the lines and numbers.
    # `look` is the drawing's tone, or an original's look (#look).
    # `icon_look` is the icon's own look (task kit-icon-atomic-unit), the words' unless given.
    def render(box, height, text, look, guides, edits = NO_EDITS, icon_look = look)
      body = toned(look, drawing(box, icon_look, *fills(look, text, edits, icon_look)))
      return document(with_defs(def_look(look, icon_look), body), box.width, height) unless guides

      document(with_defs(def_look(look, icon_look), ghost_group(look, ghost_markup(box, ghost_fill(look))) + body + line_group(guide_markup(box))),
               box.width, height, **self.class::GUIDE_PAD)
    end

    # The look whose icon data declares the gradients a drawing uses. A drawing's icon and words differ in look only
    # when one is Alt, whose fills are all #hex, so at most one of the two can name a gradient: the original one.
    def def_look(look, icon_look) = original_look?(icon_look) ? icon_look : look

    # The logo's own Alt text colour in the tone (an original's ghosts too: a ghost is a solid ruler); a watermark's one fill.
    def ghost_fill(look) = look == :watermark ? @watermark["fill"] : @style.fetch("tones").fetch(base_tone(look).to_s).fetch("text")

    # The ghosts in ONE translucent group (opacity on each path would compound where copies overlap), the lines in another.
    def ghost_group(look, markup) = %(<g class="guide-ghosts" opacity="#{format('%g', GHOST_OPACITY.fetch(base_tone(look)))}">#{markup}</g>)
    def line_group(markup) = %(<g class="guide-lines">#{markup}</g>)

    def icon_key(look)
      return @watermark["icon_key"] || @style["icon"] if look == :watermark

      key = original_look?(look) ? @style.dig("original", base_tone(look).to_s, "icon_key") : @style.dig("tones", look.to_s, "icon_key")
      key || @style["icon"]
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
    # An edited colour takes the place of the styled one: the icon's on its one role, a word's in every text version.
    # The icon's fills are its own look's (`icon_look`, the words' unless given).
    def fills(look, text, edits = NO_EDITS, icon_look = look)
      return [Hash.new(@watermark["fill"]), [@watermark["fill"]] * 2] if look == :watermark

      baked = tone_style(look)
      icon = tone_style(icon_look).fetch("icon")
      icon = icon.merge(icon_role(icon_look) => edits.dig(:icon, :colour)) if edits.dig(:icon, :colour)
      icon = icon.transform_values { |fill| gradient_ref(icon_look, fill) } if original_look?(icon_look)
      colours = word_colours(text, baked).zip(%i[first ending]).map { |colour, part| edits.dig(part, :colour) || colour }
      return [icon, colours] unless original_look?(look)

      [icon, colours.map { |fill| gradient_ref(look, fill) }]
    end

    # An original's fill as markup will write it: a #hex as it is; a url(#id) naming one of its icon's own gradients
    # as that gradient's placeholder id (#with_defs). A url naming no gradient of its icon is refused.
    def gradient_ref(look, fill)
      id = fill.to_s[URL, 1] or return hex(fill)
      declared = Array(@icons.fetch(look)["defs"]).map { |gradient| gradient["id"] }
      raise Error, "brand #{brand}: original #{base_tone(look)}'s #{fill} names no gradient in icon #{icon_key(look)}'s defs" unless declared.include?(id)

      GradientRef.new(id:)
    end

    # A drawing in `look` with the gradients it uses declared first, in one <defs>, their ids namespaced by the icon
    # and by a digest of the drawing itself: two drawings on a page never share an id, and one drawing is the same
    # bytes every time. A drawing with no gradient (every Alt one) is returned as it was.
    def with_defs(look, body)
      return body unless body.include?(DEF_TOKEN)

      used = @icons.fetch(look).fetch("defs").select { |gradient| body.include?("##{DEF_TOKEN}#{gradient['id']})") }
      markup = "<defs>#{used.map { |gradient| gradient_markup(gradient) }.join}</defs>#{body}"
      markup.gsub(DEF_TOKEN, "#{icon_key(look)}-#{Digest::SHA256.hexdigest(markup)[0, 8]}-")
    end

    def gradient_markup(gradient)
      stops = gradient.fetch("stops").map { |stop| %(<stop offset="#{format('%g', stop['offset'])}" stop-color="#{hex(stop['colour'])}"/>) }.join
      coordinates = %w[x1 y1 x2 y2].map { |name| %(#{name}="#{format('%g', gradient.fetch(name))}") }.join(" ")
      %(<linearGradient id="#{DEF_TOKEN}#{gradient['id']}" gradientUnits="#{gradient['units']}" #{coordinates}>#{stops}</linearGradient>)
    end

    # `icon_look` names the icon drawn (the words' fills come in `colours`).
    def drawing(box, icon_look, icon_fills, colours)
      icon_markup(@icons.fetch(icon_look), icon_fills) + box.letters.map { |l| letter_markup(l, box.baseline, box.cap, colours[l[:word]]) }.join
    end

    # A watermark sits inside ONE translucent group: opacity on each path would compound where layers overlap.
    def toned(look, markup)
      look == :watermark ? %(<g opacity="#{format('%g', @watermark['opacity'])}">#{markup}</g>) : markup
    end

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

    # word_weights, with each word's edited weight in place of its styled one (in every text version).
    def edited_weights(text, edits)
      word_weights(text).zip(%i[first ending]).map { |weight, part| edits.dig(part, :weight) || weight }
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

    # The name's two parts: its first word, then its ending. The ending is one word, or, for a brand set in its own
    # lettering, several traced words ("WELDING LLC") that the lettering's `spaces` set apart as the brand's art does.
    def name_parts
      words = @style["name"].to_s.split
      if @style["lettering"]
        raise Error, "brand #{@brand}: the name must be a first word and an ending of one or more words, got #{words.size} (#{@style['name'].inspect})" if words.size < 2
      elsif words.size != 2
        raise Error, "brand #{@brand}: the name must be exactly two words, got #{words.size} (#{@style['name'].inspect})"
      end
      [words.first, words.drop(1).join(" ")]
    end

    # A part's traced letters: each word's, in order. Where one word ends and the next begins, the last letter's
    # advance is set so the next word's ink starts the lettering's own space after it (in cap heights, ink to ink),
    # and the letter is marked `word_end`, so tracking widens that gap twice (`place`).
    def traced(part)
      words = @lettering.fetch("words")
      runs = part.split.map do |word|
        words[word] or raise Error, "brand #{brand}: no word #{word.inspect} in the #{@style['lettering']} lettering (it has #{words.keys.join(', ')})"
      end
      runs.each_cons(2).with_index.map do |(run, following), i|
        space = traced_space(part.split[i, 2])
        run[0...-1] + [run.last.merge("adv" => run.last["r"] - following.first["l"] + space, "word_end" => true)]
      end.flatten + runs.last
    end

    def traced_space(pair)
      space = @lettering.fetch("spaces", {})[pair.join(" ")]
      return space if space.is_a?(Numeric) && space >= 0

      raise Error, "brand #{brand}: the #{@style['lettering']} lettering has no space between #{pair.join(' and ')} (a number of cap heights in `spaces`)"
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
      icon.fetch("layers").each do |layer|
        check_path(layer["d"], layer["fill_rule"], "icon #{key} layer #{layer['role'].inspect}")
        check_paint(key, layer)
      end
      check_defs(key, icon["defs"]) if icon.key?("defs")
      icon
    end

    # A layer is filled, or (paint: stroke) stroked at its stroke_width: a number greater than 0.
    def check_paint(key, layer)
      paint = layer.fetch("paint", "fill")
      where = "icon #{key} layer #{layer['role'].inspect}"
      raise Error, "brand #{brand}: #{where} has paint #{paint.inspect}: expected #{PAINTS.join(' or ')}" unless PAINTS.include?(paint)

      width = layer["stroke_width"]
      if paint == "stroke"
        raise Error, "brand #{brand}: #{where} is stroked, so it needs a stroke_width greater than 0, got #{width.inspect[0, 40]}" unless positive_number?(width)
      elsif layer.key?("stroke_width")
        raise Error, "brand #{brand}: #{where} is filled, so it takes no stroke_width"
      end
    end

    def positive_number?(value) = (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.positive?
    def finite_number?(value) = value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)

    # An icon's `defs`: linear gradients only, each { id, units, x1, y1, x2, y2, stops }, ids unique, a lower-case id,
    # finite coordinates, and two or more stops of a #hex colour at an offset from 0 to 1. The icon's own key names its
    # gradients in markup, so it must be an id too.
    def check_defs(key, defs)
      where = "icon #{key}'s defs"
      raise Error, "brand #{brand}: #{where} must be a list of linear gradients, got #{defs.inspect[0, 80]}" unless defs.is_a?(Array) && defs.any?
      raise Error, "brand #{brand}: icon key #{key.inspect} cannot name a gradient: expected lower-case letters, digits and _" unless DEF_ID.match?(key.to_s)

      defs.each do |gradient|
        unless gradient.is_a?(Hash) && gradient.keys.sort == GRADIENT_KEYS.sort
          raise Error, "brand #{brand}: #{where}: a gradient is a map of #{GRADIENT_KEYS.join(', ')}, got #{gradient.inspect[0, 80]}"
        end
        id = gradient["id"]
        raise Error, "brand #{brand}: #{where}: gradient id #{id.inspect[0, 40]} must be lower-case letters, digits and _" unless id.is_a?(String) && DEF_ID.match?(id)
        raise Error, "brand #{brand}: #{where}: gradient #{id} units must be #{GRADIENT_UNITS.join(' or ')}" unless GRADIENT_UNITS.include?(gradient["units"])
        %w[x1 y1 x2 y2].each do |name|
          raise Error, "brand #{brand}: #{where}: gradient #{id} #{name} must be a number, got #{gradient[name].inspect[0, 40]}" unless finite_number?(gradient[name])
        end
        check_stops(where, id, gradient["stops"])
      end
      raise Error, "brand #{brand}: #{where}: two gradients share an id" unless defs.map { |gradient| gradient["id"] }.uniq.size == defs.size
    end

    def check_stops(where, id, stops)
      raise Error, "brand #{brand}: #{where}: gradient #{id} needs two or more stops" unless stops.is_a?(Array) && stops.size >= 2

      stops.each do |stop|
        ok = stop.is_a?(Hash) && stop.keys.sort == STOP_KEYS && finite_number?(stop["offset"]) && stop["offset"].between?(0, 1) &&
             stop["colour"].is_a?(String) && HEX.match?(stop["colour"])
        raise Error, "brand #{brand}: #{where}: gradient #{id} has a stop that is not {offset 0 to 1, #hex colour}: #{stop.inspect[0, 80]}" unless ok
      end
    end

    def check_path(d, fill_rule, where)
      raise Error, "brand #{brand}: #{where} has a path that is not SVG path data: #{d.inspect[0, 80]}" unless d.is_a?(String) && PATH.match?(d)
      raise Error, "brand #{brand}: #{where} has fill rule #{fill_rule.inspect}: expected #{FILL_RULES.join(' or ')}" unless FILL_RULES.include?(fill_rule)
    end

    # Sets a word with its first letter's INK starting at x_ink. Returns the placed letters and the right ink edge.
    # `tracking` (in cap heights) is the brand's own unless the caller computes one. A traced ending's word gap
    # (after a `word_end` letter) takes it twice: once as every letter gap does, once more as the word space's own
    # share, so a tracked-out ending still reads as words ("WELDING LLC", never "WELDINGLLC"). Untracked, it is the
    # lettering's own space.
    def place(word, cap, x_ink, index, tracking = @tracking)
      x = x_ink - word[0]["l"] * cap
      right = x_ink
      placed = word.map do |g|
        letter = { x:, d: g["d"], word: index }
        right = x + g["r"] * cap
        x += (g["adv"] + tracking * steps(g)) * cap   # after `right`: the ink edge takes no trailing tracking step
        letter
      end
      [placed, right]
    end

    # Tracking steps after a letter: two at a traced ending's word gap, one elsewhere.
    def steps(glyph) = glyph["word_end"] ? 2 : 1

    def letter_markup(letter, baseline, cap, fill)
      return "" if letter[:d].empty?

      %(<path transform="translate(#{f(letter[:x])},#{f(baseline)}) scale(#{f(cap, 4)})" d="#{letter[:d]}" fill="#{paint(fill)}" fill-rule="#{letter.fetch(:fill_rule, @fill_rule)}"/>)
    end

    def icon_markup(icon, fills, height = H)
      paths = icon.fetch("layers").map do |layer|
        fill = fills[layer["role"]] or raise Error, "brand #{brand}: no fill for icon layer #{layer['role'].inspect}"
        if layer["paint"] == "stroke"
          %(<path d="#{layer['d']}" fill="none" stroke="#{paint(fill)}" stroke-width="#{format('%g', layer['stroke_width'])}"/>)
        else
          %(<path d="#{layer['d']}" fill="#{paint(fill)}" fill-rule="#{layer['fill_rule']}"/>)
        end
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

    # The construction drawing: row edges, the icon's right edge, the name's left ink edge, row numbers, and a bracket
    # labelled ½ over each of the two equal gaps (after the icon, between the words): each is half a cap height.
    def guide_markup(box)
      rows = (0..box.count).map { |i| guide_line(-20, i * box.row, box.width + 20, i * box.row) }
      edges = [box.icon_width, box.name_left].map { |x| guide_line(x, -20, x, H + 20) }
      font = guide_font(box.count)
      numbers = (0...box.count).map { |i| guide_label(box.width + 30, (i + 0.5) * box.row + 0.4 * font, i + 1, font:) }
      (rows + edges + numbers + [box.icon_width, box.word_left - box.gap].flat_map { |x| gap_bracket(x, box.gap, font) }).join
    end

    GAP_BRACKET_Y = -30                        # the gap brackets' bar, above the drawing's top row edge
    GAP_TICK = 10                              # their ticks, down toward the gap's two ink edges

    def gap_bracket(left, width, font)
      right = left + width
      [guide_line(left, GAP_BRACKET_Y, right, GAP_BRACKET_Y), guide_line(left, GAP_BRACKET_Y, left, GAP_BRACKET_Y + GAP_TICK),
       guide_line(right, GAP_BRACKET_Y, right, GAP_BRACKET_Y + GAP_TICK),
       guide_label(left + width / 2, GAP_BRACKET_Y - 8, "½", %( text-anchor="middle" data-gap="#{format('%g', GAP_CAPS)}"), font:)]
    end

    def guide_line(x1, y1, x2, y2)
      %(<line x1="#{f(x1)}" y1="#{f(y1)}" x2="#{f(x2)}" y2="#{f(y2)}" stroke="#{GUIDE}" stroke-width="#{self.class::GUIDE_STROKE}"/>)
    end

    # `words` is the library's own (a row number, a band's size): never a name or a style value. `attributes` likewise.
    def guide_label(x, y, words, attributes = "", font: guide_font)
      %(<text x="#{f(x)}" y="#{f(y)}"#{attributes} font-family="Helvetica,Arial,sans-serif" font-size="#{font}" font-weight="700" fill="#{GUIDE}">#{words}</text>)
    end

    def document(body, width, height = H, left: 0, top: 0, right: 0, bottom: 0)
      w = f(width + left + right)
      h = f(height + top + bottom)
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{-left} #{-top} #{w} #{h}" width="#{w}" height="#{h}">#{body}</svg>\n)
    end

    def hex(colour) = HEX.match?(colour.to_s) ? colour : raise(Error, "brand #{brand}: #{colour.inspect} is not a #hex colour")

    # A fill as markup writes it: a #hex, or an original's gradient as #gradient_ref placed it.
    def paint(fill) = fill.is_a?(GradientRef) ? fill.to_s : hex(fill)
    def f(number, places = 2) = format("%.#{places}f", number)
  end
end
