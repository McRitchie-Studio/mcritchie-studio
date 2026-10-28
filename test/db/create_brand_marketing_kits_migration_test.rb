# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261028190000_create_brand_marketing_kits.rb").to_s

# [db] CreateBrandMarketingKits (task marketing-kit-on-logos): reversible, with one row per brand enforced by the
# database, not only the model.
class CreateBrandMarketingKitsMigrationTest < ActiveSupport::TestCase
  M = CreateBrandMarketingKits

  teardown { BrandMarketingKit.reset_column_information }

  def quietly(&) = capture_io { ActiveRecord::Migration.suppress_messages(&) }

  test "down then up: the table goes and comes back with its unique brand index" do
    quietly { M.new.migrate(:down) }
    refute ActiveRecord::Base.connection.table_exists?(:brand_marketing_kits)

    quietly { M.new.migrate(:up) }
    BrandMarketingKit.reset_column_information
    assert ActiveRecord::Base.connection.index_exists?(:brand_marketing_kits, :brand, unique: true)
    BrandMarketingKit.create!(brand: "studio", drive_url: "https://drive.google.com/drive/folders/a")
    assert_raises(ActiveRecord::RecordNotUnique) do
      BrandMarketingKit.new(brand: "studio", drive_url: "https://drive.google.com/drive/folders/b").save!(validate: false)
    end
  end
end
