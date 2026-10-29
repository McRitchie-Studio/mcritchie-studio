# frozen_string_literal: true

# TWO BRANDS' KITS SIDE BY SIDE (task logo-compare-and-original-edits; Alex McRitchie 2026-10-11 23:06: "comparing two marketing
# kits ... Commercial Welding V1 vs V2"). LogosController#compare draws it at /logos/compare?left=welding&right=welding_v2.
#
# Each SIDE draws its brand's KIT DEFAULT for the type: the saved choice (rule or form, text version, colouring,
# edits) and the kit's icon, exactly as its brand page opens on it (BrandKit#page_defaults), else the brand's style.
# The page's shared controls override it one by one: a rule, a form, a proportion, a colouring. A control a side cannot take (a form
# its name does not draw, an Original for a brand with none) leaves that side on its own, and the side says so.
# With `grid`, both sides draw their construction guide drawings instead (the brand pages' Show guides).
#
# Plain Ruby over BrandKit records: nothing here writes.
class LogoComparison
  # One side: its brand, the logo that draws it, its kit record, its version per tone ({ light:, dark: } or
  # { watermark: }), whether it is drawing a saved kit choice, which controls moved it off that, and notes.
  Side = Data.define(:brand, :logo, :kit, :variants, :saved, :changed, :notes) do
    def name = Logos::Variant.brand_name(logo)
    def variant = variants.values.first
  end

  # A brand's VERSION FAMILY: its key less a trailing _v2, so welding and welding_v2 are one family.
  def self.family(brand) = brand.to_s.sub(/_v\d+\z/, "")

  # The brand a Compare button pairs `brand` with: another version of it where there is one (welding with welding_v2),
  # else the next brand in config/logo_brands.yml, wrapping round.
  def self.partner(brand, brands = Logos::NavbarLogo.brands)
    brand = brand.to_s
    brands.find { |other| other != brand && family(other) == family(brand) } ||
      brands[((brands.index(brand) || -1) + 1) % brands.size]
  end

  # The pair the page opens on with none asked: the first brand that has another version, and that version (Commercial
  # Welding v1 and v2); with no versions, the first two brands.
  def self.default_pair(brands = Logos::NavbarLogo.brands)
    left = brands.find { |brand| brands.any? { |other| other != brand && family(other) == family(brand) } } || brands.first
    [left, partner(left, brands)]
  end

  attr_reader :type, :rule, :form, :proportion, :colouring, :grid, :sides

  # `rule`, `form`, `proportion` and `colouring` are the page's controls (nil: each side's kit default); `kits` the saved records by
  # brand (BrandKit.by_brand), a brand with none drawing its style; `tones` the versions the page carries.
  def initialize(left:, right:, type:, tones:, rule: nil, form: nil, proportion: nil, colouring: nil, grid: false, kits: {})
    @type = type
    @rule = rule
    @form = form
    @proportion = proportion
    @colouring = colouring
    @grid = grid && type != :icon
    @tones = tones
    @sides = [left, right].map { |brand| side(brand.to_s, kits[brand.to_s] || BrandKit.new(brand: brand.to_s)) }
  end

  # The forms the Form control offers: each form at least one side draws, in Logos::Variant::FORMS order.
  def forms = Logos::Variant::FORMS.keys & sides.flat_map { |side| Logos::StackedLogo.new(side.brand).forms }

  # How wide each side's drawing in `tone` is, as a share of the wider one's (1.0 for the wider), so both are drawn at
  # ONE scale and their rows and units line up. Nil for the icon, whose data have no common unit (each fits its frame).
  def widths(tone)
    return if type == :icon

    measured = sides.map { |side| view_width(side.variants.fetch(tone)) }
    widest = measured.max
    measured.map { |width| width / widest }
  end

  private

  def side(brand, kit)
    logo = Logos::Variant.logo(brand, type)
    defaults = kit.page_defaults(type)
    notes = []
    changed = []
    rule = @rule || defaults[:rule]
    changed << :rule if type == :navbar && rule != defaults[:rule]
    form = side_form(logo, defaults, notes, changed)
    proportion = side_proportion(defaults, changed)
    colouring = side_colouring(logo, defaults, notes, changed)
    edits, icon_colouring = side_edits(logo, defaults, rule, form, notes)
    # The small line and letter spacing have no compare control: each side draws its kit's (task stacked-line-width-and-spacing).
    settings = type == :stacked ? defaults.slice(:small_line, :letter_spacing) : {}
    variants = @tones.to_h do |tone|
      [tone, Logos::Variant.new(logo, type:, rule:, form:, proportion:, **settings, text: kit.default_text(type) || :homogeneous, tone:, colouring:,
                                      icon_colouring:, guides: grid, edits:)]
    end
    Side.new(brand:, logo:, kit:, variants:, saved: !defaults[:choice].nil?, changed:, notes:)
  end

  # The page's form where this side draws it, else its kit default (and the side says why).
  def side_form(logo, defaults, notes, changed)
    return unless type == :stacked
    return defaults[:form] unless @form

    unless logo.forms.include?(@form)
      notes << "#{Logos::Variant.brand_name(logo)} has no #{Logos::Variant::FORMS.fetch(@form).downcase} form, so it shows its own."
      return defaults[:form]
    end
    changed << :form unless @form == defaults[:form]
    @form
  end

  # The page's proportion, else the side's kit default: every brand draws both (task stacked-rule-of-three).
  def side_proportion(defaults, changed)
    return unless type == :stacked
    return defaults[:proportion] unless @proportion

    changed << :proportion unless @proportion == defaults[:proportion]
    @proportion
  end

  # The page's colouring where this side has it, else its kit default, else its own (its Original where it has one).
  def side_colouring(logo, defaults, notes, changed)
    own = defaults[:colouring] || logo.colourings.first
    return own unless @colouring

    unless logo.colourings.include?(@colouring)
      notes << "#{Logos::Variant.brand_name(logo)}'s logo is solid colour, so it has no Original and shows Alt."
      return own
    end
    changed << :colouring unless @colouring == own
    @colouring
  end

  # The side's edits and its icon's colouring: the kit default's word edits, and the kit's icon where it has one
  # (its colouring and colour), as the brand page draws them. Word edits the page's rule or form cannot draw (a word
  # too heavy for it) are left out, and the side says why; the icon's colour moves nothing, so it is kept.
  def side_edits(logo, defaults, rule, form, notes)
    edits = defaults[:edits]
    return [edits, nil] if type == :icon

    icon = defaults[:icon]
    edits = edits.except(:icon).merge(icon.edits.slice(:icon)) if icon
    if edits.except(:icon).any? && (refusal = logo.refusal(edits, **(type == :stacked ? { form: } : { rule: })))
      notes << "Its saved word edits cannot be drawn here, so its words are shown as styled: #{refusal}"
      edits = edits.slice(:icon)
    end
    [edits, icon&.colouring]
  end

  def view_width(variant) = variant.svg[/viewBox="\S+ \S+ (\S+) /, 1].to_f
end
