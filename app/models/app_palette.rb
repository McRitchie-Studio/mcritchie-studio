# The colour scheme a client picks at /build (.agents/epics/build-with-xan-design.md,
# "Colors"): four hex colours for light mode and four for dark.
#
#   { "light" => { "primary" => "#4F46E5", "accent" => "#F59E0B",
#                  "surface" => "#FFFFFF", "text" => "#111827" },
#     "dark"  => { … the same four keys … } }
#
# The one reader both the CTO (AppCto#palette) and the app's launch theme
# (App#theme_colors) go through, so a palette that passes here is one the chat
# header and the new app can both wear: every key present, every value a
# #RRGGBB hex, and text readable on surface (WCAG AA, 4.5:1) in both modes.
module AppPalette
  SIDES = %w[light dark].freeze
  KEYS = %w[primary accent surface text].freeze
  HEX = /\A#\h{6}\z/
  MIN_CONTRAST = 4.5

  module_function

  # The palette with string keys and upcased hex, only the known sides and keys.
  def normalize(palette)
    palette = palette.to_h.transform_keys(&:to_s) if palette.respond_to?(:to_h)
    return {} unless palette.is_a?(Hash)

    SIDES.to_h do |side|
      colors = palette[side].respond_to?(:to_h) ? palette[side].to_h.transform_keys(&:to_s) : {}
      [ side, KEYS.to_h { |key| [ key, colors[key].to_s.strip.upcase.presence ] }.compact ]
    end
  end

  def side(palette, name) = normalize(palette).fetch(name.to_s, {})

  # Why PALETTE cannot be a theme; empty when it can.
  def errors(palette)
    normal = normalize(palette)
    SIDES.flat_map do |side|
      colors = normal.fetch(side, {})
      missing = KEYS.reject { |key| colors[key].to_s.match?(HEX) }
      next [ "#{side} needs #{missing.join(', ')} as #RRGGBB" ] if missing.any?

      ratio = contrast(colors["text"], colors["surface"])
      ratio < MIN_CONTRAST ? [ "#{side} text on surface is #{ratio.round(2)}:1, under #{MIN_CONTRAST}:1" ] : []
    end
  end

  def valid?(palette) = errors(palette).empty?

  # WCAG 2.x contrast ratio of two #RRGGBB colours.
  def contrast(one, two)
    a, b = [ luminance(one), luminance(two) ].sort.reverse
    (a + 0.05) / (b + 0.05)
  end

  def luminance(hex)
    channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
    r, g, b = channels.map { |c| c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  # "79 70 229": the space-separated RGB a CSS custom property takes, so a view
  # can write `rgb(var(--cto-primary) / 0.15)`.
  def rgb_triplet(hex)
    return nil unless hex.to_s.match?(HEX)

    hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }.join(" ")
  end
end
