require "test_helper"

# The site footer is what a visitor, or a carrier reviewing the studio's SMS
# registration, finds at the bottom of every public page: where the studio is,
# how to reach it, its privacy policy and terms, and a map.
#
# studio-engine renders it (`studio_site_footer`) from the facts in
# config/initializers/studio.rb. The engine's own suite proves its rules; this
# file proves THIS app's facts and THIS app's wiring: what the footer says, and
# which pages it is on.
class SiteFooterTest < ActionDispatch::IntegrationTest
  test "public pages end with the footer: address, legal links and a map" do
    [ root_path, about_path, schedule_index_path, privacy_path, terms_path, packages_path ].each do |path|
      get path
      assert_response :success, path

      assert_select "footer[data-site-footer]", { count: 1 }, "#{path}: one footer" do
        assert_select "address a[href*='google.com/maps/dir']", { text: /3000 Lawrence St\s*Denver, CO 80205/m, count: 1 },
                      "#{path}: the address, once, linking to directions"
        assert_select "a[href='#{privacy_path}']", { minimum: 1 }, "#{path}: privacy link"
        assert_select "a[href='#{terms_path}']", { minimum: 1 }, "#{path}: terms link"
        assert_select "a[href='/contact']", { text: "Contact", count: 1 }, "#{path}: contact link"
        # data-studio-booking is the marker the engine's popup script answers to.
        assert_select "a[href='#{schedule_index_path}'][data-booking-popup][data-studio-booking]",
                      { text: "Schedule a call", count: 1 }, "#{path}: schedule link"
        assert_select "[data-footer-map][data-lat='39.7614786'][data-lng='-104.978957']", { count: 1 }, "#{path}: map"
        assert_select "[data-footer-map] a[href*='google.com/maps']", { count: 1 }, "#{path}: map fallback link"
      end
    end
  end

  test "the address links to directions for that address" do
    get root_path

    assert_select "footer[data-site-footer] address a", 1 do |links|
      assert_equal "https://www.google.com/maps/dir/?api=1&destination=3000+Lawrence+St%2C+Denver%2C+CO+80205",
                   links.first["href"]
    end
  end

  test "the brand is the studio's logo, its two-line wordmark and its tagline" do
    get root_path

    assert_select "footer[data-site-footer] .ftr-brand" do
      assert_select "a[href='#{root_path}'] img[src*='logo-icon']", 1
      assert_select ".ftr-wordmark span", 2 do |parts|
        assert_equal %w[McRitchie Studio], parts.map(&:text)
      end
      assert_select "p", text: "Software & Marketing Solutions", count: 1
      # The email is a Contact column link, not a line under the tagline.
      assert_select "a[href^='mailto:']", 0
    end
  end

  test "the Solutions column links Packages and the App Builder" do
    get root_path

    links = css_select("footer[data-site-footer] nav[aria-label='Solutions'] a").map { |link| [ link.text, link["href"] ] }
    assert_equal [ [ "Packages", packages_path ], [ "Build an app", build_path ] ], links
  end

  test "the footer has four columns, in order, and ends on the legal line" do
    get root_path

    assert_equal %w[Contact Solutions Company Legal],
                 css_select("footer[data-site-footer] nav h2").map(&:text)
    assert_select "footer[data-site-footer] .ftr-legal" do
      assert_select "p", text: /Privacy Policy\s+·\s+Terms of Service/
      assert_select "p", text: "© #{Time.current.year} McRitchie Studio"
    end
  end

  # The map's Leaflet is the engine's, served through this app's asset
  # pipeline. The copy this app vendored under public/vendor is deleted, and a
  # page that still asked for it would have a map that never mounts.
  test "Leaflet comes from the engine's assets and nothing asks for the vendored copy" do
    [ root_path, privacy_path, schedule_index_path ].each do |path|
      get path

      assert_select "[data-footer-map]", 1 do |maps|
        assert_match %r{\A/assets/studio/leaflet-[0-9a-f]+\.js\z}, maps.first["data-leaflet-js"], path
        assert_match %r{\A/assets/studio/leaflet-[0-9a-f]+\.css\z}, maps.first["data-leaflet-css"], path
      end
      assert_not_includes response.body, "vendor/leaflet", path
    end
    assert_not File.exist?(Rails.root.join("public/vendor/leaflet-1.9.4")), "the vendored Leaflet must stay deleted"
  end

  # Two copies of the footer or booking scripts collide: each stands the other
  # down across a Turbo visit. The local copy guarded itself with unprefixed
  # names; the engine's are __studio*.
  #
  # The engine carries its copy one of two ways, and either is the engine's:
  # an inline script that opens with its guard, once per page, or an ES module
  # started by the controller its element names (data-studio-controller).
  ENGINE_FOOTER_SCRIPTS = {
    "__studioFooterMapsArmed" => "[data-footer-map][data-studio-controller~='footer-map']",
    "__studioBookingFramesArmed" => "dialog[data-booking-dialog][data-studio-controller~='booking']",
    "__studioBookingPopupArmed" => "dialog[data-booking-dialog][data-studio-controller~='booking']"
  }.freeze

  test "only the engine's footer and booking scripts are on the page" do
    get root_path

    %w[__footerMapsArmed __bookingFramesArmed __bookingPopupArmed].each do |local_guard|
      assert_not_includes response.body, "window.#{local_guard}", local_guard
    end
    ENGINE_FOOTER_SCRIPTS.each do |engine_guard, controlled_element|
      inline = response.body.scan("if (window.#{engine_guard}) return;").size
      as_module = css_select(controlled_element).size

      assert_operator inline, :<=, 1, "#{engine_guard}: the engine's inline script is on the page twice"
      assert inline == 1 || as_module == 1,
             "#{engine_guard}: the page carries neither the engine's inline script nor #{controlled_element}"
      assert_not inline == 1 && as_module == 1, "#{engine_guard}: the page carries the script both ways"
    end
    assert_empty Dir[Rails.root.join("app/views/footers/*")], "the local footer partials must stay deleted"
  end

  test "the Contact column lists email, scheduling, then the contact page, and no phone" do
    get root_path

    labels = css_select("footer[data-site-footer] nav[aria-label='Contact'] a").map { |link| [ link.text, link["href"] ] }
    assert_equal [ [ "team@mcritchie.studio", "mailto:team@mcritchie.studio" ],
                   [ "Schedule a call", schedule_index_path ],
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
      assert_select "a[href='https://www.instagram.com/alexmcritchie/'][aria-label='Instagram']", 1
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

  # The five controllers that are the public site keep the footer for a
  # signed-in viewer: landing, packages, build, contact_submissions, schedule.
  test "a signed-in viewer keeps the footer on each public-site controller" do
    log_in_as(users(:alex))

    [ root_path, about_path, terms_path, packages_path, packages_stack_path, build_path, contact_form_path,
      schedule_index_path ].each do |path|
      get path
      assert_response :success, path
      assert_select "footer[data-site-footer]", { count: 1 }, path
    end
  end

  test "a signed-in viewer's working pages carry no footer, no map and no booking popup" do
    log_in_as(users(:alex))

    [ tasks_path, agents_path ].each do |path|
      get path
      assert_response :success, path
      assert_select "footer[data-site-footer]", { count: 0 }, path
      assert_select "[data-footer-map]", { count: 0 }, path
      assert_select "dialog[data-booking-dialog]", { count: 0 }, path
    end
  end

  test "the configured list is exactly the public-site controllers" do
    assert_equal %w[landing packages build contact_submissions schedule], Studio.site_footer_controllers
  end
end
