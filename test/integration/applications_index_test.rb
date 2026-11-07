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

  test "[component] each app shows its emoji with its CTO on top, or the emoji alone, and clicks through to its todos" do
    Agent.create!(slug: "turf-monster", name: "Turf Monster", status: "active", agent_type: "specialist")
    log_in_as(users(:alex))
    get applications_path

    assert_select "[data-app='turf-monster'] [data-test='app-avatar-pair'][data-agent='yes']" do
      assert_select "[data-test='app-badge']", 1
      assert_select "[data-test='app-avatar-agent'].z-10[title='Turf']", 1
    end
    assert_select "[data-app='pawsome'] [data-test='app-avatar-pair'][data-agent='no']" do
      assert_select "[data-test='app-badge']", 1
      assert_select "[data-test='app-avatar-agent']", 0
    end
    assert_select "[data-app='turf-monster'] a[data-test='application-link'][href=?]", application_path("turf-monster")
    assert_select "[data-app='pawsome'] a[data-test='application-link'][href=?]", application_path("pawsome")
    assert_select "[data-app='pawsome'] a[data-test='application-next-task'][href=?]", task_path(Task.find_by!(title: "Pawsome signup").slug)
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

  # Alex McRitchie, 2026-11-04: "Lets have All X Apps to dispaly the full number". The
  # row links this page, so its number is the page's rows, the collapsed ones included.
  test "[integration] the All N Apps number is the rows /applications lists, for an admin and for an owner" do
    capture_io { load Rails.root.join("db/seeds/00_apps.rb") }
    owner = User.create!(email: "three-apps@example.com", name: "Three Apps", role: "viewer")
    alex = users(:alex)
    alex.save!
    [ owner, alex ].each do |user|
      [ apps(:turf_monster), @pawsome, apps(:mcritchie_studio) ].each { |app| AppMembership.create!(app: app, user: user) }
    end

    { owner => 3, alex => App.count }.each do |user, expected|
      log_in_as(user)
      get applications_path
      assert_response :success
      assert_select "[data-test='application-row']", count: expected
      assert_select "#studio-link-sidebar a[href='/applications']", { text: /All #{expected} Apps/ }
    end
    assert_operator App.count, :>, 3, "control: an admin's number is not the owner's"
    assert App.exists?(slug: "studio-engine"), "control: the page and the number include the libraries"
  end

  # The row costs one COUNT, however many times the layout asks for the sections.
  test "[integration] a sidebar render with All N Apps runs one count over apps" do
    alex = users(:alex)
    alex.save!
    [ apps(:turf_monster), @pawsome, apps(:mcritchie_studio) ].each { |app| AppMembership.create!(app: app, user: alex) }
    log_in_as(alex)

    counts = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      counts << payload[:sql] if payload[:sql].match?(/COUNT\(\*\) FROM "apps"/)
    end
    get links_path
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_response :success
    assert_select "#studio-link-sidebar a[href='/applications']", text: /All \d+ Apps/
    assert_equal 1, counts.size, counts.join("\n")
  end

  test "[component] the Studio section is gone, so /applications is in the sidebar only as an owner's All N Apps, with three or more apps" do
    alex = users(:alex)
    alex.save!
    AppMembership.create!(app: apps(:turf_monster), user: alex)
    AppMembership.create!(app: @pawsome, user: alex)
    log_in_as(alex)
    get applications_path
    assert_select "#studio-link-sidebar a[href='/applications']", { count: 0 }, "up to two apps, each by name; the admin dashboard links /applications"

    AppMembership.create!(app: apps(:mcritchie_studio), user: alex)
    get applications_path
    assert_select "#studio-link-sidebar a[href='/applications']", { count: 1, text: /All #{App.count} Apps/ }, "All N Apps (Alex McRitchie, 2026-11-04: 3+ apps, no exception)"

    owner = User.create!(email: "single@example.com", name: "Single Owner", role: "viewer")
    AppMembership.create!(app: @pawsome, user: owner)
    log_in_as(owner)
    get applications_path
    assert_response :success
    assert_select "#studio-link-sidebar a[href='/applications']", { count: 0 }, "a non-admin owner's comes only from their own links"
  end
end
