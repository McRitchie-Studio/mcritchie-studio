# frozen_string_literal: true

# What the logo gallery's brand page (logos/show) is drawn from, read from the request's params: the brand's logo for
# the tab's type, the page's context, and the tab's rule, form, guides and edits. LogosController#show draws the page
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
  end

  # The colouring a brand's logos are shown in: the page's ?colouring=, else `default` (a brand page's kit default),
  # else the brand's Original where it has one. A brand with no original (Studio) is shown in Alt whatever the page
  # asks, and says why (logos/_colouring_control).
  def page_colouring(logo, default = nil) = logo.original? ? (@colouring_param || default || :original) : :alt

  # Every setting is read on every tab, so a tab that does not use one (the icon has no rule and no guides) still
  # carries it to the next. Needs set_logo and set_context first.
  #
  # THE SAVED KIT CHOICE IS THE TAB'S DEFAULT (task logo-original-and-alt, item 9): a tab whose type the brand's kit
  # has saved opens on it (its rule or form, colouring and edits; its text version is marked), and the URL's params
  # override it one by one for exploring. The edits override as one set: any edit param in the URL replaces the
  # saved edits. With nothing saved, the built-in defaults (BrandKit#page_defaults).
  def load_brand_page
    @kit_record = BrandKit.for(@logo.brand)
    @defaults = @kit_record.page_defaults(@type)
    @kit_default = @defaults[:choice]
    @rule = params.key?(:rule) ? Logos::Variant.rule(params[:rule]) : @defaults[:rule]
    @form = params.key?(:form) ? Logos::Variant.form(params[:form], (@logo if @type == :stacked)) : (@defaults[:form] if @type == :stacked)
    @guides = Logos::Variant.flag(params[:guides], "guides")
    url_edits = Logos::Variant::EDIT_PARAMS.keys.any? { |name| params.key?(name) }
    @edits = url_edits ? @logo.checked_edits(Logos::Variant.edits(params)) : @defaults[:edits]
    @colouring = page_colouring(@logo, @defaults[:colouring])
    @default_colouring = @logo.original? ? (@defaults[:colouring] || :original) : :alt
    @kit_default_shown = @kit_default && @kit_record.default_shown?(@type, rule: @rule, form: @form, colouring: @colouring, edits: @edits)
    # Edits that cannot be drawn in this rule or form (a word too heavy to sit where the rules put it) are named on
    # the page, and the logos are drawn as styled, so a change of form never loses the page. Edits apply to Alt only:
    # an Original keeps them in the URL and draws none (Logos::Variant).
    @edit_refusal = (@logo.refusal(@edits, **(@type == :stacked ? { form: @form } : { rule: @rule })) if @edits.any? && @type != :icon && @colouring == :alt)
    drawn = @edit_refusal ? Logos::NavbarLogo::NO_EDITS : @edits
    # Per logo shown, its version in each tone the page carries ({ light:, dark: } or { watermark: }).
    @variants = @tones.map do |tone|
      Logos::Variant.all(@logo, type: @type, rule: @rule, form: @form, tone:, colouring: @colouring, guides: @guides, edits: drawn)
    end.transpose.map { |versions| @tones.zip(versions).to_h }
    @kit = Logos::BrandKit.new(@logo.brand)
    @savers = BrandKit.saver_names([@kit_record])
  end
end
