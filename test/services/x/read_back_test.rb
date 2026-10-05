require "test_helper"

# [unit] X::ReadBack — what is actually live on a post, from X's own answer.
class X::ReadBackTest < ActiveSupport::TestCase
  class OneAnswer < X::Client
    attr_reader :asked

    def initialize(body) = @body = body

    def get(url, params = {})
      @asked = [url, params]
      Net::HTTPOK.new("1.1", "200", "").tap do |r|
        r.instance_variable_set(:@read, true)
        r.body = JSON.generate(@body)
      end
    end
  end

  test "reports the attached video and its length" do
    client = OneAnswer.new("data" => { "id" => "9", "text" => "Chiefs 4-0" },
                           "includes" => { "media" => [{ "type" => "video", "duration_ms" => 27_700 }] })

    assert_equal({ "video" => true, "seconds" => 27.7, "text" => "Chiefs 4-0" }, X::ReadBack.new("9", client: client).call)
    assert_equal "https://api.x.com/2/tweets/9", client.asked.first
    assert_equal "attachments.media_keys", client.asked.last["expansions"]
  end

  test "a post with no media, or only a photo, has no video" do
    assert_equal false, X::ReadBack.new("9", client: OneAnswer.new("data" => { "text" => "t" })).call["video"]
    photo = OneAnswer.new("data" => { "text" => "t" }, "includes" => { "media" => [{ "type" => "photo" }] })
    assert_equal false, X::ReadBack.new("9", client: photo).call["video"]
  end
end
