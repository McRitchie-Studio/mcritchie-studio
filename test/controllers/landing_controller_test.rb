require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  test "landing page renders for anonymous visitors" do
    get root_path

    assert_response :success
  end

  test "landing page renders acquisition-focused hero and about copy" do
    get root_path

    assert_response :success
    # Hero
    assert_includes response.body, "Solutions For"
    assert_includes response.body, "Families"
    assert_includes response.body, "An acquisition entrepreneur partnering with owners"
    # About
    assert_includes response.body, "Acquisition Entrepreneur"
    assert_includes response.body, "Over a decade of operational"
    # Cards
    assert_includes response.body, "Originating and scaling new business"
    assert_includes response.body, "Technical Architecture"
    assert_includes response.body, "Product and engineering design, development"
    # the consultant-era copy must not return
    assert_not_includes response.body, "supercharge your team"
    assert_not_includes response.body, "Ten years' experience"
    assert_not_includes response.body, "Technical Strategy"
  end

  # The hero scrim follows the theme: --color-page shades the photo dark in
  # dark mode and tints it pale in light mode, where the headline is dark text
  # (/tasks/hero-light-mode-tint).
  test "hero scrim takes the page colour token, not a fixed navy" do
    get root_path

    assert_response :success
    assert_select "[data-hero-scrim]", 1 do |scrims|
      style = scrims.first["style"]
      assert_includes style, "var(--color-page)"
      assert_not_includes style, "rgba(26, 21, 53"
    end
  end

  # The hero's call to action is the /build funnel, in the rainbow glow (Alex McRitchie,
  # 2026-10-19; /tasks/landing-build-ctas). It stands alone: the Meet Alex link
  # was dropped (Alex, 2026-10-20; /tasks/drop-hero-meet-alex).
  test "hero CTA is Build Your App to /build in the rainbow glow" do
    get root_path

    assert_response :success
    assert_select "span.cta-glow.cta-glow-rainbow[data-test='hero-build-glow']", 1 do
      assert_select "> a.btn.btn-primary[href='#{build_path}']", text: "Build Your App"
    end
    assert_select "[data-test='hero-meet-alex']", 0, "the hero has no Meet Alex link"
    assert_select "a", text: "Meet Alex", count: 0
    assert_select "section#about", 1, "the About section still renders"
  end

  # Was "shows only the full-width video chat card", pinning the "Chat Over
  # Video" heading. That card held the Sprintful widget; the section now holds
  # the Google booking frame and no card heading (/tasks/professional-site-footer).
  test "get in touch section shows the booking frame and no chat card" do
    get root_path

    assert_response :success
    assert_includes response.body, "Get in Touch"
    assert_select "iframe[data-booking-frame]", 1
    assert_not_includes response.body, "Chat Over Video"
    assert_not_includes response.body, "Chat Right Now"
  end

  # The home page's own "Get In Touch" section is gone; the site footer carries
  # these links now, and the same handles are pinned there.
  test "the home page links to the correct social profiles" do
    get root_path

    assert_response :success
    assert_select "a[href=?]", "https://www.linkedin.com/in/amcritchie/"
    assert_select "a[href=?]", "https://x.com/mcritchiealex"
    # The stale "alexmcritchie" LinkedIn and X handles must not come back. Scoped
    # to those two hosts: on Instagram, "alexmcritchie" IS the right handle.
    assert_select "a[href*='linkedin.com'][href*='alexmcritchie']", 0
    assert_select "a[href*='x.com'][href*='alexmcritchie']", 0
    assert_select "a[href*='twitter.com'][href*='alexmcritchie']", 0
  end

  test "pwa manifest renders the corrected app name" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "McRitchie Studio", manifest["name"]
    assert_equal "McRitchie Studio.", manifest["description"]
  end

  # [component] /privacy carries the Google User Data section Google's OAuth
  # verification reviews: what each permission reads, the never-list, how to
  # disconnect, and the Limited Use sentence, verbatim, linking the policy.
  test "[component] /privacy renders the Google user data section and the Limited Use link" do
    get privacy_path

    section = css_select("[data-test='google-user-data']").first
    assert section, "the Google User Data section renders"
    text = section.text.squish
    [ "Google Calendar", "Gmail", "Google Drive", "read only", "do not sell Google data", "advertising",
      "train or improve generalized artificial intelligence or machine learning models", "stored encrypted",
      "myaccount.google.com/permissions", "revoke the token with Google and delete it" ].each { assert_includes text, _1 }
    assert_includes section.at_css("[data-test='google-limited-use']").text.squish,
                    "McRitchie Studio's use and transfer to any other app of information received from Google APIs will adhere to the Google API Services User Data Policy, including the Limited Use requirements."
    assert_equal "https://developers.google.com/terms/api-services-user-data-policy", section.at_css("[data-test='google-limited-use-link']")["href"]
    assert section.at_css("a[href='/integrations']"), "disconnect points at /integrations"
  end

  # [component] drive-files-you-pick: the Drive line says a new connection reads
  # only the files the person chooses, and stays true for a legacy drive.readonly
  # one (every file, until it reconnects). Nothing claims a scope can't write.
  test "[component] /privacy narrows Drive to the files you choose and keeps the legacy line true" do
    get privacy_path

    drive = css_select("[data-test='google-drive-use']").first.text.squish
    assert_includes drive, "only the files you choose"
    assert_includes drive, "we can open only those files"
    assert_includes drive, "older read-only permission, which covers every file in your Drive, until you reconnect"
    refute_includes css_select("[data-test='google-user-data']").text.squish, "nothing we ask Google for can send, change or delete"
  end

  # [component] /privacy doubles as the Messaging Terms and Conditions a carrier
  # reads when it reviews the SMS registration. Each line below is one they check.
  test "privacy page is the combined privacy policy and messaging terms" do
    get privacy_path

    assert_response :success
    assert_select "h1", text: "Privacy Policy and Messaging Terms and Conditions"
    assert_includes response.body, "Last updated: October 27, 2026"
    text = css_select("[data-test='privacy-page']").text.squish
    assert_includes text, "McRitchie Studio LLC (doing business as McRitchie Studio)"
    assert_includes text, "3000 Lawrence St, Denver, CO 80205"
    assert_includes text, "mobile phone number"
    assert_select "[data-test='privacy-page'] a[href='/contact']"
    assert_select "a[href='mailto:alex@mcritchie.studio']"
  end

  test "privacy page states the text message program terms" do
    get privacy_path

    terms = css_select("[data-test='messaging-terms']").text.squish
    assert_includes terms, "(303) 222-2113"
    assert_includes terms, "Customer care messages"
    assert_includes terms, "Marketing messages"
    assert_includes terms, "Consent is not a condition of purchase"
    assert_includes terms, "Message frequency varies"
    assert_includes terms, "Message and data rates may apply"
    assert_includes terms, "We send general conversational messaging to answer questions and provide support to customers, as well as marketing messages to promote our products and services"
    assert_includes terms, "providing your mobile phone number and checking a consent box"
    assert_includes terms, "Reply STOP or CANCEL"
    assert_includes terms, "Reply HELP"
    assert_includes terms, "alex@mcritchie.studio"
  end

  test "privacy page says mobile opt-in data is never shared or sold for marketing" do
    get privacy_path

    assert_select "[data-test='sms-no-sharing']",
      text: /opt-in data and consent are not shared with or sold to third parties or affiliates for marketing/
  end

  test "privacy page no longer claims the site collects nothing from the public" do
    get privacy_path

    assert_not_includes response.body, "invitation-only"
    assert_not_includes response.body, "not open to the public"
    assert_not_includes response.body, "What We Don't Collect"
  end

  test "the sending number on the privacy page is the one the consent form names" do
    get privacy_path

    assert_includes response.body, ContactSubmission::SMS_NUMBER
  end

  test "terms describe a public site and point to the messaging terms" do
    get terms_path

    assert_response :success
    assert_includes response.body, "McRitchie Studio LLC"
    assert_includes response.body, "Parts of this website are open to everyone"
    assert_select "a[href='#{privacy_path}']", text: "Privacy Policy and Messaging Terms and Conditions"
    # the internal-tool framing must not return
    assert_not_includes response.body, "internal content production tool"
    assert_not_includes response.body, "invitation-only"
  end

  # The booking calendar moved from Sprintful to Google Calendar on 2026-09-30.
  # /privacy is read by carriers, so it must name the processor in use.
  test "privacy page names Google Calendar as the booking provider" do
    get privacy_path

    assert_select "section", text: /booking calendar provided by Google Calendar appointment scheduling/
    assert_select "a[href='https://policies.google.com/privacy']", 1
    assert_select "section", text: /OpenStreetMap/
    assert_not_includes response.body.downcase, "sprintful"
  end
end
