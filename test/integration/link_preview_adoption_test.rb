require "test_helper"

# [integration] The hub's adoption of studio-engine 0.82's site identity and link
# previews (task hub-adopts-link-preview; engine docs/LINK_PREVIEW.md).
#
# Pins four things the adoption is for:
#   1. every page emits the default og:/twitter: tags, carrying the drafted copy
#      from config/initializers/studio.rb and the static public/og.png;
#   2. a preview fetcher gets the slim, script-free page under Apple's 1 MiB limit;
#   3. iMessage's REAL user agent (a pinned Safari 9 string with the bot tokens
#      appended) clears `allow_browser versions: :modern`, which otherwise 406s
#      it before the slim page can form, while a plain old Safari still gets 406;
#   4. an admin's edit at /admin/link_preview reaches the tags.
class LinkPreviewAdoptionTest < ActionDispatch::IntegrationTest
  # Captured from Apple LinkPresentation (LPMetadataProvider) on macOS, 2026-09-30.
  IMESSAGE_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 " \
                "(KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 " \
                "facebookexternalhit/1.1 Facebot Twitterbot/1.0".freeze
  OLD_SAFARI_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 " \
                  "(KHTML, like Gecko) Version/9.0.1 Safari/601.2.4".freeze
  MODERN_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 " \
              "(KHTML, like Gecko) Version/18.0 Safari/605.1.15".freeze
  ONE_MIB = 1_048_576

  setup do
    Studio::SiteIdentity.bust_cache!
    Studio::SiteIdentity.reset_static_image!
  end

  def meta_content(attr, name)
    node = css_select(%(meta[#{attr}="#{name}"])).first
    node && node["content"]
  end

  test "a person's page carries the drafted default preview tags and the static image" do
    get root_path, headers: { "User-Agent" => MODERN_UA }

    assert_response :success
    assert_nil response.headers["X-Studio-Link-Preview"], "a person must get the full page"
    assert_equal Studio.site_description, meta_content("property", "og:description")
    assert_equal "McRitchie Studio", meta_content("property", "og:site_name")
    assert_equal "http://www.example.com/og.png", meta_content("property", "og:image")
    assert_equal "summary_large_image", meta_content("name", "twitter:card")
    assert_operator response.body.bytesize, :>, 20_000, "control: the full page is the heavy one"
  end

  test "the drafted copy is the hub's, not the engine fallback" do
    assert_equal "McRitchie Studio", Studio.site_title
    assert_match(/\AAlex McRitchie's studio/, Studio.site_description)
    assert File.file?(Rails.public_path.join("og.png")), "public/og.png is the last-resort image"
  end

  test "iMessage's real user agent gets the slim page, not a 406" do
    get root_path, headers: { "User-Agent" => IMESSAGE_UA }

    assert_response :success
    assert_equal "slim", response.headers["X-Studio-Link-Preview"]
    assert_includes response.headers["Vary"].to_s, "User-Agent"
    assert_operator response.body.bytesize, :<, ONE_MIB
    assert_operator response.body.bytesize, :<, 10_000, "slim means head tags and one card"
    assert_no_match(/<script/i, response.body)
    assert_equal Studio.site_description, meta_content("property", "og:description")
    assert_equal "http://www.example.com/og.png", meta_content("property", "og:image")
  end

  test "HEAD from a preview fetcher also clears the browser guard" do
    head root_path, headers: { "User-Agent" => IMESSAGE_UA }

    assert_response :success
  end

  test "a plain old Safari, with no bot token, is still turned away" do
    get root_path, headers: { "User-Agent" => OLD_SAFARI_UA }

    assert_response :not_acceptable
  end

  test "an admin's edit at /admin/link_preview reaches the tags" do
    log_in_as users(:alex)

    patch admin_link_preview_path, params: {
      site_identity: { title: "Edited Studio Title", description: "Edited studio description." }
    }
    assert_response :see_other
    assert_equal "Edited Studio Title", Studio::SiteIdentity.current.title

    # /packages names its own page title, so og:title stays the page's; the
    # description has no page override and falls to the operator's edit.
    get packages_path, headers: { "User-Agent" => IMESSAGE_UA }
    assert_response :success
    assert_equal "Edited studio description.", meta_content("property", "og:description")

    # A page with no title of its own takes the operator's title.
    assert_equal "Edited Studio Title", Studio.site_identity(base_url: "http://www.example.com")[:title]
  end

  test "the admin page renders for an admin and is closed to a viewer" do
    log_in_as users(:alex)
    get admin_link_preview_path
    assert_response :success
    assert_includes response.body, ERB::Util.html_escape(Studio.site_description), "the draft shows as the placeholder"

    reset!
    log_in_as users(:viewer)
    get admin_link_preview_path
    assert_not_equal 200, response.status
  end
end
