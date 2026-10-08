require "test_helper"
require "support/tiktok_oauth_fakes"

# [unit] Content::PostToTiktok, the Starter Post TikTok flow: a direct post on
# a drafts-only connection is refused in plain words and the card is not
# marked posted. TikTok is a stand-in throughout.
class Content::PostToTiktokTest < ActiveSupport::TestCase
  include TiktokOauthFakes

  setup do
    @content = Content.create!(title: "Bills offense", workflow: "starter_post_tiktok_offense", stage: "assets",
                               final_video_url: "https://cdn.test/v.mp4", captions: "Bills starters")
  end

  teardown { reset_tiktok_oauth }

  def with_publish_endpoint
    calls = []
    answer = Net::HTTPOK.new("1.1", "200", "OK")
    answer.instance_variable_set(:@read, true)
    answer.instance_variable_set(:@body, JSON.generate(data: { publish_id: "pub-9" }, error: { code: "ok" }))
    Net::HTTP.stub(:start, ->(host, *_rest, **_opts) { calls << host; answer }) { yield calls }
  end

  test "a direct post on a drafts-only connection is refused and the card stays unposted" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")
      with_publish_endpoint do |calls|
        error = assert_raises(Tiktok::OAuthClient::MissingScope) do
          Content::PostToTiktok.new(@content, publish_type: "direct_post").call
        end

        assert_includes error.message, "this TikTok connection was authorized for drafts only"
        assert_empty calls
        assert_nil @content.reload.posted_at
        assert_nil @content.post_id
        assert_equal "assets", @content.stage
      end
    end
  end

  test "the default publish type is the inbox, which a drafts-only connection may use" do
    with_tiktok_env do
      tiktok_grants("user.info.basic,video.upload")
      with_publish_endpoint do
        Content::PostToTiktok.new(@content).call

        assert_equal "pub-9", @content.reload.post_id
        assert_equal "tiktok://drafts/pub-9", @content.post_url
      end
    end
  end
end
