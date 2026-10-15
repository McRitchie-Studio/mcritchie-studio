# frozen_string_literal: true

module Logos
  # The PNG sizes a brand page's Download card offers (task logo-download-card): per logo type, a preset list, each
  # named by what it serves, in whole pixels. Some integrations take no SVG and want an exact pixel size, so the
  # card rasterises the logo's own SVG in the browser (app/javascript/logo_download.js) at one of these.
  #
  # Two kinds of preset:
  #   - SQUARE (the icon): the canvas is N × N and the icon is fitted inside it, centred, with transparent padding
  #     (`fit: "contain"`), because a favicon or an app icon must be square and the icons are not (Studio's is about
  #     662 × 538).
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
      [180, "Apple touch icon"], [192, "Android and PWA icon"], [512, "PWA splash and store listings"],
      [1024, "App Store master"]
    ].freeze

    WIDTH_PRESETS = {
      navbar: [[400, "Email signature"], [800, "Website header, retina"], [1200, "Open Graph and social cards"],
               [2400, "Print and slides"]],
      stacked: [[400, "Profile and directory listings"], [800, "Documents and slides"], [1200, "Social posts"],
                [2400, "Print"]]
    }.freeze

    SCALES = [1, 2, 4].freeze

    # The solid background a PNG may take instead of transparency, per tone: white behind the light logo, black behind
    # the dark and the watermark (both drawn for a dark ground). The card's colour picker starts on it.
    BACKGROUNDS = { light: "#FFFFFF", dark: "#000000", watermark: "#000000" }.freeze

    # The preset each type's card starts on.
    DEFAULTS = { icon: "512", navbar: "w800", stacked: "w800" }.freeze

    module_function

    # The drawing's own width and height, from its root viewBox: [662.45, 538.14].
    def natural(svg)
      box = svg[/<svg\b[^>]*\bviewBox="([^"]+)"/, 1] or raise ArgumentError, "an SVG with no viewBox"
      _, _, width, height = box.split.map(&:to_f)
      raise ArgumentError, "an SVG with an empty viewBox" unless width.positive? && height.positive?

      [width, height]
    end

    # Whole pixels for a drawing of `width` × `height` with one side set: `axis` :width or :height to `value`.
    def fit(axis, value, width, height)
      value = Integer(value)
      raise ArgumentError, "a PNG side is 1 to #{MAX_SIDE} px, not #{value}" unless value.between?(1, MAX_SIDE)

      other = axis == :width ? round(value * height / width) : round(value * width / height)
      axis == :width ? [value, other] : [other, value]
    end

    # Halves up, never below 1 (Math.round in logo_download.js rounds the same way for the positive sizes here).
    def round(value) = [(value + 0.5).floor, 1].max

    # The presets for a logo of `type` whose drawing is `width` × `height`: each a hash of key, label (the size), use
    # (what it serves), width, height and fit. A preset whose long side would pass MAX_SIDE is left out.
    def presets(type, width, height)
      list = if type.to_sym == :icon
               ICON_PRESETS.map { |side, use| preset(side.to_s, side, side, use, "contain") }
             else
               widths = WIDTH_PRESETS.fetch(type.to_sym).map do |px, use|
                 w, h = fit(:width, px, width, height)
                 preset("w#{px}", w, h, use, "fill")
               end
               scales = SCALES.filter_map do |scale|
                 target = SCREEN_HEIGHTS.fetch(type.to_sym) * scale
                 w, h = fit(:height, target, width, height)
                 preset("#{scale}x", w, h, "#{scale}x the size shown here (#{target} px tall)", "fill")
               end
               widths + scales
             end
      list.select { |entry| [entry[:width], entry[:height]].max <= MAX_SIDE }
    end

    def preset(key, width, height, use, fit) = { key:, label: "#{width} × #{height}", use:, width:, height:, fit: }
  end
end
