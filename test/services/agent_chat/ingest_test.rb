require "test_helper"

# [unit] A satellite's message into the hub (AgentChat::Ingest): the row it
# becomes, who answers it, the anon fold on the first signed-in post, the caps,
# and the poll-only delivery (AgentMessages::WebChat).
class AgentChatIngestTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  ANON = "anon-cookie-token-0001".freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    @routes = AgentMessages::Routes.new("web" => { "souls" => %w[alex avi], "apps" => { "alex-build" => %w[alex avi] } })
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  def ingest(text, soul: "alex", email: nil, anon_token: nil, ip: "203.0.113.4", app: "alex-build", policy: BuildIntake.policy)
    visitor = AgentChat::Visitor.new(soul, email: email, anon_token: anon_token)
    AgentChat::Ingest.new(app: app, visitor: visitor, ip: ip, routes: @routes, policy: policy).call(text)
  end

  test "a signed-out visitor's message is a received web row for Alex, answered by the dispatcher" do
    message = ingest("  What can you build?  ", anon_token: ANON)

    assert_equal %w[web alex chat received chat], [ message.channel, message.soul_slug, message.routed_by, message.status, message.channel_ref ]
    assert_equal "What can you build?", message.content
    assert_equal "chat:alex:anon:#{AgentChat.anon_digest(ANON)}", message.thread_key
    assert_equal "alex-build", message.envelope["app"], "the app is recorded, never part of the key"
    assert_equal false, message.envelope["signed_in"]
    refute_includes message.envelope.to_json, "203.0.113.4", "the raw IP is never stored"
    refute_includes message.attributes.to_json, ANON, "the anon token is never stored"
    assert_equal message, AgentMessage.claimable(soul: "alex").first, "the claim's SQL guard admits it"
  end

  test "the same signed-in person posting from two apps lands in one thread" do
    user = User.create!(email: "builder@example.com", name: "Builder", role: "viewer")
    @routes = AgentMessages::Routes.new("web" => { "souls" => %w[alex], "apps" => { "alex-build" => %w[alex], "turf-monster" => %w[alex] } })

    one = ingest("from alex.build", email: user.email)
    two = ingest("from turf", email: user.email, app: "turf-monster")

    assert_equal "chat:alex:#{user.id}", one.thread_key
    assert_equal one.thread_key, two.thread_key
    assert_equal one.person, two.person
    assert_equal %w[alex-build turf-monster], [ one.envelope["app"], two.envelope["app"] ]
  end

  test "the public is answered only on the intake soul's chat: another soul holds it" do
    message = ingest("hi Avi", soul: "avi", anon_token: ANON)

    assert_equal "held", message.status
    assert message.events.exists?(kind: "held")
    assert_empty AgentMessage.claimable(soul: "avi")
  end

  test "an app or soul the allow-list does not name stores nothing" do
    assert_no_difference -> { AgentMessage.count } do
      assert_raises(AgentChat::Ingest::NotAvailable) { ingest("hi", anon_token: ANON, app: "turf-monster") }
      assert_raises(AgentChat::Ingest::NotAvailable) { ingest("hi", soul: "tyrion", anon_token: ANON) }
    end
  end

  test "an empty or over-long text is refused" do
    assert_equal "EMPTY", assert_raises(AgentChat::Ingest::Refused) { ingest("   ", anon_token: ANON) }.code
    long = "x" * (AgentMessages::WebIngest::MAX_LENGTH + 1)
    assert_equal "TOO_LONG", assert_raises(AgentChat::Ingest::Refused) { ingest(long, anon_token: ANON) }.code
  end

  test "the anon thread folds into the person's on their first signed-in post, once" do
    user = User.create!(email: "fold@example.com", name: "Fold", role: "viewer")
    first = ingest("before sign-in", anon_token: ANON)
    second = ingest("still signed out", anon_token: ANON)

    signed = ingest("now signed in", email: user.email, anon_token: ANON)

    person_key = "chat:alex:#{user.id}"
    assert_equal [ person_key ] * 3, [ first.reload, second.reload, signed ].map(&:thread_key)
    assert_equal 2, AgentMessageEvent.where(kind: "thread_folded", agent_message_id: [ first.id, second.id ]).count
    assert_equal "chat:alex:anon:#{AgentChat.anon_digest(ANON)}", first.events.find_by(kind: "thread_folded").detail["from"]
    refute AgentMessage.exists?(thread_key: "chat:alex:anon:#{AgentChat.anon_digest(ANON)}")

    assert_no_difference -> { AgentMessageEvent.where(kind: "thread_folded").count } do
      ingest("again", email: user.email, anon_token: ANON)
    end
  end

  test "the fold moves the anon visitor's identity, rows and notes to the person, orphaning nothing" do
    user = User.create!(email: "notes@example.com", name: "Notes", role: "viewer")
    anon_row = ingest("I run a bakery", anon_token: ANON)
    anon_person = anon_row.person
    AgentPersonNote.record_from!(anon_row, [ "Runs a bakery." ])

    signed = ingest("signed in", email: user.email, anon_token: ANON)

    person = signed.person
    assert_equal person, anon_row.reload.person, "the row is restamped to the person"
    assert_equal [ "Runs a bakery." ], person.notes.reload.map(&:body)
    assert_empty anon_person.notes.reload
    assert_equal person.id, AgentPersonIdentity.find_by(platform: "web", external_id: "chat-anon:#{AgentChat.anon_digest(ANON)}").agent_person_id
    assert_equal person, AgentChat::Visitor.new("alex", anon_token: ANON).person!, "the same browser signed out is still them"
  end

  test "a fold reaches only the visitor's own anon thread for that soul" do
    other = ingest("someone else", anon_token: "another-anon-token-0002")
    avi = ingest("to avi", soul: "avi", anon_token: ANON)

    ingest("signed in", email: "fold2@example.com", anon_token: ANON)

    assert_equal "chat:alex:anon:#{AgentChat.anon_digest('another-anon-token-0002')}", other.reload.thread_key
    assert_equal "chat:avi:anon:#{AgentChat.anon_digest(ANON)}", avi.reload.thread_key
  end

  test "caps: an anon thread past turns_per_request is refused and stores nothing" do
    policy = BuildIntake.policy.dup.tap { |p| p.turns_per_request = 2 }
    2.times { |i| ingest("q#{i}", anon_token: ANON, policy: policy) }

    error = assert_no_difference(-> { AgentMessage.count }) do
      assert_raises(AgentChat::Ingest::Capped) { ingest("one more", anon_token: ANON, policy: policy) }
    end
    assert_equal :thread, error.code
    assert_equal BuildIntake::Caps::REPLIES[:request_signed_out], error.message
  end

  test "caps: one visitor IP shares its hourly budget with /build" do
    policy = BuildIntake.policy.dup.tap { |p| p.per_ip_per_hour = 2 }
    request = AppRequest.create!(prompt: "A league site")
    BuildIntake::Ingest.new(request: request, ip: "203.0.113.9", policy: policy).call("on /build")
    ingest("on alex.build", anon_token: ANON, ip: "203.0.113.9", policy: policy)

    error = assert_raises(AgentChat::Ingest::Capped) { ingest("third", anon_token: "fresh-anon-token-0003", ip: "203.0.113.9", policy: policy) }
    assert_equal :ip, error.code
    assert ingest("another IP", anon_token: "fresh-anon-token-0003", ip: "198.51.100.1", policy: policy)
  end

  test "caps: the signed-out daily total" do
    policy = BuildIntake.policy.dup.tap { |p| p.daily_total = 1 }
    ingest("first today", anon_token: ANON, ip: nil, policy: policy)

    assert_equal :daily, assert_raises(AgentChat::Ingest::Capped) { ingest("second", anon_token: "fresh-anon-token-0003", ip: nil, policy: policy) }.code
  end

  test "caps: a signed-in thread takes WebIngest's rolling rate, not a lifetime count" do
    user = User.create!(email: "rate@example.com", name: "Rate", role: "viewer")
    stub_const(AgentMessages::WebIngest, :RATE_LIMIT, 2) do
      2.times { |i| ingest("m#{i}", email: user.email) }
      assert_equal :rate, assert_raises(AgentChat::Ingest::Capped) { ingest("m3", email: user.email) }.code
      AgentMessage.where(thread_key: "chat:alex:#{user.id}").update_all(created_at: 2.hours.ago)
      assert ingest("an hour later", email: user.email)
    end
  end

  test "the answer is delivered by the mark alone and the typing phase kept on the row: the app polls" do
    message = ingest("hello", anon_token: ANON)
    message.update!(status: "claimed", claimed_by: "w1", claimed_at: Time.current)

    refute AgentMessages::WebChat.broadcast_typing(message, phase: "thinking")
    assert_equal "thinking", message.reload.typing_phase

    message.update!(status: "completed", completed_at: Time.current, response_text: "Hi there")
    assert AgentMessages::WebChat.deliver!(message)
    assert_equal "posted", message.reload.reply_status
  end

  private

  def stub_const(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, old)
  end
end
