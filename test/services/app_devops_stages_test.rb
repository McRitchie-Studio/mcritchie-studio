require "test_helper"

# [unit] The app chat's Building · Releasing · Deploying pills, from the build
# task's stage (.agents/epics/build-with-ray-v2.md, section 6).
class AppDevopsStagesTest < ActiveSupport::TestCase
  def states(...) = AppDevopsStages.from(...).map { |stage| [ stage.key, stage.state ] }.to_h

  test "every stage up to review is Building, live" do
    %w[designed building submitted reviewed].each do |stage|
      assert_equal({ "building" => :live, "releasing" => :pending, "deploying" => :pending }, states(stage), stage)
    end
  end

  test "assembled is Releasing, live, with Building done" do
    assert_equal({ "building" => :done, "releasing" => :live, "deploying" => :pending }, states("assembled"))
    assert_equal({ "building" => :done, "releasing" => :live, "deploying" => :pending },
                 states("assembled", release_stage: "qa_deployed"), "QA is still releasing")
  end

  test "assembled while its release deploys production is Deploying, live" do
    assert_equal({ "building" => :done, "releasing" => :done, "deploying" => :live },
                 states("assembled", release_stage: "prod_deploying"))
  end

  test "shipped shows all three done and nothing live" do
    assert_equal({ "building" => :done, "releasing" => :done, "deploying" => :done }, states("shipped"))
    assert_not AppDevopsStages.from("shipped").any?(&:live?)
  end

  test "an archived or unknown stage shows nothing live" do
    assert_equal({ "building" => :pending, "releasing" => :pending, "deploying" => :pending }, states("archived"))
    assert_equal %w[Building Releasing Deploying], AppDevopsStages.from(nil).map(&:label)
  end

  test "an app reads its build task through the request that claimed its subdomain" do
    own = App.create!(slug: "own-probe", name: "Own Probe", status: "active")
    assert_equal %i[pending pending pending], AppDevopsStages.for_app(own).map(&:state), "nothing in flight: no checks"

    task = Task.create!(title: "Build Launch App stage-probe", stage: "building", priority: 1)
    AppRequest.create!(prompt: "A probe", subdomain: "stage-probe", task_slug: task.slug)
    app = App.create!(slug: "stage-probe", name: "Stage Probe", status: "active")
    assert_equal %i[live pending pending], AppDevopsStages.for_app(app).map(&:state)

    task.update_columns(stage: "assembled")
    assert_equal %i[done live pending], AppDevopsStages.for_app(app).map(&:state)

    task.update_columns(stage: "archived")
    assert_equal %i[pending pending pending], AppDevopsStages.for_app(app).map(&:state), "archived unshipped"
    task.update_columns(completed_at: Time.current)
    assert_equal %i[pending pending pending], AppDevopsStages.for_app(app).map(&:state), "shipped: nothing in flight"
  end

  # --- the card: every open task for the app (task app-card-live-tasks) -------

  def card_task(title, stage, repos: [ "lane-probe" ], thread: nil, release: nil, **attrs)
    Task.create!(title: title, stage: stage, priority: 1, release_slug: release&.slug,
                 metadata: { "devops" => { "repositories" => repos, "source_thread" => thread }.compact }, **attrs)
  end

  def lane_app = @lane_app ||= App.create!(slug: "lane-probe", name: "Lane Probe", status: "active")
  def counts(board) = board.stages.to_h { |stage| [ stage.key, [ stage.state, stage.count ] ] }

  test "[unit] the pills count every open task for the app's repo, one lane each" do
    releasing = Release.create!(slug: "rel-lane-qa", state: "assembled")
    deploying = Release.create!(slug: "rel-lane-prod", train: "lane-probe", state: "assembled",
                                prod_deploy_started_at: 1.minute.ago)
    %w[designed building submitted reviewed].each { |stage| card_task("Lane #{stage}", stage) }
    card_task("On QA", "assembled", release: releasing)
    card_task("Going out", "assembled", release: deploying)
    card_task("Other app", "building", repos: [ "other-probe" ])

    board = AppDevopsStages.board_for(lane_app, admin: true)
    assert_equal({ "building" => [ :live, 4 ], "releasing" => [ :live, 1 ], "deploying" => [ :live, 1 ] }, counts(board))
    assert_equal 6, board.total
    assert_not board.idle?
    assert_not_includes board.items.map(&:title), "Other app"
  end

  test "[unit] shipped and archived tasks, and members of a shipped release, count nowhere" do
    shipped = Release.create!(slug: "rel-lane-done", state: "shipped")
    card_task("Shipped", "shipped", completed_at: 1.day.ago)
    card_task("Archived", "archived")
    card_task("Released", "assembled", release: shipped)

    board = AppDevopsStages.board_for(lane_app)
    assert board.idle?, "nothing in flight"
    assert_equal [ :pending ] * 3, board.stages.map(&:state), "never three checks for an app with nothing moving"
    assert_equal [ 0, 0, 0 ], board.stages.map(&:count)
    assert_empty board.items
  end

  test "[unit] a task opened from this app's chat shows, whatever repo it names" do
    card_task("Add a leaderboard", "designed", repos: [ "mcritchie-studio" ],
                                               thread: "https://mcritchie.studio/applications/lane-probe/chat")
    card_task("Another chat's ask", "designed", repos: [ "mcritchie-studio" ],
                                                thread: "https://mcritchie.studio/applications/lane-probe-two/chat")

    board = AppDevopsStages.board_for(lane_app)
    assert_equal [ "Shared platform work" ], board.items.map(&:title), "names another repo: an owner reads it as shared work"
    assert_equal [ "Add a leaderboard" ], AppDevopsStages.board_for(lane_app, admin: true).items.map(&:title)
  end

  test "[unit] the app's build task counts even when it names no repo, and keeps the launch's checks" do
    launch = card_task("Build Launch App lane-probe", "assembled", repos: [])
    AppRequest.create!(prompt: "A probe", subdomain: "lane-probe", task_slug: launch.slug)
    card_task("Polish", "building")

    board = AppDevopsStages.board_for(lane_app)
    assert_equal({ "building" => [ :live, 1 ], "releasing" => [ :live, 1 ], "deploying" => [ :pending, 0 ] }, counts(board))
    assert_equal [ "Polish", "Launching Lane Probe" ], board.items.map(&:title), "an owner reads the build task in plain words"
    assert_includes AppDevopsStages.board_for(lane_app, admin: true).items.map(&:title), "Build Launch App lane-probe"

    Task.find_by!(title: "Polish").update_columns(stage: "archived")
    board = AppDevopsStages.board_for(lane_app)
    assert_equal({ "building" => [ :done, 0 ], "releasing" => [ :live, 1 ], "deploying" => [ :pending, 0 ] }, counts(board),
                 "the build task has passed Building: its check stays")
  end

  test "[unit] the list is the newest few, and an owner sees no slug and a scrubbed title" do
    7.times { |i| card_task("Task #{i}", "building").update_columns(updated_at: (i + 1).hours.ago) }
    card_task("Fix https://example.com/x for Carl", "building").update_columns(updated_at: 1.minute.ago)

    owner = AppDevopsStages.board_for(lane_app)
    assert_equal 8, owner.total
    assert_equal 5, owner.items.size
    assert_equal 3, owner.more
    assert_equal [ "Fix [link] for the team", "Task 0", "Task 1", "Task 2", "Task 3" ], owner.items.map(&:title)
    assert owner.items.all? { |item| item.slug.nil? }, "no internal slug crosses to an owner"
    assert_equal [ "Building" ], owner.items.map(&:lane).uniq

    admin = AppDevopsStages.board_for(lane_app, admin: true)
    assert_equal "Fix https://example.com/x for Carl", admin.items.first.title
    assert admin.items.all?(&:slug)
  end

  test "[unit] one query reads the tasks, one their releases, however many there are" do
    release = Release.create!(slug: "rel-lane-n1", state: "assembled")
    3.times { |i| card_task("Q#{i}", "assembled", release: release) }
    AppDevopsStages.board_for(lane_app, admin: true) # warm: the first read loads column types
    queries = count_card_queries { AppDevopsStages.board_for(lane_app, admin: true) }
    6.times { |i| card_task("R#{i}", "assembled", release: release) }
    assert_equal queries, count_card_queries { AppDevopsStages.board_for(lane_app, admin: true) }, "no N+1"
    assert_operator queries, :<=, 3, "the request, the tasks, their releases"
  end

  def count_card_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveRecord::Base.uncached { ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block) }
    count
  end
end
