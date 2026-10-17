require "test_helper"

# [unit] The web chat's delivery side (AgentMessages::WebChat) and the two jobs
# that call it: the typing pulse and the answer go to the sender's own stream
# only, never Discord; the answer is marked posted ONCE and broadcast once; a
# typing pulse is refused for a message the worker no longer holds; a failed
# broadcast never loses the answer.
class WebChatTest < ActiveJob::TestCase
  include ActionCable::TestHelper

  setup do
    @owner_person = AgentPerson.seed_owner!
    @alex = users(:alex)
    @message = AgentMessages::WebIngest.new(user: @alex, cto: AppOwnership.cto_for_app("turf-monster"))
                                       .call("How are signups?")
    @stream = AgentMessages::WebChat.stream_name("turf-monster", @alex.id)
  end

  def claim! = AgentMessage.claim!(soul: "turf_monster", worker: "w1").message

  # What the stream carried, as the HTML the browser receives (each broadcast is
  # a JSON-encoded Turbo Stream string).
  def sent = broadcasts(@stream).map { |payload| JSON.parse(payload) }

  test "a stream name is one user and one app, and parses back; anything else is not a chat stream" do
    assert_equal "cto_chat:turf-monster:#{@alex.id}", @stream
    assert_equal [ "turf-monster", @alex.id ], AgentMessages::WebChat.parse_stream(@stream)
    assert_equal @stream, AgentMessages::WebChat.stream_for(@message)
    [ "deployments", "cto_chat:turf-monster:", "cto_chat:Turf:1", "cto_chat:turf-monster:1:2", nil ].each do |name|
      assert_nil AgentMessages::WebChat.parse_stream(name), name.inspect
    end
  end

  test "a typing pulse for a held web message broadcasts the indicator on the sender's stream, and calls no bot" do
    claimed = claim!
    assert_equal @message, claimed
    assert_nil claimed.typing_refusal(worker: "w1"), "web is a typing channel"

    with_env("DISCORD_AGENT_BOT_TOKEN", nil) do
      assert_broadcasts(@stream, 1) { AgentMessageTypingJob.perform_now(claimed.id, "w1") }
    end
    payload = sent.last
    assert_includes payload, %(action="update" target="#{AgentMessages::WebChat::TYPING_TARGET}"),
                    "the slot keeps its id and fade: only its contents change"
    assert_includes payload, "Turf is typing"
    assert_match(/data-typing-at="\d{13}"/, payload)
  end

  test "no pulse for a worker that does not hold the claim, or once the message is answered" do
    claimed = claim!
    assert_no_broadcasts(@stream) { AgentMessageTypingJob.perform_now(claimed.id, "someone-else") }

    claimed.complete!(worker: "w1", response_text: "Steady.")
    assert_equal "not_holder", claimed.reload.typing_refusal(worker: "w1")
    assert_no_broadcasts(@stream) { AgentMessageTypingJob.perform_now(claimed.id, "w1") }
  end

  test "the answer is delivered once: marked posted, the turn replaced, typing cleared, the meter redrawn" do
    claimed = claim!
    claimed.complete!(worker: "w1", response_text: "**Steady**: 12 signups.")

    assert_broadcasts(@stream, 3) { AgentMessageReplyJob.perform_now(claimed.id) }
    claimed.reload
    assert_equal [ "web:#{claimed.id}", "posted" ], [ claimed.reply_external_id, claimed.reply_status ]
    assert_equal({ "via" => "web_chat" }, claimed.events.find_by(kind: "reply_posted").detail)

    turn, typing, meter = sent.last(3)
    assert_includes turn, %(action="replace" target="cto-chat-turn-#{claimed.id}")
    assert_includes turn, "<strong>Steady</strong>: 12 signups.", "the answer renders as safe Markdown"
    assert_includes turn, "data-replied-at="
    assert_includes typing, %(action="update" target="#{AgentMessages::WebChat::TYPING_TARGET}"><template></template>)
    assert_includes meter, %(target="#{AgentMessages::WebChat::METER_TARGET}")
    assert_includes meter, "usage-meter"
    assert_not_includes meter, "$", "the chat's meter is tokens, never dollars"

    assert_no_broadcasts(@stream) { AgentMessageReplyJob.perform_now(claimed.id) }
    assert_equal 1, claimed.events.where(kind: "reply_posted").count
  end

  test "the answer's markup is the model's text, escaped: raw HTML never renders" do
    claimed = claim!
    claimed.complete!(worker: "w1", response_text: %(<script>alert(1)</script> and [x](javascript:alert(1))))
    AgentMessageReplyJob.perform_now(claimed.id)

    turn = sent.find { |payload| payload.include?("cto-chat-turn-#{claimed.id}") && payload.include?("replace") }
    assert_not_includes turn, "<script>alert"
    assert_not_includes turn, %(href="javascript:)
  end

  test "a failed broadcast is logged and the answer stays posted on the row" do
    claimed = claim!
    claimed.complete!(worker: "w1", response_text: "Steady.")
    boom = ->(*) { raise Redis::CannotConnectError, "down" }

    Turbo::StreamsChannel.stub(:broadcast_replace_to, boom) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert AgentMessages::WebChat.deliver!(claimed.reload)
      end
    end
    assert_equal "posted", claimed.reload.reply_status
  end

  test "history is the thread's newest turns, oldest first, and only this user's thread for this app" do
    other_app = AgentMessages::WebIngest.new(user: @alex, cto: AppOwnership.cto_for_app("mcritchie-studio")).call("studio")
    later = AgentMessages::WebIngest.new(user: @alex, cto: AppOwnership.cto_for_app("turf-monster")).call("second")

    assert_equal [ @message, later ], AgentMessages::WebChat.history("turf-monster", @alex.id)
    assert_equal [ other_app ], AgentMessages::WebChat.history("mcritchie-studio", @alex.id)
    assert_empty AgentMessages::WebChat.history("turf-monster", users(:viewer).id)
  end
end
