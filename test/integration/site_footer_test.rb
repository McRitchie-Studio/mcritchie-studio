require "test_helper"

# The site footer is what a visitor, or a carrier reviewing the studio's SMS
# registration, finds at the bottom of every public page: where the studio is,
# how to reach it, its privacy policy and terms, and a map.
class SiteFooterTest < ActionDispatch::IntegrationTest
  test "public pages end with the footer: address, legal links and a map" do
    [ root_path, about_path, privacy_path, terms_path, packages_path ].each do |path|
      get path
      assert_response :success, path

      assert_select "footer[data-site-footer]", { count: 1 }, "#{path}: one footer" do
        assert_select "address a[href*='google.com/maps/dir']", { text: /3000 Lawrence St\s*Denver, CO 80205/m, count: 1 },
                      "#{path}: the address, once, linking to directions"
        assert_select "a[href='#{privacy_path}']", { minimum: 1 }, "#{path}: privacy link"
        assert_select "a[href='#{terms_path}']", { minimum: 1 }, "#{path}: terms link"
        assert_select "a[href='/contact']", { text: "Contact", count: 1 }, "#{path}: contact link"
        assert_select "a[href='https://on.sprintful.com/alex-mcritchie'][target='_blank']", { text: "Schedule a call", count: 1 },
                      "#{path}: schedule link"
        assert_select "[data-footer-map][data-lat][data-lng]", { count: 1 }, "#{path}: map"
        assert_select "[data-footer-map] a[href*='google.com/maps']", { count: 1 }, "#{path}: map fallback link"
      end
    end
  end

  test "the Contact column lists email, scheduling, then the contact page, and no phone" do
    get root_path

    labels = css_select("footer[data-site-footer] nav[aria-label='Contact'] a").map { |link| [ link.text, link["href"] ] }
    assert_equal [ [ "team@mcritchie.studio", "mailto:team@mcritchie.studio" ],
                   [ "Schedule a call", "https://on.sprintful.com/alex-mcritchie" ],
                   [ "Contact", "/contact" ] ], labels
    assert_select "footer[data-site-footer] a[href^='tel:']", 0
    assert_select "footer[data-site-footer] nav[aria-label='Help']", 0
  end

  test "the Company column links Home and About, and shows Career disabled" do
    get root_path

    assert_select "footer[data-site-footer] nav[aria-label='Company']" do
      assert_select "a", 2
      assert_select "a[href='#{root_path}']", text: "Home"
      assert_select "a[href='#{about_path}']", text: "About"
      assert_select "span[aria-disabled='true']", text: "Career", count: 1
    end
  end

  test "the footer leads with social profiles" do
    get root_path

    assert_select "footer[data-site-footer] ul[aria-label='Social profiles']" do
      assert_select "a[href='https://www.linkedin.com/in/amcritchie/'][aria-label='LinkedIn']", 1
      assert_select "a[href='https://x.com/mcritchiealex'][aria-label='X']", 1
      assert_select "[aria-label='Instagram']", 1
    end
  end

  test "the landing page prints one address, the footer's" do
    get root_path

    assert_no_match(/Humboldt/, response.body)
  end

  test "a signed-in viewer keeps the footer on public pages and loses it on working ones" do
    log_in_as(users(:alex))

    get privacy_path
    assert_response :success
    assert_select "footer[data-site-footer]", 1

    get tasks_path
    assert_response :success
    assert_select "footer[data-site-footer]", 0
  end
end
