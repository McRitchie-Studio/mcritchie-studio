require "test_helper"

# The DevOps card's averages are precomputed at the end of a deployment and stored
# in POSTGRES, on the release they were taken for.
#
# THE LESSON THIS FILE EXISTS TO KEEP, in two layers, because it took two
# send-backs to learn both.
#
# 1. WHERE. The first version stored them in Rails.cache and every test here
#    passed, because the whole suite is one process against one store. In
#    production `ship!` runs on a ONE-OFF dyno and Rails.cache is a per-dyno
#    FileStore, so the warm went to a filesystem no web dyno could read. A
#    single-process suite cannot prove a cross-process warm; it can only prove the
#    value lands somewhere SHARED.
#
# 2. WHAT CALLS IT. The second version reached Postgres but wrote into the shared
#    `metadata` blob, and was erased four lines later by the mascot re-stamp — a
#    full-column write from a stale instance. Every test still passed, because
#    they all drove Release#ship! (the model) and never
#    Release::Conductor.ship! (what bin/release actually invokes). Testing the
#    unit while production calls the caller is how a defect stays invisible twice.
#
# So these assert the value is in DEDICATED columns, for every window the UI
# renders, and they drive the CONDUCTOR — with a seeded mascot, so the re-stamp
# that did the erasing actually fires.
class ReleaseAveragesCacheTest < ActiveSupport::TestCase
  def shipped_release(branch:, created: 3.hours.ago, shipped: 1.hour.ago)
    release = Release.create!(branch: branch, state: "shipped")
    release.update_columns(created_at: created, shipped_at: shipped)
    release
  end

  test "[unit] a cold store computes instead of rendering blank" do
    shipped_release(branch: "release/cold-store-one")
    # No snapshot has ever been written — the state after any fresh database.
    assert_equal 0, Release.last_shipped.stage_averages_version

    averages = Release.deployment_stage_averages

    assert_equal 1, averages["sample_count"]
    assert averages["stages"].key?("total")
  end

  test "[integration] the warm lands in the database, where another process can read it" do
    release = shipped_release(branch: "release/warm-persists")
    Release.refresh_deployment_stage_averages!

    # Re-read from the DATABASE, not from the object we just wrote through. This
    # is the closest a single process gets to "another dyno asked".
    stored = Release.find(release.id)

    assert stored.stage_averages.present?, "the snapshot must be persisted, not held in process memory"
    assert_equal Release::DEPLOYMENT_AVERAGES_VERSION, stored.stage_averages_version
    assert stored.stage_averages_cached_at.present?
  end

  test "[integration] EVERY rendered window is warmed, not just the default" do
    shipped_release(branch: "release/every-window-one")
    Release.refresh_deployment_stage_averages!

    stored = Release.last_shipped.stage_averages

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
    release.update_columns(stage_averages_version: Release::DEPLOYMENT_AVERAGES_VERSION - 1)

    assert_nil Release.stored_deployment_stage_averages(10)
    # …and the public reader still answers, by recomputing.
    assert_equal 1, Release.deployment_stage_averages["sample_count"]
  end

  test "[unit] a malformed snapshot cannot 500 the public page" do
    release = shipped_release(branch: "release/malformed-snapshot")
    release.update_columns(stage_averages: { "10" => "not a hash" },
                           stage_averages_version: Release::DEPLOYMENT_AVERAGES_VERSION)

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

  # THE TEST THE LAST TWO ROUNDS DID NOT HAVE. Everything above drives
  # Release#ship!; production calls Release::Conductor.ship!, which does more —
  # including the mascot re-stamp that erased the previous implementation's
  # snapshot. The mascot stamp is also a no-op unless a Pokémon can be drawn, so
  # this seeds one: without it the test would pass while proving nothing, which is
  # the second half of how this stayed invisible.
  test "[integration] the conductor's ship! leaves the snapshot intact" do
    shipped_release(branch: "release/conductor-existing")
    pokemon = Pokemon.create!(slug: "conductor-probe-mon", name: "ConductorProbeMon", dex: 9001)
    release = Release.create!(branch: "release/conductor-warm", state: "assembling")

    # Current.conductor_session_id is what bin/release prefixes onto every
    # conductor payload, and it is the switch that arms the mascot re-stamp
    # (conductor.rb:955). Without it the stamp returns early, nothing rewrites
    # metadata, and this test would go green over a path that never ran.
    Current.set(conductor_session_id: SecureRandom.uuid) do
      Release::Conductor.ship!(release: release, deployed_sha: "0" * 40, by: "steffon")
    end

    stored = Release.find(release.id)
    assert_equal Release::DEPLOYMENT_AVERAGES_VERSION, stored.stage_averages_version,
                 "the conductor path erased the snapshot the ship just wrote"
    Release::RENDERED_AVERAGE_WINDOWS.each do |window|
      assert_equal 2, Release.deployment_stage_averages(limit: window)["sample_count"],
                   "the #{window}-release window did not survive the conductor's ship"
    end
    # …and the mascot re-stamp DID run, so the snapshot survived a real
    # metadata rewrite rather than a path where nothing rewrote it.
    assert_equal pokemon.slug, stored.metadata.dig("devops", "mascot"),
                 "premise: the mascot stamp must actually fire, or this proves nothing"
  end
end
