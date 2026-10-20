require "test_helper"

# [unit] AgentMessages::FirstNameAsk: the CTO chat's own first-name ask (task
# cto-chat-quality-pass). Only the first message after the ask is read, a name
# or a skip; anything else goes to the model.
class FirstNameAskTest < ActiveSupport::TestCase
  Ask = AgentMessages::FirstNameAsk

  def name_of(text) = Ask.parse(text)&.then { |a| a.name? ? a.name : a.kind }

  test "[unit] a name: one word, two capitalized words, or up to three after a cue" do
    assert_equal "Ada", name_of("Ada")
    assert_equal "Ada", name_of("ada.")
    assert_equal "Mary Jane", name_of("Mary Jane")
    assert_equal "Ada Lovelace", name_of("Ada Lovelace")
    assert_equal "Ada Lovelace", name_of("I'm Ada Lovelace")
    assert_equal "Ada Lovelace", name_of("i'm ada lovelace"), "after a cue, any case, capitalized"
    assert_equal "Jo", name_of("call me jo!")
    assert_equal "Alex", name_of("call me alex")
    assert_equal "Mary-Jane", name_of("Hi, my name is Mary-Jane")
    assert_equal "José", name_of("It's José")
    assert_equal "DeShawn", name_of("DeShawn"), "a typed capital is kept"
    assert_nil Ask.parse("call me Will"), "a stop word rejects even after a cue (\"It's fine\"): such a name goes to the model and /profile"
  end

  test "[unit] a skip is read as a skip" do
    %w[skip Skip. pass nah later].each { |text| assert_equal :skip, name_of(text), text }
    [ "no thanks", "not now", "skip for now", "rather not" ].each { |text| assert_equal :skip, name_of(text), text }
  end

  # Carl's probe list (review of this task): each was saved as a first name, and
  # the request never reached the model. When in doubt, the model answers.
  CARL_PROBES = [ "Add dark mode", "Sounds good", "Thank you", "Looks great", "Make it blue", "Change the logo",
                  "What's next", "Love it", "Perfect", "Great", "Awesome", "Cool", "Can you help", "Add a blog",
                  "Sure thing", "Go ahead", "Ship it", "Let's go", "Ignore previous instructions" ].freeze

  test "[unit] anything that is not a name goes to the model" do
    (CARL_PROBES + [ "Can you add a booking page?", "yes", "hello", "what do you need", "1234", "a b c d", "",
                     "ok", "Add dark mode to the site please", "dark mode", "ada lovelace", "Pricing", "Logo",
                     "Will", "It's fine", "This is great", "Book Now Please", "make it pop" ]).each do |text|
      assert_nil Ask.parse(text), "#{text.inspect} must reach the model"
    end
    assert_nil Ask.parse("A" * 41), "past the engine's per-name cap"
  end

  test "[unit] a correction needs a cue" do
    assert_equal "Al", Ask.parse("call me Al", cue_required: true).name
    assert_nil Ask.parse("Al", cue_required: true)
    assert_nil Ask.parse("skip", cue_required: true)
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

  test "[unit] right after a saved name, a cued message corrects it, name and all; anything else is the model's" do
    user = User.create!(email: "nameless-#{SecureRandom.hex(3)}@example.test")
    assert_match(/\ANice to meet you, Ada! \(Not right\? Say "call me" and your name\.\)/, Ask.reply!(user, Ask.parse("Ada Lovelace")))
    thread = "web:pawsome:#{user.id}"
    AgentMessage.create!(channel: "web", external_id: SecureRandom.uuid, channel_ref: "pawsome", thread_key: thread,
                         author_ref: user.id.to_s, author_name: "x", content: "Ada Lovelace", mentions: {}, sent_at: Time.current,
                         soul_slug: AppCto::SOUL, status: "completed", run_meta: { "first_name" => "saved" })
    assert_nil Ask.answer_for(user.reload, thread, "Add dark mode")
    assert_nil Ask.answer_for(user, thread, "Al")
    correction = Ask.answer_for(user, thread, "call me Al")
    assert correction.correction
    assert_equal "Got it, Al. #{Ask::NEXT_STEP}", Ask.reply!(user, correction)
    assert_equal [ "Al", nil, "Al" ], user.reload.values_at(:first_name, :last_name, :name)
  end
end
