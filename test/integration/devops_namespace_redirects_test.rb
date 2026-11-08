require "test_helper"

# [integration] devops-namespace (Alex McRitchie, 2026-11-07): the board and its insight
# pages moved under /devops. Every old address answers 301 to its new one, the path
# suffix and the query string kept, so a printed task link, a Discord or Slack post and
# a doc still land on the page they named. The redirects are routing, not controller
# actions: they answer before the admin wall, so these requests are all logged out.
class DevopsNamespaceRedirectsTest < ActionDispatch::IntegrationTest
  # Every old GET path => the /devops path it must land on.
  OLD_TO_NEW = {
    "/deployments"                              => "/devops",
    "/deployments?stage=archived"               => "/devops?stage=archived",
    "/deployments/all"                          => "/devops/deployments",
    "/deployments/all?page=2"                   => "/devops/deployments?page=2",
    "/deployments/2026-11-07-a"                 => "/devops/deployments/2026-11-07-a",
    "/deployments/2026-11-07-a?tab=gates"       => "/devops/deployments/2026-11-07-a?tab=gates",
    "/tasks"                                    => "/devops/tasks",
    "/tasks?epic=devops-v3&stage=building"      => "/devops/tasks?epic=devops-v3&stage=building",
    "/tasks.json"                               => "/devops/tasks.json",
    "/tasks/recent"                             => "/devops/tasks/recent",
    "/tasks/new"                                => "/devops/tasks/new",
    "/tasks/some-task"                          => "/devops/tasks/some-task",
    "/tasks/some-task.json"                     => "/devops/tasks/some-task.json",
    "/tasks/some-task?tab=timeline"             => "/devops/tasks/some-task?tab=timeline",
    "/tasks/some-task/edit"                     => "/devops/tasks/some-task/edit",
    "/tasks/some-task/sizing"                   => "/devops/tasks/some-task/sizing",
    "/tasks/some-task/review_events"            => "/devops/tasks/some-task/review_events",
    "/tasks/some-task/local_review"             => "/devops/tasks/some-task/local_review",
    "/triage"                                   => "/devops/triage",
    "/triage?status=open"                       => "/devops/triage?status=open",
    "/stages"                                   => "/devops/stages",
    "/stages/sop"                               => "/devops/stages/sop",
    "/epics"                                    => "/devops/epics",
    "/epics/devops-v3"                          => "/devops/epics/devops-v3",
    "/epics/devops-v3?stage=shipped"            => "/devops/epics/devops-v3?stage=shipped",
    "/review_events"                            => "/devops/review_events",
    "/review_events?soul=carl"                  => "/devops/review_events?soul=carl",
    "/intelligence"                             => "/devops/intelligence",
    "/intelligence?range=30d"                   => "/devops/intelligence?range=30d",
    "/mason/insights"                           => "/devops/insights",
    "/mason/pipeline"                           => "/devops/pipeline",
    "/mason/pipeline?session_id=abc"            => "/devops/pipeline?session_id=abc",
    "/ray/insights?session_id=abc"              => "/devops/insights?session_id=abc",
    "/xan/pipeline"                             => "/devops/pipeline"
  }.freeze

  OLD_TO_NEW.each do |old, new|
    test "[integration] #{old} answers 301 to #{new}" do
      get old
      assert_response :moved_permanently
      assert_equal "http://www.example.com#{new}", response.location
    end
  end

  test "[integration] one hop: no old address redirects to another redirect" do
    OLD_TO_NEW.each_value do |new|
      path = new.split("?").first
      route = Rails.application.routes.recognize_path(path, method: :get)
      refute_equal "redirect", route[:controller].to_s, "#{new} is itself a redirect"
    rescue ActionController::RoutingError => e
      flunk "#{new} does not route: #{e.message}"
    end
  end

  # The public CTA keeps working logged out: the 301 lands on the action the wall
  # leaves open (TasksController::PUBLIC_ACTIONS), not on a sign-in page.
  test "[integration] a logged-out old local_review CTA reaches the public action at its new address" do
    task = tasks(:new_task)

    get "/tasks/#{task.slug}/local_review"
    assert_response :moved_permanently
    assert_equal "http://www.example.com/devops/tasks/#{task.slug}/local_review", response.location

    # The action itself answered (a task with no local URL goes back to its page),
    # not the admin wall's sign-in redirect.
    follow_redirect!
    assert_response :redirect
    assert_equal "http://www.example.com/devops/tasks/#{task.slug}", response.location
  end

  test "[integration] the route names kept their keys and point under /devops" do
    helpers = Rails.application.routes.url_helpers
    assert_equal "/devops", helpers.deployments_path
    assert_equal "/devops/deployments", helpers.all_deployments_path
    assert_equal "/devops/deployments/r1", helpers.deployment_path("r1")
    assert_equal "/devops/tasks", helpers.tasks_path
    assert_equal "/devops/tasks/t1", helpers.task_path("t1")
    assert_equal "/devops/tasks/recent", helpers.recent_tasks_path
    assert_equal "/devops/triage", helpers.triage_path
    assert_equal "/devops/stages", helpers.stages_path
    assert_equal "/devops/stages/sop", helpers.sop_path
    assert_equal "/devops/epics", helpers.epics_path
    assert_equal "/devops/epics/e1", helpers.epic_path("e1")
    assert_equal "/devops/review_events", helpers.review_events_hub_path
    assert_equal "/devops/intelligence", helpers.intelligence_path
    assert_equal "/devops/insights", helpers.mason_insights_path
    assert_equal "/devops/pipeline", helpers.mason_pipeline_path
    assert_equal "/mason/heartbeat", helpers.mason_heartbeat_path, "the per-session heartbeat stays put"
  end

  test "[integration] the agent pages and the API stay where they are" do
    helpers = Rails.application.routes.url_helpers
    assert_equal "/pokedex", helpers.pokedex_path
    assert_equal "/agents", helpers.agents_path
    assert_equal "/api/v1/tasks", helpers.api_v1_tasks_path
  end
end
