require "test_helper"

# [integration] The client pipeline (docs/agents/system/client-pipeline.md): an owner
# opens /applications/:slug/pipeline from the app page and the sidebar and sees
# only their app's tasks, by lane, with nothing internal in the page; a stranger,
# another app's owner and a visitor are kept out (404, or sign in); an unannounced
# app is a 404 even to its owner; an admin sees the task links and PR links.
class ClientPipelineFlowTest < ActionDispatch::IntegrationTest
  PR = "https://github.com/McRitchie-Studio/turf-monster/pull/4242".freeze

  setup do
    @turf = apps(:turf_monster)
    @turf.update!(package_tier: "builder")
    @cyvasse = App.create!(slug: "cyvasse", name: "Cyvasse", emoji: "🐉", position: 5)
    @owner = User.create!(email: "pipeline-owner@example.com", name: "Pipeline Owner", role: "viewer")
    @cyvasse_owner = User.create!(email: "pipeline-cyvasse@example.com", name: "Cyvasse Owner", role: "viewer")
    @stranger = User.create!(email: "pipeline-stranger@example.com", name: "Stranger", role: "viewer")
    AppMembership.create!(app: @turf, user: @owner)
    AppMembership.create!(app: @cyvasse, user: @cyvasse_owner)

    @building = Task.create!(title: "Wire the live scores", stage: "building", started_at: 3.hours.ago, agent_slug: nil,
                             session_id: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b", pr_url: PR,
                             metadata: { "devops" => { "repositories" => [ "turf-monster" ], "built_by" => "carl", "pr_url" => PR,
                                                       "local_url" => "http://localhost:3104/contests",
                                                       "agent_context" => "AGENT-CONTEXT-NEVER-SHOWN" } })
    Task.create!(title: "Steffon rotates HEALTH_TOKEN_TURF_MONSTER", stage: "designed",
                 metadata: { "devops" => { "repositories" => [ "turf-monster" ] } })
    Task.create!(title: "Cyvasse only work", stage: "submitted", metadata: { "devops" => { "repositories" => [ "cyvasse" ] } })
  end

  test "[integration] the owner sees their app's lanes and cards, with no internals anywhere in the page" do
    log_in_as(@owner)
    get application_path("turf-monster")
    assert_select "a[data-test='application-pipeline-link'][href=?]", pipeline_application_path("turf-monster")
    assert_select "#studio-link-sidebar a[href=?]", pipeline_application_path("turf-monster"), text: /Pipeline/

    get pipeline_application_path("turf-monster")
    assert_response :success
    assert_select "h1", text: "Turf Monster pipeline"
    assert_select "[data-test='pipeline-lane']", count: 6
    assert_select "[data-test='pipeline-lane'][data-lane='building'] [data-test='pipeline-card-title']", text: /Wire the live scores/
    assert_select "[data-test='pipeline-lane'][data-lane='building'] [data-test='pipeline-card-role']", text: "Builder"
    assert_select "[data-test='pipeline-lane'][data-lane='queued'] [data-test='pipeline-card-title']", text: /#1\s+Security maintenance/
    assert_select "[data-test='pipeline-lanes-label']", text: "1 of 2 lanes in use"
    assert_select "[data-test='pipeline-card-admin']", count: 0
    assert_select "[data-test='pipeline-card-pr']", count: 0

    page = css_select("[data-test='pipeline-page']").to_html
    assert_includes page, "Wire the live scores", "the scan below reads the real page"
    [ "pull/4242", "Carl", "carl", "019f3b0c", "localhost", "AGENT-CONTEXT", "HEALTH_TOKEN", "Steffon",
      "Cyvasse only work", @building.slug, "/tasks/" ].each do |internal|
      refute_includes page, internal, "#{internal} leaked into the pipeline"
    end
  end

  test "[integration] a stranger and another app's owner get 404; a visitor signs in; an unannounced app is a 404 to its owner" do
    get pipeline_application_path("turf-monster")
    assert_redirected_to login_path

    [ @stranger, @cyvasse_owner ].each do |user|
      log_in_as(user)
      get pipeline_application_path("turf-monster")
      assert_response :not_found, user.email
    end
    get pipeline_application_path("no-such-app")
    assert_response :not_found

    welding = App.create!(slug: AppCatalog::UNANNOUNCED.first, name: "Unannounced", position: 9)
    AppMembership.create!(app: welding, user: @stranger)
    log_in_as(@stranger)
    get pipeline_application_path(welding.slug)
    assert_response :not_found, "an unannounced app's pipeline is not shown to a client"
  end

  test "[integration] an admin sees task links, PR links and titles as written" do
    log_in_as(users(:alex))
    get pipeline_application_path("turf-monster")
    assert_response :success
    assert_select "[data-test='pipeline-card-pr'][href=?]", PR
    assert_select "[data-test='pipeline-card-admin'] a[href=?]", task_path(@building.slug)
    assert_select "[data-test='pipeline-card-title']", text: /Steffon rotates HEALTH_TOKEN_TURF_MONSTER/
  end
end
