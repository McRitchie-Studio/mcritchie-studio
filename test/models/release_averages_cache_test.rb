require "test_helper"

# The DevOps card's averages are precomputed at the end of a deployment and stored
# in POSTGRES, on the release they were taken for.
#
# THE LESSON THIS FILE EXISTS TO KEEP. The first version stored them in
# Rails.cache and every test here passed, because the whole suite is one process
# against one store. In production `ship!` runs on a ONE-OFF dyno and Rails.cache
# is a per-dyno FileStore, so the warm was written to a filesystem no web dyno
# could ever read — a defect that only existed across a process boundary the
# suite could not cross. A single-process test cannot prove a cross-process warm;
# it can only prove the warm lands somewhere SHARED. That is what these assert:
# the value is in the database, and it is there for every window the UI renders.
class ReleaseAveragesCacheTest < ActiveSupport::TestCase
  def shipped_release(branch:, created: 3.hours.ago, shipped: 1.hour.ago)
    release = Release.create!(branch: branch, state: "shipped")
    release.update_columns(created_at: created, shipped_at: shipped)
    release
  end

  test "[unit] a cold store computes instead of rendering blank" do
    shipped_release(branch: "release/cold-store-one")
    # No snapshot has ever been written — the state after any fresh database.
    assert_nil Release.last_shipped.metadata["deployment_stage_averages"]

    averages = Release.deployment_stage_averages

    assert_equal 1, averages["sample_count"]
    assert averages["stages"].key?("total")
  end

  test "[integration] the warm lands in the database, where another process can read it" do
    release = shipped_release(branch: "release/warm-persists")
    Release.refresh_deployment_stage_averages!

    # Re-read from the DATABASE, not from the object we just wrote through. This
    # is the closest a single process gets to "another dyno asked".
    stored = Release.find(release.id).metadata["deployment_stage_averages"]

    assert stored.is_a?(Hash), "the snapshot must be persisted, not held in process memory"
    assert_equal Release::DEPLOYMENT_AVERAGES_VERSION, stored["version"]
    assert stored["cached_at"].present?
  end

  test "[integration] EVERY rendered window is warmed, not just the default" do
    shipped_release(branch: "release/every-window-one")
    Release.refresh_deployment_stage_averages!

    stored = Release.last_shipped.metadata.dig("deployment_stage_averages", "windows")

    # The bug this replaces: the page rendered [3, 10] while the warm refreshed
    # only 10, so a 3-release row could exclude a release the 10-release row
    # above it included.
    assert_equal Release::RENDERED_AVERAGE_WINDOWS.map(&:to_s).sort, stored.keys.sort
    Release::RENDERED_AVERAGE_WINDOWS.each do |window|
      assert stored[window.to_s]["stages"].key?("total"), "window #{window} was not warmed"
    end
  end

  test "[integration] every rendered window is FRESH after a ship" do
    shipped_release(branch: "release/fresh-windows-old")
    Release.refresh_deployment_stage_averages!
    Release::RENDERED_AVERAGE_WINDOWS.each do |window|
      assert_equal 1, Release.deployment_stage_averages(limit: window)["sample_count"]
    end

    release = Release.create!(branch: "release/fresh-windows-new", state: "assembling")
    release.ship!(by: "steffon")

    # No explicit refresh and no store clearing: the ship itself must have
    # rewritten EVERY window, or one of these still reads the stale 1.
    Release::RENDERED_AVERAGE_WINDOWS.each do |window|
      assert_equal 2, Release.deployment_stage_averages(limit: window)["sample_count"],
                   "the #{window}-release window is stale after a ship"
    end
  end

  test "[unit] a version bump makes an old snapshot unreadable rather than wrong" do
    release = shipped_release(branch: "release/version-gate-one")
    Release.refresh_deployment_stage_averages!
    stale = release.reload.metadata["deployment_stage_averages"].merge("version" => 0)
    release.update_columns(metadata: release.metadata.merge("deployment_stage_averages" => stale))

    assert_nil Release.stored_deployment_stage_averages(10)
    # …and the public reader still answers, by recomputing.
    assert_equal 1, Release.deployment_stage_averages["sample_count"]
  end

  test "[unit] a malformed snapshot cannot 500 the public page" do
    release = shipped_release(branch: "release/malformed-snapshot")
    release.update_columns(metadata: release.metadata.merge("deployment_stage_averages" => "not a hash"))

    # /deployments is unauthenticated and ApplicationController has no rescue_from,
    # so anything that raises here is a public 500.
    assert_nothing_raised { Release.deployment_stage_averages }
    assert_equal 1, Release.deployment_stage_averages["sample_count"]
  end

  test "[unit] a snapshot write failure cannot break a ship" do
    release = Release.create!(branch: "release/ship-warm-blows-up", state: "assembling")
    Release.stub(:refresh_deployment_stage_averages!, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_nothing_raised { release.ship!(by: "steffon") }
    end

    assert_equal "shipped", release.reload.state
  end
end
