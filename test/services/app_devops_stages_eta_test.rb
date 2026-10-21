require "test_helper"

# [unit] The status card's sub-labels and ETAs (task app-card-stage-labels):
# each live pill says where its furthest-along task is (Prepping, Building,
# Reviewing, Approved, On QA, Going live) and how long that step usually has
# left, the median of the board's recent stage durations, with no ETA when the
# board has too few and "waiting for a builder" while nobody can start a
# designed task.
class AppDevopsStagesEtaTest < ActiveSupport::TestCase
  Eta = AppDevopsStages::Eta

  # The stage timestamps are written after create: a save stamps the stage's own
  # column with now (Task#set_stage_timestamp).
  def card_task(title, stage, repos: [ "eta-probe" ], release_slug: nil, **stamps)
    task = Task.create!(title: title, stage: stage, priority: 1, release_slug: release_slug,
                        metadata: { "devops" => { "repositories" => repos } })
    task.update_columns(stamps) if stamps.any?
    task
  end

  def eta_app = @eta_app ||= App.create!(slug: "eta-probe", name: "Eta Probe", status: "active")

  # Durations out of `from` into its next stage, newest last.
  def durations(from, seconds, to: Eta::NEXT_STAGE.fetch(from))
    task = card_task("History #{from}", "designed", repos: [ "history-probe" ])
    seconds.each_with_index do |value, index|
      TaskEvent.create!(task_slug: task.slug, from_stage: from, to_stage: to, seconds_in_from: value,
                        occurred_at: (seconds.size - index).minutes.ago)
    end
  end

  def launcher!(paused_until: nil, seen: 1.minute.ago, souls: [ Eta::LAUNCHER_SOUL ])
    AgentDispatcher.create!(worker_id: "launcher-#{SecureRandom.hex(3)}", last_seen_at: seen, souls: souls, paused_until: paused_until)
  end

  def lane(board, key) = board.stages.find { |stage| stage.key == key }

  test "[unit] each step has its sub-label; a blocked build is On hold" do
    assert_equal({ "designed" => "Prepping", "building" => "Building", "submitted" => "Reviewing",
                   "reviewed" => "Approved", "assembled" => "On QA", "deploying" => "Going live" },
                 AppDevopsStages::STEPS.index_with { |step| AppDevopsStages.sub_label_for(step) })
    assert_equal "On hold", AppDevopsStages.sub_label_for("building", blocked: true)
    assert_equal "Prepping", AppDevopsStages.sub_label_for("designed", preview_ready: true), "no preview before a build"
    assert_equal "Preview ready", AppDevopsStages.sub_label_for("submitted", preview_ready: true)
    assert_equal "On QA", AppDevopsStages.sub_label_for("assembled", preview_ready: true), "the release lanes keep their own words"
  end

  test "[unit] the usual time is the median of the last SAMPLE durations, and absent below MIN_SAMPLES" do
    durations("building", [ 99_999 ] * 5 + [ 600, 1800 ] * 10) # the oldest five fall outside the 20; with them the median is 1800
    durations("submitted", [ 300, 900 ])
    durations("reviewed", [ 60, 0, 120, 180 ], to: "building") # a rework bounce is not the step's end

    medians = Eta.medians(%w[building submitted reviewed designed])
    assert_equal 1200, medians["building"], "median of the newest 20, the stale outliers dropped"
    assert_nil medians["submitted"], "two durations are not a usual time"
    assert_nil medians["reviewed"], "only the forward move counts"
    assert_nil medians["designed"]
  end

  test "[unit] Deploying reads the median of recent production deploys" do
    [ 300, 600, 900 ].each_with_index do |seconds, index|
      start = (index + 1).days.ago
      Release.create!(slug: "rel-eta-#{index}", state: "shipped", prod_deploy_started_at: start, shipped_at: start + seconds)
    end
    assert_equal 600, Eta.medians([ Eta::DEPLOYING ])[Eta::DEPLOYING]
  end

  test "[unit] the ETA is the usual time less the time already spent, worded for a phone" do
    now = Time.current
    medians = { "building" => 2.hours.to_i, "submitted" => 25.minutes.to_i }
    eta = Eta.estimate("building", entered_at: now - 30.minutes, medians: medians, launcher: false, now: now)
    assert_equal [ "~2 h", "~2 h left", :left ], [ eta.text, eta.phrase, eta.kind ]
    assert_equal "~25 min", Eta.estimate("submitted", entered_at: now, medians: medians, launcher: false, now: now).text

    long = Eta.estimate("submitted", entered_at: now - 1.hour, medians: medians, launcher: false, now: now)
    assert_equal [ "Any minute now", :long ], [ long.text, long.kind ], "never a negative or a zero promise"
    assert_nil Eta.estimate("reviewed", entered_at: now, medians: medians, launcher: true, now: now), "no data: no ETA"

    assert_equal [ "3 min", "20 min", "1 h", "2 h", "3 days" ],
                 [ 150, 1190, 3500, 5400, 3 * 86_400 ].map { |seconds| Eta.format_duration(seconds) }
  end

  test "[unit] a step with a real start carries its expected finish: entered_at plus the usual time" do
    now = Time.current.change(usec: 0)
    medians = { "building" => 30.minutes.to_i, "designed" => 20.minutes.to_i }
    eta = Eta.estimate("building", entered_at: now - 24.minutes - 12.seconds, medians: medians, launcher: false, now: now)
    assert_equal now + 5.minutes + 48.seconds, eta.deadline
    assert eta.countdown?
    assert_equal "05:48", eta.pill_text(now: now), "the pill paints the clock; the row keeps the rounded words"
    assert_equal [ "~6 min", "~6 min left" ], [ eta.text, eta.phrase ]

    long = Eta.estimate("building", entered_at: now - 31.minutes, medians: medians, launcher: false, now: now)
    assert_equal [ now - 1.minute, "Any minute now", :long ], [ long.deadline, long.pill_text(now: now), long.kind ]

    prepping = Eta.estimate("designed", entered_at: now - 1.minute, medians: medians, launcher: true, now: now)
    assert_nil prepping.deadline, "a designed task's created_at is no start: no countdown"
    assert_equal "~20 min", prepping.pill_text(now: now)
    assert_nil Eta.estimate("building", entered_at: nil, medians: medians, launcher: false, now: now).deadline, "no start time, no countdown"
    assert_not Eta::WAITING.countdown?
  end

  test "[unit] the clock reads MM:SS, H:MM:SS from an hour up, and Any minute now at or past zero" do
    assert_equal [ "05:48", "00:01", "59:59", "1:00:00", "1:02:03", "26:00:00" ],
                 [ 348, 1.9, 3599, 3600, 3723, 26 * 3600 ].map { |seconds| Eta.clock(seconds) }
    assert_equal [ "Any minute now" ] * 3, [ 0, 0.5, -90 ].map { |seconds| Eta.clock(seconds) }, "never a negative"
  end

  # A launch task's run record (ClientBuilds#write_run!), as the launcher leaves it.
  def client_run(state, minutes, finished_ago: 1.hour)
    finished = finished_ago.ago
    card_task("Build Launch App run #{SecureRandom.hex(2)}", state == "building" ? "building" : "shipped", repos: [ "history-probe" ]).tap do |task|
      run = { "state" => state, "started_at" => (finished - minutes.minutes).iso8601, "finished_at" => (finished.iso8601 unless state == "building") }
      task.update_columns(metadata: task.metadata.deep_merge("devops" => { ClientBuilds::KEY => run.compact }))
    end
  end

  test "[unit] a client build's usual time is the launcher's own preview_ready runs, else the configured default" do
    assert_equal 8 * 60, Eta.client_build_usual, "no run yet: config/client_builds.yml typical_build_minutes"

    client_run("preview_ready", 6)
    client_run("preview_ready", 5)
    client_run("failed", 40)
    client_run("released", 1)
    client_run("building", 2)
    durations("building", [ 1800 ] * 3) # the hub's PR work is not a first version
    assert_equal 330, Eta.client_build_usual, "the median of the runs that built a preview, nothing else"
  end

  test "[unit] a building client build counts down from its run's start by the launcher's time; a hub task keeps the board's" do
    durations("building", [ 1800 ] * 3)
    3.times { |i| client_run("preview_ready", 6, finished_ago: (i + 1).hours) }
    launch = card_task("Build Launch App eta-probe", "building", repos: [], started_at: 10.minutes.ago)
    started = 2.minutes.ago.change(usec: 0)
    launch.update_columns(metadata: launch.metadata.deep_merge("devops" => { ClientBuilds::KEY => { "state" => "building", "started_at" => started.iso8601 } }))
    AppRequest.create!(prompt: "A probe", subdomain: "eta-probe", task_slug: launch.slug)

    board = AppDevopsStages.board_for(eta_app)
    eta = lane(board, "building").eta
    assert_equal [ started + 6.minutes, "~4 min" ], [ eta.deadline, eta.text ], "the run's start plus the launcher's median, not ~30 min"
    assert_equal "Building · ~4 min left", board.items.sole.status

    hub = card_task("Add a gallery", "building", started_at: 1.minute.ago.change(usec: 0))
    hub_row = AppDevopsStages.board_for(eta_app).items.find { |item| item.title == "Add a gallery" }
    assert_equal hub.started_at + 30.minutes, hub_row.eta.deadline, "a hub task reads the board's building median"
  end

  test "[unit] a designed task promises no minutes until a launcher is live" do
    now = Time.current
    medians = { "designed" => 20.minutes.to_i }
    assert_equal Eta::WAITING, Eta.estimate("designed", entered_at: now, medians: medians, launcher: false, now: now)
    assert_equal "waiting for a builder", Eta::WAITING.phrase
    assert_equal "~20 min", Eta.estimate("designed", entered_at: now, medians: medians, launcher: true, now: now).text

    assert_not Eta.launcher_live?, "no launcher has ever pinged"
    launcher!(souls: [ "turf_monster" ])
    launcher!(seen: 10.minutes.ago)
    launcher!(paused_until: 1.hour.from_now)
    assert_not Eta.launcher_live?, "a mailbox dispatcher, a silent launcher and a paused one start nothing"
    launcher!
    assert Eta.launcher_live?
  end

  test "[unit] a lane of only designed tasks reads Prepping with no count; one real build makes it Building with its count" do
    card_task("Add a gallery", "designed")
    card_task("Add a menu", "designed")
    building = lane(AppDevopsStages.board_for(eta_app), "building")
    assert_equal [ "Prepping", true, 2, 0, nil ], [ building.label, building.prepping?, building.count, building.shown_count, building.sub_label ]

    card_task("Add a footer", "building", started_at: 1.minute.ago)
    building = lane(AppDevopsStages.board_for(eta_app), "building")
    assert_equal [ "Building", false, 3, 3, "Building", nil ], [ building.label, building.prepping?, building.count, building.shown_count, building.sub_label, building.shown_sub_label ]
    assert_not lane(AppDevopsStages.board_for(eta_app), "releasing").prepping?, "only the Building lane can be prepping"
  end

  test "[unit] the single designed launch task reads Prepping, waiting for a builder" do
    durations("designed", [ 1200 ] * 3)
    launch = card_task("Build Launch App eta-probe", "designed", repos: [])
    AppRequest.create!(prompt: "A probe", subdomain: "eta-probe", task_slug: launch.slug)

    board = AppDevopsStages.board_for(eta_app)
    building = lane(board, "building")
    # A lane of only designed tasks reads Prepping as its label: no count shown, no sub-label, no "no builder".
    assert_equal [ :live, 1, 0, "Prepping", nil, nil ], [ building.state, building.count, building.shown_count, building.label, building.sub_label, building.eta ]
    assert_equal "Prepping · waiting for a builder", board.items.sole.status
    assert_nil lane(board, "releasing").sub_label, "a muted pill carries no sub-label"

    launcher!
    board = AppDevopsStages.board_for(eta_app)
    assert_equal "Prepping · ~20 min left", board.items.sole.status
    assert_equal "~20 min", lane(board, "building").eta.text
  end

  test "[unit] a lane's pill reads its furthest-along task; each row reads its own" do
    durations("submitted", [ 600 ] * 3)
    durations("building", [ 7200 ] * 3)
    card_task("Newest idea", "designed")
    card_task("In review", "submitted", submitted_at: 10.seconds.ago).update_columns(updated_at: 1.hour.ago)
    card_task("Being built", "building", started_at: 1.hour.ago).update_columns(updated_at: 2.hours.ago)
    card_task("Stuck", "building", blocked_at: 1.minute.ago).update_columns(updated_at: 3.hours.ago)

    board = AppDevopsStages.board_for(eta_app)
    assert_equal [ 4, "Reviewing", "~10 min" ], lane(board, "building").then { |stage| [ stage.count, stage.sub_label, stage.eta.text ] }
    assert_equal [ "Prepping · waiting for a builder", "Reviewing · ~10 min left", "Building · ~1 h left", "On hold" ],
                 board.items.map(&:status)
  end

  test "[unit] Releasing reads On QA and Deploying reads Going live" do
    qa = Release.create!(slug: "rel-eta-qa", state: "assembled")
    prod = Release.create!(slug: "rel-eta-prod", train: "eta-probe", state: "assembled", prod_deploy_started_at: 1.minute.ago)
    card_task("On QA", "assembled", release_slug: qa.slug, assembled_at: 10.minutes.ago)
    card_task("Going out", "assembled", release_slug: prod.slug, assembled_at: 1.hour.ago)

    board = AppDevopsStages.board_for(eta_app)
    assert_equal "On QA", lane(board, "releasing").sub_label
    assert_equal "Going live", lane(board, "deploying").sub_label
    assert_nil lane(board, "deploying").eta, "no deploy history: no ETA"
  end

  test "[unit] the preview seam: a preview_ready checkpoint reads Preview ready, with no ETA" do
    durations("submitted", [ 600 ] * 3)
    task = card_task("Build Launch App eta-probe", "submitted", submitted_at: 1.minute.ago)
    task.record_checkpoint_event(name: AppDevopsStages::PREVIEW_READY_EVENT, status: "done")

    building = lane(AppDevopsStages.board_for(eta_app), "building")
    assert_equal "Preview ready", building.sub_label
    assert_nil building.eta
  end

  test "[unit] a live lane of one shows no count; the count shows from two up" do
    stage = ->(count, **opts) { AppDevopsStages::Stage.new(key: "building", label: "Building", state: :live, count: count, **opts) }
    assert_equal [ 0, 0, 2, 5 ], [ 0, 1, 2, 5 ].map { |count| stage.(count).shown_count }
    assert_equal 0, stage.(3, prepping: true).shown_count, "a prepping lane never shows a count"
  end

  test "[unit] a sub-label that repeats the label, in any case, is not shown; a different one is" do
    stage = ->(sub_label, eta: nil) { AppDevopsStages::Stage.new(key: "building", label: "Building", state: :live, count: 1, sub_label: sub_label, eta: eta) }
    assert_nil stage.("Building").shown_sub_label
    assert_nil stage.("building").shown_sub_label
    assert_not stage.("Building").second_line?, "nothing under the label when the sub-label is hidden and there is no ETA"
    assert stage.("Building", eta: Object.new).second_line?, "the ETA still shows beneath"
    assert_equal "Reviewing", stage.("Reviewing").shown_sub_label
    assert stage.("Reviewing").second_line?
  end
end
