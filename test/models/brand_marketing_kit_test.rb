# frozen_string_literal: true

require "test_helper"

# [unit] A brand's Google marketing kit (task marketing-kit-on-logos): Up to date while the brand kit is unchanged
# since the publish, Kit changed once its logos are saved again, read to the second as BrandKitApp#status is;
# record_published! creates or updates the one row per brand.
class BrandMarketingKitTest < ActiveSupport::TestCase
  URL = "https://drive.google.com/drive/folders/abc123"

  def gkit(**attrs) = BrandMarketingKit.create!({ brand: "welding_v2", drive_url: URL }.merge(attrs))

  test "status: Up to date until the brand kit is saved again, then Kit changed" do
    kit = BrandKit.create!(brand: "welding_v2", saved_at: Time.utc(2026, 10, 1))
    row = gkit(published_at: Time.utc(2026, 10, 2), published_saved_at: Time.utc(2026, 10, 1))
    assert_equal :current, row.status(kit)
    assert_equal "Up to date", row.status_label(kit)

    kit.update!(saved_at: Time.utc(2026, 10, 3))
    assert_equal :changed, row.reload.status
    assert_equal "Kit changed", row.status_label
  end

  test "the published version decides, to the second; without one, published_at does" do
    kit = BrandKit.create!(brand: "welding_v2", saved_at: Time.utc(2026, 10, 5, 12, 0, 0, 500_000))
    row = gkit(published_at: Time.utc(2026, 10, 6), published_saved_at: Time.utc(2026, 10, 4))
    assert_equal :changed, row.status(kit), "published after the save, but it carried the older kit"
    row.update!(published_saved_at: Time.utc(2026, 10, 5, 12))
    assert_equal :current, row.status(kit)

    row.update!(published_saved_at: nil, published_at: Time.utc(2026, 10, 4))
    assert_equal :changed, row.status(kit)
    row.update!(published_at: nil)
    assert_equal :changed, row.status(kit), "never stamped as published: not known to be current"
    assert_equal :current, row.status(nil), "a brand kit never saved has nothing newer"
  end

  test "record_published! creates or updates the brand's one row, carrying the kit's saved_at unless given" do
    BrandKit.create!(brand: "welding_v2", saved_at: Time.utc(2026, 10, 7))
    row = travel_to(Time.utc(2026, 10, 8)) do
      BrandMarketingKit.record_published!(brand: "welding_v2", drive_url: URL, workspace: "CommercialWelding.llc", by: "alex")
    end
    assert_equal [Time.utc(2026, 10, 8), "alex", Time.utc(2026, 10, 7), "commercialwelding.llc"],
                 [row.published_at, row.published_by, row.published_saved_at, row.workspace]

    again = BrandMarketingKit.record_published!(brand: "welding_v2", drive_url: "#{URL}x", by: "steffon",
                                                at: Time.utc(2026, 10, 9), saved_at: Time.utc(2026, 10, 6))
    assert_equal row.id, again.id
    assert_equal ["#{URL}x", "commercialwelding.llc"], [again.drive_url, again.workspace], "a blank workspace keeps the old one"
    assert_equal :changed, again.status
    assert_equal({ "welding_v2" => again }, BrandMarketingKit.by_brand(%w[welding_v2 studio]))
    assert_equal again, BrandKit.find_by!(brand: "welding_v2").marketing_kit
  end

  test "refuses a brand not on /logos, a link that is not Drive, a second row per brand and a bad workspace" do
    refute BrandMarketingKit.new(brand: "nike", drive_url: URL).valid?
    refute BrandMarketingKit.new(brand: "studio", drive_url: "https://evil.example/drive.google.com/x").valid?
    refute BrandMarketingKit.new(brand: "studio", drive_url: "javascript:alert(1)").valid?
    refute BrandMarketingKit.new(brand: "studio", drive_url: URL, workspace: "not a domain").valid?
    gkit
    refute BrandMarketingKit.new(brand: "welding_v2", drive_url: URL).valid?
  end
end
