require "test_helper"
# Rails 8.1 defers turbo-rails' on_load(:action_cable) hook, which is what
# normally requires this helper, so load it explicitly before the include below.
require "turbo/broadcastable/test_helper"

# [integration] the operator-window countdown on BOTH render paths of the live
# card — the full page (/tasks and /deployments) and the turbo-stream push
# DeploymentsBroadcaster sends — plus the task API's derived `windows` field
# that `bin/task wait-window` polls, and the Next Release card's production
# window with its Approve button on both of ITS render paths.
class BoardWindowChipTest < ActionDispatch::IntegrationTest
  include Turbo::Broadcastable::TestHelper

  setup do
    @waiting = Task.create!(title: "Window waiting board task", stage: "building",
                            metadata: { "devops" => { "approval_status" => "waiting", "local_url" => "http://localhost:3011/tasks" } })
    @quiet = Task.create!(title: "Window quiet board task", stage: "building")
    @headers = {
      "Authorization" => "Bearer #{Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)}"
    }
  end

  # --- render path 1: the full page --------------------------------------------

  test "[integration] /tasks renders the approval countdown on the waiting card and none on a quiet one" do
    get tasks_path
    assert_response :success

    assert_select "#card-#{@waiting.slug} [data-test='task-slug-row'] [data-test='task-window-chip'][data-window-kind='approval'][data-window-state='open']"
    assert_select "#card-#{@waiting.slug} [data-test='task-window-clock'][data-mode='window']", text: /\A\d{2}:\d{2}\z/
    assert_select "#card-#{@quiet.slug} [data-test='task-window-chip']", count: 0
    assert_select "[data-release-ticker]", { minimum: 1 }, "the install-once ticker rides the board"
  end

  test "[integration] /deployments renders the escalation countdown on a blocked member" do
    @waiting.update!(stage: "submitted")
    @waiting.block!(by: "avi", kind: "dependency")
    Activity.create!(task_slug: @waiting.slug, activity_type: "qa_feedback", agent_slug: "avi",
                     description: "POLICY QUESTION", metadata: { "summary" => "Escalated: chip default", "kind" => "dependency" })

    get deployments_path
    assert_response :success

    assert_select "#card-#{@waiting.slug} [data-test='task-window-chip']", count: 1
    assert_select "#card-#{@waiting.slug} [data-test='task-window-chip'][data-window-kind='escalation']"
  end

  # --- render path 2: the turbo-stream push ------------------------------------

  test "[integration] the broadcast card carries the countdown the page render carries" do
    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.approval_change(@waiting) }

    assert_equal 1, streams.size
    html = streams.first.to_html
    assert_includes html, "data-test=\"task-window-chip\""
    assert_includes html, "data-window-kind=\"approval\""
    assert_includes html, "data-mode=\"window\""
  end

  # --- the API field the CLI polls ---------------------------------------------

  test "[integration] the task API carries the derived windows, escalation first, and an empty list when quiet" do
    get "/api/v1/tasks/#{@waiting.slug}", headers: @headers, as: :json
    assert_response :success
    windows = response.parsed_body.dig("data", "windows")
    assert_equal ["approval"], windows.map { |w| w["kind"] }
    assert_equal 10, windows.first["minutes"]
    assert_equal false, windows.first["lapsed"]
    assert_match(/\A\d{2}:\d{2}\z/, windows.first["label"])
    assert_in_delta 600, windows.first["remaining_seconds"], 5

    @waiting.block!(by: "avi", kind: "dependency")
    Activity.create!(task_slug: @waiting.slug, activity_type: "qa_feedback", agent_slug: "avi",
                     description: "POLICY QUESTION", metadata: { "summary" => "Escalated: chip default", "kind" => "dependency" })
    get "/api/v1/tasks/#{@waiting.slug}", headers: @headers, as: :json
    assert_equal %w[escalation approval], response.parsed_body.dig("data", "windows").map { |w| w["kind"] }

    get "/api/v1/tasks/#{@quiet.slug}", headers: @headers, as: :json
    assert_equal [], response.parsed_body.dig("data", "windows")
  end

  test "[integration] a lapsed approval reads lapsed with its label" do
    @waiting.update!(metadata: @waiting.metadata.deep_merge("devops" => { "approval_requested_at" => 11.minutes.ago.utc.iso8601 }))
    get "/api/v1/tasks/#{@waiting.slug}", headers: @headers, as: :json
    window = response.parsed_body.dig("data", "windows").first
    assert_equal true, window["lapsed"]
    assert_equal 0, window["remaining_seconds"]
    assert_equal "unanswered, proceeding", window["label"]
  end

  # --- the Next Release card ---------------------------------------------------

  test "[integration] the Next Release card shows the production countdown and Approve on the page and on the push, and drops both on the grant" do
    rel = Release.open!
    rel.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                      metadata: { "mode" => "timed", "window_ends_at" => 30.minutes.from_now.utc.iso8601, "window_minutes" => 30 })

    get deployments_path
    assert_response :success
    assert_select "#current-release [data-test='release-ship-window'] [data-test='task-window-chip'][data-window-kind='production']"
    assert_select "#current-release [data-test='release-ship-approve'][data-approve-url='/deployments/#{rel.slug}/ship_authorization']"

    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.release_modules }
    html = streams.map(&:to_html).join
    assert_includes html, "data-test=\"release-ship-approve\"", "the live push wears the same button the page wears"
    assert_includes html, "data-window-kind=\"production\""

    rel.grant_ship_authorization!(actor: "alex@example.com")
    get deployments_path
    assert_select "#current-release [data-test='release-ship-window']", count: 0
    assert_select "#current-release [data-test='task-window-chip']", count: 0
  end
end
