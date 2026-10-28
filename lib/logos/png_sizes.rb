# frozen_string_literal: true

module Logos
  # The PNG sizes a brand page's Download card offers (task logo-download-card): per logo type, a preset list, each
  # named by what it serves, in whole pixels. Some integrations take no SVG and want an exact pixel size, so the
  # card rasterises the logo's own SVG in the browser (app/javascript/logo_download.js) at one of these.
  #
  # The kinds of preset:
  #   - SIDE (the icon): N is the icon's LONG side and the other follows its true ink aspect (an icon's box is its
  #     ink), so Studio's chest (about 662 × 538) at 512 is 512 × 416 with no padding (Alex McRitchie, 2026-10-14 22:35: "the
  #     default should be to download the true aspect ratio"). An icon within SQUARE_TOLERANCE of 1:1 (Industries,
  #     215 × 217) is square already: N × N, fitted inside (`fit: "contain"`). The card has no 1:1 toggle (task
  #     brand-page-split-layout): its Custom size, N × N without Keep aspect ratio, pads an icon to a square.
  #   - WIDTH or SCALE (the Navbar and Stacked Logos): the canvas keeps the drawing's aspect (`fit: "fill"`). A width
  #     preset sets the width and the height follows; a scale preset is 1x, 2x or 4x the height the brand page shows
  #     the logo at (SCREEN_HEIGHTS), the width following.
  #
  # The other side is always rounded to the nearest whole pixel (halves up), and never below 1. A custom size goes
  # through the same rounding (#fit here, pngSize in logo_download.js), so a preset and the same custom width agree.
  module PngSizes
    # The longest side a PNG may have: a browser canvas refuses much past this, and nothing the card serves needs more.
    MAX_SIDE = 8192

    # The height the brand page draws each wide type at (LogosHelper::LOGO_HEIGHTS): the 1x of a scale preset.
    SCREEN_HEIGHTS = { navbar: 60, stacked: 240 }.freeze

    ICON_PRESETS = [
      [16, "Favicon"], [32, "Favicon, retina"], [48, "Windows site icon"], [64, "Small app icon"],
      [180, "Apple touch icon"], [192, "Android and PWA icon"], [256, "App favicon (as script/brand_png.cjs installs it)"],
      [512, "PWA splash and store listings"],
      [1024, "App Store master"]
    ].freeze

    WIDTH_PRESETS = {
      navbar: [[200, "Footers and small badges"], [400, "Email signature"], [800, "Website header, retina"],
               [1200, "Banners and web heroes"], [2400, "Print and slides"], [4800, "Large print and signage"]],
      stacked: [[200, "Avatars and thumbnails"], [400, "Profile and directory listings"], [800, "Documents and slides"],
                [1200, "Social posts"], [2400, "Print"], [4800, "Large print and signage"]]
    }.freeze

    SCALES = [1, 2, 4].freeze

    # How far from 1:1 an icon may be and still count as square (Industries is 215 × 217, under 1% off).
    SQUARE_TOLERANCE = 0.01

    # The solid background a PNG may take instead of transparency, per tone: white behind the light logo, black behind
    # the dark and the watermark (both drawn for a dark ground). The /logos table's JPEG links fill with it; the brand
    # page's Download card has no Background and stays transparent.
    BACKGROUNDS = { light: "#FFFFFF", dark: "#000000", watermark: "#000000" }.freeze

    # The preset each type's card starts on.
    DEFAULTS = { icon: "512", navbar: "w800", stacked: "w800" }.freeze

    # The six sizes the brand page's Download card offers as buttons, beside Custom (task brand-page-split-layout,
    # Alex McRitchie 2026-10-27: "standard sizes, 3 best guess", then "add 3 more sizes"), smallest to largest. Each
    # type's default is one of them.
    STANDARD = { icon: %w[32 64 180 256 512 1024], navbar: %w[w200 w400 w800 w1200 w2400 w4800],
                 stacked: %w[w200 w400 w800 w1200 w2400 w4800] }.freeze

    module_function

    # The size a one-click download from the /logos table is drawn at (task logos-index-download-formats): the type's
    # DEFAULTS preset as the browser reads it (app/javascript/logo_download.js, rasterSize), "width:800" (the width set,
    # the height following) or "long:512" (the icon's long side, the other following; 512 × 512 for a square icon).
    # The table sends no SVG to the page, so the browser reads the drawing's own size from the file it fetches.
    def default_size(type)
      key = DEFAULTS.fetch(type.to_sym)
      key.start_with?("w") ? "width:#{key.delete_prefix('w')}" : "long:#{key}"
    end

    # The drawing's own width and height, from its root viewBox: [662.45, 538.14].
    def natural(svg)
      box = svg[/<svg\b[^>]*\bviewBox="([^"]+)"/, 1] or raise ArgumentError, "an SVG with no viewBox"
      _, _, width, height = box.split.map(&:to_f)
      raise ArgumentError, "an SVG with an empty viewBox" unless width.positive? && height.positive?

      [width, height]
    end

    # Whole pixels for a drawing of `width` × `height` with one side set: `axis` :width or :height to `value`. Refused
    # (ArgumentError) when either side would be under 1 or past MAX_SIDE, or `value` is not a whole number.
    def fit(axis, value, width, height)
      value = Integer(value)
      raise ArgumentError, "a PNG side is 1 to #{MAX_SIDE} px, not #{value}" unless value.between?(1, MAX_SIDE)

      other = axis == :width ? round(value * height / width) : round(value * width / height)
      raise ArgumentError, "the other side would be #{other} px, past #{MAX_SIDE}" if other > MAX_SIDE

      axis == :width ? [value, other] : [other, value]
    end

    # True when a drawing of `width` × `height` is 1:1 within SQUARE_TOLERANCE.
    def square?(width, height) = ((width.to_f / height) - 1).abs <= SQUARE_TOLERANCE

    # Halves up, never below 1 (Math.round in logo_download.js rounds the same way for the positive sizes here).
    def round(value) = [(value + 0.5).floor, 1].max

    # The presets for a logo of `type` whose drawing is `width` × `height`: each a hash of key, label (the size), use
    # (what it serves), width, height and fit. A preset whose long side would pass MAX_SIDE is left out.
    def presets(type, width, height)
      list = if type.to_sym == :icon
               ICON_PRESETS.filter_map do |side, use|
                 next preset(side.to_s, side, side, use, "contain") if square?(width, height)

                 fitted(width >= height ? :width : :height, side, width, height) { |w, h| preset(side.to_s, w, h, use, "fill") }
               end
             else
               widths = WIDTH_PRESETS.fetch(type.to_sym).filter_map do |px, use|
                 fitted(:width, px, width, height) { |w, h| preset("w#{px}", w, h, use, "fill") }
               end
               scales = SCALES.filter_map do |scale|
                 target = SCREEN_HEIGHTS.fetch(type.to_sym) * scale
                 fitted(:height, target, width, height) { |w, h| preset("#{scale}x", w, h, "#{scale}x the size shown here (#{target} px tall)", "fill") }
               end
               widths + scales
             end
      list.select { |entry| [entry[:width], entry[:height]].max <= MAX_SIDE }
    end

    # The type's STANDARD presets, in that order, from the full list.
    def standard(type, width, height)
      list = presets(type, width, height)
      STANDARD.fetch(type.to_sym).filter_map { |key| list.find { |entry| entry[:key] == key } }
    end

    # The block's preset for a fitted size, or nil when the size passes MAX_SIDE.
    def fitted(axis, value, width, height)
      yield(*fit(axis, value, width, height))
    rescue ArgumentError
      nil
    end

    def preset(key, width, height, use, fit) = { key:, label: "#{width} × #{height}", use:, width:, height:, fit: }
  end
end
