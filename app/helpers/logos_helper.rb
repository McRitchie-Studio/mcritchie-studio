# frozen_string_literal: true

# The logo gallery's view words (LogosController).
#
# There are NO PLATES: every logo sits on the page's own background, and the
# page's Context control drives the hub's own theme (html.dark, localStorage
# 'theme', the moon icon's switch). Light and Dark show the light or the dark
# logos to match; Watermark turns the page dark and shows the watermark logos.
# A logo file has no background of its own either.
module LogosHelper
  # The gallery's page params: the type, context, colouring, rule, form, proportion, small line, letter spacing and
  # guides in force, less the defaults (the Navbar Logo, the theme's own logos, each brand's own colouring, the rule of
  # 4, the brand's own stacked form, 3-2-1, a 3-2-1 small line, letters as styled, guides off), and the edits in force (task logo-part-editor), with `changes` on top. A change to nil goes back to the
  # default. Only the watermark is carried as a context: light and dark are the hub's theme, which every page already
  # keeps. The colouring is the page's own ?colouring= (task logo-original-and-alt), carried as asked even on a brand
  # that shows only Alt, so it comes back on the next brand.
  #
  # A brand page's defaults are its kit's saved choices (task logo-original-and-alt, item 9; LogoBrandPage): a rule,
  # form or set of edits equal to the page's default is left out, so a link never pins a setting the next tab would
  # read from its own saved choice. The page's own ?icon_colouring= (task kit-icon-atomic-unit: exploring an icon other
  # than the kit's) is carried as asked.
  #
  # The /logos table's download format (?download_format=, task logos-index-download-formats) is carried by every page,
  # less its default (PNG), so the table opens on it again from any brand or compare page.
  #
  # The text version (?text=, the Words control) is the tab's own: it is carried while the tab stays, and dropped by a
  # link to another tab, which opens on its own kit's text version (task logo-download-card).
  def logo_page_params(**changes)
    defaults = @defaults || {}
    edits = (@edits unless @edits.nil? || @edits == defaults.fetch(:edits, Logos::NavbarLogo::NO_EDITS))
    same_tab = !changes.key?(:type) || (changes[:type] || :navbar).to_sym == @type
    { type: (@type unless @type == :navbar), context: (@context if @context == :watermark), colouring: @colouring_param,
      text: (@text if same_tab && @text != @default_text),
      icon_colouring: @icon_colouring_param,
      rule: (@rule unless @rule == defaults.fetch(:rule, 4)),
      form: (@form unless @type == :stacked && @form == defaults.fetch(:form, @logo&.form)),
      proportion: (@proportion unless @type == :stacked && @proportion == defaults.fetch(:proportion, Logos::Variant::PROPORTIONS.keys.first)),
      small_line: (@small_line unless @type == :stacked && @small_line == defaults.fetch(:small_line, Logos::Variant::SMALL_LINES.keys.first)),
      letter_spacing: (@letter_spacing unless @type == :stacked &&
                                               @letter_spacing == defaults.fetch(:letter_spacing, Logos::Variant::LETTER_SPACINGS.keys.first)),
      guides: (1 if @guides), download_format: logo_download_format_param }
      .merge(Logos::Variant.edit_params(edits || {})).merge(changes).compact
  end

  # The compare page's params (task logo-compare-and-original-edits): the two brands, the type (less the Navbar Logo),
  # the watermark context, and the shared controls in force (each absent: every side's kit default), with `changes`
  # on top; a change to nil drops a param.
  def logo_compare_params(**changes)
    { left: @left, right: @right, type: (@type unless @type == :navbar), context: (@context if @context == :watermark),
      colouring: @colouring_param, rule: @rule_param, form: @form_param, proportion: @proportion_param, grid: (1 if @grid),
      download_format: logo_download_format_param }.merge(changes).compact
  end

  # The page's ?download_format= as a URL param: nil for the default (PNG) or none read.
  def logo_download_format_param = (@download_format unless @download_format.nil? || @download_format == LogoBrandPage::DOWNLOAD_FORMATS.keys.first)

  # The compare page a brand page's Compare button opens: this brand on the left, its other version (or the next
  # brand) on the right, on the tab's type, in the page's context and colouring.
  def logo_compare_path_for(brand, type: nil)
    logos_compare_path({ left: brand, right: LogoComparison.partner(brand), type: (type unless type == :navbar) }
                         .merge(logo_page_keeps).compact)
  end

  # What a compare side draws, in a line: "Kit default: …" (its saved choice) or "Brand style: …" (nothing saved), as
  # moved by the page's controls ("rule and colouring from the controls above").
  def logo_compare_source(side)
    source = side.saved ? "Kit default" : "Brand style (no #{Logos::Variant::TYPES.fetch(side.variant.type)} saved)"
    moved = (" · #{side.changed.map(&:to_s).to_sentence} from the controls above" if side.changed.any?)
    "#{source}: #{logo_choice_summary(side.variant)}#{moved}"
  end

  # The bare tab: what it opens on, its kit default where it has one. Only the context and guides are kept.
  def logo_tab_default_path = logo_brand_path(@logo.brand, { type: (@type unless @type == :navbar) }.merge(logo_page_params.slice(:context, :guides)).compact)

  # The page params that keep the page's context and colouring, for a link or form that leaves the tab's own settings.
  def logo_page_keeps(*more) = logo_page_params.slice(:context, :colouring, :download_format, *more)

  # A brand's own colouring on a page with no ?colouring=: its Original where it has one, else Alt.
  def logo_default_colouring(logo) = logo.original? ? :original : :alt

  # The page params with no edits: the edit panel's Reset, and the hidden fields of its own form (which sends its own).
  # On the Icon tab, whose only edit is the icon's colour, the word edits other tabs carry are kept for the way back.
  def logo_unedited_params = logo_page_params.except(*(@type == :icon ? %i[icon_colour] : Logos::Variant::EDIT_PARAMS.keys))

  # The edit panel's rows (logos/_edit_panel): each part this tab's logos show, with what it is called, the words it
  # draws, and the settings it takes. The tagline only on the Stacked Logo's tagline form; the Icon tab, the icon alone.
  def logo_edit_rows
    rows = [{ part: :icon, label: "Icon", settings: %i[colour] }]
    return rows if @type == :icon

    rows += [
            { part: :first, label: "First word", word: @logo.words.first, settings: %i[colour weight] },
            { part: :ending, label: "Ending", word: @logo.words.last, settings: %i[colour weight] }]
    rows << { part: :tagline, label: "Tagline", word: @logo.tagline, settings: %i[colour weight visible] } if @type == :stacked && @form == :tagline
    rows
  end

  # True when the tab's icon is drawn in its Original (the brand's art), so the edit panel's Icon row offers no colour.
  # The icon's colouring is its own where it has one (the URL's ?icon_colouring=), else the tab's.
  def logo_icon_original? = (@icon_colouring || @colouring) == :original

  # The URL param of one part's setting: first_colour, tagline_visible.
  def logo_edit_param(part, setting) = :"#{part}_#{setting}"

  # Why `weight` on `part` cannot be drawn in this rule or form with the other edits in force, or nil. A weight that
  # cannot is offered disabled.
  def logo_edit_weight_refusal(part, weight)
    edits = @edits.merge(part => (@edits[part] || {}).merge(weight:))
    @logo.refusal(edits, **@shape)
  end

  # What the icon's colour edit recolours in `tone`, in one line, read from the icon that tone draws: the whole icon,
  # or its one main layer of several (an icon with no primary layer, such as Turf Monster's three-colour head, its first). Commercial Welding's
  # dark tone draws its two-colour helmet, so there the edit recolours the blue half.
  def logo_icon_edit_note(logo, tone = :light)
    roles = logo.icon_roles(tone)
    return "Recolours the whole icon." if roles.size == 1

    role = logo.icon_role(tone)
    others = roles - [role]
    "Recolours the icon's #{role == 'primary' ? 'main' : role} layer only; its #{others.to_sentence} " \
      "#{others.size == 1 ? 'layer keeps its' : 'layers keep their'} brand #{others.size == 1 ? 'colour' : 'colours'}."
  end

  # The icon note for each tone the page shows ({ light: "…", dark: "…" }), or one note when every tone says the same.
  def logo_icon_edit_notes(logo, tones)
    notes = tones.to_h { |tone| [tone, logo_icon_edit_note(logo, tone)] }
    notes.values.uniq.size == 1 ? notes.values.first : notes
  end

  # What a part is called in a sentence.
  LOGO_PART_NAMES = { icon: "icon", first: "first word", ending: "ending", tagline: "tagline" }.freeze

  # A Navbar or Stacked choice in words, as the kit saves it (BrandKit): "rule of 4, second word leads, as styled",
  # "with tagline, first word leads, first word Deep Violet 300 Light; tagline hidden".
  # A brand that has an Original says which colouring the choice is in ("original colouring"); an Original's words
  # show their edits (task logo-compare-and-original-edits), and an all-Original choice with none says none. An Icon choice is its colouring and its colour ("alt colouring, icon Deep Violet"); a logo
  # drawing an icon of its own colouring says so ("original icon": the kit's, task kit-icon-atomic-unit).
  def logo_choice_summary(variant)
    colouring = ("#{Logos::Variant::COLOURINGS.fetch(variant.colouring).downcase} colouring" if variant.logo.original?)
    icon = ("#{Logos::Variant::COLOURINGS.fetch(variant.icon_colouring).downcase} icon" if variant.own_icon?)
    edits = (logo_edits_summary(variant.logo, variant.edits) unless variant.original? && variant.icon_colouring == :original && !variant.edited?)
    return [colouring, edits].compact.join(", ") if variant.type == :icon

    shape = variant.type == :stacked ? Logos::Variant::FORMS.fetch(variant.form) : Logos::Variant::RULES.fetch(variant.rule)
    proportion = (Logos::Variant::PROPORTIONS.fetch(variant.proportion).downcase if variant.rule_of_three?)
    settings = [("small line matched" if variant.match?), ("letters open" if variant.open?)]
    [shape.downcase, proportion, *settings, Logos::Variant::TEXTS.fetch(variant.text).downcase, colouring, icon, edits].compact.join(", ")
  end

  # Checked edits in words, by part, the colours by their palette names; "as styled" for none.
  def logo_edits_summary(logo, edits)
    return "as styled" if edits.empty?

    palette = Logos::BrandKit.new(logo.brand)
    edits.map do |part, settings|
      words = [(logo_swatch_name(palette, settings[:colour]) if settings[:colour]),
               ("#{settings[:weight]} #{Logos::BrandKit::WEIGHT_NAMES.fetch(settings[:weight])}" if settings[:weight]),
               ("hidden" if settings[:visible] == false)]
      "#{LOGO_PART_NAMES.fetch(part)} #{words.compact.join(' ')}"
    end.join("; ")
  end

  # The saved edits of `type` the kit leaves out because the brand can no longer draw them (BrandKit#stale_edits), in
  # one sentence, or nil: "Left out of the saved choice, because the brand can no longer draw it: first word colour
  # #123456."
  def logo_stale_edits_sentence(kit, type)
    stale = kit.stale_edits(type)
    return if stale.empty?

    words = stale.keys.map do |name|
      part, setting = Logos::Variant::EDIT_PARAMS.fetch(name.to_sym)
      value = kit.choice(type).dig("edits", name).to_s
      value = "##{value.upcase}" if setting == :colour
      "#{LOGO_PART_NAMES.fetch(part)} #{setting} #{value}"
    end
    "Left out of the saved choice, because the brand can no longer draw #{stale.size == 1 ? 'it' : 'them'}: #{words.to_sentence}. Save again to keep the choice as shown."
  end

  # "Kit: saved Oct 11, 2026 by Alex McRitchie" or "Kit: not saved yet", then " · motion: Pop and slide on the Stacked
  # Logo" when it has a motion choice, then " · originals: 2" when it holds any. A
  # kit is saved once it holds a saved Icon, Navbar or Stacked choice or a motion choice: a record left with none (a cleared choice, only
  # originals or notes) is not saved yet (task logo-gallery-polish-pass, item 4). The saver is named by their user
  # name (`savers`, BrandKit.saver_names), else their email's local part; `full: true` adds the email in brackets,
  # for the title attribute of a status cut short. The date is the kit's saved_at (its last logo choice saved or
  # cleared; task brand-kit-applied-status), else updated_at for a kit saved before saved_at was kept. The brand page,
  # its Kit card and Compare show it; the /logos table shows each app's status instead (brand_kit_apps/_status).
  def logo_kit_status(kit, savers = {}, full: false)
    saved = kit&.persisted? && kit.anything_saved?
    status = saved ? ["Kit: saved #{(kit.saved_at || kit.updated_at).strftime('%b %-d, %Y')}", logo_kit_saver(kit, savers, full:)].compact.join(" ") : "Kit: not saved yet"
    motion = (kit.saved_motion if saved)
    status = "#{status} · motion: #{logo_motion_summary(motion)}" if motion
    originals = kit&.persisted? ? kit.originals_attachments.size : 0
    originals.positive? ? "#{status} · originals: #{originals}" : status
  end

  # A motion choice in words: "Pop and slide on the Stacked Logo" (task logo-motion-presets).
  def logo_motion_summary(choice)
    "#{Logos::MotionPreset.find(choice['preset']).title} on the #{Logos::MotionPreset::LOGOS.fetch(choice['logo'].to_sym)}"
  end

  # "by Alex McRitchie", "by alex" (an email with no named user), with " (alex@…)" when `full`; nil when nobody is named.
  def logo_kit_saver(kit, savers, full:)
    email = kit.updated_by.presence or return
    name = savers[email].presence || email.split("@").first
    "by #{name}#{" (#{email})" if full}"
  end

  # The hidden fields the kit's save form sends: the tab's own choice (rule, or form and proportion, and the text version
  # the Words control picked) and its edits, then the page settings the redirect brings back (guides, context).
  def logo_kit_save_fields
    # A proportion, small line or letter spacing is sent only away from its default (the rule of three, Match, Open):
    # absent is the default, as the kit stores it (BrandKit.choice_of).
    stacked = { form: @form, proportion: (@proportion if @proportion == :rule_of_three), small_line: (@small_line if @small_line == :match),
                letter_spacing: (@letter_spacing if @letter_spacing == :open) }.compact
    choice = { icon: {}, stacked: }.fetch(@type) { { rule: @rule } }
    choice = choice.merge(text: @text) unless @type == :icon
    { type: @type }.merge(choice).merge(Logos::Variant.edit_params(@edits)).merge(logo_page_params.slice(:guides, :context))
                   .merge(colouring: @colouring)
  end

  # The brand page's params that open a kit choice on its own tab: its rule or form and its edits (less the page's
  # defaults), in the page's context. A logo drawing the kit's icon (`kit_icon`) leaves the icon's edit out: its tab
  # draws the kit's icon of itself.
  def logo_kit_tab_params(variant, kit_icon: false)
    shape = case variant.type
            when :icon then { type: :icon }
            when :stacked then { type: :stacked, form: (variant.form unless variant.form == variant.logo.form),
                                 proportion: (variant.proportion if variant.rule_of_three?), small_line: (variant.small_line if variant.match?),
                                 letter_spacing: (variant.letter_spacing if variant.open?) }
            else { rule: (variant.rule unless variant.rule == 4) }
            end
    colouring = (variant.colouring unless variant.colouring == logo_default_colouring(variant.logo))
    edits = kit_icon && variant.type != :icon ? variant.edits.except(:icon) : variant.edits
    shape.merge(Logos::Variant.edit_params(edits)).merge(logo_page_params.slice(:context)).merge(colouring:).compact
  end

  # How tall the kit card's Icon, Navbar and Stacked logos are, in px.
  LOGO_KIT_HEIGHTS = { icon: 64, navbar: 48, stacked: 140 }.freeze

  # The palette swatch a hex names ("Deep Violet").
  def logo_swatch_name(kit, hex) = kit.palette.find { |swatch| swatch.hex.casecmp?(hex) }&.name || hex

  # How tall each type's sample is in the index table's cluster (logos/_cluster), in px: the most each fits in its
  # tile under the tile's badge.
  LOGO_SAMPLE_HEIGHTS = { icon: 28, navbar: 28, stacked: 88 }.freeze
  # The badge on each tile of the cluster, so each type is easy to tell.
  LOGO_BADGES = { stacked: "Stacked", navbar: "Navbar", icon: "Icon" }.freeze
  # The most a logo may be tall on its brand page, in px, and the most its guide drawing may be.
  LOGO_HEIGHTS = { icon: 160, navbar: 60, stacked: 240 }.freeze
  # A guide drawing's height, kept near the card it replaces (Alex McRitchie 2026-10-27: guides "shouldn't open a card
  # that is taller than the normal card"). A drawing whose labels would fall below LOGO_GUIDE_LABEL_PX at that height
  # takes the least height that keeps them readable instead (two lines about 290 px; the tagline form up to 467): logo_height.
  LOGO_GUIDE_HEIGHTS = { navbar: 132, stacked: 280 }.freeze
  # A guide drawing FITS its plate first, like any logo. It only stops shrinking at the width where its labels
  # would render below this many px, and from there the plate scrolls sideways inside itself. The widest plate on
  # a 1280 px page is LOGO_PLATE_WIDTH px, and every drawing's minimum is under it, so nothing scrolls there
  # (test/helpers/logos_helper_test.rb measures every drawing).
  LOGO_GUIDE_LABEL_PX = 9
  LOGO_PLATE_WIDTH = 1028

  # The narrowest a guide drawing may be shown, in px: where its labels are LOGO_GUIDE_LABEL_PX tall.
  def logo_guide_min_width(variant) = (LOGO_GUIDE_LABEL_PX * variant.guide_width / variant.guide_font).ceil

  def logo_height(variant)
    return LOGO_HEIGHTS.fetch(variant.type) unless variant.guides

    width, height = Logos::PngSizes.natural(variant.svg)
    [LOGO_GUIDE_HEIGHTS.fetch(variant.type), (logo_guide_min_width(variant) * height / width).ceil].max
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
