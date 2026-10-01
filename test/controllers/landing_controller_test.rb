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

  test "get in touch section shows only the full-width video chat card" do
    get root_path

    assert_response :success
    assert_includes response.body, "Chat Over Video"
    assert_not_includes response.body, "Chat Right Now"
  end

  test "contact section links to the correct social profiles" do
    get root_path

    assert_response :success
    assert_select "a[href=?]", "https://www.linkedin.com/in/amcritchie/"
    assert_select "a[href=?]", "https://x.com/mcritchiealex"
    # the stale "alexmcritchie" handles must not come back
    assert_select "a[href*=?]", "alexmcritchie", count: 0
  end

  test "pwa manifest renders the corrected app name" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "McRitchie Studio", manifest["name"]
    assert_equal "McRitchie Studio.", manifest["description"]
  end

  # [component] /privacy doubles as the Messaging Terms and Conditions a carrier
  # reads when it reviews the SMS registration. Each line below is one they check.
  test "privacy page is the combined privacy policy and messaging terms" do
    get privacy_path

    assert_response :success
    assert_select "h1", text: "Privacy Policy and Messaging Terms and Conditions"
    assert_includes response.body, "Last updated: September 30, 2026"
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
end
