require "test_helper"

# [component] /applications as two tables (ApplicationsWatchList): live apps on
# the left with a lazy health frame each, apps pending launch on the right with
# why. The page itself reads no app's health: every frame loads after render.
class ApplicationsIndexTest < ActionDispatch::IntegrationTest
  setup do
    @pawsome = App.create!(slug: "pawsome", name: "Pawsome", emoji: "🐾", color: "#F59E0B", position: 9)
    Task.create!(title: "Pawsome signup", stage: "building", metadata: { "devops" => { "repositories" => [ "pawsome" ] } })
  end

  # Any health read during the page render fails the test.
  def without_health_reads(&)
    raiser = ->(*) { raise "the index must not read health at render" }
    DailyAppReport.stub(:health_for, raiser) { DailyAppReport::Fetcher.stub(:new, raiser, &) }
  end

  test "[component] an admin sees live apps left and pending launch right, with why, and no health read at render" do
    log_in_as(users(:alex))
    without_health_reads { get applications_path }
    assert_response :success

    assert_select "[data-test='applications-page'] .grid.lg\\:grid-cols-5", 1, "one column on mobile, two from lg"
    assert_select "[data-test='applications-live'] [data-test='application-row'][data-list='live']", count: 2
    assert_select "[data-test='applications-live'] [data-app='turf-monster'] [data-test='application-url']", text: "turfmonster.media"
    assert_select "[data-test='applications-live'] turbo-frame#application-health-turf-monster[loading='lazy'][src=?]",
                  health_application_path("turf-monster", compact: 1)

    assert_select "[data-test='applications-pending'] [data-app='pawsome']" do
      assert_select "[data-test='application-why']", text: /Not launched; no production URL on record/
      assert_select "[data-test='application-open-tasks']", text: /1 open task: 1 building/
      assert_select "[data-test='application-next-task']", text: "Pawsome signup"
    end
    assert_select "[data-test='applications-live'] [data-app='pawsome']", count: 0
  end

  test "[component] the compact health cell answers in its own frame" do
    log_in_as(users(:alex))
    with_env("HEALTH_TOKEN_TURF_MONSTER", nil) { get health_application_path("turf-monster", compact: 1) }
    assert_response :success
    assert_select "turbo-frame#application-health-turf-monster [data-test='application-health-compact'][data-state='not_wired']"
  end

  test "[component] an owner sees only their own app in the split, with counts but no task titles; a stranger gets 404" do
    owner = User.create!(email: "paws@example.com", name: "Paws Owner", role: "viewer")
    AppMembership.create!(app: @pawsome, user: owner)
    log_in_as(owner)
    get applications_path
    assert_response :success
    assert_select "[data-test='application-row']", count: 1
    assert_select "[data-test='applications-pending'] [data-app='pawsome'] [data-test='application-open-tasks']", text: /1 building/
    assert_select "[data-test='application-next-task']", count: 0

    log_in_as(User.create!(email: "nobody@example.com", name: "Nobody", role: "viewer"))
    get applications_path
    assert_response :not_found
  end
end
