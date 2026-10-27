require "application_system_test_case"
require "support/google_connect_fakes"
require "support/fathom_connect_fakes"

# [e2e] /integrations at phone, tablet and desktop width, light and dark: the page
# renders both groups and never scrolls sideways. Every system test signs in as
# the admin, so the Google section carries Connect Google (the OAuth client set
# here) and its three cards carry no contact-form Connect, nor does the Fathom
# card (its OAuth app set here too), which carries Connect Fathom instead.
class IntegrationsPageTest < ApplicationSystemTestCase
  include GoogleConnectFakes
  include FathomConnectFakes

  GOOGLE_CARDS = %w[google_calendar gmail google_drive].freeze
  # The admin's cards whose real Connect replaces the contact-form one, in page order.
  CONNECTION_CARDS = (GOOGLE_CARDS + %w[fathom]).freeze
  WIDTHS = [ 375, 768, 1280 ].freeze

  # A headless window will not shrink below about 500px, so the width is set by
  # device emulation: innerWidth is then the width under test, asserted below.
  teardown { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  test "[e2e] /integrations loads light and dark at 375, 768 and 1280 with no horizontal scroll" do
    with_connect_env { with_fathom_env { assert_no_sideways_scroll } }
  end

  def assert_no_sideways_scroll
    %w[light dark].each do |theme|
      WIDTHS.each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 768)
        visit integrations_path
        page.execute_script("localStorage.setItem('theme', '#{theme}')")
        visit integrations_path

        assert_selector "[data-test='integration-group']", count: 5
        assert_equal width, page.evaluate_script("window.innerWidth"), "viewport is #{width}px"
        assert_equal theme == "dark", page.evaluate_script("document.documentElement.classList.contains('dark')"), "#{theme} at #{width}"
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert_operator overflow, :<=, 0, "#{theme} at #{width}px scrolls sideways by #{overflow}px"
        # Every card's button sits inside its card, wrapped below the price if it
        # must. The admin's Google and Fathom cards have none: their Connect is above.
        without = page.evaluate_script(<<~JS)
          [...document.querySelectorAll("[data-test='integration-entry']")].filter(card => !card.querySelector("[data-test='entry-cta']")).map(card => card.dataset.entry)
        JS
        assert_equal CONNECTION_CARDS, without, "#{theme} at #{width}px: only the admin's Google and Fathom cards drop their CTA"
        clipped = page.evaluate_script(<<~JS)
          [...document.querySelectorAll("[data-test='integration-entry']")].filter(card => {
            const cta = card.querySelector("[data-test='entry-cta']");
            if (!cta) return false;
            const c = card.getBoundingClientRect(), b = cta.getBoundingClientRect();
            return b.right > c.right + 0.5 || b.left < c.left - 0.5;
          }).map(card => card.dataset.entry)
        JS
        assert_empty clipped, "#{theme} at #{width}px: buttons overflow their cards"
        row = page.evaluate_script(<<~JS)
          (() => { const r = document.querySelector("[data-test='google-connect-all']").getBoundingClientRect(),
                   b = document.querySelector("[data-test='google-connect-all-button']").getBoundingClientRect();
                   return b.left >= r.left - 0.5 && b.right <= r.right + 0.5; })()
        JS
        assert row, "#{theme} at #{width}px: Connect Google spills out of its row"
      end
    end
  end

  test "[e2e] a card's Connect opens the contact form prefilled, carrying where it came from" do
    visit integrations_path
    within("[data-test='integration-entry'][data-entry='github_org']") { click_on "Connect" }

    assert_current_path(/\A\/contact\?/)
    assert_field "contact_submission[message]", with: "I'd like to connect GitHub."
    hidden = all("[data-test='contact-source']", visible: :all).to_h { |input| [ input["data-source-key"], input.value ] }
    assert_equal({ "page" => "integrations", "item" => "github_org", "intent" => "connect", "ref" => "/integrations" }, hidden)
    assert_selector "[data-test='contact-consent'] input[type='checkbox']:checked", count: 0
  end

  test "[e2e] signed out, a Google card's Connect opens the sign-in modal, not the contact form" do
    visit logout_path
    visit integrations_path
    assert_no_selector "[data-test='user-menu'], [data-test='google-connection']" # the control: signed out, no real Connect
    within("[data-test='integration-entry'][data-entry='gmail']") { click_on "Connect" }

    assert_selector "[data-test='auth-modal']", text: "Sign in to connect Google"
    assert_current_path integrations_path
  end

  test "[e2e] at 1280 Integrations is one row of four and every section's cards in a row end level" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1280, height: 1000, deviceScaleFactor: 1, mobile: false)
    with_connect_env { visit integrations_path }
    assert_selector "[data-test='integration-group'][data-group='google_sign_in'] [data-test='google-connect-all']", count: 1 # the control: the row is there

    rows = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("[data-test='integration-group']")].map(group => {
        const byTop = {};
        group.querySelectorAll("[data-test='integration-entry']").forEach(card => {
          const r = card.getBoundingClientRect();
          (byTop[Math.round(r.top)] ||= []).push(Math.round(r.height));
        });
        return [group.dataset.group, Object.values(byTop)];
      })
    JS
    rows.each do |group, heights|
      heights.each { |row| assert_equal 1, row.uniq.size, "#{group}: cards in a row differ in height #{row}" }
      assert_operator heights.first.size, :<=, 4, group
    end
    assert_equal [ [ 4 ] ], [ rows.to_h.fetch("integrations").map(&:size) ], "Integrations is exactly one row of four"
    assert_equal [ 3 ], rows.to_h.fetch("google_sign_in").map(&:size), "Connect Google sits above the Google cards, not in their row"
  end

  test "[e2e] Discord's Connect opens its guide, whose request opens the contact form prefilled" do
    visit integrations_path
    within("[data-test='integration-entry'][data-entry='discord']") { click_on "Connect" }

    assert_current_path integrations_discord_path
    assert_text "Give your agents a home in Discord"
    click_on "Request the Discord bot"

    assert_current_path(/\A\/contact\?/)
    assert_field "contact_submission[message]", with: "I'd like to connect Discord."
    hidden = all("[data-test='contact-source']", visible: :all).to_h { |input| [ input["data-source-key"], input.value ] }
    assert_equal({ "page" => "integrations/discord", "item" => "discord", "intent" => "connect", "ref" => "/integrations/discord" }, hidden)
  end

  test "[e2e] the Discord guide has no sideways scroll at 375 and 1280, light and dark" do
    %w[light dark].each do |theme|
      [ 375, 1280 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 768)
        visit integrations_discord_path
        page.execute_script("localStorage.setItem('theme', '#{theme}')")
        visit integrations_discord_path

        assert_equal width, page.evaluate_script("window.innerWidth")
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert_operator overflow, :<=, 0, "#{theme} at #{width}px scrolls sideways by #{overflow}px"
      end
    end
  end

  test "[e2e] the numbered setup guide shows every step and its drawing inside its card at 375 and 1280, light and dark" do
    %w[light dark].each do |theme|
      [ 375, 1280 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 768)
        visit integrations_discord_path
        page.execute_script("localStorage.setItem('theme', '#{theme}')")
        visit integrations_discord_path

        assert_equal theme == "dark", page.evaluate_script("document.documentElement.classList.contains('dark')"), "#{theme} at #{width}"
        assert_selector "[data-test='setup-step']", count: 7
        assert_selector "[data-test='step-visual']", count: 7, visible: true
        assert_selector "[data-test='step-help-link'][target='_blank']", count: 5
        assert_text "Allow anyone to @mention this role"
        # Each drawing sits inside its step's card, side by side at desktop and stacked on a phone.
        boxes = page.evaluate_script(<<~JS)
          Array.from(document.querySelectorAll("[data-test='setup-step']")).map((step) => {
            const card = step.getBoundingClientRect();
            const visual = step.querySelector("[data-test='step-visual']").getBoundingClientRect();
            const text = step.querySelector("h3").getBoundingClientRect();
            return { inside: visual.left >= card.left && visual.right <= card.right + 0.5, beside: visual.top < text.bottom }
          })
        JS
        assert boxes.all? { |box| box["inside"] }, "#{theme} at #{width}: a drawing spills out of its card #{boxes}"
        expected_beside = width >= 768
        assert boxes.all? { |box| box["beside"] == expected_beside }, "#{theme} at #{width}: drawings #{expected_beside ? "beside" : "below"} the text #{boxes}"
      end
    end
  end

  # --- A viewer connects their own Google (/tasks/every-user-connects-google) ---

  def sign_in_as_viewer
    visit logout_path
    sign_in_through_magic_link(users(:viewer))
  end

  def google_slot(card) = "[data-test='integration-entry'][data-entry='#{card}'] [data-test='entry-method'][data-method='sign_in'] [data-test='google-connection']"

  test "[e2e] a viewer sees Connect on each Google card, connects Calendar, sees the account, then disconnects it" do
    sign_in_as_viewer
    GoogleConnect::OAuthClient.sign_in_stand_in = GoogleConnectStandIn::SignIn.new
    store_google(email: "household@example.com", scope: "openid #{CALENDAR}") # the admin's, which a viewer never sees
    visit integrations_path

    GOOGLE_CARDS.each do |card|
      assert_selector "#{google_slot(card)}[data-state='none'] [data-test='google-connect']"
      assert_no_selector "[data-test='integration-entry'][data-entry='#{card}'] [data-test='entry-cta']"
    end
    assert_no_text "household@example.com"

    within(google_slot("google_calendar")) { click_on "Connect Google Calendar" }

    assert_current_path integrations_path
    assert_text "Google Calendar connected for #{GoogleConnectStandIn::EMAIL}."
    assert_selector "#{google_slot('google_calendar')}[data-state='connected']", text: "Connected as #{GoogleConnectStandIn::EMAIL}"
    assert_selector "#{google_slot('gmail')}[data-state='none']"
    assert_equal users(:viewer), GoogleConnection.find_by!(email: GoogleConnectStandIn::EMAIL).user
    assert_equal "household@example.com", GoogleConnection.for(:calendar).email, "the agent reader still answers the household's"

    accept_confirm { within(google_slot("google_calendar")) { click_on "Disconnect" } }

    assert_text "Google Calendar disconnected"
    assert_selector "#{google_slot('google_calendar')}[data-state='none']"
    assert_nil GoogleConnection.find_by(email: GoogleConnectStandIn::EMAIL)
  ensure
    reset_google_connect
  end

  test "[e2e] a viewer's /integrations has no sideways scroll at 375 and 1280, light and dark" do
    sign_in_as_viewer
    GoogleConnect::OAuthClient.sign_in_stand_in = GoogleConnectStandIn::SignIn.new
    %w[light dark].each do |theme|
      [ 375, 1280 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 768)
        visit integrations_path
        page.execute_script("localStorage.setItem('theme', '#{theme}')")
        visit integrations_path

        assert_selector "[data-test='google-connect-all'][data-state='none']"
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert_operator overflow, :<=, 0, "#{theme} at #{width}px scrolls sideways by #{overflow}px"
      end
    end
  ensure
    reset_google_connect
  end

  # --- Gmail needs a Workspace admin's OK (/tasks/google-verification-readiness) ---

  test "[system] signed in, clicking Connect Gmail opens the admin modal, the copy button copies the client ID, Continue lands on the connect route" do
    sign_in_as_viewer
    with_connect_env do
      GoogleConnect::OAuthClient.sign_in_stand_in = GoogleConnectStandIn::SignIn.new
      page.driver.browser.execute_cdp("Browser.grantPermissions", permissions: %w[clipboardReadWrite clipboardSanitizedWrite])
      visit integrations_path

      within(google_slot("gmail")) { click_on "Connect Gmail" }

      assert_current_path integrations_path # the control: no trip to Google yet
      modal = find("[data-test='gmail-admin-modal']")
      assert_text "Gmail needs your Google admin's OK"
      within(modal) do
        assert_selector "[data-test='gmail-admin-steps'] li", count: 4
        assert_text "Manage Third-Party App Access"
        assert_text "personal @gmail.com"
        assert_selector "[data-test='gmail-admin-client-id']", text: "test-connect-id"
        mailto = find("[data-test='gmail-admin-email']")["href"]
        assert mailto.start_with?("mailto:?subject="), mailto
        assert_includes CGI.unescape(mailto), "test-connect-id"
        assert_includes CGI.unescape(mailto), "Choose Trusted"

        find("[data-test='gmail-admin-copy']").click
        assert_selector "[data-test='gmail-admin-copy']", text: "Copied"
      end
      assert_equal "test-connect-id", page.evaluate_async_script("navigator.clipboard.readText().then(arguments[0])")

      click_on "Not now"
      assert_no_selector "[data-test='gmail-admin-modal']"

      within(google_slot("gmail")) { click_on "Connect Gmail" }
      within("[data-test='gmail-admin-modal']") { click_on "Continue to Google" }

      assert_current_path integrations_path
      assert_text "Gmail connected for #{GoogleConnectStandIn::EMAIL}."
      assert_selector "#{google_slot('gmail')}[data-state='connected']"
    end
  ensure
    reset_google_connect
  end

  test "[system] signed in, Drive's Connect still goes straight to Google with no admin modal" do
    sign_in_as_viewer
    with_connect_env do
      GoogleConnect::OAuthClient.sign_in_stand_in = GoogleConnectStandIn::SignIn.new
      visit integrations_path
      within(google_slot("google_drive")) { click_on "Connect Google Drive" }

      assert_text "Google Drive connected for #{GoogleConnectStandIn::EMAIL}."
      assert_no_selector "[data-test='gmail-admin-modal']"
    end
  ensure
    reset_google_connect
  end
end
