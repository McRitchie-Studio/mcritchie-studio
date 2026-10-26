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
# Beside the files, kit.json records what they were drawn from (the brand and its three choices, null for a default),
# so a later reader can tell which saved kit the committed files are, and a test can redraw them to check.
class BrandKitInstall
  MANIFEST = "kit.json"

  Result = Struct.new(:written, :unchanged, :refused, keyword_init: true)

  attr_reader :kit, :dest

  def initialize(kit, dest:)
    @kit = kit
    @dest = Pathname(dest)
  end

  def self.default_dest = Rails.root.join("public/brand")

  # The manifest's content: the brand and each choice as stored (nil where the brand's default is drawn).
  def self.manifest_for(kit)
    { "brand" => kit.brand }.merge(BrandKit::CHOICE_TYPES.to_h { |type| [type.to_s, kit.choice(type)] })
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
