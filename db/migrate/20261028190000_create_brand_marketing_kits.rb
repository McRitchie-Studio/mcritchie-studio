# frozen_string_literal: true

# WHICH BRANDS HAVE A GOOGLE MARKETING KIT, AND WHETHER IT HAS THE LATEST LOGOS (task marketing-kit-on-logos; Alex
# McRitchie 2026-10-28). One row per brand, the same convention as brand_kit_apps: `brand` is the kit's brand key
# (config/logo_brands.yml, brand_kits.brand), NOT a foreign key, because a brand's kit row is only created on its
# first save. drive_url is the kit's root folder in Drive and workspace the Google Workspace domain that owns it.
# published_at / published_by: when and by whom `bin/marketing-kit publish` last wrote it; published_saved_at: the
# brand kit's saved_at that publish carried, so BrandMarketingKit#status can tell Up to date from Kit changed.
#
# No seed rows: a kit's folder id is client data, and this repo is public. The marketing-kit SOP stamps each kit on
# production with `bin/rails logos:marketing_kit`.
class CreateBrandMarketingKits < ActiveRecord::Migration[8.1]
  def change
    create_table :brand_marketing_kits do |t|
      t.string :brand, null: false
      t.string :drive_url, null: false
      t.string :workspace
      t.datetime :published_at
      t.string :published_by
      t.datetime :published_saved_at
      t.timestamps
    end
    add_index :brand_marketing_kits, :brand, unique: true
  end
end
