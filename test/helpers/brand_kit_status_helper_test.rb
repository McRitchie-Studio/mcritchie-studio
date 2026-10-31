# frozen_string_literal: true

require "test_helper"

# [unit] BrandKitStatusHelper (task logos-table-columns-tidy): each status's chip mark and the dates its tooltip gives.
class BrandKitStatusHelperTest < ActionView::TestCase
  test "every status maps to a mark: a check for done, a triangle for changed, a hollow ring for none" do
    expected = { applied: "done", current: "done", changed: "changed", not_applied: "none", none: "none" }
    expected.each do |status, mark|
      svg = Nokogiri::HTML5.fragment(kit_status_mark(status)).at_css("svg")
      assert_equal [mark, "true"], [svg["data-mark"], svg["aria-hidden"]], status
    end
    assert_includes kit_status_mark(:changed), "M8 1.75 14.75 13.75H1.25Z", "the changed mark is a triangle"
    assert_includes kit_status_mark(:none), "stroke-dasharray", "the none mark is a broken ring, not a filled one"
    assert_raises(KeyError) { kit_status_mark(:unknown) }
  end

  test "a link's and a Google kit's dates" do
    kit = BrandKit.new(brand: "studio", saved_at: Time.utc(2026, 10, 20))
    link = BrandKitApp.new(brand: "studio", app_slug: "turf-monster", used_at: Time.utc(2026, 10, 21), applied_saved_at: Time.utc(2026, 10, 20))
    assert_equal "Kit saved Oct 20, 2026; applied Oct 21, 2026 (kit of Oct 20, 2026)", kit_app_dates(link, kit)
    assert_equal "Kit never saved; not applied yet", kit_app_dates(BrandKitApp.new, nil)
    assert_equal "Kit never saved; published at an unknown time", marketing_kit_dates(BrandMarketingKit.new, nil)
  end
end
