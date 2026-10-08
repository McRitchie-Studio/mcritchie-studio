require "test_helper"
require "support/tiktok_oauth_fakes"

# [unit] Tiktok::OAuthClient: which permissions the sign-in asks for, and
# which the connection was granted. TikTok is a stand-in throughout.
class Tiktok::OAuthClientTest < ActiveSupport::TestCase
  include TiktokOauthFakes

  teardown { reset_tiktok_oauth }

  def scope_param(url) = Rack::Utils.parse_query(URI(url).query).fetch("scope")

  def authorize_url = Tiktok::OAuthClient.authorize_url(redirect_uri: "https://hub.test/admin/tiktok/callback", state: "s1")

  test "the sign-in asks for drafts only by default" do
    with_tiktok_env("TIKTOK_SCOPES" => nil) do
      assert_equal "user.info.basic,video.upload", scope_param(authorize_url)
      assert_equal %w[user.info.basic video.upload], Tiktok::OAuthClient::DEFAULT_SCOPES
    end
  end

  test "TIKTOK_SCOPES opts the sign-in into direct post" do
    with_tiktok_env("TIKTOK_SCOPES" => " user.info.basic, video.upload ,video.publish,video.upload ") do
      assert_equal "user.info.basic,video.upload,video.publish", scope_param(authorize_url)
    end
  end

  test "a blank TIKTOK_SCOPES is the default" do
    with_tiktok_env("TIKTOK_SCOPES" => " , ") do
      assert_equal "user.info.basic,video.upload", scope_param(authorize_url)
    end
  end

  test "an unknown scope in TIKTOK_SCOPES is refused by name before any redirect is built" do
    with_tiktok_env("TIKTOK_SCOPES" => "user.info.basic,video.uplaod") do
      error = assert_raises(Tiktok::OAuthClient::InvalidScopes) { authorize_url }
      assert_includes error.message, "video.uplaod"
      assert_includes error.message, "video.publish" # names what is allowed
    end
  end

  test "TIKTOK_SCOPES may not drop the scopes drafting needs" do
    with_tiktok_env("TIKTOK_SCOPES" => "video.publish") do
      error = assert_raises(Tiktok::OAuthClient::InvalidScopes) { authorize_url }
      assert_includes error.message, "video.upload"
    end
  end

  test "the granted scopes are TikTok's own answer to the token refresh" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")

      assert_equal %w[user.info.basic video.upload], Tiktok::OAuthClient.granted_scopes
      assert_equal "act.test", Tiktok::OAuthClient.access_token
      assert_equal "refresh_token", token_requests.last[:grant_type]
    end
  end

  test "a drafts-only connection is refused direct post in plain words" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")

      error = assert_raises(Tiktok::OAuthClient::MissingScope) { Tiktok::OAuthClient.ensure_direct_post! }
      assert_includes error.message, "this TikTok connection was authorized for drafts only"
      assert_includes error.message, "video.publish"
    end
  end

  test "a connection granted video.publish may direct post" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload,video.publish")

      assert_nil Tiktok::OAuthClient.ensure_direct_post!
    end
  end

  test "a refresh that names no scope is refused direct post: unknown is not granted" do
    with_tiktok_env do
      tiktok_grants(nil)

      error = assert_raises(Tiktok::OAuthClient::MissingScope) { Tiktok::OAuthClient.ensure_direct_post! }
      assert_includes error.message, "video.publish"
    end
  end

  test "a refused token request reports TikTok's reason and never a token" do
    with_tiktok_env do
      tiktok_grants(nil, status: 400, body: JSON.generate(
        error: "invalid_grant", error_description: "Refresh token is invalid.", refresh_token: "rft.leak", access_token: nil
      ))

      error = assert_raises(Tiktok::OAuthClient::Error) { Tiktok::OAuthClient.access_token }
      assert_includes error.message, "invalid_grant"
      assert_includes error.message, "Refresh token is invalid."
      assert_not_includes error.message, "rft.leak"
      assert_not_includes error.message, "test-refresh-token"
    end
  end
end
