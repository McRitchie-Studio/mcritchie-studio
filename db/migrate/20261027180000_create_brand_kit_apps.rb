# frozen_string_literal: true

# WHICH APPS TAKE WHICH KIT, AND WHETHER THEY HAVE THE LATEST (task brand-kit-applied-status; Alex McRitchie
# 2026-10-27). Two parts, one migration so `down` undoes both:
#
#   brand_kits.saved_at   when a logo choice (icon, navbar, stacked) was last saved or cleared: the kit's VERSION.
#                         updated_at keeps moving on notes and originals, which no app installs. Backfilled from
#                         updated_at for every kit that has a saved choice (the best this data knows).
#   brand_kit_apps        a kit feeds many apps, an app may take many kits (Commercial Welding v1 and v2 both feed
#                         commercial-welding). `brand` is the kit's brand key (config/logo_brands.yml, brand_kits.brand);
#                         it is NOT a foreign key to brand_kits, because a brand's kit row is only created on its first
#                         save and a link may come first. `app_slug` is a slug FK to apps (cascade on rename/delete).
#                         used_at / used_by: when and by whom the kit was last applied to the app; applied_saved_at:
#                         the kit's saved_at that application carried (kit.json's saved_at), so BrandKitApp#status
#                         can tell Applied from Kit changed.
#
# SEED LINKS (LINKS): studio → mcritchie-studio, industries → mcritchie-industries, turf → turf-monster, welding and
# welding_v2 → commercial-welding. A link whose app row is missing is skipped and named on stdout. None is stamped
# applied EXCEPT the hub's own: its committed public/brand/kit.json is the install, and when its choices equal the
# studio kit row's, that kit version is provably what the hub serves, so its link is stamped with the kit's saved_at.
# Idempotent: ON CONFLICT DO NOTHING, and the hub stamp only fills a link that has no used_at.
class CreateBrandKitApps < ActiveRecord::Migration[8.1]
  LINKS = [%w[studio mcritchie-studio], %w[industries mcritchie-industries], %w[turf turf-monster],
           %w[welding commercial-welding], %w[welding_v2 commercial-welding]].freeze
  HUB_LINK = %w[studio mcritchie-studio].freeze
  HUB_MANIFEST = "public/brand/kit.json"
  STAMPED_BY = "migration: public/brand/kit.json matches the saved kit"

  def up
    add_column :brand_kits, :saved_at, :datetime
    execute(<<~SQL.squish)
      UPDATE brand_kits SET saved_at = updated_at
       WHERE icon_choice IS NOT NULL OR navbar_choice IS NOT NULL OR stacked_choice IS NOT NULL
    SQL

    create_table :brand_kit_apps do |t|
      t.string :brand, null: false
      t.string :app_slug, null: false
      t.datetime :used_at
      t.string :used_by
      t.datetime :applied_saved_at
      t.timestamps
    end
    add_index :brand_kit_apps, %i[brand app_slug], unique: true
    add_index :brand_kit_apps, :app_slug
    add_foreign_key :brand_kit_apps, :apps, column: :app_slug, primary_key: :slug, on_update: :cascade, on_delete: :cascade

    seed_links
  end

  def down
    drop_table :brand_kit_apps
    remove_column :brand_kits, :saved_at
  end

  # The seed links and the hub's stamp. Returns the app slugs it skipped (no apps row).
  def seed_links(manifest_path: Rails.root.join(HUB_MANIFEST))
    apps = connection.select_values("SELECT slug FROM apps WHERE slug IN (#{LINKS.map { |_, app| connection.quote(app) }.uniq.join(', ')})")
    skipped = []
    LINKS.each do |brand, app|
      next skipped << app unless apps.include?(app)

      execute(<<~SQL.squish)
        INSERT INTO brand_kit_apps (brand, app_slug, created_at, updated_at)
        VALUES (#{connection.quote(brand)}, #{connection.quote(app)}, NOW(), NOW())
        ON CONFLICT (brand, app_slug) DO NOTHING
      SQL
    end
    skipped.uniq.each { |app| say "skipped: no apps row for #{app}; its brand kit link was not seeded" }
    stamp_hub(manifest_path) if apps.include?(HUB_LINK.last)
    skipped.uniq
  end

  private

  # Stamps the hub's link applied when its committed kit.json carries exactly the studio kit's saved choices.
  def stamp_hub(manifest_path)
    return say("hub link left Not applied: no #{HUB_MANIFEST}") unless File.file?(manifest_path)

    manifest = JSON.parse(File.read(manifest_path))
    kit = connection.select_one("SELECT icon_choice, navbar_choice, stacked_choice, saved_at FROM brand_kits WHERE brand = #{connection.quote(HUB_LINK.first)}")
    return say("hub link left Not applied: no saved studio kit in this database") unless kit && kit["saved_at"]

    choices = %w[icon navbar stacked].to_h { |type| [type, decode(kit["#{type}_choice"])] }
    unless manifest["brand"] == HUB_LINK.first && choices.all? { |type, choice| manifest[type] == choice }
      return say("hub link left Not applied: #{HUB_MANIFEST} differs from the saved studio kit")
    end

    saved_at = connection.quote(kit["saved_at"])
    execute(<<~SQL.squish)
      UPDATE brand_kit_apps SET used_at = #{saved_at}, applied_saved_at = #{saved_at}, used_by = #{connection.quote(STAMPED_BY)}, updated_at = NOW()
       WHERE brand = #{connection.quote(HUB_LINK.first)} AND app_slug = #{connection.quote(HUB_LINK.last)} AND used_at IS NULL
    SQL
    say "hub link stamped Applied: #{HUB_MANIFEST} matches the studio kit saved #{kit['saved_at']}"
  end

  def decode(value) = value.is_a?(String) ? JSON.parse(value) : value
end
