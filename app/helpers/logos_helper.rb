# frozen_string_literal: true

# The logo gallery's view words and its three fixed plates (LogosController).
module LogosHelper
  # The plates are FIXED surfaces, never theme tokens: a logo's fills are baked
  # per tone, so the light logo needs a light plate in both hub themes and the
  # dark logo a dark one. The watermark's plate is a gradient standing in for a
  # photograph, so the logo's transparency shows; it is dark enough that the
  # default watermark (white at 0.6) is at least 3:1 against every point of it
  # (test/helpers/logos_helper_test.rb measures that). A logo file has no
  # background of its own: the plate is the page's.
  WATERMARK_PLATE = %w[#263B5C #2C625E].freeze
  LOGO_PLATES = {
    light: "background-color: #FFFFFF",
    dark: "background-color: #12141A",
    watermark: "background-image: linear-gradient(135deg, #{WATERMARK_PLATE.join(', ')})"
  }.freeze

  def logo_plate_style(tone) = LOGO_PLATES.fetch(tone.to_sym)

  # The gallery's page params: the type, context, rule and guides in force, less the defaults (the Navbar Logo,
  # light, the rule of 4, guides off), with `changes` on top. A change to nil goes back to the default.
  def logo_page_params(**changes)
    { type: (@type unless @type == :navbar), context: (@context unless @context == :light), rule: (@rule unless @rule == 4),
      guides: (1 if @guides) }.merge(changes).compact
  end

  # How tall each type's sample is in the index table, in px: one size per type, so a column reads as a column.
  LOGO_SAMPLE_HEIGHTS = { icon: 48, navbar: 28, stacked: 96 }.freeze
  # The most a logo may be tall on its brand page, in px.
  LOGO_HEIGHTS = { icon: 160, navbar: 60, stacked: 240 }.freeze
  # A guide drawing is shown at exactly this height, at every page width, so its labels keep a readable size (at
  # least 11 px; test/helpers/logos_helper_test.rb measures every drawing). On a narrow page the plate scrolls
  # sideways inside itself rather than shrinking the drawing.
  LOGO_GUIDE_HEIGHTS = { navbar: 132, stacked: 380 }.freeze

  def logo_height(variant) = (variant.guides ? LOGO_GUIDE_HEIGHTS : LOGO_HEIGHTS).fetch(variant.type)

  # A brand page's one-line account of the type being shown.
  def logo_type_sentence(logo, type, rule)
    case type
    when :icon then "The icon alone, as this brand's logos draw it."
    when :navbar then Logos::Variant::RULE_SENTENCES.fetch(rule)
    else "#{Logos::Variant::METHOD_SENTENCE} #{Logos::Variant::FORM_SENTENCES.fetch(logo.form)}"
    end
  end

  # A logo's own SVG route: /logos/:brand/icon, /navbar or /stacked, with the type's own params.
  def logo_asset_path(variant, **more)
    public_send(:"#{variant.type}_logo_path", variant.logo.brand, variant.params.merge(more))
  end

  # One logo as a picture that carries its name. It scales down inside its plate, up to `height` px tall; `fixed`
  # (a guide drawing) holds it at exactly `height` and lets the plate scroll.
  def logo_image(variant, height:, fixed: false)
    image_tag logo_asset_path(variant), alt: variant.label, loading: "lazy", data: { test: "logo-image" },
              style: fixed ? "height: #{height}px; max-width: none" : "max-height: #{height}px",
              class: fixed ? "block mx-auto w-auto" : "block max-w-full w-auto h-auto"
  end

  # What a brand's name is set in, as [typeface, detail]: Montserrat and its
  # weights (heaviest first), or the brand's own traced lettering.
  def logo_brand_typeface(brand)
    style = Logos::NavbarLogo.styles.fetch(brand)
    return ["Traced from its own lettering", "(typeface not identified)"] if style["lettering"]

    weights = [style["heavy"], (style["light"] if style["highlight"] == "weight")].compact.uniq
    ["Montserrat", "#{'weight'.pluralize(weights.size)} #{weights.join(' and ')}"]
  end

  # Every fill the brand's logos use, per tone, in the order the style lists them. The watermark has one.
  def logo_brand_colours(logo)
    baked = Logos::NavbarLogo.styles.fetch(logo.brand).fetch("tones").transform_values do |fills|
      [fills["text"], fills["quiet"], fills["accent"], *fills.fetch("icon").values].compact.uniq
    end
    baked.merge("watermark" => [logo.watermark.fetch("fill")])
  end

  # "60%": how much of the watermark shows.
  def logo_watermark_opacity(logo) = number_to_percentage(logo.watermark.fetch("opacity") * 100, precision: 0)
end
