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
    assert_equal [ "running long", :long ], [ long.text, long.kind ], "never a negative or a zero promise"
    assert_nil Eta.estimate("reviewed", entered_at: now, medians: medians, launcher: true, now: now), "no data: no ETA"

    assert_equal [ "3 min", "20 min", "1 h", "2 h", "3 days" ],
                 [ 150, 1190, 3500, 5400, 3 * 86_400 ].map { |seconds| Eta.format_duration(seconds) }
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
