# frozen_string_literal: true

# A BRAND'S KIT RECORD (epic brand-studio, piece 3; task brand-kit-record): what the
# operator has SAVED for one brand of config/logo_brands.yml, and the artwork its
# logos were derived from.
#
#   navbar_choice   the Navbar Logo the brand uses: {"rule" => 4, "text" => "second", "edits" => {...}}
#   stacked_choice  the Stacked Logo it uses:       {"form" => "tagline", "text" => "first", "edits" => {...}}
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

  TYPES = %i[navbar stacked].freeze
  # The keys a stored choice may carry, per type. `edits` may be absent (no edits).
  CHOICE_KEYS = { navbar: %w[rule text edits], stacked: %w[form text edits] }.freeze
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

  # Every saved record for these brands, by brand: the index table reads them all in one query.
  def self.by_brand(brands) = where(brand: brands).index_by(&:brand)

  # A stored choice as the Logos::Variant it draws in `tone` (light unless given). Anything the gallery's parser
  # refuses is an Error, and so are edits that cannot be drawn in the choice's rule or form.
  def self.variant(brand, type, choice, tone: :light)
    type = type.to_sym
    keys = CHOICE_KEYS.fetch(type) { raise Error, "a kit saves a navbar or a stacked choice, not #{type.inspect}" }
    unless choice.is_a?(Hash) && (choice.keys - keys).empty? && (keys - %w[edits]).all? { |key| choice.key?(key) }
      raise Error, "a #{type} choice is a map of #{keys.join(', ')}, got #{choice.inspect[0, 80]}"
    end

    edits = choice["edits"] || {}
    unless edits.is_a?(Hash) && edits.all? { |name, value| Logos::Variant::EDIT_PARAMS.key?(name.to_sym) && (value.is_a?(String) || value.is_a?(Integer)) }
      raise Error, "a #{type} choice's edits are the edit params (#{Logos::Variant::EDIT_PARAMS.keys.join(', ')}), got #{edits.inspect[0, 80]}"
    end

    logo = Logos::Variant.logo(brand, type)
    params = edits.to_h { |name, value| [name.to_sym, value.to_s] }
                  .merge(text: choice["text"].to_s, rule: choice["rule"]&.to_s, form: choice["form"]&.to_s, tone: tone.to_s).compact
    variant = Logos::Variant.parse(logo, params, type:)
    refusal = logo.refusal(variant.edits, **(type == :stacked ? { form: variant.form } : { rule: variant.rule }))
    raise Error, refusal if refusal

    variant
  end

  # A choice as it is stored: the variant's own choices and its checked, shown edits, in one spelling.
  def self.choice_of(variant)
    choice = variant.type == :stacked ? { "form" => variant.form.to_s } : { "rule" => variant.rule }
    edits = Logos::Variant.edit_params(variant.edits).to_h { |name, value| [name.to_s, value.to_s] }
    choice.merge("text" => variant.text.to_s, "edits" => edits)
  end

  def choice(type) = public_send(:"#{type}_choice")
  def saved?(type) = choice(type).present?

  # The saved choice for `type` as a Logos::Variant in `tone`, or the brand's default (DEFAULTS) when none is saved.
  def variant(type, tone: :light)
    type = type.to_sym
    return self.class.variant(brand, type, choice(type), tone:) if saved?(type)

    Logos::Variant.new(Logos::Variant.logo(brand, type), type:, tone:, **DEFAULTS.fetch(type))
  end

  # The text version the save form offers first: the saved one, else the default.
  def default_text(type) = saved?(type) ? choice(type)["text"].to_sym : DEFAULTS.fetch(type.to_sym).fetch(:text)

  # Reads `params` (strings, as a request gives them: rule or form, text, and the edit params) exactly as the gallery
  # does, and stores the choice they name. An Error says what was refused; nothing is stored then.
  def save_choice(type, params, by:)
    type = type.to_sym
    raise Error, "a kit saves a navbar or a stacked choice, not #{type.inspect}" unless TYPES.include?(type)

    keys = CHOICE_KEYS.fetch(type) - %w[edits]
    choice = keys.to_h { |key| [key, params[key.to_sym].presence] }
    raise Error, "a #{type} choice needs a #{keys.join(' and a ')}" if choice.values.any?(&:nil?)

    edits = Logos::Variant::EDIT_PARAMS.keys.to_h { |name| [name.to_s, params[name].to_s] }.reject { |_, value| value.empty? }
    variant = self.class.variant(brand, type, choice.merge("edits" => edits))
    self[:"#{type}_choice"] = self.class.choice_of(variant)
    self.updated_by = by
    save!
    variant
  end

  def clear_choice(type, by:)
    raise Error, "a kit saves a navbar or a stacked choice, not #{type.inspect}" unless TYPES.include?(type.to_sym)

    self[:"#{type}_choice"] = nil
    self.updated_by = by
    save!
  end

  # Adds uploaded files (ActionDispatch::Http::UploadedFile) as originals, each checked first: its type read from its
  # bytes, its size under the cap. One bad file refuses them all, with an Error that names it.
  def add_originals(files, by:)
    files = Array(files).compact_blank
    raise Error, "choose at least one file to upload" if files.empty?

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
      raise Error, "#{name} is not an SVG, PNG, JPEG, PDF or ZIP (its contents read as #{content_type})"
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

  def brand_has_a_style
    errors.add(:brand, "is not a brand in config/logo_brands.yml") unless Logos::NavbarLogo.brands.include?(brand)
  end

  def choices_drawable
    return unless Logos::NavbarLogo.brands.include?(brand)

    TYPES.each do |type|
      next unless saved?(type)

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
