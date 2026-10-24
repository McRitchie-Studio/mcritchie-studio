require "test_helper"
require_relative "../../support/agent_message_fixtures"
require_relative "../../support/agent_email_fixtures"

# [component] /admin/agent_messages — the list renders each message's soul, status
# chip, claim holder, attempts and reply link, filters narrow it, and the detail
# page renders the event timeline. Admin only.
class Admin::AgentMessagesControllerTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures
  include AgentEmailFixtures

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
    agent_message!(soul: "ray", content: "what is on the board?")
    agent_message!(soul: nil, status: "unrouted", routed_by: "none", content: "thinking out loud")

    log_in_as(admin)
    get admin_agent_messages_path
    assert_response :success
    assert_select "#am-rows tbody tr", 3
    assert_select "#am-row-#{claimed.id} .am-status-claimed", "claimed"
    assert_select "#am-row-#{claimed.id}", /macbook-4242-ab12/
    assert_select "#am-row-#{claimed.id}", /lease \d+m \d+s left/

    get admin_agent_messages_path(soul: "ray")
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

  test "the dispatcher row shows who serves the mailbox, its last ping, and a usage pause" do
    log_in_as(admin)
    get admin_agent_messages_path
    assert_select "#am-dispatchers", /No dispatcher has pinged yet/

    AgentDispatcher.ping!({ "worker" => "dispatcher-alex-mac-1-abc", "souls" => %w[ray], "running" => 2, "capacity" => 5,
                            "paused_until" => 2.hours.from_now.iso8601, "pause_reason" => "usage_limit",
                            "version" => "abc1234" })
    AgentDispatcher.ping!({ "worker" => "dispatcher-old" }, now: 1.hour.ago)
    get admin_agent_messages_path
    assert_select "#am-dispatchers .am-dispatcher", 2
    assert_select ".am-dispatcher[data-live=true]", /dispatcher-alex-mac-1-abc/
    assert_select ".am-dispatcher[data-live=true]", %r{2/5 running · ray}
    assert_select ".am-dispatcher[data-live=true] .am-chip", "paused"
    assert_select ".am-dispatcher[data-live=true]", /paused until .* \(usage_limit\)/
    assert_select ".am-dispatcher[data-live=false] .am-chip", "silent"
    assert_select "[data-test='dispatcher-role']", 0, "a primary carries no role chip"

    # [component] A registered standby is named, with its domains.
    AgentDispatcher.where(worker_id: "dispatcher-alex-mac-1-abc").update_all(role: "standby", standby_domains: %w[mcritchie_studio])
    get admin_agent_messages_path
    assert_select ".am-dispatcher[data-live=true] [data-test='dispatcher-role']", "standby · mcritchie_studio"
  end

  test "an email row shows its sender and whether the sender was verified" do
    AgentPerson.seed_owner!
    verified = AgentMessages::EmailIngest.new.call(agent_email)
    forged = AgentMessages::EmailIngest.new.call(agent_email(top_result: nil, message_id: "forged-admin@x"))

    log_in_as(admin)
    get admin_agent_message_path(verified)
    assert_select "#am-email-trust", /alex@mcritchie\.studio.*verified/m
    get admin_agent_message_path(forged)
    assert_select "#am-email-trust", /NOT verified \(treated as the public\)/
    get admin_agent_messages_path(channel: "email")
    assert_select "#am-rows tbody tr", 2
  end
end
