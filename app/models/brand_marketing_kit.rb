# frozen_string_literal: true

# ONE BRAND'S GOOGLE MARKETING KIT (task marketing-kit-on-logos; Alex McRitchie 2026-10-28): the Drive folder
# `bin/marketing-kit publish` builds from a kit spec (docs/agents/agents/alex/sops/marketing-kit.md), recorded the
# way BrandKitApp records a kit applied to an app.
#
#   brand               the kit's brand key (config/logo_brands.yml; brand_kits.brand). Not a foreign key: a brand's
#                       kit row is created on its first save, and a Google kit may come first.
#   drive_url           the kit's root folder (https://drive.google.com/…)
#   owner               the Google account that owns it (the spec's drive.subject, e.g. team@mcritchie.studio)
#   published_at, _by   when and by whom it was last published (`bin/rails logos:marketing_kit`)
#   published_saved_at  the brand kit's saved_at that publish carried
#
# #status reads it against the kit's saved_at, as BrandKitApp#status does:
#
#   :current  published, and the brand kit has not been saved since ("Up to date"). A brand whose logos were never
#             saved reads Up to date too: there is nothing newer to publish (BrandKitApp's Applied, the same way).
#   :changed  the brand kit was saved after the last publish ("Kit changed")
#
# A brand with no row has no Google kit (NONE_LABEL). Only the logos are watched: the kit's colours, words and photos
# live in its private spec, which the hub never sees.
class BrandMarketingKit < ApplicationRecord
  STATUSES = { current: "Up to date", changed: "Kit changed" }.freeze
  NONE_LABEL = "No Google kit"
  DRIVE_URL = %r{\Ahttps://drive\.google\.com/\S+\z}

  belongs_to :brand_kit, foreign_key: :brand, primary_key: :brand, optional: true, inverse_of: :marketing_kit

  validates :brand, presence: true, uniqueness: true
  validates :drive_url, format: { with: DRIVE_URL, message: "must be a https://drive.google.com/ link" }
  validates :owner, format: { with: /\A[a-z0-9._%+-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/, allow_blank: true }
  validates :published_by, length: { maximum: 200 }
  validate :brand_has_a_style

  # Every brand's Google kit for these brands, by brand: the /logos table reads them in one query.
  def self.by_brand(brands) = where(brand: brands).index_by(&:brand)

  # Records that `brand`'s Google kit, owned by `owner`, was published to `drive_url`: at `at` (now unless given), by `by`, carrying
  # `saved_at` (the brand kit's saved_at unless given). Creates the row if needed.
  def self.record_published!(brand:, drive_url:, by:, owner: nil, at: nil, saved_at: nil)
    kit = find_or_initialize_by(brand: brand.to_s)
    saved_at ||= BrandKit.find_by(brand: brand.to_s)&.saved_at
    kit.update!(drive_url:, owner: owner.presence&.downcase || kit.owner, published_at: at || Time.current,
                published_by: by, published_saved_at: saved_at)
    kit
  end

  # :current or :changed. `kit` is the brand's BrandKit (nil: never saved); it defaults to the association. Compared
  # to the second, as BrandKitApp#status is.
  def status(kit = brand_kit)
    kit_saved = kit&.saved_at or return :current
    published = published_saved_at || published_at or return :changed
    published.to_i >= kit_saved.to_i ? :current : :changed
  end

  def status_label(kit = brand_kit) = STATUSES.fetch(status(kit))

  private

  def brand_has_a_style
    errors.add(:brand, "is not a brand in config/logo_brands.yml") unless Logos::NavbarLogo.brands.include?(brand)
  end
end
