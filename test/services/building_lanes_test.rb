require "test_helper"

# [unit] Concurrent task lanes per tier (BuildingLanes, docs/agents/system/client-pipeline.md):
# a tiered client app may have its tier's building_lanes tasks in `building`; the
# claim past the cap is refused with the tier and the upgrade named; the hub and
# an app with no tier are never capped; a rework bounce and a re-claim take no lane.
class BuildingLanesTest < ActiveSupport::TestCase
  setup do
    @turf = apps(:turf_monster)
    @hub = apps(:mcritchie_studio)
  end

  def task!(title, stage:, repos: [ "turf-monster" ], **attrs)
    Task.create!(title: title, stage: stage, metadata: { "devops" => { "repositories" => repos } }, **attrs)
  end

  test "[unit] each tier caps its app at its own lane count" do
    { "vibe" => 1, "builder" => 2, "pro" => 3, "team" => 4 }.each do |tier, cap|
      Task.where(stage: "building").update_all(stage: "archived")
      @turf.update!(package_tier: tier)
      cap.times { |n| task!("Lane #{tier} #{n}", stage: "building", started_at: n.minutes.ago) }

      status = BuildingLanes.status(@turf)
      assert_equal cap, status.cap, tier
      assert status.full?, tier
      assert_equal "#{cap} of #{cap} #{cap == 1 ? 'lane' : 'lanes'} in use", status.label

      extra = task!("Waiting #{tier}", stage: "designed")
      refute extra.update(stage: "building"), "#{tier}: lane #{cap + 1} is refused"
      assert_equal "designed", extra.reload.stage
      assert_match(/Turf Monster is on the #{WorkspacePackage.find(tier).name} tier: #{cap} of #{cap} building/, extra.errors[:base].first)
    end
  end

  test "[unit] the refusal names the lanes in use and the next tier up" do
    @turf.update!(package_tier: "builder")
    task!("First", stage: "building", slug: "lane-first", started_at: 2.hours.ago)
    task!("Second", stage: "building", slug: "lane-second", started_at: 1.hour.ago)
    message = BuildingLanes.refusal_for(task!("Third", stage: "designed"))

    assert_includes message, "2 of 2 building lanes in use (lane-first, lane-second)"
    assert_includes message, "upgrade to Pro for 3 lanes (/packages)"
    assert_includes message, "waits in designed"

    @turf.update!(package_tier: "team")
    2.times { |n| task!("More #{n}", stage: "building") }
    assert_includes BuildingLanes.refusal_for(task!("Fifth", stage: "designed")), "upgrade to Enterprise for unlimited lanes"
  end

  test "[unit] under the cap a claim goes through, and the count is per app" do
    @turf.update!(package_tier: "builder")
    task!("Hub work", stage: "building", repos: [ "mcritchie-studio" ])
    task!("Turf one", stage: "building")
    second = task!("Turf two", stage: "designed")

    assert second.update(stage: "building"), second.errors.full_messages.to_sentence
    assert_equal 2, BuildingLanes.status(@turf).in_use
  end

  test "[unit] the hub, an app with no tier, and an unlimited tier are never capped" do
    @hub.update!(package_tier: "vibe")
    3.times { |n| task!("Hub #{n}", stage: "building", repos: [ "mcritchie-studio" ]) }
    assert task!("Hub more", stage: "designed", repos: [ "mcritchie-studio" ]).update(stage: "building")
    refute BuildingLanes.status(@hub).capped?, "the hub is internal whatever its tier"

    @turf.update!(package_tier: nil)
    3.times { |n| task!("Untiered #{n}", stage: "building") }
    assert task!("Untiered more", stage: "designed").update(stage: "building")
    assert_equal "4 lanes in use", BuildingLanes.status(@turf).label

    @turf.update!(package_tier: "enterprise")
    assert task!("Enterprise more", stage: "designed").update(stage: "building")
    assert_nil BuildingLanes.cap_for(@turf)
  end

  test "[unit] a rework bounce and a re-claim of a building task take no new lane" do
    @turf.update!(package_tier: "vibe")
    building = task!("Holding the lane", stage: "building")
    submitted = task!("Back for rework", stage: "submitted", started_at: 1.day.ago)

    assert submitted.update(stage: "building"), "a submitted task bounced back to building is not a claim"
    assert building.update(stage: "building", title: "Holding the lane (re-claimed)")
  end

  test "[unit] a create straight into building is a claim too" do
    @turf.update!(package_tier: "vibe")
    task!("Only lane", stage: "building")
    assert_raises(ActiveRecord::RecordInvalid) { task!("Sneaks in", stage: "building") }
  end

  # Carl's review of client-devops-view-lanes, note 3: paths into building the
  # first cut did not check.
  test "[unit] a reopen from shipped or archived is a claim" do
    @turf.update!(package_tier: "vibe")
    task!("Only lane", stage: "building")
    %w[shipped archived].each do |from|
      reopened = task!("Reopened from #{from}", stage: from)
      refute reopened.update(stage: "building"), "a #{from} task reopened past the cap is refused"
      assert_equal from, reopened.reload.stage
    end
  end

  test "[unit] a task created at a later stage and moved back is a claim" do
    @turf.update!(package_tier: "vibe")
    task!("Only lane", stage: "building")
    never_claimed = task!("Created at submitted", stage: "submitted")
    assert_nil never_claimed.started_at

    refute never_claimed.update(stage: "building"), "a never-claimed task's first move to building takes a lane"
    assert_raises(ActiveRecord::RecordInvalid) { never_claimed.reload.block!(by: "carl", kind: "rework") }
  end

  test "[unit] adding a client repo to a building task checks that app's lanes only" do
    @turf.update!(package_tier: "vibe")
    task!("Only turf lane", stage: "building")
    hub_task = task!("Hub work", stage: "building", repos: [ "mcritchie-studio" ])

    hub_task.metadata = hub_task.metadata.deep_merge("devops" => { "repositories" => %w[mcritchie-studio turf-monster] })
    refute hub_task.save, "adding turf-monster at its cap is refused"
    assert_match(/Turf Monster is on the Vibe tier/, hub_task.errors[:base].first)

    turf_task = Task.find_by!(title: "Only turf lane")
    turf_task.title = "Only turf lane (renamed)"
    assert turf_task.save, "a building task's other edits take no new lane"
  end

  test "[unit] the claim takes a per-app advisory lock so concurrent claims serialize" do
    @turf.update!(package_tier: "builder")
    claim = task!("Claiming", stage: "designed")
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      assert claim.update(stage: "building")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    lock = statements.index { |sql| sql.include?("pg_advisory_xact_lock(#{BuildingLanes::LOCK_NAMESPACE},") }
    count = statements.index { |sql| sql.include?(%(SELECT "tasks"."slug")) && sql.include?("'repositories' @>") }
    assert lock, "the claim takes the lane lock"
    assert count && lock < count, "the lock is taken before the lanes are counted"

    statements.clear
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      BuildingLanes.refusal_for(claim)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    refute statements.any? { |sql| sql.include?("pg_advisory_xact_lock") }, "the read-only check takes no lock"
  end
end
