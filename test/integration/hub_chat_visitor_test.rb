# frozen_string_literal: true

require "test_helper"

# [integration] The hub's /chat is open: a visitor chats on an anon thread, the tier
# is the server's, and a browser cannot raise it.
class HubChatVisitorTest < ActionDispatch::IntegrationTest
  def last_viewer = AgentMessage.order(:id).last.envelope["viewer"]

  # A row saved before emails had one spelling: User.normalizes rewrites any write
  # through the model, so only raw SQL can still make one.
  def legacy_unproven_email!(user, email)
    User.connection.execute("UPDATE users SET email = #{User.connection.quote(email)}, email_verified_at = NULL WHERE id = #{user.id}")
  end

  test "[component] a visitor opens /chat with no voice recorder" do
    get chat_index_path
    assert_response :success
    assert_select "[data-test='alex-chat-page'] [data-test='agent-chat']"
    assert_select "[data-test='agent-chat-empty']", text: "What brought you here today?"
    assert_select "[data-test='voice-chat']", count: 0
    assert_select "h1[data-test='chat-heading']", text: "How Can I Help?", count: 1
    assert_select "[data-test='agent-chat-caption']", text: /Alex\s+·\s+AI Builder/
  end

  test "[component] /chat's heading has the weight of /build's" do
    get chat_index_path
    assert_select "h1.font-bold[data-test='chat-heading']", count: 1

    get build_path
    assert_select "h1.font-bold", text: "Want to Build Something?", count: 1
  end

  test "[component] /chat is only the chat: no form, no support rows, and one link to the sign-up" do
    get chat_index_path
    main = css_select("[data-test='alex-chat-page']").first

    assert_select "form[data-test='contact-form']", count: 0
    assert_select "[data-test='sms-disclosure']", count: 0
    assert_select "[data-test='contact-consent']", count: 0
    assert_equal 0, main.css("a[href^='mailto:'], a[href='/schedule']").size
    assert_select "[data-test='alex-chat-page'] a[href='/contact'][data-test='chat-sms-signup']", text: "Text message sign-up", count: 1
  end

  test "[component] a member and an admin get the same page; only an admin has the recorder" do
    Studio.stub(:voice_transcription, true) do
      log_in_as users(:viewer)
      get chat_index_path
      assert_response :success
      assert_select "[data-test='chat-sms-signup']", count: 1
      assert_select "[data-test='voice-chat']", count: 0

      reset!
      log_in_as users(:alex)
      get chat_index_path
      assert_response :success
      assert_select "[data-test='chat-sms-signup']", count: 1
      assert_select "[data-test='voice-chat']"
    end
  end

  test "a row from the hub's chat reaches the prompt with its directions" do
    require Rails.root.join("bin/lib/agent_mailbox").to_s
    post "/agent_chat/messages", params: { soul: "alex", text: "I need help" }
    row = AgentMessage.order(:id).last
    message = { "id" => row.id, "channel" => row.channel, "author_name" => "A visitor", "content" => row.content,
                "envelope" => row.envelope }
    prompt = AgentMailbox::ContextBuilder.new(soul: "alex", message: message, context: nil).prompt
    assert_includes prompt, "You NEVER collect text message consent"
  end

  test "a visitor who has not written polls an empty thread and gets no cookie" do
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_response :success
    assert_equal({ "turns" => [], "pending" => false }, response.parsed_body)
    assert_nil cookies[:studio_agent_chat_anon]
  end

  test "a visitor's post is stored as a visitor, whatever the browser claims" do
    post "/agent_chat/messages", params: { soul: "alex", text: "hello", viewer: "admin" }
    assert_response :created
    assert_equal "visitor", last_viewer
    assert_match %r{\Achat:alex:anon:}, AgentMessage.order(:id).last.thread_key

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal 1, response.parsed_body["turns"].size
  end

  test "a member and an admin carry their own tier" do
    log_in_as users(:viewer)
    post "/agent_chat/messages", params: { soul: "alex", text: "hello" }
    assert_response :created
    assert_equal "member", last_viewer

    reset!
    log_in_as users(:alex)
    post "/agent_chat/messages", params: { soul: "alex", text: "hello" }
    assert_equal "admin", last_viewer
  end

  test "signing in folds the visitor's thread into the person's on the next post" do
    post "/agent_chat/messages", params: { soul: "alex", text: "before" }
    log_in_as users(:viewer)
    post "/agent_chat/messages", params: { soul: "alex", text: "after" }
    assert_response :created

    get "/agent_chat/turns", params: { soul: "alex" }
    texts = response.parsed_body["turns"].map { |turn| turn["text"] || turn["content"] }
    assert_includes texts, "before"
    assert_includes texts, "after"
  end

  test "the public cap answers 429 and stores nothing" do
    full = Object.new
    def full.check(**) = :ip
    AgentChat::Caps.stub(:new, full) do
      before = AgentMessage.count
      post "/agent_chat/messages", params: { soul: "alex", text: "hello" }
      assert_response :too_many_requests
      assert_equal before, AgentMessage.count
    end
  end

  test "after sign-in the first poll shows the visitor's thread, in order, before any new post" do
    post "/agent_chat/messages", params: { soul: "alex", text: "before" }
    log_in_as users(:viewer)

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal [ "before" ], response.parsed_body["turns"].map { |turn| turn["text"] || turn["content"] }

    post "/agent_chat/messages", params: { soul: "alex", text: "after" }
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal %w[before after], response.parsed_body["turns"].map { |turn| turn["text"] || turn["content"] }
  end

  test "a claimed email cannot read its owner's thread" do
    victim = users(:viewer)
    victim_thread = AgentChat.user_thread_key("alex", victim.id)
    log_in_as victim
    post "/agent_chat/messages", params: { soul: "alex", text: "my secret" }
    assert_equal victim_thread, AgentMessage.order(:id).last.thread_key
    reset!

    claimer = User.create!(email: "claimer@example.com", name: "Claimer", role: "viewer", email_verified_at: Time.current)
    log_in_as claimer
    legacy_unproven_email!(claimer, victim.email.upcase)

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal [], response.parsed_body["turns"]

    post "/agent_chat/messages", params: { soul: "alex", text: "from the claimer" }
    assert_response :created
    assert_match %r{\Achat:alex:anon:}, AgentMessage.order(:id).last.thread_key
  end

  test "a claimed address on a satellite does not reach an unverified member's page" do
    claimer = User.create!(email: "first@example.com", name: "Claimer", role: "viewer", email_verified_at: Time.current)
    log_in_as claimer
    claimer.update_columns(email: "victim@example.com", email_verified_at: nil)
    person = AgentChat::Visitor.new("alex", email: "victim@example.com")
    AgentChat::Ingest.new(app: "alex-build", visitor: person, ip: "203.0.113.9").call("theirs")

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal [], response.parsed_body["turns"]
  end

  test "with forgery protection on, a first-visit token posts and no token is refused" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get chat_index_path
    token = css_select("[data-agent-chat-form] input[name='authenticity_token'], meta[name='csrf-token']").first
    value = token["value"] || token["content"]

    post "/agent_chat/messages", params: { soul: "alex", text: "no token" }
    assert_response :unprocessable_entity

    post "/agent_chat/messages", params: { soul: "alex", text: "with token" }, headers: { "X-CSRF-Token" => value }
    assert_response :created
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "a satellite's message for an address someone only claimed never reaches the claimer" do
    claimer = users(:viewer)
    log_in_as claimer
    patch "/profile", params: { profile: { email: "someone@example.com" } }
    person = AgentChat::Visitor.new("alex", email: "someone@example.com")
    assert_nil person.user, "an unproven address names no hub user"
    message = AgentChat::Ingest.new(app: "alex-build", visitor: person, ip: "203.0.113.9").call("my private business")

    refute_equal AgentChat.user_thread_key("alex", claimer.id), message.thread_key
    reset!
    claimer.update_columns(email: "claimer.again@example.com", email_verified_at: Time.current)
    log_in_as claimer.reload
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_empty response.parsed_body["turns"]
  end

  test "an older account claiming a member's address in another case does not capture their post" do
    claimer = User.create!(email: "older@example.com", name: "Older", role: "viewer")
    victim = User.create!(email: "victim@example.com", name: "Victim", role: "viewer", email_verified_at: Time.current)
    legacy_unproven_email!(claimer, "VICTIM@example.com")

    log_in_as victim
    post "/agent_chat/messages", params: { soul: "alex", text: "mine" }
    assert_response :created
    row = AgentMessage.order(:id).last
    assert_equal AgentChat.user_thread_key("alex", victim.id), row.thread_key
    assert_equal victim.id, row.envelope["user_id"]
  end

  # [integration] A poll never sends the session cookie back: a poll in flight
  # would otherwise undo a session write made meanwhile ("Skip for now").
  test "[integration] the turns poll leaves the session cookie alone" do
    log_in_as users(:viewer)
    get "/agent_chat/turns", params: { soul: "alex" }

    assert_response :success
    key = Rails.application.config.session_options[:key]
    assert_no_match(/^#{Regexp.escape(key)}=/, Array(response.headers["Set-Cookie"]).join("\n"))
  end

  # [integration] The home page's chat starts fresh: `since` hides the turns
  # before it, the thread keeps them, and a bad value is refused.
  test "[integration] since floors the poll; the thread keeps everything" do
    log_in_as users(:viewer)
    post "/agent_chat/messages", params: { soul: "alex", text: "earlier visit" }
    floor = AgentMessage.maximum(:id)
    post "/agent_chat/messages", params: { soul: "alex", text: "this visit" }

    texts = ->(body) { body["turns"].map { |turn| turn["text"] || turn["content"] } }
    get "/agent_chat/turns", params: { soul: "alex", since: floor }
    assert_equal [ "this visit" ], texts.call(response.parsed_body)

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal [ "earlier visit", "this visit" ], texts.call(response.parsed_body)

    get "/agent_chat/turns", params: { soul: "alex", since: "x" }
    assert_response :unprocessable_entity
  end
end
