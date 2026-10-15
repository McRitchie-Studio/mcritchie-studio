# frozen_string_literal: true

# A BRAND'S KIT RECORD (epic brand-studio, piece 3; task brand-kit-record): what the
# operator has SAVED for one brand of config/logo_brands.yml, and the artwork its
# logos were derived from.
#
#   icon_choice     the ICON every one of the brand's logos draws (task kit-icon-atomic-unit): {"colouring" => "original",
#                   "edits" => {"icon_colour" => "2D5E8E"}}. The icon is an atomic unit: with one saved, the Navbar and
#                   Stacked Logos draw it, whatever icon colouring or colour their own choice was saved with, and their
#                   own `colouring` governs their words. Without one, every logo is drawn exactly as before.
#   navbar_choice   the Navbar Logo the brand uses: {"rule" => 4, "text" => "second", "colouring" => "alt", "edits" => {...}}
#   stacked_choice  the Stacked Logo it uses:       {"form" => "tagline", "text" => "first", "colouring" => "original", "edits" => {...}}
#                   `colouring` (task logo-original-and-alt) is optional: a choice saved before it has none and is
#                   read as "alt", which is what it showed when it was saved. No migration: the JSON reads it so.
#                   `proportion` (task stacked-rule-of-three) is stored only for the rule of three ("rule_of_three"):
#                   absent is 3-2-1, so every choice saved before it reloads unchanged.
#   originals       the ORIGINAL artwork, unedited (Active Storage, the hub's R2 service): SVG, PNG, JPEG, PDF or ZIP,
#                   25 MB each. Alex: every kit keeps its original, so anyone can see where a derivation came from.
#   notes           the operator's own words on the kit
#   updated_by      who changed it last (the admin's email)
#
# A choice's `edits` are the gallery's own URL params (Logos::Variant::EDIT_PARAMS: first_colour, ending_weight, …),
# and a choice is read through the same parser the URL is (Logos::Variant.parse, then the logo's own refusal), so a
# saved choice can never hold something the page could not draw. Saving stores the parsed choice back in one
# spelling (#save_choice), so two saves of the same logo store the same hash.
#
# Not to be confused with Logos::BrandKit (lib/logos/brand_kit.rb): that is the brand's palette and typefaces, read
# from config/logo_brands.yml and never stored. This record holds only what the operator chose and uploaded.
#
# No seed rows: a brand with no record draws its defaults (DEFAULTS), and its record is created on the first save.
class BrandKit < ApplicationRecord
  Error = Logos::NavbarLogo::Error

  # The logos a kit saves a choice of (each drawn with the kit's icon), and every choice it saves: the icon too.
  TYPES = %i[navbar stacked].freeze
  CHOICE_TYPES = %i[icon navbar stacked].freeze
  # The keys a stored choice may carry, per type. `edits` and `colouring` may be absent (no edits; Alt).
  CHOICE_KEYS = { icon: %w[colouring edits], navbar: %w[rule text colouring edits], stacked: %w[form proportion text colouring edits] }.freeze
  OPTIONAL_KEYS = %w[colouring edits proportion].freeze
  # The only edit an icon choice carries: its colour (the edit panel's Icon row).
  ICON_EDITS = %w[icon_colour].freeze
  # The logo a brand shows with nothing saved: the rule-of-4 Navbar Logo with the second word leading, and its Stacked
  # Logo, in its own form, with the first word leading. The text versions are also the save form's default.
  DEFAULTS = { navbar: { rule: 4, text: :second }, stacked: { text: :first } }.freeze

  # The types an original may be, read from its BYTES (never its name), and how the card names each.
  ORIGINAL_TYPES = { "image/svg+xml" => "SVG", "image/png" => "PNG", "image/jpeg" => "JPEG",
                     "application/pdf" => "PDF", "application/zip" => "ZIP" }.freeze
  # The originals the card can show as a picture; the rest are links.
  PREVIEWABLE = %w[image/svg+xml image/png image/jpeg].freeze
  MAX_ORIGINAL_BYTES = 25.megabytes
  MAX_NOTES = 5_000

  has_many_attached :originals

  validates :brand, presence: true, uniqueness: true
  validates :notes, length: { maximum: MAX_NOTES }
  validates :updated_by, length: { maximum: 200 }
  validate :brand_has_a_style
  validate :choices_drawable
  validate :originals_allowed

  # The brand's record, or a new unsaved one: a brand's first save creates it.
  def self.for(brand) = find_or_initialize_by(brand: brand.to_s)

  # Every saved record for these brands, by brand, with its originals' attachment rows (the kit status counts them):
  # the index table reads them all in two queries, whatever the number of brands.
  def self.by_brand(brands) = where(brand: brands).includes(:originals_attachments).index_by(&:brand)

  # The names of the people who last changed these kits, by email, in one query: { "alex@…" => "Alex McRitchie" }. An
  # email with no named user is left out (the kit status then shows the email's local part).
  def self.saver_names(kits)
    emails = kits.filter_map(&:updated_by).uniq
    return {} if emails.empty?

    User.where(email: emails).where.not(name: [nil, ""]).pluck(:email, :name).to_h
  end

  # A stored choice as the Logos::Variant it draws in `tone` (light unless given), in its saved colouring or, given one,
  # in `colouring` (the table's): an Original for a brand that has none is drawn in Alt. Anything the gallery's parser
  # refuses is an Error, and so are edits that cannot be drawn in the choice's rule or form.
  # `icon` (an icon Logos::Variant: the kit's icon) is the icon a Navbar or Stacked choice draws, in its colouring and
  # with its colour, in place of whatever icon colour the choice was saved with (task kit-icon-atomic-unit).
  def self.variant(brand, type, choice, tone: :light, colouring: nil, icon: nil)
    type = type.to_sym
    keys = CHOICE_KEYS.fetch(type) { raise Error, "a kit saves an icon, a navbar or a stacked choice, not #{type.inspect}" }
    unless choice.is_a?(Hash) && (choice.keys - keys).empty? && (keys - OPTIONAL_KEYS).all? { |key| choice.key?(key) }
      raise Error, "a #{type} choice is a map of #{keys.join(', ')}, got #{choice.inspect[0, 80]}"
    end

    edits = choice["edits"] || {}
    names = type == :icon ? ICON_EDITS : Logos::Variant::EDIT_PARAMS.keys.map(&:to_s)
    unless edits.is_a?(Hash) && edits.all? { |name, value| names.include?(name.to_s) && (value.is_a?(String) || value.is_a?(Integer)) }
      raise Error, "a #{type} choice's edits are the edit params (#{names.join(', ')}), got #{edits.inspect[0, 80]}"
    end

    logo = Logos::Variant.logo(brand, type)
    colouring = (colouring.to_s if colouring && (colouring.to_sym == :alt || logo.original?))   # else the saved one (Alt)
    params = edits.to_h { |name, value| [name.to_sym, value.to_s] }
                  .merge(text: choice["text"]&.to_s, rule: choice["rule"]&.to_s, form: choice["form"]&.to_s,
                         proportion: choice["proportion"]&.to_s, tone: tone.to_s,
                         colouring: colouring || choice["colouring"]&.to_s).compact
    params = with_icon(params, icon) if icon && type != :icon
    variant = Logos::Variant.parse(logo, params, type:)
    return variant if type == :icon   # an icon's colour moves no geometry, so it has nothing to refuse

    refusal = logo.refusal(variant.edits, **(type == :stacked ? { form: variant.form, proportion: variant.proportion } : { rule: variant.rule }))
    raise Error, refusal if refusal

    variant
  end

  # A Navbar or Stacked choice's params with `icon`'s colouring and colour in place of its own icon colour.
  def self.with_icon(params, icon)
    colour = Logos::Variant.edit_params(icon.edits)[:icon_colour]
    params.except(:icon_colour).merge(icon_colouring: icon.colouring.to_s, icon_colour: colour).compact
  end
  private_class_method :with_icon

  # A choice as it is stored: the variant's own choices, its colouring and its checked, shown edits (an Original's
  # words keep theirs, task logo-compare-and-original-edits; an original icon shows no colour), in one spelling. An icon's is its colouring and its colour.
  def self.choice_of(variant)
    edits = Logos::Variant.edit_params(variant.edits).to_h { |name, value| [name.to_s, value.to_s] }
    return { "colouring" => variant.colouring.to_s, "edits" => edits } if variant.type == :icon

    choice = variant.type == :stacked ? { "form" => variant.form.to_s, "proportion" => (variant.proportion.to_s if variant.rule_of_three?) } : { "rule" => variant.rule }
    choice.compact.merge("text" => variant.text.to_s, "colouring" => variant.colouring.to_s, "edits" => edits)
  end

  def choice(type) = public_send(:"#{type}_choice")
  def saved?(type) = choice(type).present?

  # The saved choice for `type` as a Logos::Variant in `tone`, or the brand's default (DEFAULTS) when none is saved.
  # A saved edit the brand's data can no longer draw (a colour since taken out of the palette) is DROPPED here, not
  # refused, so a stale kit never takes the table or the brand page down: #stale_edits names what was dropped, and
  # the brand page says so. Only a choice whose rule, form or text is itself refused is an Error.
  # `colouring` draws the choice in that colouring instead of its saved one (the table's; Alt for a brand with no
  # original). With nothing saved, the default is drawn in the brand's own colouring (its Original where it has one)
  # unless asked.
  # A Navbar or Stacked Logo draws the KIT'S ICON (#kit_icon) where one is saved, or `icon` (an icon Logos::Variant)
  # when given: the table's one icon per row (task kit-icon-atomic-unit). With neither, its own, as before.
  def variant(type, tone: :light, colouring: nil, icon: nil)
    type = type.to_sym
    icon ||= kit_icon unless type == :icon
    return self.class.variant(brand, type, drawable_choice(type), tone:, colouring:, icon:) if saved?(type)

    logo = Logos::Variant.logo(brand, type)
    colouring = logo.colourings.first unless colouring && logo.colourings.include?(colouring.to_sym)
    return Logos::Variant.new(logo, type: :icon, tone:, colouring: colouring.to_sym) if type == :icon

    Logos::Variant.new(logo, type:, tone:, colouring: colouring.to_sym, icon_colouring: icon&.colouring,
                             edits: icon&.edits || Logos::NavbarLogo::NO_EDITS, **DEFAULTS.fetch(type))
  end

  # The kit's saved icon as an icon Logos::Variant (light), or nil when none is saved or it can no longer be drawn.
  def kit_icon = saved_variant(:icon)

  # What a brand page's tab opens on (task logo-original-and-alt, item 9: the saved kit choice is the default): the
  # Navbar rule and Stacked form and proportion (read on every tab, so each carries to its own), and the tab's colouring and edits,
  # from the saved choices, else the built-in defaults (the rule of 4, the brand's own form, the brand's own colouring,
  # no edits). `choice` is the tab's saved choice as a Logos::Variant, or nil (nothing saved, or a saved choice the
  # brand can no longer draw). `icon` is the kit's icon (#kit_icon): with one, a Navbar or Stacked tab's edits are its
  # words' alone, because its icon is the kit's.
  def page_defaults(type)
    navbar = saved_variant(:navbar)
    stacked = saved_variant(:stacked)
    icon = kit_icon
    choice = { icon:, navbar:, stacked: }[type.to_sym]
    { rule: navbar&.rule || 4, form: stacked&.form || Logos::StackedLogo.new(brand).form,
      proportion: stacked&.proportion || Logos::Variant::PROPORTIONS.keys.first, colouring: choice&.colouring,
      edits: (choice ? page_edits(type, choice, icon) : Logos::NavbarLogo::NO_EDITS), choice:, icon: }
  end

  # True when a tab's settings are exactly its saved choice's (the page then says it shows the kit default).
  # `text` (the page's text version) is checked only when given; an icon has none.
  def default_shown?(type, rule:, form:, colouring:, edits:, proportion: Logos::Variant::PROPORTIONS.keys.first, text: nil)
    choice = saved_variant(type) or return false
    return false if text && choice.text && choice.text != text
    shape = case type.to_sym
            when :icon then true
            when :stacked then choice.form == form && choice.proportion == proportion
            else choice.rule == rule
            end
    shape && choice.colouring == colouring && page_edits(type, choice, kit_icon) == edits
  end

  # The saved choice of `type` as a Logos::Variant, or nil when none is saved or it can no longer be drawn.
  def saved_variant(type)
    return unless CHOICE_TYPES.include?(type.to_sym) && saved?(type)

    variant(type)
  rescue Error
    nil
  end

  # The saved edits of `type` that #variant drops because they can no longer be drawn: { "first_colour" => reason }.
  def stale_edits(type)
    return {} unless saved?(type)

    drawable_choice(type)
    @stale_edits.fetch(type.to_sym, {})
  end

  # The text version the save form offers first: the saved one, else the default; an icon has none.
  def default_text(type)
    return if type.to_sym == :icon

    saved?(type) ? choice(type)["text"].to_sym : DEFAULTS.fetch(type.to_sym).fetch(:text)
  end

  # Reads `params` (strings, as a request gives them: rule or form, text, and the edit params) exactly as the gallery
  # does, and stores the choice they name. An Error says what was refused; nothing is stored then.
  # An icon choice keeps only the icon's colour edit; a Navbar or Stacked choice saved while the kit has an icon keeps
  # no icon colour of its own (task kit-icon-atomic-unit, item 3): its icon is the kit's.
  def save_choice(type, params, by:)
    type = type.to_sym
    raise Error, "a kit saves an icon, a navbar or a stacked choice, not #{type.inspect}" unless CHOICE_TYPES.include?(type)

    keys = CHOICE_KEYS.fetch(type) - OPTIONAL_KEYS
    choice = keys.to_h { |key| [key, params[key.to_sym].presence] }
    raise Error, "a #{type} choice needs a #{keys.join(' and a ')}" if choice.values.any?(&:nil?)

    edits = Logos::Variant::EDIT_PARAMS.keys.to_h { |name| [name.to_s, params[name].to_s] }.reject { |_, value| value.empty? }
    edits = edits.slice(*ICON_EDITS) if type == :icon
    edits = edits.except(*ICON_EDITS) if type != :icon && saved?(:icon)
    colouring = params[:colouring].presence
    proportion = (params[:proportion].presence if type == :stacked)
    variant = self.class.variant(brand, type, choice.merge("edits" => edits, "colouring" => colouring, "proportion" => proportion).compact)
    self[:"#{type}_choice"] = self.class.choice_of(variant)
    self.updated_by = by
    save!
    variant
  end

  def clear_choice(type, by:)
    raise Error, "a kit saves an icon, a navbar or a stacked choice, not #{type.inspect}" unless CHOICE_TYPES.include?(type.to_sym)

    self[:"#{type}_choice"] = nil
    self.updated_by = by
    save!
  end

  # Adds uploaded files (ActionDispatch::Http::UploadedFile) as originals, each checked first: its type read from its
  # bytes, its size under the cap. One bad file refuses them all, with an Error that names it.
  def add_originals(files, by:)
    files = Array(files).compact_blank
    raise Error, "choose at least one file to upload" if files.empty?
    raise Error, "an original must be an uploaded file" unless files.all? { |file| file.respond_to?(:original_filename) && file.respond_to?(:read) }

    attachables = files.map { |file| self.class.original_attachable(file) }
    self.updated_by = by
    originals.attach(attachables)
    save!
  end

  def remove_original(attachment_id, by:)
    original = originals.find(attachment_id)
    original.purge
    update!(updated_by: by, updated_at: Time.current)
    original
  end

  # One upload as an attachable, or an Error naming the file and what is wrong with it.
  def self.original_attachable(file)
    name = ActiveStorage::Filename.new(file.original_filename.to_s).sanitized
    raise Error, "#{name} is over #{MAX_ORIGINAL_BYTES / 1.megabyte} MB" if file.size > MAX_ORIGINAL_BYTES
    raise Error, "#{name} is empty" if file.size.zero?

    content_type = original_type_of(file)
    unless ORIGINAL_TYPES.key?(content_type)
      raise Error, "#{name} is not an SVG, PNG, JPEG, PDF or ZIP (read from its contents, not its name)"
    end

    { io: file, filename: name, content_type:, identify: false }
  end

  # The type a file's BYTES are, whatever it is called: a text file named logo.png is not a PNG.
  def self.original_type_of(file)
    io = file.respond_to?(:tempfile) ? file.tempfile : file
    io.rewind
    Marcel::MimeType.for(io).tap { io.rewind }
  end

  private

  # A tab's edits for a saved choice: a Navbar or Stacked choice's words' alone when the kit has an icon (its icon edit
  # is the kit's, not the tab's).
  def page_edits(type, choice, icon) = icon && type.to_sym != :icon ? choice.edits.except(:icon) : choice.edits

  # The saved choice less its edits that cannot be drawn, kept edit by edit in the saved order; the dropped ones go
  # to @stale_edits. Read again whenever the stored choice changes.
  def drawable_choice(type)
    type = type.to_sym
    stored = choice(type)
    @drawable ||= {}
    @stale_edits ||= {}
    return @drawable[type][:choice] if @drawable[type] && @drawable[type][:stored] == stored

    @stale_edits[type] = {}
    # A choice that is no map, or whose rule, form or text is refused, is not mended: #variant refuses it whole.
    return stored unless stored.is_a?(Hash) && stored["edits"].is_a?(Hash) && base_drawable?(type, stored)

    kept = {}
    stale = {}
    stored["edits"].each do |name, value|
      self.class.variant(brand, type, stored.merge("edits" => kept.merge(name => value)))
      kept[name] = value
    rescue Error => e
      stale[name] = e.message
    end
    @stale_edits[type] = stale
    (@drawable[type] = { stored:, choice: stored.merge("edits" => kept) })[:choice]
  end

  def base_drawable?(type, stored)
    self.class.variant(brand, type, stored.merge("edits" => {}))
    true
  rescue Error
    false
  end

  def brand_has_a_style
    errors.add(:brand, "is not a brand in config/logo_brands.yml") unless Logos::NavbarLogo.brands.include?(brand)
  end

  def choices_drawable
    return unless Logos::NavbarLogo.brands.include?(brand)

    CHOICE_TYPES.each do |type|
      # Only a choice being written is checked strictly: one saved earlier that has since gone stale is drawn without
      # its stale edits (#variant), and must not refuse a save of the other type or of the notes.
      next unless saved?(type) && will_save_change_to_attribute?(:"#{type}_choice")

      self.class.variant(brand, type, choice(type))
    rescue Error => e
      errors.add(:"#{type}_choice", e.message)
    end
  end

  def originals_allowed
    originals.each do |original|
      blob = original.blob
      errors.add(:originals, "#{blob.filename} is not an SVG, PNG, JPEG, PDF or ZIP") unless ORIGINAL_TYPES.key?(blob.content_type)
      errors.add(:originals, "#{blob.filename} is over #{MAX_ORIGINAL_BYTES / 1.megabyte} MB") if blob.byte_size > MAX_ORIGINAL_BYTES
    end
  end
end
