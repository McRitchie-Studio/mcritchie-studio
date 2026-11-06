require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [integration] /admin/upgrade_proposals: the owner's review of Alex's upgrade
# proposals. Admin only; Approve sets the tier on an app the person owns and
# says so; Decline drops it; a settled proposal is told, never changed again.
class Admin::UpgradeProposalsControllerTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  setup do
    @user = User.create!(email: "review-visitor@example.com", name: "Review Visitor")
    @client_app = App.create!(slug: "review-test-app", name: "Review Test App", package_tier: "builder")
    AppMembership.create!(app_slug: @client_app.slug, user_slug: @user.slug)
    person = AgentPerson.resolve!(platform: "web", external_id: "review-#{SecureRandom.hex(3)}", display_name: "Review Visitor")
    message = agent_message!(soul: "alex", person: person, channel: "web", guild_id: nil, channel_ref: "chat",
                             thread_key: AgentChat.user_thread_key("alex", @user.id), status: "claimed", claimed_by: "w1",
                             lease_expires_at: 5.minutes.from_now, attempts: 1)
    message.complete!(worker: "w1", response_text: "Sure.",
                      proposal: { "kind" => "upgrade", "params" => { "tier" => "pro", "app" => @client_app.slug }, "summary" => "Wants Pro" })
    @proposal = AgentProposal.sole
  end

  def admin
    @admin ||= User.find_by(role: "admin") || User.create!(email: "review-admin@example.com", name: "Review Admin", role: "admin")
  end

  test "anonymous and non-admin visitors can neither read nor approve" do
    get admin_upgrade_proposals_path
    assert_response :redirect
    log_in_as(@user)
    post admin_approve_upgrade_proposal_path(@proposal)
    assert_response :redirect
    assert_equal "proposed", @proposal.reload.status
    assert_equal "builder", @client_app.reload.package_tier
  end

  test "the owner sees the open proposal with its app, and Approve sets the tier" do
    log_in_as(admin)
    get admin_upgrade_proposals_path
    assert_response :success
    assert_select "[data-test='upgrade-proposal'][data-proposal-id='#{@proposal.id}']" do
      assert_select "h2", text: /Pro · monthly/
      assert_select "[data-test='upgrade-proposal-summary']", text: "Wants Pro"
      assert_select "[data-test='upgrade-proposal-app']", text: /review-test-app \(now Builder\)/
      assert_select "form[action='#{admin_approve_upgrade_proposal_path(@proposal)}']"
      assert_select "form[action='#{admin_decline_upgrade_proposal_path(@proposal)}']"
    end

    post admin_approve_upgrade_proposal_path(@proposal)
    assert_redirected_to admin_upgrade_proposals_path
    assert_equal "Approved: review-test-app is now on Pro.", flash[:notice]
    assert_equal "pro", @client_app.reload.package_tier
    assert_equal "user:#{User.find_by(email: admin.email).slug}", @proposal.reload.settled_by

    post admin_approve_upgrade_proposal_path(@proposal)
    assert_equal "Nothing changed: that proposal is executed.", flash[:alert]
    follow_redirect!
    assert_select "[data-test='upgrade-proposals-empty']"
    assert_select "[data-test='upgrade-proposals-recent']", text: /approved, tier set/
  end

  test "Decline drops it and changes no tier" do
    log_in_as(admin)
    post admin_decline_upgrade_proposal_path(@proposal)
    assert_redirected_to admin_upgrade_proposals_path
    assert_equal "rejected", @proposal.reload.status
    assert_equal "builder", @client_app.reload.package_tier
  end
end
