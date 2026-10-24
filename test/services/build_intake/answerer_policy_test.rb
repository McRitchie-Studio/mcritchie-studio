require "test_helper"

# [unit] The answerer policy for public intake, with the shipped
# config/agent_answerers.yml: Ritch answers a signed-out visitor ONLY on a web row
# of a web:build: thread, the claim's SQL guard agrees with allowed?, the config
# cannot widen the prefix, and the caps hold per request, per IP and per day.
class BuildIntakeAnswererPolicyTest < ActiveSupport::TestCase
  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    @answerers = AgentMessages::Answerers.current
    @owner = AgentPerson.seed_owner!
    @request = AppRequest.create!(prompt: "A booking site for my dog-grooming business")
    @stranger = AgentPerson.create!(display_name: "Stranger")
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  def row(thread_key:, soul: "ray", channel: "web", person: @stranger, status: "received", **extra)
    AgentMessage.create!(channel: channel, external_id: SecureRandom.uuid, channel_ref: channel == "web" ? "build" : "1",
                         thread_key: thread_key, soul_slug: soul, content: "hi", person: person, status: status,
                         author_ref: "x", **extra)
  end

  def build_thread = BuildIntake.thread_key(@request.token)

  test "the shipped config answers the owner everywhere and the public only on /build threads" do
    assert_equal %w[owner], @answerers.roles
    assert_equal "ray", @answerers.public_intake_soul

    intake = row(thread_key: build_thread)
    cto_chat = row(thread_key: "web:turf-monster:12", soul: "turf_monster")
    ray_elsewhere = row(thread_key: "web:mcritchie-studio:12")
    other_soul = row(thread_key: build_thread, soul: "avi")
    discord = row(thread_key: "discord:#{build_thread}", channel: "discord")

    assert @answerers.allowed?(@stranger, message: intake)
    refute @answerers.allowed?(@stranger), "no message: the public is not answered"
    [ cto_chat, ray_elsewhere, other_soul, discord ].each do |m|
      refute @answerers.allowed?(@stranger, message: m), "#{m.thread_key} (#{m.soul_slug}) must not answer the public"
    end
    assert @answerers.allowed?(@owner, message: cto_chat), "the owner is answered as before"
    refute @answerers.allowed?(nil, message: intake), "a row with no person is never answered"
  end

  test "the claim's SQL guard is the same rule: only the intake row is claimable for the public" do
    # Each row from its own person, the intake row LAST, so neither wait rule
    # (one open message per person, per thread) can be what hides the others.
    person = -> { AgentPerson.create!(display_name: "Visitor") }
    row(thread_key: "web:mcritchie-studio:12", person: person.call)
    row(thread_key: "web:buildx:#{@request.token}", person: person.call)
    row(thread_key: "web_build_#{@request.token}", person: person.call)
    row(thread_key: build_thread, soul: "avi", person: person.call)
    intake = row(thread_key: build_thread, person: person.call)

    assert_equal [ intake.id ], AgentMessage.claimable(soul: %w[ray avi turf_monster]).pluck(:id),
                 "a lookalike key (web:buildx:, web_build_, a LIKE wildcard) or another soul is not intake"
  end

  test "a held intake row (bot shield) is never claimed" do
    row(thread_key: build_thread, status: "held")
    assert_empty AgentMessage.claimable(soul: "ray")
  end

  test "the config cannot widen public intake or set a bad cap" do
    base = { "soul" => "ray", "thread_prefix" => "web:build:", "turns_per_request" => 12,
             "signed_in_turns_per_request" => 40, "per_ip_per_hour" => 20, "daily_total" => 400 }
    assert AgentMessages::Answerers.new(%w[owner], public_intake: base).public_intake

    [ { "thread_prefix" => "web:" }, { "thread_prefix" => "" }, { "soul" => "Ritch; DROP" },
      { "turns_per_request" => 0 }, { "daily_total" => "400" } ].each do |bad|
      assert_raises(AgentMessages::Answerers::Invalid, bad.inspect) do
        AgentMessages::Answerers.new(%w[owner], public_intake: base.merge(bad))
      end
    end
    refute AgentMessages::Answerers.new(%w[owner]).allowed?(@stranger, message: row(thread_key: build_thread)),
           "with no public_intake block nobody signed out is answered"
  end

  test "caps: 12 answers per request signed out, 40 signed in" do
    caps = BuildIntake::Caps.new
    11.times { row(thread_key: build_thread, status: "completed") }
    row(thread_key: build_thread, status: "held")
    row(thread_key: build_thread, status: "completed", action_summary: BuildIntake::Caps::CAP_SUMMARY)
    assert_nil caps.check(token: @request.token, signed_in: false), "held rows and cap replies are not answers"

    row(thread_key: build_thread, status: "completed")
    assert_equal :request, caps.check(token: @request.token, signed_in: false)
    assert_nil caps.check(token: @request.token, signed_in: true)
    assert_match(/Sign in to continue/, BuildIntake::Caps.reply(:request, signed_in: false))
  end

  test "caps: per IP per hour across requests, and a daily total of signed-out answers" do
    policy = BuildIntake.policy.dup.tap { |p| p.per_ip_per_hour = 2; p.daily_total = 3 }
    caps = BuildIntake::Caps.new(policy: policy)
    ip = BuildIntake::Ingest.ip_hash("203.0.113.9")
    other = AppRequest.create!(prompt: "another")
    row(thread_key: build_thread, envelope: { "ip_hash" => ip, "signed_in" => false })
    row(thread_key: BuildIntake.thread_key(other.token), envelope: { "ip_hash" => ip, "signed_in" => false })
    assert_equal :ip, caps.check(token: "fresh-token-0000000000", signed_in: false, ip_hash: ip)
    assert_nil caps.check(token: "fresh-token-0000000000", signed_in: true, ip_hash: ip), "an account is not IP-capped"

    row(thread_key: BuildIntake.thread_key(other.token), envelope: { "ip_hash" => "elsewhere", "signed_in" => false })
    assert_equal :daily, caps.check(token: "fresh-token-0000000000", signed_in: false, ip_hash: "new-ip")
    travel 1.day do
      assert_nil BuildIntake::Caps.new(policy: policy).check(token: "fresh-token-0000000000", signed_in: false, ip_hash: "new-ip")
    end
  end
end
