require "test_helper"
require "minitest/mock"

# [unit] The floor's harness_degraded check, its flapping line, and its
# escalation to a person (AgentMessages::FloorAlert, AgentFloorMailer):
#
#   - harness_degraded opens after AgentDispatcher::HARNESS_BEATS (5) consecutive
#     measured beats with op or gh false, and only while the dispatcher is live
#   - an episode that opens 3 times within an hour posts ONE "flapping, N since
#     HH:MM" line instead of a line per flap, and one line when it is steady
#   - ONE email to the ops address when an incident stays open 15 minutes or its
#     episode flaps, ONE when the episode has been quiet 15 minutes, through the
#     outbox (Studio::EmailDelivery rows asserted), whether or not Discord is set
#
# Discord is a recording transport; mail goes no further than the outbox table.
class AgentMessages::FloorEscalationTest < ActiveSupport::TestCase
  OPS = "900000000000000777".freeze
  OPS_EMAIL = "ops-test@mcritchie.studio".freeze

  class Recorder
    attr_reader :posts

    def initialize = @posts = []

    def call(_method, _url, _headers, body)
      @posts << JSON.parse(body)["content"]
      [ 200, JSON.generate("id" => "1#{@posts.size}") ]
    end
  end

  setup do
    @t0 = Time.zone.parse("2026-10-24 14:00:00 -0600")
    @recorder = Recorder.new
  end

  def floor(ops: OPS)
    routes = AgentMessages::Routes.new("discord" => { "ops_channel_id" => ops, "guilds" => {} },
                                       "floor" => { "escalation_email" => OPS_EMAIL })
    bot = AgentMessages::DiscordBot.new(token: "test-token", transport: @recorder)
    AgentMessages::FloorAlert.new(routes: routes, bot: bot, logger: Logger.new(nil))
  end

  def at(minutes) = @t0 + minutes.minutes

  def ping!(time, **harness)
    params = { "worker" => "d-1", "host" => "alex-mac", "souls" => [ "ray" ] }
    params.merge!(harness.transform_keys(&:to_s))
    AgentDispatcher.ping!(params, now: time)
  end

  def beat!(time, op_ok: true, gh_ok: true)
    ping!(time, op_ok: op_ok, gh_ok: gh_ok, power: "ac", harness_measured_at: time.iso8601)
  end

  def emails(action = nil)
    scope = Studio::EmailDelivery.where(mailer: "AgentFloorMailer")
    action ? scope.where(action: action.to_s) : scope
  end

  # ── harness_degraded ──────────────────────────────────────────────────────

  test "harness_degraded opens on the fifth consecutive failing beat, once, and recovers on a good one" do
    f = floor
    4.times do |i|
      beat!(at(i), op_ok: false)
      f.call(now: at(i))
    end
    assert_nil AgentMailboxIncident.open_for("harness_degraded"), "four failing beats are not yet an incident"
    assert_equal 4, AgentDispatcher.sole.harness_failing_beats

    beat!(at(4), op_ok: false)
    f.call(now: at(4))
    beat!(at(5), op_ok: false)
    f.call(now: at(5))

    incident = AgentMailboxIncident.open_for("harness_degraded")
    assert incident
    assert_equal 1, @recorder.posts.size, "one line per incident, not one per beat"
    assert_match(/Agent harness degraded on alex-mac: 1Password \(`op whoami`\) failing on 5 beats in a row/, @recorder.posts.first)
    assert_match(/OP_CACHE=false op whoami/, @recorder.posts.first)
    assert_match(/SOP agent-dispatcher/, @recorder.posts.first)

    beat!(at(6))
    f.call(now: at(6))
    assert_equal 0, AgentDispatcher.sole.harness_failing_beats
    assert incident.reload.resolved_at
    assert_match(/Agent harness healthy/, @recorder.posts.last)
  end

  test "a ping repeating the same measurement, or carrying none, does not count as a beat" do
    beat!(at(0), gh_ok: false)
    3.times { |i| ping!(at(i + 1), op_ok: true, gh_ok: false, harness_measured_at: at(0).iso8601) }
    ping!(at(5))
    assert_equal 1, AgentDispatcher.sole.harness_failing_beats, "five pings, one measurement"
    assert_equal false, AgentDispatcher.sole.gh_ok
  end

  test "control: a silent dispatcher's stale harness is not harness_degraded; dispatcher_silent covers it" do
    5.times { |i| beat!(at(i), gh_ok: false) }
    checks = floor.call(now: at(15))

    refute checks.find { |c| c.kind == "harness_degraded" }.failing
    assert checks.find { |c| c.kind == "dispatcher_silent" }.failing
  end

  test "dispatcher_silent says when the last ping was on battery" do
    ping!(at(0), power: "battery")
    floor.call(now: at(6))
    assert_match(/Its last ping said the Mac was on battery/, @recorder.posts.first)
  end

  # ── flapping and escalation ───────────────────────────────────────────────

  # Silent at +k, back at +k+1: each cycle is one incident of dispatcher_silent.
  def flap!(f, silent_at)
    f.call(now: at(silent_at))
    ping!(at(silent_at + 1))
    f.call(now: at(silent_at + 1))
  end

  test "a flapping incident posts one flapping line, emails once, and once more when steady" do
    f = floor
    ping!(at(-6))
    flap!(f, 0)
    flap!(f, 7)
    assert_equal 4, @recorder.posts.size, "two flaps under the threshold: a line per incident and recovery"
    assert_equal 0, emails.count

    f.call(now: at(14))
    assert_match(/\AAgent dispatcher silent: flapping, 3 since 14:00 MDT\./, @recorder.posts.last)
    assert_equal 1, emails(:escalated).count, "the third opening within the hour escalates"
    escalated = emails(:escalated).sole
    assert_equal OPS_EMAIL, escalated.to

    ping!(at(15))
    f.call(now: at(15))
    flap!(f, 21)
    assert_equal 5, @recorder.posts.size, "later flaps and their recoveries post nothing; the flapping line covers them"
    assert_equal 1, emails(:escalated).count, "never a second escalation for the episode"
    assert_equal 4, AgentMailboxIncident.where(kind: "dispatcher_silent").count
    assert_equal 1, AgentMailboxIncident.roots.where(kind: "dispatcher_silent").count, "four incidents, one episode"

    ping!(at(30))
    f.call(now: at(30))
    assert_equal 0, emails(:recovered).count, "eight quiet minutes is not yet steady"

    ping!(at(38))
    f.call(now: at(38))
    ping!(at(39))
    f.call(now: at(39))
    assert_equal 1, emails(:recovered).count, "one recovery email once quiet for 15 minutes"
    assert_match(/steady again, nothing open for 15 minutes after 4 openings since 14:00 MDT/, @recorder.posts.last)
    assert_equal 6, @recorder.posts.size, "one closing line"
  end

  test "an incident open 15 minutes emails once, and once on recovery after 15 quiet minutes" do
    f = floor
    ping!(at(-6))
    f.call(now: at(0))
    f.call(now: at(14))
    assert_equal 0, emails.count, "14 minutes open: no email yet"

    f.call(now: at(15))
    f.call(now: at(16))
    f.call(now: at(20))
    assert_equal 1, emails(:escalated).count

    ping!(at(25))
    f.call(now: at(25))
    assert_match(/Agent dispatcher back/, @recorder.posts.last, "Discord keeps its per-incident recovery line")
    ping!(at(30))
    f.call(now: at(30))
    assert_equal 0, emails(:recovered).count

    ping!(at(40))
    f.call(now: at(40))
    ping!(at(45))
    f.call(now: at(45))
    assert_equal 1, emails(:recovered).count
    assert_equal 2, emails.count, "never more than one email per incident per state"
    assert_equal 2, @recorder.posts.size, "one alert, one recovery: no flapping line for a single long incident"
  end

  test "control: a short incident that recovers in time emails nobody" do
    f = floor
    ping!(at(-6))
    f.call(now: at(0))
    ping!(at(3))
    f.call(now: at(3))
    ping!(at(30))
    f.call(now: at(30))
    assert_equal 0, emails.count
  end

  test "the email goes out with no Discord configured" do
    f = floor(ops: nil)
    ping!(at(-6))
    f.call(now: at(0))
    f.call(now: at(15))
    assert_empty @recorder.posts
    assert_equal 1, emails(:escalated).count
  end

  test "a failed send stamps nothing and is retried on the next run" do
    f = floor
    ping!(at(-6))
    f.call(now: at(0))
    Studio::Email.stub(:deliver, ->(*_a, **_k) { raise "outbox down" }) { f.call(now: at(15)) }
    assert_nil AgentMailboxIncident.sole.escalated_at
    f.call(now: at(16))
    assert_equal 1, emails(:escalated).count
    assert AgentMailboxIncident.sole.escalated_at
  end

  # Two overlapping job runs both read the root before either stamped it: the
  # row lock and the re-read under it let only the first send.
  test "an overlapping run holding a stale root sends no second email" do
    f = floor
    ping!(at(-6))
    f.call(now: at(0))
    stale = AgentMailboxIncident.sole
    f.call(now: at(15))
    assert_equal 1, emails(:escalated).count
    assert_nil stale.escalated_at, "the second run's copy predates the stamp"

    sent = false
    f.send(:send_once, stale, :escalated_at, at(15)) { sent = true }
    refute sent, "the stamp read under the lock stops the second send"
  end

  test "the escalation email names the incident and the SOP" do
    ping!(at(-6))
    floor.call(now: at(0))
    root = AgentMailboxIncident.sole

    travel_to(at(16)) do
      mail = AgentFloorMailer.escalated(root.id, "open", OPS_EMAIL)
      assert_equal [ OPS_EMAIL ], mail.to
      assert_equal "Floor alert: Agent dispatcher silent (open 16 min)", mail.subject
      assert_match(/Agent dispatcher silent: no ping from bin\/dispatcher on alex-mac/, mail.body.encoded)
      assert_match(/SOP agent-dispatcher/, mail.body.encoded)
      assert_match(%r{docs/agents/agents/steffon/sops/agent-dispatcher\.md}, mail.body.encoded)

      recovered = AgentFloorMailer.recovered(root.id, OPS_EMAIL)
      assert_equal "Floor clear: Agent dispatcher silent", recovered.subject
    end
  end

  test "the ops address comes from floor.escalation_email, else alex@mcritchie.studio" do
    assert_equal "alex@mcritchie.studio", AgentMessages::Routes.new({}).ops_email
    assert_equal OPS_EMAIL, AgentMessages::Routes.new("floor" => { "escalation_email" => OPS_EMAIL }).ops_email
    assert_equal "alex@mcritchie.studio", AgentMessages::Routes.load.ops_email
  end
end
