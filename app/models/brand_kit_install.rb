# frozen_string_literal: true

# A BRAND'S KIT, INSTALLED INTO AN APP (task studio-adopts-its-kit; Alex McRitchie 2026-10-14: "migrate the MS kit to the actual
# application"). The rollout step that writes a kit's files into an app's public/brand/, so the app draws its logo
# from the saved kit and never from a hand-made copy:
#
#   bin/rails logos:install BRAND=studio                                  this app's public/brand/
#   bin/rails logos:install BRAND=turf DEST=../turf-monster/public/brand  another app's
#
# Each file is BrandKitExport#svg, byte for byte: the same bytes /logos/:brand/kit/<file> serves for the kit record in
# THIS database. A file whose bytes are already right is not rewritten, so a second install changes nothing.
# Beside the files, kit.json records what they were drawn from (the brand and its three choices, null for a default)
# and the kit's saved_at (ISO 8601, UTC; null for a kit never saved), so a later reader can tell which saved kit the
# committed files are, a test can redraw them to check, and the brand-kit-rollout SOP can read an app's live
# /brand/kit.json to record the version it serves (`bin/rails logos:applied`, BrandKitApp).
class BrandKitInstall
  MANIFEST = "kit.json"

  Result = Struct.new(:written, :unchanged, :refused, keyword_init: true)

  attr_reader :kit, :dest

  def initialize(kit, dest:)
    @kit = kit
    @dest = Pathname(dest)
  end

  def self.default_dest = Rails.root.join("public/brand")

  # The manifest's content: the brand, each choice as stored (nil where the brand's default is drawn), the kit's
  # saved_at to the second, and the brand's type scale as the four studio-engine settings an app sets from it
  # (Logos::TypeScale#engine_settings; task brand-kit-carries-type-scale). The type scale is read from the brand's
  # typefaces, not the saved record, so it carries no version of its own.
  def self.manifest_for(kit)
    { "brand" => kit.brand }.merge(BrandKit::CHOICE_TYPES.to_h { |type| [type.to_s, kit.choice(type)] })
                            .merge("saved_at" => kit.saved_at&.utc&.iso8601,
                                   "type_scale" => Logos::TypeScale.new(Logos::BrandKit.new(kit.brand)).engine_settings)
  end

  # An unsaved BrandKit holding what a kit.json names (its choices and saved_at), to install a kit another database
  # holds (production's, read with .manifest_for there). An ArgumentError when it names another brand, or a choice
  # the brand cannot draw.
  def self.kit_from_manifest(json, brand:)
    manifest = JSON.parse(json)
    raise ArgumentError, "it names brand #{manifest['brand'].inspect}, not #{brand.inspect}" unless manifest["brand"] == brand.to_s && Logos::NavbarLogo.brands.include?(brand.to_s)

    kit = BrandKit.new(brand: brand.to_s, saved_at: manifest["saved_at"] && Time.iso8601(manifest["saved_at"]),
                       **BrandKit::CHOICE_TYPES.to_h { |type| [:"#{type}_choice", manifest[type.to_s]] })
    BrandKit::CHOICE_TYPES.each { |type| BrandKit.variant(kit.brand, type, kit.choice(type)) if kit.saved?(type) }
    kit
  rescue BrandKit::Error => e
    raise ArgumentError, e.message
  end

  # Writes every file the kit draws, and the manifest. Returns which were written, which were already right, and
  # which the brand's data cannot draw (name => why); a refused file is left as it was.
  def call
    FileUtils.mkdir_p(dest)
    export = BrandKitExport.new(kit, base_url: "")
    files = export.drawings[:drawn].transform_values(&:svg)
    files[MANIFEST] = "#{JSON.pretty_generate(self.class.manifest_for(kit))}\n"

    written, unchanged = files.keys.partition { |name| write_if_changed(dest.join(name), files.fetch(name)) }
    Result.new(written:, unchanged:, refused: export.drawings[:refused])
  end

  private

  # True when the file was (re)written.
  def write_if_changed(path, bytes)
    return false if path.file? && path.binread == bytes.b

    path.binwrite(bytes)
    true
  end
end
