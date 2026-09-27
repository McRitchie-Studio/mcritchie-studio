require "test_helper"

# [unit] Tracked links: a template's fixed links resolve like the column ones,
# and nothing else resolves (the click redirect is never an open redirect).
class BroadcastTest < ActiveSupport::TestCase
  test "the Cyvasse email's play and build links resolve and are tracked" do
    broadcast = Broadcast.new(subject: "Hi", template_key: "cyvasse_is_back")
    assert_equal "https://cyvasse.mcritchie.studio/play", broadcast.link_for(:play)
    assert_equal "https://mcritchie.studio/build", broadcast.link_for("build")
    assert_includes broadcast.link_keys, "play"
    assert_nil broadcast.link_for("https://evil.example")
  end

  test "another template does not get the Cyvasse links" do
    broadcast = Broadcast.new(subject: "Hi", template_key: "world_cup_kickoff", survivor_url: "https://x/sv")
    assert_nil broadcast.link_for(:play)
    assert_equal "https://x/sv", broadcast.link_for(:survivor)
  end
end
