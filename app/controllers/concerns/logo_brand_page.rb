# frozen_string_literal: true

# What the logo gallery's brand page (logos/show) is drawn from, read from the request's params: the brand's logo for
# the tab's type, the page's context, and the tab's rule, form, proportion, guides and edits. LogosController#show draws the page
# with it; BrandKitsController draws the same page again when it refuses an upload, so the refusal is shown in the
# Kit originals card with every other card as it was (task logo-gallery-polish-pass).
module LogoBrandPage
  extend ActiveSupport::Concern

  private

  # An unknown brand is a 404. The logo is the one that draws the type asked for.
  def set_logo
    brand = params[:brand].to_s
    raise ActiveRecord::RecordNotFound, "No logo brand #{brand.inspect}" unless Logos::NavbarLogo.brands.include?(brand)

    @type = Logos::Variant.type(params[:type])
    @logo = Logos::Variant.logo(brand, @type)
  end

  # @context is nil (follow the hub theme), :light, :dark or :watermark; @theme is the theme the page sets on load
  # (nil: leave it as it is); @tones the logo versions the page renders. @colouring_param is the page's ?colouring=
  # (task logo-original-and-alt): nil (each brand's own default), :original or :alt.
  def set_context
    @context = Logos::Variant.context(params[:context]) if params.key?(:context)
    @theme = @context == :watermark ? :dark : @context
    @tones = @context == :watermark ? [:watermark] : Logos::NavbarLogo::BAKED
    @colouring_param = Logos::Variant.colouring(params[:colouring])
    @icon_colouring_param = Logos::Variant.colouring(params[:icon_colouring])
    @download_format = download_format(params[:download_format])
  end

  # The /logos table's download format (task logos-index-download-formats): ?download_format= png, svg or jpeg, PNG
  # unless asked. Read on every page so every link carries it (LogosHelper#logo_page_params) and the table opens on it
  # again; anything else is refused, as every other logo param is.
  DOWNLOAD_FORMATS = { png: "PNG", svg: "SVG", jpeg: "JPEG" }.freeze

  def download_format(value)
    return DOWNLOAD_FORMATS.keys.first if value.nil?

    DOWNLOAD_FORMATS.keys.find { |format| format.to_s == value.to_s } or
      raise Logos::NavbarLogo::Error, "a download format is #{DOWNLOAD_FORMATS.keys.join(', ')}, not #{value.to_s.inspect[0, 40]}"
  end

  # The colouring a brand's logos are shown in: the page's ?colouring=, else `default` (a brand page's kit default),
  # else the brand's Original where it has one. A brand with no original (Studio) is shown in Alt whatever the page
  # asks, and says why (logos/_colouring_control).
  def page_colouring(logo, default = nil) = logo.original? ? (@colouring_param || default || :original) : :alt

  # Every setting is read on every tab, so a tab that does not use one (the icon has no rule and no guides) still
  # carries it to the next. Needs set_logo and set_context first.
  #
  # THE SAVED KIT CHOICE IS THE TAB'S DEFAULT (task logo-original-and-alt, item 9): a tab whose type the brand's kit
  # has saved opens on it (its rule, or form and proportion, colouring and edits; its text version is marked), and the URL's params
  # override it one by one for exploring. The edits override as one set: any edit param in the URL replaces the
  # saved edits. With nothing saved, the built-in defaults (BrandKit#page_defaults).
  def load_brand_page
    @kit_record = BrandKit.for(@logo.brand)
    @defaults = @kit_record.page_defaults(@type)
    @kit_default = @defaults[:choice]
    @rule = params.key?(:rule) ? Logos::Variant.rule(params[:rule]) : @defaults[:rule]
    @form = params.key?(:form) ? Logos::Variant.form(params[:form], (@logo if @type == :stacked)) : (@defaults[:form] if @type == :stacked)
    @proportion = params.key?(:proportion) ? Logos::Variant.proportion(params[:proportion]) : (@defaults[:proportion] if @type == :stacked)
    @guides = Logos::Variant.flag(params[:guides], "guides")
    # The text version (homogeneous, first or second word leads): the URL's ?text=, else the kit's saved one, else the
    # brand's default (BrandKit#default_text). The Words control picks it; an icon has none.
    @default_text = @kit_record.default_text(@type)
    @text = params.key?(:text) && @type != :icon ? Logos::Variant.text(params[:text]) : @default_text
    url_edits = Logos::Variant::EDIT_PARAMS.keys.any? { |name| params.key?(name) }
    @edits = url_edits ? @logo.checked_edits(Logos::Variant.edits(params)) : @defaults[:edits]
    # The Icon tab's only edit is the icon's colour, so the word edits other tabs carry in its URL (kept for the way
    # back) do not replace the kit icon's: only ?icon_colour= does.
    @edits = @edits.except(:icon).merge(@defaults[:edits].slice(:icon)) if @type == :icon && !params.key?(:icon_colour)
    @colouring = page_colouring(@logo, @defaults[:colouring])
    @default_colouring = @logo.original? ? (@defaults[:colouring] || :original) : :alt
    load_icon
    @kit_default_shown = @kit_default && !@icon_overridden &&
                         @kit_record.default_shown?(@type, rule: @rule, form: @form, proportion: @proportion, colouring: @colouring, text: @text,
                                                           edits: @type == :icon ? @edits.slice(:icon) : @edits)
    # Edits that cannot be drawn in this rule or form (a word too heavy to sit where the rules put it) are named on
    # the page, and the logos are drawn as styled, so a change of form never loses the page. The word edits apply in
    # Original as in Alt (task logo-compare-and-original-edits); an original icon draws no colour edit (Logos::Variant).
    @edit_refusal = (@logo.refusal(@edits, **(@type == :stacked ? { form: @form, proportion: @proportion } : { rule: @rule })) if @edits.any? && @type != :icon)
    drawn = @edit_refusal ? Logos::NavbarLogo::NO_EDITS : @edits
    drawn = drawn.except(:icon).merge(@kit_icon.edits.slice(:icon)) if @icon_from_kit
    # ONE LOGO PER TAB (task logo-download-card): the tab's logo in each tone the page carries ({ light:, dark: } or
    # { watermark: }), in the one text version @text, and the same logo in every tone for the Download card.
    choose = ->(tone) { Logos::Variant.new(@logo, type: @type, rule: @rule, form: @form, proportion: @proportion, text: @text, tone:,
                                                  colouring: @colouring, icon_colouring: @icon_colouring, guides: @guides, edits: drawn) }
    @shown = @tones.to_h { |tone| [tone, choose.(tone)] }
    @downloads = Logos::NavbarLogo::TONES.to_h { |tone| [tone, @shown[tone] || choose.(tone)] }
    @kit = Logos::BrandKit.new(@logo.brand)
    @savers = BrandKit.saver_names([@kit_record])
  end

  # THE ICON IS AN ATOMIC UNIT (task kit-icon-atomic-unit): a Navbar or Stacked tab's icon is, in order, the URL's
  # icon params (?icon_colouring=, and ?icon_colour= while the kit has an icon: for exploring), else the kit's icon
  # (@kit_icon, saved on the Icon tab), else the tab's own colouring and icon edit, exactly as before. The tab's
  # Colouring then governs its words. @icon_colouring is nil when the icon takes the words' colouring; @icon_from_kit
  # says the kit's icon is drawn, so the edit panel's Icon row defers to the Icon tab and @edits are the words' alone.
  def load_icon
    return if @type == :icon

    @kit_icon = @defaults[:icon]
    @icon_overridden = params.key?(:icon_colouring) || (@kit_icon && params.key?(:icon_colour)) || false
    @icon_from_kit = @kit_icon && !@icon_overridden
    @icon_colouring = if @icon_from_kit then @kit_icon.colouring
                      elsif @icon_colouring_param then @logo.original? ? @icon_colouring_param : :alt
                      end
    @edits = @edits.except(:icon) if @icon_from_kit
  end
end
