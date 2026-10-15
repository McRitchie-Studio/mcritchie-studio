require "test_helper"
require "socket"
require "websocket/driver"
require_relative "../support/agent_message_fixtures"

# [integration] AgentMessages::DiscordGateway end to end over a REAL websocket:
# the listener's thread speaks to an in-process fake Discord Gateway across a
# UNIX socket pair, framed by websocket-driver on both sides. Only the TLS
# connector is replaced; the handshake, frames, heartbeats, close codes, the
# leader lock and DiscordIngest are the production code. Nothing reaches Discord.
class DiscordGatewayTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  TOKEN = "gateway-test-token-#{Process.pid}".freeze

  # The server half: answers the upgrade, sends HELLO, records every frame the
  # listener sends and every close code, and lets the test push dispatches.
  class FakeGateway
    attr_reader :url, :frames, :closes, :client_io

    def initialize(url, heartbeat_interval:)
      @url = url
      @frames = []
      @closes = []
      @seq = 0
      @mutex = Monitor.new
      @client_io, @server_io = UNIXSocket.pair
      @driver = WebSocket::Driver.server(self)
      @driver.on(:connect) { @driver.start }
      @driver.on(:open) { push(op: 10, d: { heartbeat_interval: heartbeat_interval }) }
      @driver.on(:message) { |event| @frames << JSON.parse(event.data) }
      @driver.on(:close) { |event| @closes << event.code }
      @reader = Thread.new do
        loop do
          data = @server_io.readpartial(65_536)
          @mutex.synchronize { @driver.parse(data) }
        end
      rescue IOError, SystemCallError
        nil
      end
    end

    # The listener may already have dropped its end after its close frame.
    def write(data)
      @server_io.write(data)
    rescue IOError, SystemCallError
      nil
    end

    def push(payload) = @mutex.synchronize { @driver.text(JSON.generate(payload)) }

    def dispatch(type, data) = push(op: 0, t: type, s: (@seq += 1), d: data)

    def ack = push(op: 11)

    def close_with(code) = @mutex.synchronize { @driver.close("bye", code) }

    def ops = @frames.map { |f| f["op"] }

    def shutdown
      @server_io.close unless @server_io.closed?
      @reader.join(1)
    end
  end

  # A lock the test flips, for the stand-down path.
  class SwitchLock
    attr_accessor :holding

    def initialize = (@holding = true)
    def acquire = @holding
    def held? = @holding
    def release = nil
  end

  setup do
    @gateways = []
    @log = StringIO.new
    @logger = ActiveSupport::Logger.new(@log)
    AgentMessages::DiscordIngest.reset_unlisted_guilds!
  end

  teardown do
    Array(@listeners).each(&:stop)
    @gateways.each(&:shutdown)
    Array(@connections).each(&:disconnect!)
  end

  def connector(heartbeat_interval: 45_000)
    lambda do |url|
      gateway = FakeGateway.new(url, heartbeat_interval: heartbeat_interval)
      @gateways << gateway
      gateway.client_io
    end
  end

  def listener(lock: SwitchLock.new, heartbeat_interval: 45_000, **opts)
    AgentMessages::DiscordGateway.new(token: TOKEN, routes: agent_routes, logger: @logger,
                                      connector: connector(heartbeat_interval: heartbeat_interval), lock: lock,
                                      lock_retry: 0.1, lock_check_every: 0.1, backoff: [ 0.05 ], **opts)
                                 .tap { |l| (@listeners ||= []) << l }
  end

  def dedicated_lock(key)
    config = ActiveRecord::Base.connection_pool.db_config
    connection = config.adapter_class.new(config.configuration_hash)
    (@connections ||= []) << connection
    AgentMessages::GatewayLeaderLock.new(key: key, connection: connection)
  end

  def wait_until(what, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out waiting for #{what}\n#{@log.string}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def identified(gateway)
    wait_until("IDENTIFY") { gateway.ops.include?(2) }
    gateway.frames.find { |f| f["op"] == 2 }
  end

  test "a MESSAGE_CREATE in an unlisted channel of a listed guild routes to xan, and the backstop poll dedupes it" do
    gateway_listener = listener.start
    wait_until("a connection") { @gateways.any? }
    gateway = @gateways.first

    identify = identified(gateway)
    assert_equal "wss://gateway.discord.gg/?v=10&encoding=json", gateway.url
    assert_equal TOKEN, identify.dig("d", "token")
    assert_equal AgentMessages::GatewaySession::INTENTS, identify.dig("d", "intents")

    gateway.dispatch("READY", { "session_id" => "s-1", "resume_gateway_url" => "wss://resume.example", "user" => { "id" => SHARED_BOT } })
    gateway.dispatch("GUILD_CREATE", { "id" => GUILD, "threads" => [ { "id" => DESK_THREAD, "parent_id" => DESK } ] })
    addressed = discord_raw(8001, content: "<@&#{XAN_ROLE}> what is building?", channel: LOUNGE, roles: [ XAN_ROLE ], guild: GUILD)
    gateway.dispatch("MESSAGE_CREATE", addressed)
    gateway.dispatch("MESSAGE_CREATE", discord_raw(8002, content: "lunch anyone?", channel: LOUNGE, guild: GUILD))
    gateway.dispatch("MESSAGE_CREATE", discord_raw(8003, content: "<@&#{XAN_ROLE}> hi", channel: "1", roles: [ XAN_ROLE ],
                                                         guild: OTHER_GUILD))
    gateway.dispatch("MESSAGE_CREATE", discord_raw(8004, content: "<@&#{AVI_ROLE}> muted", channel: "900000000000000070",
                                                         roles: [ AVI_ROLE ], guild: GUILD))
    gateway.dispatch("THREAD_CREATE", { "id" => "900000000000000071", "parent_id" => MUTED })
    gateway.dispatch("MESSAGE_CREATE", discord_raw(8005, content: "<@&#{AVI_ROLE}> muted thread", channel: "900000000000000071",
                                                         roles: [ AVI_ROLE ], guild: GUILD))
    gateway.dispatch("MESSAGE_CREATE", discord_raw(8006, content: "last", channel: LOUNGE, guild: GUILD,
                                                         roles: [ AVI_ROLE ]))

    wait_until("the last message") { AgentMessage.exists?(external_id: "8006") }
    message = AgentMessage.find_by!(external_id: "8001")
    assert_equal [ "xan", "role", "received", LOUNGE, GUILD ],
                 [ message.soul_slug, message.routed_by, message.status, message.channel_ref, message.guild_id ]
    assert_equal "discord-gateway", message.events.find_by(kind: "received").actor
    assert_nil AgentMessage.find_by(external_id: "8002"), "an unaddressed message is not stored"
    assert_nil AgentMessage.find_by(external_id: "8003"), "a guild that is not listed is ignored"
    assert_equal 1, @log.string.scan(/ignoring Discord guild #{OTHER_GUILD}/).size
    assert AgentMessage.exists?(external_id: "8004"), "a thread the listener never saw has no parent, so no override"
    assert_nil AgentMessage.find_by(external_id: "8005"), "a thread under a muted channel is muted"

    # The backstop poll reads the same message from REST: one row, nothing new.
    fake = ->(_m, url, _h, _b) do
      if url.end_with?("/guilds/#{GUILD}/channels") then [ 200, JSON.generate([ { "id" => LOUNGE, "type" => 0 } ]) ]
      elsif url.end_with?("/threads/active") then [ 200, '{"threads":[]}' ]
      else [ 200, JSON.generate([ addressed.except("guild_id") ]) ]
      end
    end
    summary = AgentMessages::DiscordPoll.new(routes: agent_routes, bot: AgentMessages::DiscordBot.new(token: TOKEN, transport: fake)).call
    assert_equal 0, summary.stored
    assert_equal 1, AgentMessage.where(external_id: "8001").count

    gateway_listener.stop
    refute gateway_listener.alive?
    refute_includes @log.string, TOKEN, "the token is never logged"
  end

  test "an unanswered heartbeat closes the zombie and RESUMEs at the resume URL with session id and seq" do
    gateway_listener = listener(heartbeat_interval: 100).start
    wait_until("a connection") { @gateways.any? }
    first = @gateways.first
    identified(first)
    first.dispatch("READY", { "session_id" => "s-9", "resume_gateway_url" => "wss://resume.example" })
    first.dispatch("MESSAGE_CREATE", discord_raw(8101, content: "chatter", channel: LOUNGE, guild: GUILD))

    wait_until("a heartbeat") { first.ops.include?(1) }
    assert_equal 2, first.frames.find { |f| f["op"] == 1 }["d"], "the heartbeat carries the last seq"
    # No ACK: the next beat finds the zombie, closes with 4000 (keeping the session) and reconnects.
    wait_until("a second connection") { @gateways.size >= 2 }
    second = @gateways[1]
    wait_until("RESUME") { second.ops.include?(6) }

    assert_includes first.closes, 4000
    assert_equal "wss://resume.example/?v=10&encoding=json", second.url
    resume = second.frames.find { |f| f["op"] == 6 }
    assert_equal({ "token" => TOKEN, "session_id" => "s-9", "seq" => 2 }, resume["d"])
    gateway_listener.stop
  end

  test "an acknowledged heartbeat keeps the connection; a fatal close code stops the listener for good" do
    gateway_listener = listener(heartbeat_interval: 100).start
    wait_until("a connection") { @gateways.any? }
    gateway = @gateways.first
    identified(gateway)
    3.times do |i|
      wait_until("heartbeat #{i + 1}") { gateway.ops.count(1) > i }
      gateway.ack
    end
    assert_equal 1, @gateways.size, "acked beats never reconnect"

    gateway.close_with(4004)

    wait_until("the listener to stop") { !gateway_listener.alive? }
    assert_equal 1, @gateways.size, "no reconnect after an authentication failure"
    assert_match(/closed the connection with 4004; not reconnecting/, @log.string)
    assert ErrorLog.where("message LIKE ?", "%closed the connection with 4004%").exists?, "a fatal close leaves an ErrorLog receipt"
  end

  test "RECONNECT and a non-resumable INVALID_SESSION reconnect; the second IDENTIFYs afresh" do
    gateway_listener = listener.start
    wait_until("a connection") { @gateways.any? }
    identified(@gateways[0])
    @gateways[0].dispatch("READY", { "session_id" => "s-2", "resume_gateway_url" => "wss://resume.example" })
    @gateways[0].push(op: 7, d: nil)

    wait_until("RESUME after RECONNECT") { @gateways.size >= 2 && @gateways[1].ops.include?(6) }
    @gateways[1].push(op: 9, d: false)

    wait_until("IDENTIFY after INVALID_SESSION") { @gateways.size >= 3 && @gateways[2].ops.include?(2) }
    assert_equal "wss://gateway.discord.gg/?v=10&encoding=json", @gateways[2].url
    gateway_listener.stop
  end

  test "a second listener cannot take the lock: it never connects until the first stops" do
    key = AgentMessages::GatewayLeaderLock.key_for("#{TOKEN}-#{name}")
    first = listener(lock: dedicated_lock(key)).start
    wait_until("the first connection") { @gateways.size == 1 }
    identified(@gateways.first)

    second = listener(lock: dedicated_lock(key)).start
    sleep 0.5 # five lock retries
    assert_equal 1, @gateways.size, "one connection per bot token"
    assert_match(/another process holds the connection; standing by/, @log.string)

    first.stop
    wait_until("the second listener to take over") { @gateways.size == 2 }
    identified(@gateways.last)
    second.stop
  end

  test "a lost lock makes the holder close the socket and stand down" do
    lock = SwitchLock.new
    gateway_listener = listener(lock: lock).start
    wait_until("a connection") { @gateways.any? }
    identified(@gateways.first)

    lock.holding = false

    wait_until("the close") { @gateways.first.closes.any? }
    assert_match(/leader lock lost; standing down/, @log.string)
    sleep 0.3
    assert_equal 1, @gateways.size, "it does not reconnect without the lock"
    assert gateway_listener.alive?, "it waits to take the lock again"

    lock.holding = true
    wait_until("the reconnect") { @gateways.size == 2 }
    gateway_listener.stop
  end

  test "boot is inert with one log line when the token is missing, switched off, or no guild is listed" do
    logger = ActiveSupport::Logger.new(log = StringIO.new)
    assert_nil AgentMessages::DiscordGateway.boot(logger: logger, env: {}, routes: agent_routes)
    assert_nil AgentMessages::DiscordGateway.boot(logger: logger, env: { "DISCORD_AGENT_BOT_TOKEN" => "x", "DISCORD_GATEWAY" => "off" },
                                                  routes: agent_routes)
    assert_nil AgentMessages::DiscordGateway.boot(logger: logger, env: { "DISCORD_AGENT_BOT_TOKEN" => "x" },
                                                  routes: AgentMessages::Routes.new({}))
    lines = log.string.lines
    assert_equal 3, lines.size
    assert_match(/idle: DISCORD_AGENT_BOT_TOKEN is unset/, lines[0])
    assert_match(/idle: DISCORD_GATEWAY=off/, lines[1])
    assert_match(/idle: config\/agent_routes.yml lists no Discord guild/, lines[2])
    assert_nil AgentMessages::DiscordGateway.instance
  end

  test "the scheduler's start and stop hooks are registered" do
    starts = SolidQueue::Scheduler.lifecycle_hooks[:start]
    stops = SolidQueue::Scheduler.lifecycle_hooks[:stop]
    assert(starts.any? { |hook| hook.source_location.first.end_with?("config/initializers/agent_message_gateway.rb") })
    assert(stops.any? { |hook| hook.source_location.first.end_with?("config/initializers/agent_message_gateway.rb") })
  end
end
