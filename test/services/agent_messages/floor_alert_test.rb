require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] AgentMessages::FloorAlert, the floor under bin/dispatcher: each check
# opens an incident once, posts ONE alert, and posts one recovery when it clears.
# Discord is a recording transport; nothing leaves the process.
class AgentMessages::FloorAlertTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  OPS = "900000000000000777".freeze

  class Recorder
    attr_reader :posts

    def initialize(fail_times: 0)
      @posts = []
      @fail_times = fail_times
    end

    def call(method, url, _headers, body)
      if @fail_times.positive?
        @fail_times -= 1
        return [ 500, "{}" ]
      end
      @posts << [ method, url, JSON.parse(body) ]
      [ 200, JSON.generate("id" => "1#{@posts.size}") ]
    end
  end

  def routes(ops: OPS)
    AgentMessages::Routes.new("discord" => { "ops_channel_id" => ops, "guilds" => {} })
  end

  def alert(recorder, ops: OPS, logger: Logger.new(nil))
    bot = AgentMessages::DiscordBot.new(token: "test-token", transport: recorder)
    AgentMessages::FloorAlert.new(routes: routes(ops: ops), bot: bot, logger: logger)
  end

  def ping!(at)
    AgentDispatcher.ping!({ "worker" => "d-1", "host" => "alex-mac", "souls" => [ "xan" ] }, now: at)
  end

  test "a dispatcher that never pinged is not an outage" do
    recorder = Recorder.new
    checks = alert(recorder).call

    refute checks.find { |c| c.kind == "dispatcher_silent" }.failing
    assert_empty recorder.posts
    assert_equal 0, AgentMailboxIncident.count
  end

  test "a silent dispatcher is announced once, then its recovery once" do
    t0 = Time.current
    ping!(t0 - 6.minutes)
    recorder = Recorder.new
    floor = alert(recorder)

    floor.call(now: t0)
    floor.call(now: t0 + 1.minute)
    floor.call(now: t0 + 2.minutes)

    assert_equal 1, recorder.posts.size, "one alert per incident, not one a minute"
    method, url, body = recorder.posts.first
    assert_equal :post, method
    assert_match %r{/channels/#{OPS}/messages\z}, url
    assert_match(/Agent dispatcher silent: no ping from bin\/dispatcher on alex-mac for 6 min/, body["content"])
    assert_equal({ "parse" => [] }, body["allowed_mentions"], "the alert pings nobody")
    assert_nil body["message_reference"]
    assert body["enforce_nonce"]

    ping!(t0 + 3.minutes)
    floor.call(now: t0 + 3.minutes)
    floor.call(now: t0 + 4.minutes)

    assert_equal 2, recorder.posts.size
    assert_match(/Agent dispatcher back/, recorder.posts.last[2]["content"])
    incident = AgentMailboxIncident.sole
    assert incident.resolved_at && incident.alert_posted_at && incident.recovery_posted_at

    ping!(t0 + 3.minutes)
    floor.call(now: t0 + 20.minutes)
    assert_equal 3, recorder.posts.size, "a second outage is a second incident"
    assert_equal 2, AgentMailboxIncident.count
  end

  test "a routed message waiting over 10 minutes is announced once with its pause, unrouted ones never" do
    t0 = Time.current
    ping!(t0)
    AgentDispatcher.last.update!(paused_until: t0 + 2.hours, pause_reason: "usage_limit")
    waiting = agent_message!(soul: "xan", created_at: t0 - 11.minutes)
    agent_message!(soul: nil, status: "unrouted", routed_by: "none", created_at: t0 - 1.hour)
    agent_message!(soul: "xan", created_at: t0 - 2.minutes)
    recorder = Recorder.new
    floor = alert(recorder)

    floor.call(now: t0)
    floor.call(now: t0 + 1.minute)

    assert_equal 1, recorder.posts.size
    text = recorder.posts.first[2]["content"]
    assert_match(/1 routed message\(s\) waiting over 10 minutes; oldest is ##{waiting.id} for xan, 11 min old/, text)
    assert_match(/paused until .* \(usage_limit\)/, text)

    waiting.update!(status: "completed")
    floor.call(now: t0 + 2.minutes)
    assert_equal 2, recorder.posts.size
    assert_match(/Agent mailbox clear/, recorder.posts.last[2]["content"])
  end

  test "no ops channel or no token: the incident is kept, nothing is posted, and one line is logged" do
    t0 = Time.current
    ping!(t0 - 6.minutes)
    log = StringIO.new
    recorder = Recorder.new

    alert(recorder, ops: nil, logger: Logger.new(log)).call(now: t0)

    assert_empty recorder.posts
    assert_match(/floor alert not posted \(config\/agent_routes.yml names no discord.ops_channel_id\)/, log.string)
    assert AgentMailboxIncident.open_for("dispatcher_silent")

    with_env(AgentMessages::DiscordBot::TOKEN_ENV => nil) do
      log2 = StringIO.new
      AgentMessages::FloorAlert.new(routes: routes, logger: Logger.new(log2)).call(now: t0 + 1.minute)
      assert_match(/DISCORD_AGENT_BOT_TOKEN is unset/, log2.string)
    end
  end

  test "an incident whose alert never posted gets no recovery line" do
    t0 = Time.current
    ping!(t0 - 6.minutes)
    recorder = Recorder.new
    alert(recorder, ops: nil).call(now: t0)
    ping!(t0 + 1.minute)

    alert(recorder).call(now: t0 + 1.minute)

    assert_empty recorder.posts
    assert AgentMailboxIncident.sole.resolved_at
  end

  test "a failed post is retried on the next run, and still posted once" do
    t0 = Time.current
    ping!(t0 - 6.minutes)
    recorder = Recorder.new(fail_times: 1)
    floor = alert(recorder)

    floor.call(now: t0)
    assert_empty recorder.posts
    assert_nil AgentMailboxIncident.sole.alert_posted_at

    floor.call(now: t0 + 1.minute)
    floor.call(now: t0 + 2.minutes)
    assert_equal 1, recorder.posts.size
  end

  test "the job runs the floor alert" do
    assert_nothing_raised { AgentDispatcherAlertJob.perform_now }
  end

  private

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
