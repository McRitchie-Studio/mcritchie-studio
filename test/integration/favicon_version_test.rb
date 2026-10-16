require "test_helper"
require "digest"

# [component] The favicon and the app icon are linked by their content version
# (task footer-stacked-logo). Chrome caches a favicon per origin and a hard reload
# does not reliably clear it, so the redrawn favicon kept showing the old picture
# on a reused localhost port, as it would for a returning visitor. studio-engine's
# head links /favicon.png?v=<first 8 hex of its SHA-256> (Studio::PublicFileVersion)
# and the manifest does the same for icon.png. On an engine from before that the
# links are bare, so each check follows whichever engine is bundled.
class FaviconVersionTest < ActionDispatch::IntegrationTest
  def versioned? = defined?(Studio::PublicFileVersion)
  def digest(file) = Digest::SHA256.file(Rails.public_path.join(file)).hexdigest[0, 8]

  test "the page's icon link carries the current favicon's digest" do
    get root_path

    href = css_select("head link[rel=icon]").sole["href"]
    assert_equal(versioned? ? "/favicon.png?v=#{digest('favicon.png')}" : "/favicon.png", href)
  end

  test "the manifest's icons carry the current app icon's digest" do
    get pwa_manifest_path(format: :json)

    assert_response :success
    srcs = JSON.parse(response.body).fetch("icons").map { |icon| icon["src"] }
    assert_equal [versioned? ? "/icon.png?v=#{digest('icon.png')}" : "/icon.png"] * 2, srcs
  end
end
