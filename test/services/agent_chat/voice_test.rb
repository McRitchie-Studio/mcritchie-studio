require "test_helper"

# [unit] AgentChat::Voice: the `voice` a spoken /chat message keeps
# (envelope["voice"]; epic .agents/epics/studio-voice.md, card 4). Its shape,
# and that the speaker is named on the server, never taken from the browser.
class AgentChatVoiceTest < ActiveSupport::TestCase
  setup { @user = User.create!(email: "speaker@example.com", name: "Pat Speaker", role: "viewer") }

  test "a matched take keeps four fields and names the signed-in user" do
    voice = AgentChat::Voice.from_param({ "speaker" => "Pat Speaker", "score" => 0.87312, "check" => "matched", "duration_ms" => "2140" }, user: @user)

    assert_equal %w[speaker score check duration_ms], voice.keys
    assert_equal({ "speaker" => "Pat Speaker", "score" => 0.8731, "check" => "matched", "duration_ms" => 2140 }, voice)
  end

  test "the browser's speaker is never trusted: a forged name becomes the account's own, or Someone new" do
    forged = AgentChat::Voice.from_param({ speaker: "Alex McRitchie (owner)", check: "matched", score: 0.9 }, user: @user)
    assert_equal "Pat Speaker", forged["speaker"]

    unknown = AgentChat::Voice.from_param({ speaker: "Pat Speaker", check: "below_threshold", score: 0.31 }, user: @user)
    assert_equal "Someone new", unknown["speaker"]
    %w[no_profile embedder_mismatch no_embedding].each do |check|
      assert_equal "Someone new", AgentChat::Voice.from_param({ check: check }, user: @user)["speaker"], check
    end
  end

  test "ActionController::Parameters are read like a hash" do
    params = ActionController::Parameters.new(voice: { check: "no_profile", duration_ms: 900 })
    assert_equal "no_profile", AgentChat::Voice.from_param(params[:voice], user: @user)["check"]
  end

  test "a typed message has no voice" do
    assert_nil AgentChat::Voice.from_param(nil, user: @user)
    assert_nil AgentChat::Voice.from_param("", user: @user)
  end

  test "a voice that is not a hash, or names an unknown check, is refused" do
    assert_raises(AgentChat::Voice::Invalid) { AgentChat::Voice.from_param("matched", user: @user) }
    assert_raises(AgentChat::Voice::Invalid) { AgentChat::Voice.from_param({ check: "trust_me" }, user: @user) }
    assert_raises(AgentChat::Voice::Invalid) { AgentChat::Voice.from_param({ speaker: "x" }, user: @user) }
  end

  test "score is a cosine in -1..1 or nil; duration is 1..MAX_DURATION_MS or nil" do
    read = ->(raw) { AgentChat::Voice.from_param({ check: "below_threshold" }.merge(raw), user: @user) }

    assert_equal 1.0, read.call(score: 7)["score"]
    assert_equal(-1.0, read.call(score: "-3")["score"])
    assert_nil read.call(score: "NaN")["score"]
    assert_nil read.call(score: "high")["score"]
    assert_nil read.call(score: nil)["score"]
    assert_nil read.call(duration_ms: 0)["duration_ms"]
    assert_nil read.call(duration_ms: AgentChat::Voice::MAX_DURATION_MS + 1)["duration_ms"]
    assert_nil read.call(duration_ms: "12.5")["duration_ms"]
    assert_equal 1, read.call(duration_ms: 1)["duration_ms"]
  end

  test "the checks and the unknown speaker are the engine's own" do
    assert_equal Studio::VoiceTranscription::CHECKS, AgentChat::Voice::CHECKS
    assert_equal Studio::VoiceTranscription::SOMEONE_NEW, AgentChat::Voice::SOMEONE_NEW
  end
end
