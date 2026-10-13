require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [component] /admin/agent_messages — the list renders each message's soul, status
# chip, claim holder, attempts and reply link, filters narrow it, and the detail
# page renders the event timeline. Admin only.
class Admin::AgentMessagesControllerTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  def admin
    @admin ||= User.find_by(role: "admin") || User.create!(email: "inbox-admin@example.com", name: "Inbox Admin", role: "admin")
  end

  test "anonymous and non-admin visitors are turned away" do
    get admin_agent_messages_path
    assert_response :redirect

    log_in_as(User.create!(email: "inbox-member@example.com", name: "Member"))
    get admin_agent_messages_path
    assert_response :redirect
  end

  test "the list shows status, soul, claim holder and attempts, and filters by soul and status" do
    claimed = agent_message!(soul: "avi", content: "is the release green?")
    AgentMessage.claim!(soul: "avi", worker: "macbook-4242-ab12")
    agent_message!(soul: "xan", content: "what is on the board?")
    agent_message!(soul: nil, status: "unrouted", routed_by: "none", content: "thinking out loud")

    log_in_as(admin)
    get admin_agent_messages_path
    assert_response :success
    assert_select "#am-rows tbody tr", 3
    assert_select "#am-row-#{claimed.id} .am-status-claimed", "claimed"
    assert_select "#am-row-#{claimed.id}", /macbook-4242-ab12/
    assert_select "#am-row-#{claimed.id}", /lease \d+m \d+s left/

    get admin_agent_messages_path(soul: "xan")
    assert_select "#am-rows tbody tr", 1
    assert_select "#am-rows", /what is on the board/

    get admin_agent_messages_path(soul: "avi", status: "received")
    assert_select "#am-empty", /matching these filters/
    assert_select "#am-filters a[href=?]", admin_agent_messages_path(soul: "avi"), text: "Any"
  end

  test "the detail page shows the untrusted message, the answer and the timeline with the reply link" do
    message = agent_message!(soul: "avi", content: "<script>alert(1)</script> release?")
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "rel-1 is green.", action_summary: "ran bin/release status")
    message.update!(reply_external_id: "880000000000000001", reply_posted_at: Time.current)
    message.record!("reply_posted", actor: "discord-bot", detail: { "reply_id" => "880000000000000001", "url" => message.reply_url })

    log_in_as(admin)
    get admin_agent_message_path(message)
    assert_response :success
    assert_select "#am-status.am-status-completed"
    assert_select "#am-timeline li", 3
    assert_select "#am-timeline li[data-kind=claimed]", /by avi/
    assert_select "#am-timeline li[data-kind=reply_posted] a[href=?]", message.reply_url
    assert_select "#am-reply-link a[href=?]", message.reply_url
    assert_includes response.body, "rel-1 is green."
    assert_includes response.body, "ran bin/release status"
    refute_includes response.body, "<script>alert(1)</script>", "untrusted content is escaped"
  end

  test "mention tokens read as the soul they route to; a completed message shows its reply state" do
    routes = agent_routes
    message = agent_message!(soul: "avi", content: "<@&#{AVI_ROLE}> and <@&123> and <@#{SHARED_BOT}> hi")
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "ok")

    log_in_as(admin)
    AgentMessages::Routes.stub(:load, routes) do
      get admin_agent_messages_path
      assert_select "#am-row-#{message.id}", /@avi and @role and @user hi/
      assert_select "#am-row-#{message.id} .am-reply-queued", "queued"

      get admin_agent_message_path(message)
      assert_select ".am-untrusted", "@avi and @role and @user hi"
    end
  end
end
