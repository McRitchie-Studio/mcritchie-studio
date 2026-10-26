require "test_helper"

# [unit] AppRequest.origin_from reads only the known alex.build origin, from a
# ref, a utm_source or the referrer's host, and the column refuses anything else.
class AppRequestOriginTest < ActiveSupport::TestCase
  def origin(params = nil, referer: nil, **query)
    AppRequest.origin_from(params: ActionController::Parameters.new(params || query), referer: referer)
  end

  test "each alex.build spelling names the origin" do
    %w[alex.build alex-build ALEX.BUILD alex_build].each do |tag|
      assert_equal "alex.build", origin(ref: tag), tag
      assert_equal "alex.build", origin(utm_source: tag), tag
    end
    assert_equal "alex.build", origin(referer: "https://alex.build/")
    assert_equal "alex.build", origin(referer: "https://hello.alex.build/pricing?x=1")
  end

  test "anything else names nothing" do
    assert_nil origin
    assert_nil origin(ref: "a" * 20)
    assert_nil origin(ref: [ "alex.build" ]), "only a string parameter counts"
    assert_nil origin(referer: "https://alex.build.evil.example/")
    assert_nil origin(referer: "https://notalex.build/")
    assert_nil origin(referer: "not a url ::")
  end

  test "the column holds only a known origin" do
    assert AppRequest.new(prompt: "x", origin: "alex.build").valid?
    assert AppRequest.new(prompt: "x", origin: nil).valid?
    refute AppRequest.new(prompt: "x", origin: "elsewhere").valid?
  end
end
