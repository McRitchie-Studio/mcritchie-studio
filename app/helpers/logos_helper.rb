# frozen_string_literal: true

# The logo gallery's view words (LogosController).
#
# There are NO PLATES: every logo sits on the page's own background, and the
# page's Context control drives the hub's own theme (html.dark, localStorage
# 'theme', the moon icon's switch). Light and Dark show the light or the dark
# logos to match; Watermark turns the page dark and shows the watermark logos.
# A logo file has no background of its own either.
module LogosHelper
  # The gallery's page params: the type, context, rule, form and guides in force, less the defaults (the Navbar Logo,
  # the theme's own logos, the rule of 4, the brand's own stacked form, guides off), with `changes` on top. A change
  # to nil goes back to the default. Only the watermark is carried as a context: light and dark are the hub's theme,
  # which every page already keeps.
  def logo_page_params(**changes)
    { type: (@type unless @type == :navbar), context: (@context if @context == :watermark), rule: (@rule unless @rule == 4),
      form: (@form unless @type == :stacked && @form == @logo.form), guides: (1 if @guides) }.merge(changes).compact
  end

  # How tall each type's sample is in the index table's cluster (logos/_cluster), in px: the most each fits in its
  # tile under the tile's badge.
  LOGO_SAMPLE_HEIGHTS = { icon: 28, navbar: 28, stacked: 88 }.freeze
  # The badge on each tile of the cluster, so each type is easy to tell.
  LOGO_BADGES = { stacked: "Stacked", navbar: "Navbar", icon: "Icon" }.freeze
  # The most a logo may be tall on its brand page, in px, and the most its guide drawing may be.
  LOGO_HEIGHTS = { icon: 160, navbar: 60, stacked: 240 }.freeze
  # A stacked guide drawing carries its ruler beside it, so it is wider than the logo and needs more height to keep
  # its numbers readable (the tagline form's tallest least-width height is 531 px).
  LOGO_GUIDE_HEIGHTS = { navbar: 132, stacked: 540 }.freeze
  # A guide drawing FITS its plate first, like any logo. It only stops shrinking at the width where its labels
  # would render below this many px, and from there the plate scrolls sideways inside itself. The widest plate on
  # a 1280 px page is LOGO_PLATE_WIDTH px, and every drawing's minimum is under it, so nothing scrolls there
  # (test/helpers/logos_helper_test.rb measures every drawing).
  LOGO_GUIDE_LABEL_PX = 9
  LOGO_PLATE_WIDTH = 1028

  # The narrowest a guide drawing may be shown, in px: where its labels are LOGO_GUIDE_LABEL_PX tall.
  def logo_guide_min_width(variant) = (LOGO_GUIDE_LABEL_PX * variant.guide_width / variant.guide_font).ceil

  def logo_height(variant) = (variant.guides ? LOGO_GUIDE_HEIGHTS : LOGO_HEIGHTS).fetch(variant.type)

  # A brand page's one-line account of the type being shown (a Stacked Logo's in the form shown).
  def logo_type_sentence(logo, type, rule, form = nil)
    case type
    when :icon then "The icon alone, as this brand's logos draw it."
    when :navbar then Logos::Variant::RULE_SENTENCES.fetch(rule)
    else "#{Logos::Variant::METHOD_SENTENCE} #{Logos::Variant::FORM_SENTENCES.fetch(form || logo.form)}"
    end
  end

  # A logo's own SVG route: /logos/:brand/icon, /navbar or /stacked, with the type's own params.
  def logo_asset_path(variant, **more)
    public_send(:"#{variant.type}_logo_path", variant.logo.brand, variant.params.merge(more))
  end

  # One logo as a picture that carries its name. It scales down inside its frame, up to `height` px tall. A guide
  # drawing also has a least width (above), so its frame scrolls once the frame is narrower than that.
  def logo_image(variant, height:, loading: "lazy", test: "logo-image")
    least = "; min-width: #{logo_guide_min_width(variant)}px" if variant.guides
    image_tag logo_asset_path(variant), alt: variant.label, loading:, data: { test: },
              style: "max-height: #{height}px#{least}", class: class_names("block max-w-full w-auto h-auto", "mx-auto" => variant.guides)
  end

  # A typeface level's name size, in px, by level (0 is the most prominent): it steps down so the hierarchy reads as
  # one. The index table's cell is narrower, so its steps are smaller.
  LOGO_TYPEFACE_SIZES = { false => [30, 20, 15], true => [17, 13, 11] }.freeze

  def logo_typeface_size(level, compact: false) = LOGO_TYPEFACE_SIZES.fetch(compact).fetch(level)

  # The brand's name in its own traced lettering, as the typeface hierarchy shows it: the rule-of-4 Navbar Logo with
  # both words alike, one per baked tone.
  def logo_traced_name_variants(brand)
    logo = Logos::NavbarLogo.new(brand)
    Logos::NavbarLogo::BAKED.to_h { |tone| [tone, Logos::Variant.new(logo, rule: 4, text: :homogeneous, tone:)] }
  end

  # One logo in the hub theme's tone: the light version while the page is light and the dark one under html.dark,
  # switched by CSS alone, so a change of theme needs no request and the first paint is already right. Given one
  # tone only (the watermark), that one is shown. Both pictures load eagerly: a hidden lazy picture would only start
  # loading when the theme turns, and a waiting reader would see an empty space.
  def logo_themed_images(variants, height:, test: "logo-image")
    return logo_image(variants.values.first, height:, loading: "eager", test:) if variants.size == 1

    safe_join(variants.map do |tone, variant|
      tag.span(logo_image(variant, height:, loading: "eager", test:), class: LOGO_THEME_CLASSES.fetch(tone), data: { test: "logo-themed", tone: })
    end)
  end

  # The light and dark versions of one thing in the page (a picture, a download, a copy button), each wrapped so that
  # only the one matching the hub theme shows; a single tone (the watermark) is given unwrapped.
  def logo_themed(tones, &block)
    return capture(tones.first, &block) if tones.size == 1

    safe_join(tones.map { |tone| tag.span(capture(tone, &block), class: LOGO_THEME_CLASSES.fetch(tone), data: { test: "logo-themed", tone: }) })
  end

  # Which picture of a light/dark pair shows: the light one unless the hub's root carries `dark`.
  LOGO_THEME_CLASSES = { light: "contents dark:hidden", dark: "hidden dark:contents" }.freeze
end
