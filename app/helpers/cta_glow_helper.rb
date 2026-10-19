# The CTA glow primitive's colours (app/assets/tailwind/cta_glow.css): the
# style a `cta-glow` wrapper carries, --glow-a, --glow-b and --glow-c, from a
# /build palette ({ name, light, dark }, each mode { primary, accent, surface,
# text }). The light primary, the light accent, and the dark primary as the
# third, so the glow reads in either site theme. Every value goes through
# BuildIntake::Contrast.normalize, so only a #rrggbb ever reaches the style
# attribute. No palette (the idea card, before a theme is chosen) or a broken
# one gives nil: the wrapper then falls back to the studio's own primary and
# accent.
module CtaGlowHelper
  GLOW_ROLES = [ %w[light primary], %w[light accent], %w[dark primary] ].freeze

  # { "--glow-a" => "#15803d", ... } or nil.
  def cta_glow_vars(palette)
    return nil unless palette.is_a?(Hash) && palette.present?

    colors = GLOW_ROLES.map { |mode, role| BuildIntake::Contrast.normalize(palette.dig(mode, role)) }
    return nil if colors.any?(&:nil?)

    %w[--glow-a --glow-b --glow-c].zip(colors).to_h
  end

  def cta_glow_style(palette)
    cta_glow_vars(palette)&.map { |k, v| "#{k}: #{v}" }&.join("; ")
  end
end
