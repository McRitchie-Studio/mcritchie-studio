# frozen_string_literal: true

# ONE BRAND KIT FEEDING ONE APP (task brand-kit-applied-status; Alex McRitchie 2026-10-27). A kit may feed many apps
# and an app may take many kits (Commercial Welding v1 and v2 both feed commercial-welding).
#
#   brand             the kit's brand key (config/logo_brands.yml; brand_kits.brand). Not a foreign key: a brand's kit
#                     row is created on its first save, and a link may come first (BrandKit.for draws its defaults).
#   app_slug          the app (apps.slug, FK, cascades)
#   used_at, used_by  when and by whom the kit was last applied to the app (`bin/rails logos:applied`)
#   applied_saved_at  the kit's saved_at that application carried: the version the app's kit.json names
#
# #status reads it against the kit's saved_at (BrandKit#saved_at, stamped by every saved or cleared logo choice):
#
#   :applied      applied, and the kit has not been saved since
#   :changed      the kit was saved after the app last applied it ("Kit changed")
#   :not_applied  never applied (no used_at)
#
# The brand-kit-rollout SOP (docs/agents/agents/alex/sops/brand-kit-rollout.md) is how a link moves to :applied.
class BrandKitApp < ApplicationRecord
  STATUSES = { applied: "Applied", changed: "Kit changed", not_applied: "Not applied" }.freeze

  belongs_to :app, foreign_key: :app_slug, primary_key: :slug, inverse_of: :brand_kit_apps
  belongs_to :brand_kit, foreign_key: :brand, primary_key: :brand, optional: true, inverse_of: :app_links

  validates :brand, presence: true, uniqueness: { scope: :app_slug }
  validates :used_by, length: { maximum: 200 }
  validate :brand_has_a_style

  # Every link for these brands, by brand, apps loaded: the /logos table reads them all in one query.
  def self.by_brand(brands) = where(brand: brands).includes(:app).order(:app_slug).group_by(&:brand)

  # Records that `brand`'s kit was applied to `app_slug`: at `at` (now unless given), by `by`, carrying `saved_at`
  # (the kit's saved_at unless given: pass the saved_at the app's live kit.json names). Creates the link if needed.
  def self.record_applied!(brand:, app_slug:, by:, at: nil, saved_at: nil)
    link = find_or_initialize_by(brand: brand.to_s, app_slug: app_slug.to_s)
    saved_at ||= BrandKit.find_by(brand: brand.to_s)&.saved_at
    link.update!(used_at: at || Time.current, used_by: by, applied_saved_at: saved_at)
    link
  end

  # :applied, :changed or :not_applied. `kit` is the brand's BrandKit (nil: never saved), passed so a table of links
  # reads their kits once; it defaults to the association. Compared to the second: kit.json carries ISO 8601 seconds.
  def status(kit = brand_kit)
    return :not_applied if used_at.nil?

    kit_saved = kit&.saved_at or return :applied
    applied = applied_saved_at || used_at
    applied.to_i >= kit_saved.to_i ? :applied : :changed
  end

  def status_label(kit = brand_kit) = STATUSES.fetch(status(kit))

  private

  def brand_has_a_style
    errors.add(:brand, "is not a brand in config/logo_brands.yml") unless Logos::NavbarLogo.brands.include?(brand)
  end
end
