require "test_helper"

# Release.deployment_stage_averages is read through a cache and re-warmed at the
# end of every deployment.
#
# The behaviour worth guarding is NOT the speed — computing it is 5-9ms of a
# 1,200-2,000ms request, so this was always a shape change. It is that a COLD
# cache still renders. Production's Rails.cache is a per-dyno FileStore, wiped by
# every deploy and restart, so a write-on-ship-only design would have left the
# DevOps card blank from a restart until the next deployment finished.
class ReleaseAveragesCacheTest < ActiveSupport::TestCase
  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    @original = Rails.cache
    Rails.cache = @store
    Rails.cache.clear
  end

  teardown { Rails.cache = @original }

  def shipped_release(branch:, created: 3.hours.ago, shipped: 1.hour.ago)
    release = Release.create!(branch: branch, state: "shipped")
    release.update_columns(created_at: created, shipped_at: shipped)
    release
  end

  test "[unit] a cold cache recomputes instead of rendering blank" do
    shipped_release(branch: "release/cold-cache-one")
    Rails.cache.clear # exactly what a deploy or a dyno restart does to the FileStore

    averages = Release.deployment_stage_averages

    assert_equal 1, averages["sample_count"]
    assert averages["stages"].key?("total")
  end

  test "[unit] a second read is served from the cache, not recomputed" do
    shipped_release(branch: "release/second-read-one")
    first = Release.deployment_stage_averages

    # A release landing WITHOUT a refresh must not change the cached answer —
    # that is what proves the second read never recomputed.
    shipped_release(branch: "release/second-read-two")

    assert_equal first, Release.deployment_stage_averages
    assert_equal 1, Release.deployment_stage_averages["sample_count"]
  end

  test "[unit] refreshing recomputes and replaces the cached value" do
    shipped_release(branch: "release/refresh-one")
    assert_equal 1, Release.deployment_stage_averages["sample_count"]

    shipped_release(branch: "release/refresh-two")
    refreshed = Release.refresh_deployment_stage_averages!

    assert_equal 2, refreshed["sample_count"]
    # …and the next reader sees it, i.e. the refresh WROTE rather than just returned.
    assert_equal 2, Release.deployment_stage_averages["sample_count"]
  end

  test "[unit] the cached value survives a marshal round trip" do
    shipped_release(branch: "release/marshal-one")
    value = Release.refresh_deployment_stage_averages!

    # Production's store is a FileStore, which marshals. A value that cannot make
    # the round trip would fail only in production.
    assert_equal value, Marshal.load(Marshal.dump(value))
  end

  # Crosses both I/O boundaries this feature has — the database and the cache
  # store — through the real ship! path, which is the event the whole design hangs
  # on. A green unit test for refresh_deployment_stage_averages! says nothing
  # about whether anything CALLS it.
  test "[integration] finishing a deployment warms the cache with the new figures" do
    shipped_release(branch: "release/warm-existing")
    assert_equal 1, Release.deployment_stage_averages["sample_count"], "premise: one shipped release cached"

    release = Release.create!(branch: "release/warm-on-ship", state: "assembling")
    release.ship!(by: "steffon")

    # No explicit refresh here, and no cache clear: the ship itself must have
    # rewritten the value, or this still reads the stale 1.
    assert_equal 2, Release.deployment_stage_averages["sample_count"]
  end

  test "[unit] a cache-store failure cannot break a ship" do
    release = Release.create!(branch: "release/ship-cache-blows-up", state: "assembling")
    Release.stub(:refresh_deployment_stage_averages!, ->(*) { raise Errno::ENOSPC, "cache" }) do
      assert_nothing_raised { release.ship!(by: "steffon") }
    end

    assert_equal "shipped", release.reload.state
  end
end
