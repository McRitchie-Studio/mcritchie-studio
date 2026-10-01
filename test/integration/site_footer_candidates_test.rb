require "test_helper"

# /footers stacks the candidate site footers. Whichever one wins, a footer
# owes the visitor the same things: where the studio is, how to call it, the
# privacy policy and terms, and a map. Each candidate is held to that here.
class SiteFooterCandidatesTest < ActionDispatch::IntegrationTest
  VARIANTS = %w[blueprint map-stage terminal mile-high postcard directory].freeze

  test "the preview is public and stacks every candidate" do
    get footers_path

    assert_response :success
    assert_equal VARIANTS, css_select("footer[data-footer]").map { |footer| footer["data-footer"] }
  end

  test "every candidate carries the address, phone, legal links and a live map" do
    get footers_path

    VARIANTS.each do |variant|
      assert_select "footer[data-footer='#{variant}']" do
        assert_select "address", { text: /3000 Lawrence St/, count: 1 }, "#{variant}: street, once"
        assert_select "address", text: /Denver, CO 80205/, message: "#{variant}: city line"
        assert_select "a[href='tel:+13032222113']", { minimum: 1 }, "#{variant}: phone link"
        assert_select "a[href='#{privacy_path}']", { minimum: 1 }, "#{variant}: privacy link"
        assert_select "a[href='#{terms_path}']", { minimum: 1 }, "#{variant}: terms link"
        assert_select "[data-footer-map][data-lat][data-lng]", { count: 1 }, "#{variant}: map"
        assert_select "[data-footer-map] a[href*='google.com/maps']", { count: 1 }, "#{variant}: map fallback link"
      end
    end
  end

  test "the directory footer leads with social profiles, not a second address" do
    get footers_path

    assert_select "footer[data-footer='directory'] ul[aria-label='Social profiles']" do
      assert_select "a[href='https://www.linkedin.com/in/amcritchie/'][aria-label='LinkedIn']", 1
      assert_select "a[href='https://x.com/mcritchiealex'][aria-label='X']", 1
      assert_select "[aria-label='Instagram']", 1
    end
  end
end
