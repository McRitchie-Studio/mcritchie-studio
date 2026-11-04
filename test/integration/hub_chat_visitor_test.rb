# frozen_string_literal: true

require "test_helper"

# [integration] The hub's chat on /contact is open: a visitor chats on an anon thread, the
# tier is the server's, and a browser cannot raise it. /chat redirects to it.
class HubChatVisitorTest < ActionDispatch::IntegrationTest
  def last_viewer = AgentMessage.order(:id).last.envelope["viewer"]

  # A row saved before emails had one spelling: User.normalizes rewrites any write
  # through the model, so only raw SQL can still make one.
  def legacy_unproven_email!(user, email)
    User.connection.execute("UPDATE users SET email = #{User.connection.quote(email)}, email_verified_at = NULL WHERE id = #{user.id}")
  end

  test "[component] a visitor opens the chat on /contact with no voice recorder" do
    get contact_form_path
    assert_response :success
    assert_select "[data-test='alex-chat-page'] [data-test='agent-chat']"
    assert_select "[data-test='agent-chat-empty']", text: "What brought you here today?"
    assert_select "[data-test='voice-chat']", count: 0
  end

  test "[component] a member gets no voice recorder and an admin's stays" do
    Studio.stub(:voice_transcription, true) do
      log_in_as users(:viewer)
      get contact_form_path
      assert_select "[data-test='agent-chat']"
      assert_select "[data-test='voice-chat']", count: 0

      reset!
      log_in_as users(:alex)
      get contact_form_path
      assert_select "[data-test='voice-chat']"
      assert_select "[data-test='agent-chat-empty']", text: /hold to talk/
    end
  end

  test "/chat answers a permanent redirect to /contact for a visitor, a member and an admin" do
    get "/chat"
    assert_response :moved_permanently
    assert_equal contact_form_url, response.location

    log_in_as users(:viewer)
    get "/chat"
    assert_response :moved_permanently
    assert_equal contact_form_url, response.location

    reset!
    log_in_as users(:alex)
    get "/chat"
    assert_response :moved_permanently
    assert_equal contact_form_url, response.location
  end

  test "/chat keeps no query string, so it cannot carry a source onto the form" do
    get "/chat", params: { source: { page: "integrations", item: "github" }, x: "1" }
    assert_response :moved_permanently
    assert_equal contact_form_url, response.location
  end

  test "the legacy POST /chat stays admin-only behind the wall" do
    post "/chat", params: { message: "hello" }, as: :json
    refute response.successful?, "a visitor must not reach the session-only responder"
  end

  test "a row from the hub's page reaches the prompt with the contact page's directions" do
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
    get contact_form_path
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
end
