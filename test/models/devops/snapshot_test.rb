# frozen_string_literal: true

require "test_helper"

# Devops::Snapshot is the ONE read behind the /deployments DevOps card and its sidebar,
# shared by TasksController#deployments and DeploymentsBroadcaster.devops_card so the
# page load and the live push cannot drift (task devops-card-live-sidebar). These pin
# that it reads what each source reads, and that the locals it hands each partial name
# the same values: a mapping slip here is exactly the drift the object exists to stop.
class Devops::SnapshotTest < ActiveSupport::TestCase
  setup do
    Release.delete_all
    Task.delete_all
  end

  # Each release 20m batch, 30m QA, 10m hold, 10m ship.
  def seed_shipped_history(count = 3)
    count.times do |i|
      start = (i + 1).days.ago
      Release.create!(branch: "release", state: "shipped", created_at: start,
                      assembling_started_at: start, assembled_at: start + 50.minutes,
                      prod_deploy_started_at: start + 60.minutes, shipped_at: start + 70.minutes)
    end
  end

  test "[unit] build reads the flow, the in-flight estimate, WIP and the stage averages" do
    seed_shipped_history
    release = Release.open!
    Task.create!(title: "In flight one", stage: "building")
    Task.create!(title: "In flight two", stage: "reviewed")
    Task.create!(title: "Done", stage: "shipped")

    snapshot = Devops::Snapshot.build

    assert_equal release, snapshot.current_release, "defaults to the active singleton"
    assert_equal 3, snapshot.flow.size
    assert_equal Release::Flow.recent.median_total, snapshot.flow.median_total
    assert_kind_of Release::Flow::Estimate, snapshot.estimate, "a release in flight has a countdown"
    assert_equal "batch", snapshot.estimate.phase
    assert_equal 2, snapshot.wip_count, "shipped work is not in flight"
    assert_equal Task.wip_by_stage, snapshot.wip_by_stage
    assert_equal 1, snapshot.wip_by_stage["building"]
    assert_equal snapshot.wip_count, snapshot.wip_by_stage.values.sum, "the split adds up to the count"
    assert_equal Release.deployment_stage_averages, snapshot.stage_averages
  end

  test "[unit] nothing in flight: no estimate, and an empty board reads zero WIP" do
    seed_shipped_history

    snapshot = Devops::Snapshot.build

    assert_nil snapshot.current_release
    assert_nil snapshot.estimate, "no release in flight, no countdown"
    assert_equal 0, snapshot.wip_count
    assert snapshot.wip_by_stage.values.all?(&:zero?)
  end

  test "[unit] the controller's release is used, not a second lookup of the singleton" do
    seed_shipped_history
    release = Release.open!

    snapshot = Release.stub(:current, -> { flunk "build must not re-read Release.current when handed one" }) do
      Devops::Snapshot.build(current_release: release)
    end

    assert_same release, snapshot.current_release
    assert_not_nil snapshot.estimate
  end

  test "[unit] card and sidebar locals carry the SAME values, under each partial's own names" do
    seed_shipped_history
    Release.open!
    Task.create!(title: "In flight", stage: "building")

    snapshot = Devops::Snapshot.build
    card = snapshot.card_locals
    sidebar = snapshot.sidebar_locals

    assert_equal %i[flow estimate wip_count wip_by_stage], card.keys
    assert_equal %i[flow wip_count wip_by_stage dashboard], sidebar.keys
    assert_same card[:flow], sidebar[:flow]
    assert_equal card[:wip_count], sidebar[:wip_count]
    assert_same card[:wip_by_stage], sidebar[:wip_by_stage]
    assert_same snapshot.stage_averages, sidebar[:dashboard]
    assert_equal 1, sidebar[:wip_count]
  end
end
