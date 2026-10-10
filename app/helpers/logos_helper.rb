# frozen_string_literal: true

# The logo gallery's view words and its three fixed plates (LogosController).
module LogosHelper
  # The plates are FIXED surfaces, never theme tokens: a logo's fills are baked
  # per tone, so the light logo needs a light plate in both hub themes and the
  # dark logo a dark one. The watermark's plate is a mid-tone gradient standing
  # in for a photograph, so the logo's transparency shows. A logo file has no
  # background of its own: the plate is the page's.
  LOGO_PLATES = {
    light: "background-color: #FFFFFF",
    dark: "background-color: #12141A",
    watermark: "background-image: linear-gradient(135deg, #3F5E8C, #4F9A94)"
  }.freeze

  def logo_plate_style(tone) = LOGO_PLATES.fetch(tone.to_sym)

  # The gallery's page params: the context and guides in force, less the defaults, with `changes` on top.
  def logo_page_params(**changes)
    { context: (@context unless @context == :light), guides: (1 if @guides) }.merge(changes).compact
  end

  # One logo as a picture that scales down inside its plate and carries its name.
  def logo_image(variant, max_height:)
    image_tag navbar_logo_path(variant.logo.brand, variant.params), alt: variant.label, loading: "lazy",
              style: "max-height: #{max_height}px", class: "block max-w-full w-auto h-auto",
              data: { test: "logo-image" }
  end

  # What a brand's name is set in, as [typeface, detail]: Montserrat and its
  # weights (heaviest first), or the brand's own traced lettering.
  def logo_brand_typeface(brand)
    style = Logos::NavbarLogo.styles.fetch(brand)
    return ["Traced from its own lettering", "(typeface not identified)"] if style["lettering"]

    weights = [style["heavy"], (style["light"] if style["highlight"] == "weight")].compact.uniq
    ["Montserrat", "#{'weight'.pluralize(weights.size)} #{weights.join(' and ')}"]
  end

  # Every fill the brand's logos use, per tone, in the order the style lists them.
  def logo_brand_colours(brand)
    Logos::NavbarLogo.styles.fetch(brand).fetch("tones").transform_values do |fills|
      [fills["text"], fills["quiet"], fills["accent"], *fills.fetch("icon").values].compact.uniq
    end
  end
end
