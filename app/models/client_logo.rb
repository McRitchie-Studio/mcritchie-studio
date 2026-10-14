# frozen_string_literal: true

# A CLIENT'S OWN LOGO, as /stack and /stack/matrix draw it beside the client's
# name (task stack-matrix-client-logos). It is read from one place: the
# client's workspace's `logo:` in config/workspace_icons.yml, which names one
# of two sources.
#
#   logo: { brand: industries }               a brand of the logo studio
#                                             (config/logo_brands.yml): the
#                                             brand's KIT ICON, the one /logos
#                                             draws in its table — the saved
#                                             icon choice (BrandKit), else the
#                                             brand's Original art where it has
#                                             one, else Alt — in light and dark
#   logo: { file: client_logos/cyvasse.svg }  a mark filed in the hub's brand
#                                             assets (app/assets/images), for a
#                                             client the studio has no brand for
#                                             yet; copied in from the client
#                                             app's public/, never hot-linked
#
# A workspace with no `logo:` has no ClientLogo, and the page draws an empty
# ring. An entry that names an unknown brand or a missing file raises Error,
# and test/models/client_logo_test.rb walks every entry in the config.
class ClientLogo
  class Error < StandardError; end

  ASSETS = Rails.root.join("app/assets/images")
  TONES = Logos::NavbarLogo::BAKED

  attr_reader :slug, :brand, :file

  # The logo of each slug that has one, slug => ClientLogo; every brand kit is read in one query.
  def self.for_all(slugs)
    entries = slugs.to_h { |slug| [slug, WorkspaceIconConfig.logo(slug)] }.compact
    brands = entries.values.filter_map { |entry| entry["brand"] }
    kits = brands.any? ? BrandKit.where(brand: brands).index_by(&:brand) : {}
    entries.to_h { |slug, entry| [slug, new(slug, entry, kits:)] }
  end

  def self.for(slug) = for_all([slug])[slug]

  def initialize(slug, entry, kits: nil)
    @slug = slug
    @brand = entry["brand"]&.to_s
    @file = entry["file"]&.to_s
    raise Error, "#{slug}: a logo names a brand or a file, not both" if @brand && @file
    raise Error, "#{slug}: a logo needs a brand or a file, got #{entry.inspect[0, 80]}" unless @brand || @file

    @brand ? check_brand : check_file
    @kit = (kits&.fetch(@brand, nil) || BrandKit.new(brand: @brand)) if @brand
  end

  def source = brand ? :brand : :file

  # tone => the brand's kit icon as a Logos::Variant, for LogosHelper#logo_themed_images.
  # A saved icon choice the kit can no longer draw raises BrandKit::Error; the client
  # then shows the brand's default icon, as with nothing saved, the way
  # BrandKit#saved_variant drops an undrawable choice, so one bad kit never 500s /stack.
  def variants
    @variants ||= TONES.to_h { |tone| [tone, icon(tone)] }
  end

  private

  # The ErrorLog receipt is written once per logo, not per tone, so the broken kit
  # is on record without doubling its count.
  def icon(tone)
    @kit.variant(:icon, tone:)
  rescue BrandKit::Error => e
    ErrorLog.capture!(e) unless @kit_error_logged
    @kit_error_logged = true
    BrandKit.new(brand: @brand).variant(:icon, tone:)
  end

  def check_brand
    return if Logos::NavbarLogo.brands.include?(@brand)

    raise Error, "#{slug}: no logo brand #{@brand.inspect} in config/logo_brands.yml"
  end

  def check_file
    path = ASSETS.join(@file).expand_path
    raise Error, "#{slug}: a logo file is a path under app/assets/images, got #{@file.inspect}" unless path.to_s.start_with?("#{ASSETS}/")
    raise Error, "#{slug}: no logo file app/assets/images/#{@file}" unless path.file?
  end
end
