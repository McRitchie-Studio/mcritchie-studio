require "test_helper"
require "rake"
require_relative "../support/agent_message_fixtures"

# [integration] The owner-only guard end to end, with the shipped
# config/agent_answerers.yml: a stranger's @Ray arriving through the ingest the
# gateway and poll share is stored held, the claim API (bin/dispatcher's call)
# never hands it out, the admin page shows it with a CSRF-guarded Release button,
# and releasing it (the button or `bin/rails agent_people:release`) makes it
# claimable. Alex's own @Ray is claimed, completed and queued for reply as before.
class AgentOwnerOnlyGuardTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  ALEX = AgentPerson::OWNER[:external_id]
  STRANGER = "777000000000000009".freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    AgentPerson.seed_owner!
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @shared = { "Authorization" => "Bearer #{token}" }
    @admin = User.find_by(role: "admin") || User.create!(email: "guard-admin@example.com", name: "Guard Admin", role: "admin")
  end

  def ingest(id, author:)
    raw = discord_raw(id, content: "<@&#{RAY_ROLE}> what is on the board?", author: author, roles: [ RAY_ROLE ], guild: GUILD)
    AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD, source: "discord-gateway")
  end

  def claim_over_http(worker)
    post claim_api_v1_agent_messages_url, params: { souls: %w[ray avi], worker: worker }, headers: @shared, as: :json
    assert_response :success
    response.parsed_body["data"]
  end

  test "a stranger's @Ray is held and never claimed; Alex's is answered as before" do
    held = ingest(2001, author: STRANGER)
    assert_equal "held", held.status

    assert_nil claim_over_http("mac-1"), "the dispatcher's claim never returns a held message"

    get api_v1_agent_messages_url, params: { status: "held" }, headers: @shared
    assert_response :success
    assert_equal [ held.id ], response.parsed_body["data"].map { |m| m["id"] }, "bin/agent-inbox list --status held reads it"

    mine = ingest(2002, author: ALEX)
    data = claim_over_http("mac-1")
    assert_equal mine.id, data["id"]
    post complete_api_v1_agent_message_url(mine), params: { worker: "mac-1", response_text: "Two tasks in review." },
                                                  headers: @shared, as: :json
    assert_response :success
    assert_equal "completed", mine.reload.status
    assert_equal "queued", mine.reply_status
    assert_equal "held", held.reload.status
    assert_nil claim_over_http("mac-1")
  end

  test "[unit] a stranger's held message never shows typing; Alex's claimed one does" do
    held = ingest(2201, author: STRANGER)
    assert_no_enqueued_jobs(only: AgentMessageTypingJob) do
      post typing_api_v1_agent_message_url(held), params: { worker: "mac-1" }, headers: @shared, as: :json
    end
    assert_response :conflict, "a held message is never claimed, so nobody holds it to type for"

    mine = ingest(2202, author: ALEX)
    assert_equal mine.id, claim_over_http("mac-1")["id"]
    assert_enqueued_with(job: AgentMessageTypingJob, args: [ mine.id, "mac-1" ]) do
      post typing_api_v1_agent_message_url(mine), params: { worker: "mac-1" }, headers: @shared, as: :json
    end
    assert_equal "queued", response.parsed_body.dig("meta", "typing")
  end

  test "the admin page shows a held message with a Release button, and releasing it makes it claimable" do
    held = ingest(2101, author: STRANGER)

    log_in_as(@admin)
    get admin_agent_messages_path(status: "held")
    assert_response :success
    assert_select "#am-row-#{held.id} .am-status-held", text: "held"

    get admin_agent_message_path(held)
    assert_response :success
    assert_select "#am-hold", /role \(public\) is not answered; config\/agent_answerers.yml answers owner/
    assert_select "form[action='#{release_hold_admin_agent_message_path(held)}'] button#am-release-hold"

    post release_hold_admin_agent_message_path(held)
    assert_redirected_to admin_agent_message_path(held)
    assert_equal "received", held.reload.status
    assert_equal "admin:#{@admin.reload.slug}", held.hold_released_by

    assert_equal held.id, claim_over_http("mac-2")&.fetch("id")

    post release_hold_admin_agent_message_path(held)
    assert_redirected_to admin_agent_message_path(held)
    assert_match(/only a held message can be released/, flash[:alert])
  end

  test "a non-admin cannot release a held message" do
    held = ingest(2201, author: STRANGER)
    log_in_as(User.create!(email: "guard-member@example.com", name: "Member"))

    post release_hold_admin_agent_message_path(held)
    assert_response :redirect
    assert_equal "held", held.reload.status
  end

  test "bin/rails agent_people:release MESSAGE=<id> releases a held message, and refuses one that is not held" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("agent_people:release")
    held = ingest(2301, author: STRANGER)
    run = lambda do |id|
      ENV["MESSAGE"] = id.to_s
      Rake::Task["agent_people:release"].reenable
      capture_io { Rake::Task["agent_people:release"].invoke }
    ensure
      ENV.delete("MESSAGE")
    end

    out, = run.call(held.id)
    assert_includes out, "released ##{held.id}"
    assert_equal "received", held.reload.status
    assert_equal held.id, claim_over_http("mac-3")&.fetch("id")

    assert_raises(SystemExit) { run.call(held.id) }
  end
end
