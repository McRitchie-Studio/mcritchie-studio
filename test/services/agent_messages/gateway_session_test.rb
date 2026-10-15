require "test_helper"

# [unit] AgentMessages::GatewaySession — the Discord Gateway v10 protocol state
# with no I/O: HELLO, IDENTIFY vs RESUME, the sequence number, heartbeats and
# their ACKs, RECONNECT and INVALID_SESSION, close codes, and the dispatches the
# listener acts on.
class AgentMessages::GatewaySessionTest < ActiveSupport::TestCase
  TOKEN = "test-token".freeze

  def session = (@session ||= AgentMessages::GatewaySession.new)

  def dispatch(type, data, seq)
    session.receive("op" => 0, "t" => type, "s" => seq, "d" => data)
  end

  def ready!(seq: 1)
    dispatch("READY", { "session_id" => "sess-1", "resume_gateway_url" => "wss://resume.discord.gg",
                        "user" => { "id" => "42" } }, seq)
  end

  test "intents are GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT" do
    assert_equal 1 + 512 + 32_768, AgentMessages::GatewaySession::INTENTS
  end

  test "HELLO hands back the heartbeat interval; a fresh session opens with IDENTIFY at the default gateway" do
    assert_equal [ [ :hello, 41_250 ] ], session.receive("op" => 10, "d" => { "heartbeat_interval" => 41_250 })
    assert_equal 41_250, session.heartbeat_interval
    refute session.resumable?
    assert_equal "wss://gateway.discord.gg/?v=10&encoding=json", session.connect_url

    opening = session.opening_payload(TOKEN)
    assert_equal 2, opening[:op]
    assert_equal TOKEN, opening[:d][:token]
    assert_equal AgentMessages::GatewaySession::INTENTS, opening[:d][:intents]
  end

  test "READY records the session and resume URL; every dispatch advances seq; the next opening is RESUME" do
    assert_equal [ [ :ready, "sess-1" ] ], ready!(seq: 1)
    dispatch("TYPING_START", {}, 7)
    session.receive("op" => 11, "d" => nil) # an ACK carries no seq and changes none

    assert_equal 7, session.seq
    assert session.resumable?
    assert_equal "42", session.bot_user_id
    assert_equal "wss://resume.discord.gg/?v=10&encoding=json", session.connect_url
    assert_equal({ op: 6, d: { token: TOKEN, session_id: "sess-1", seq: 7 } }, session.opening_payload(TOKEN))
  end

  test "a heartbeat carries the last seq and waits for its ACK; an unanswered one marks a zombie" do
    assert_equal({ op: 1, d: nil }, session.heartbeat_payload)
    assert session.zombie?
    session.receive("op" => 11)
    refute session.zombie?

    ready!(seq: 3)
    assert_equal({ op: 1, d: 3 }, session.heartbeat_payload)
    assert session.zombie?
    session.connection_opened!
    refute session.zombie?, "a new connection starts with no beat in flight"
  end

  test "Discord asking for a heartbeat, RECONNECT, and INVALID_SESSION each say what to do" do
    ready!
    assert_equal [ [ :heartbeat_now, nil ] ], session.receive("op" => 1, "d" => nil)
    assert_equal [ [ :reconnect, :resume ] ], session.receive("op" => 7, "d" => nil)

    assert_equal [ [ :reconnect, :resume ] ], session.receive("op" => 9, "d" => true)
    assert session.resumable?, "a resumable invalid session keeps its state"

    assert_equal [ [ :reconnect, :identify ] ], session.receive("op" => 9, "d" => false)
    refute session.resumable?
    assert_equal 2, session.opening_payload(TOKEN)[:op]
  end

  test "close codes: auth and intent failures are fatal, a timed-out session starts over, the rest resume" do
    ready!
    [ 4004, 4010, 4011, 4012, 4013, 4014 ].each { |code| assert_equal :fatal, session.close_outcome(code), code.to_s }
    [ 1000, 1001, 1006, 4000, 4001, 4008 ].each { |code| assert_equal :resume, session.close_outcome(code), code.to_s }
    assert session.resumable?

    assert_equal :identify, session.close_outcome(4009)
    refute session.resumable?
    ready!
    assert_equal :identify, session.close_outcome(4007)
    refute session.resumable?
  end

  test "dispatches the listener acts on: messages, guilds, and thread parents" do
    message = { "id" => "1", "channel_id" => "2", "guild_id" => "3", "content" => "hi" }
    assert_equal [ [ :message, message ] ], dispatch("MESSAGE_CREATE", message, 2)
    assert_equal [ [ :guild, { "id" => "3" } ] ], dispatch("GUILD_CREATE", { "id" => "3" }, 3)
    thread = { "id" => "5", "parent_id" => "2" }
    assert_equal [ [ :threads, [ thread ] ] ], dispatch("THREAD_CREATE", thread, 4)
    assert_equal [ [ :threads, [ thread ] ] ], dispatch("THREAD_LIST_SYNC", { "threads" => [ thread ] }, 5)
    assert_equal [ [ :resumed, nil ] ], dispatch("RESUMED", nil, 6)
    assert_empty dispatch("PRESENCE_UPDATE", {}, 7)
    assert_empty session.receive("op" => 99)
  end
end
