require "test_helper"

# /footers stacks the five candidate site footers. Whichever one wins, a footer
# owes the visitor the same things: where the studio is, how to call it, the
# privacy policy and terms, and a map. Each candidate is held to that here.
class SiteFooterCandidatesTest < ActionDispatch::IntegrationTest
  VARIANTS = %w[blueprint map-stage terminal mile-high postcard].freeze

  test "the preview is public and stacks all five candidates" do
    get footers_path

    assert_response :success
    assert_equal VARIANTS, css_select("footer[data-footer]").map { |footer| footer["data-footer"] }
  end

  test "every candidate carries the address, phone, legal links and a live map" do
    get footers_path

    VARIANTS.each do |variant|
      assert_select "footer[data-footer='#{variant}']" do
        assert_select "address", text: /3000 Lawrence St/, message: "#{variant}: street"
        assert_select "address", text: /Denver, CO 80205/, message: "#{variant}: city line"
        assert_select "a[href^='tel:+1']", { minimum: 1 }, "#{variant}: phone link"
        assert_select "a[href='#{privacy_path}']", { minimum: 1 }, "#{variant}: privacy link"
        assert_select "a[href='#{terms_path}']", { minimum: 1 }, "#{variant}: terms link"
        assert_select "[data-footer-map][data-lat][data-lng]", { count: 1 }, "#{variant}: map"
        assert_select "[data-footer-map] a[href*='google.com/maps']", { count: 1 }, "#{variant}: map fallback link"
      end
    end
  end
end
