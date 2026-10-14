require "application_system_test_case"

# [e2e] /integrations at phone, tablet and desktop width, light and dark: the page
# renders both groups and never scrolls sideways.
class IntegrationsPageTest < ApplicationSystemTestCase
  WIDTHS = [ 375, 768, 1280 ].freeze

  # A headless window will not shrink below about 500px, so the width is set by
  # device emulation: innerWidth is then the width under test, asserted below.
  teardown { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  test "[e2e] /integrations loads light and dark at 375, 768 and 1280 with no horizontal scroll" do
    %w[light dark].each do |theme|
      WIDTHS.each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 768)
        visit integrations_path
        page.execute_script("localStorage.setItem('theme', '#{theme}')")
        visit integrations_path

        assert_selector "[data-test='integration-group']", count: 3
        assert_equal width, page.evaluate_script("window.innerWidth"), "viewport is #{width}px"
        assert_equal theme == "dark", page.evaluate_script("document.documentElement.classList.contains('dark')"), "#{theme} at #{width}"
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert_operator overflow, :<=, 0, "#{theme} at #{width}px scrolls sideways by #{overflow}px"
        # Every card's button sits inside its card, wrapped below the price if it must.
        clipped = page.evaluate_script(<<~JS)
          [...document.querySelectorAll("[data-test='integration-entry']")].filter(card => {
            const c = card.getBoundingClientRect(), b = card.querySelector("[data-test='entry-cta']").getBoundingClientRect();
            return b.right > c.right + 0.5 || b.left < c.left - 0.5;
          }).map(card => card.dataset.entry)
        JS
        assert_empty clipped, "#{theme} at #{width}px: buttons overflow their cards"
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

  test "[e2e] at 1280 Integrations is one row of four and every section's cards in a row end level" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1280, height: 1000, deviceScaleFactor: 1, mobile: false)
    visit integrations_path

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
end
