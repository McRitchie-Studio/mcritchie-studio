require "test_helper"
require "support/tiktok_oauth_fakes"

# [unit] Tiktok::PostMedia: a direct post needs video.publish, and a
# connection authorized for drafts only is told so before TikTok is asked to
# publish anything. TikTok is a stand-in throughout.
class Tiktok::PostMediaTest < ActiveSupport::TestCase
  include TiktokOauthFakes

  teardown { reset_tiktok_oauth }

  # Stands in for Net::HTTP.start on the publish endpoints, recording each call.
  def with_publish_endpoint
    calls = []
    answer = Net::HTTPOK.new("1.1", "200", "OK")
    answer.instance_variable_set(:@read, true)
    answer.instance_variable_set(:@body, JSON.generate(data: { publish_id: "pub-1" }, error: { code: "ok" }))
    Net::HTTP.stub(:start, ->(host, *_rest, **_opts) { calls << host; answer }) { yield calls }
  end

  def media(publish_type) = Tiktok::PostMedia.new(text: "Bills 3-2", video_url: "https://cdn.test/v.mp4", publish_type:)

  test "a direct post on a drafts-only connection is refused before any publish call" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")
      with_publish_endpoint do |calls|
        error = assert_raises(Tiktok::OAuthClient::MissingScope) { media(:direct_post).call }

        assert_includes error.message, "this TikTok connection was authorized for drafts only"
        assert_empty calls
      end
    end
  end

  test "the refusal is a Tiktok::OAuthClient::Error, so the rescues that catch a TikTok failure catch it" do
    assert_operator Tiktok::OAuthClient::MissingScope, :<, Tiktok::OAuthClient::Error
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")
      with_publish_endpoint { assert_raises(Tiktok::OAuthClient::Error) { media(:direct_post).call } }
    end
  end

  test "a direct post goes out when the connection holds video.publish" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload,video.publish")
      with_publish_endpoint do |calls|
        assert_equal "pub-1", media(:direct_post).call[:publish_id]
        assert_equal ["open.tiktokapis.com"], calls
      end
    end
  end

  test "an inbox upload needs no video.publish" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")
      with_publish_endpoint do |calls|
        assert_equal "pub-1", media(:inbox).call[:publish_id]
        assert_equal 1, calls.size
      end
    end
  end
end
