# frozen_string_literal: true

require "test_helper"

# [integration] The hub's /chat is open: a visitor chats on an anon thread, the tier
# is the server's, and a browser cannot raise it.
class HubChatVisitorTest < ActionDispatch::IntegrationTest
  def last_viewer = AgentMessage.order(:id).last.envelope["viewer"]

  test "[component] a visitor opens /chat with no voice recorder" do
    get chat_index_path
    assert_response :success
    assert_select "[data-test='alex-chat-page']"
    assert_select "[data-test='voice-chat']", count: 0
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
end
