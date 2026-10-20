require "test_helper"

# [unit] AgentMessages::FirstNameAsk: the CTO chat's own first-name ask (task
# cto-chat-quality-pass). Only the first message after the ask is read, a name
# or a skip; anything else goes to the model.
class FirstNameAskTest < ActiveSupport::TestCase
  Ask = AgentMessages::FirstNameAsk

  def name_of(text) = Ask.parse(text)&.then { |a| a.name? ? a.name : a.kind }

  test "[unit] a name, bare or introduced, is read; a lowercase one is capitalized" do
    assert_equal "Ada", name_of("Ada")
    assert_equal "Ada", name_of("ada.")
    assert_equal "Ada Lovelace", name_of("I'm Ada Lovelace")
    assert_equal "Jo", name_of("call me jo!")
    assert_equal "Mary-Jane", name_of("Hi, my name is Mary-Jane")
    assert_equal "José", name_of("It's José")
    assert_equal "DeShawn", name_of("DeShawn"), "a typed capital is kept"
  end

  test "[unit] a skip is read as a skip" do
    %w[skip Skip. pass nah later].each { |text| assert_equal :skip, name_of(text), text }
    [ "no thanks", "not now", "skip for now", "rather not" ].each { |text| assert_equal :skip, name_of(text), text }
  end

  test "[unit] anything that is not a name goes to the model" do
    [ "Can you add a booking page?", "yes", "hello", "what do you need", "1234", "a b c d", "",
      "ok", "Add dark mode to the site please" ].each { |text| assert_nil Ask.parse(text), text.inspect }
    assert_nil Ask.parse("A" * 41), "past the engine's per-name cap"
  end

  test "[unit] the save writes the engine's columns and backfills a blank name" do
    user = User.create!(email: "nameless-#{SecureRandom.hex(3)}@example.test")
    assert Ask.ask?(user)
    assert_equal "Ada", Ask.save!(user, "Ada Lovelace")
    user.reload
    assert_equal [ "Ada", "Lovelace", "Ada Lovelace" ], [ user.first_name, user.last_name, user.name ]
    assert_not Ask.ask?(user)
    assert_not Studio.first_name_outstanding?(user, {}), "the engine's own rule is settled"
  end

  test "[unit] the ask is pending only while the thread's newest turn asked and the name is blank" do
    user = User.create!(email: "nameless-#{SecureRandom.hex(3)}@example.test")
    thread = "web:pawsome:#{user.id}"
    row = ->(meta) { AgentMessage.create!(channel: "web", external_id: SecureRandom.uuid, channel_ref: "pawsome", thread_key: thread,
                                           author_ref: user.id.to_s, author_name: "x", content: "x", mentions: {}, sent_at: Time.current,
                                           soul_slug: AppCto::SOUL, status: "completed", run_meta: meta) }
    assert_not Ask.pending?(user, thread), "no turn yet"
    row.call({ Ask::META => true })
    assert Ask.pending?(user, thread)
    row.call({})
    assert_not Ask.pending?(user, thread), "only the first message after the ask"
  end
end
