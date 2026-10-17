# frozen_string_literal: true

require "test_helper"

# Per-app release trains, record side (release-trains-design.md §2, task B): the
# conductor sweeps one train at a time, Release#add keeps a repo on one active train,
# and the forming claim and live reads scope by train. config/release_trains.yml lists
# turf-monster, so a task naming only turf-monster rides the turf-monster train.
class Release::TrainRoutingTest < ActiveSupport::TestCase
  TURF = "turf-monster"

  def task_on(label, repos:, stage: "reviewed", merged: nil)
    Task.create!(title: "train routing #{label} task", stage: stage, merged: merged,
                 metadata: { "devops" => {
                   "shape" => "backend",
                   "repositories" => repos,
                   "pr_urls" => repos.to_h { |r| [ r, "https://github.com/McRitchie-Studio/#{r}/pull/7" ] }
                 } })
  end

  # --- the sweep -------------------------------------------------------------------

  test "[unit] the hub sweep holds a turf-only task under other_train" do
    turf = task_on("turf only", repos: [ TURF ])
    hub  = task_on("hub", repos: [ "mcritchie-studio" ])
    both = task_on("turf plus engine", repos: [ TURF, "studio-engine" ])

    cands = Release::Conductor.sweep_candidates

    reviewed = cands["reviewed"].map(&:slug)
    assert_includes reviewed, hub.slug
    assert_includes reviewed, both.slug, "an app-plus-engine task rides the hub"
    refute_includes reviewed, turf.slug, "the hub never sweeps an app train's task"
    assert_includes cands["other_train"].map(&:slug), turf.slug
  end

  test "[unit] the turf-monster sweep offers only turf-only tasks and holds hub work" do
    turf = task_on("turf only", repos: [ TURF ])
    hub  = task_on("hub", repos: [ "mcritchie-studio" ])
    both = task_on("turf plus engine", repos: [ TURF, "studio-engine" ])

    cands = Release::Conductor.sweep_candidates(train: TURF)

    assert_equal [ turf.slug ], cands["reviewed"].map(&:slug) & [ turf.slug, hub.slug, both.slug ]
    assert_includes cands["other_train"].map(&:slug), hub.slug
    assert_includes cands["other_train"].map(&:slug), both.slug
  end

  test "[unit] stragglers are filtered by train" do
    turf = task_on("turf straggler", repos: [ TURF ], stage: "assembled")
    hub  = task_on("hub straggler", repos: [ "mcritchie-studio" ], stage: "assembled")

    assert_includes Release::Conductor.straggler_tasks.map(&:slug), hub.slug
    refute_includes Release::Conductor.straggler_tasks.map(&:slug), turf.slug
    assert_equal [ turf.slug ], Release::Conductor.straggler_tasks(train: TURF).map(&:slug) & [ turf.slug, hub.slug ]
    assert_includes Release::Conductor.sweep_candidates["other_train"].map(&:slug), turf.slug
  end

  test "[unit] the turf straggler read is relative to the turf train's own release" do
    rel  = Release.open!(train: TURF)
    turf = task_on("turf member", repos: [ TURF ], stage: "assembled")
    turf.update!(release_slug: rel.slug)

    refute_includes Release::Conductor.straggler_tasks(train: TURF).map(&:slug), turf.slug,
                    "a member of the turf train's current release is not its straggler"
  end

  test "[unit] sweep! with train: opens and fills that train's release, leaving the hub alone" do
    turf = task_on("turf sweep", repos: [ TURF ], merged: "accepted")

    release = Release::Conductor.sweep!(turf, train: TURF)

    assert_equal TURF, release.train
    assert_equal release.slug, turf.reload.release_slug
    assert_nil Release.current, "no hub release was opened"
  end

  test "[unit] sweep! without train: still rides the hub (today's behaviour)" do
    hub = task_on("hub sweep", repos: [ "mcritchie-studio" ], merged: "accepted")
    release = Release::Conductor.sweep!(hub)
    assert_equal "hub", release.train
  end

  test "[unit] sweep! refuses another train's task named through an explicit door, before any write" do
    turf = task_on("turf named", repos: [ TURF ], merged: "accepted")

    error = assert_raises(ArgumentError) { Release::Conductor.sweep!(turf) }
    assert_match(/rides the turf-monster train, not hub: sweep it with `bin\/release prepare --train turf-monster`/, error.message)
    assert_nil Release.current, "the refusal opened no hub release"
    assert_nil turf.reload.release_slug
  end

  test "[unit] sweep! override is the audited escape hatch past the train backstop" do
    turf = task_on("turf override", repos: [ TURF ], merged: "accepted")
    release = Release::Conductor.sweep!(turf, override: true)
    assert_equal "hub", release.train
  end

  test "[unit] a member already riding the hub release stays on it after its app gets a train" do
    hub_rel = Release.open!
    turf = task_on("turf legacy member", repos: [ TURF ])
    turf.update_columns(release_slug: hub_rel.slug)

    assert_includes Release::Conductor.sweep_candidates["reviewed"].map(&:slug), turf.slug
    assert_equal hub_rel.slug, Release::Conductor.sweep!(turf).slug
  end

  # --- repo exclusivity ------------------------------------------------------------

  test "[unit] Release#add refuses a task whose repo another active train holds" do
    turf_rel = Release.open!(train: TURF)
    turf_rel.add(task_on("turf member", repos: [ TURF ]))
    hub_rel = Release.open!

    both = task_on("turf plus engine", repos: [ TURF, "studio-engine" ])
    error = assert_raises(ArgumentError) { hub_rel.add(both) }
    assert_match(/turf-monster \(turf-monster train, #{turf_rel.slug}\)/, error.message)
    assert_nil both.reload.release_slug, "nothing was attached"

    hub_only = task_on("hub only", repos: [ "mcritchie-studio" ])
    assert_equal hub_rel.slug, hub_rel.add(hub_only).release_slug, "a repo no other train holds attaches"
  end

  test "[unit] Release#add refuses even with override, and an empty other train holds nothing" do
    turf_rel = Release.open!(train: TURF)
    hub_rel  = Release.open!
    both = task_on("turf plus engine", repos: [ TURF, "studio-engine" ])
    assert_equal hub_rel.slug, hub_rel.add(both).release_slug, "an active train with no members holds no repo"

    turf_task = task_on("turf only", repos: [ TURF ])
    assert_raises(ArgumentError) { turf_rel.add(turf_task, override: true) }
  end

  test "[unit] a shipped release on another train holds no repo" do
    turf_rel = Release.open!(train: TURF)
    turf_rel.add(task_on("turf member", repos: [ TURF ]))
    turf_rel.update!(state: "shipped")
    hub_rel = Release.open!

    both = task_on("turf plus engine", repos: [ TURF, "studio-engine" ])
    assert_equal hub_rel.slug, hub_rel.add(both).release_slug
  end

  # --- claims ----------------------------------------------------------------------

  test "[unit] the hub keeps the bare forming sentinel; another train scopes it" do
    assert_equal "__forming__", ReleaseConductorClaim.forming_slug
    assert_equal "__forming__", ReleaseConductorClaim.forming_slug("hub")
    assert_equal "__forming__:turf-monster", ReleaseConductorClaim.forming_slug(TURF)
  end

  test "[unit] any_live? and live_holder scope by train, and stay global without one" do
    turf_rel = Release.open!(train: TURF)
    ReleaseConductorClaim.acquire(release_slug: turf_rel.slug, role: "deployer", session: "s-turf", nonce: "n-turf")

    assert ReleaseConductorClaim.any_live?(role: "deployer"), "unscoped reads every train"
    assert ReleaseConductorClaim.any_live?(role: "deployer", train: TURF)
    refute ReleaseConductorClaim.any_live?(role: "deployer", train: "hub")
    assert_nil ReleaseConductorClaim.live_holder(role: "deployer", train: "hub")
    refute_nil ReleaseConductorClaim.live_holder(role: "deployer", train: TURF)
  end

  test "[unit] a train's forming claim counts for that train only" do
    ReleaseConductorClaim.acquire(release_slug: ReleaseConductorClaim.forming_slug(TURF), role: "assembler",
                                  session: "s-turf", nonce: "n-turf")

    assert ReleaseConductorClaim.any_live?(role: "assembler", train: TURF)
    refute ReleaseConductorClaim.any_live?(role: "assembler", train: "hub")
  end

  test "[unit] the hub forming claim and a turf forming claim never contend" do
    hub  = ReleaseConductorClaim.acquire(release_slug: ReleaseConductorClaim.forming_slug, role: "assembler",
                                         session: "s-hub", nonce: "n-hub")
    turf = ReleaseConductorClaim.acquire(release_slug: ReleaseConductorClaim.forming_slug(TURF), role: "assembler",
                                         session: "s-turf", nonce: "n-turf")
    assert hub.acquired
    assert turf.acquired, "an app train's fresh prepare never stands the hub down"
  end

  test "[unit] a train's forming slug routes as one release slug on the claim API" do
    route = Rails.application.routes.recognize_path("/api/v1/releases/__forming__:turf-monster/conductor_claim",
                                                    method: :post)
    assert_equal "__forming__:turf-monster", route[:slug]
    assert_equal "acquire", route[:action]
  end

  test "[unit] the CLI forming slug mirrors the model's" do
    require Rails.root.join("bin/lib/release_claim_cli").to_s
    [ nil, "hub", TURF ].each do |train|
      assert_equal ReleaseConductorClaim.forming_slug(train), ReleaseClaimCli.forming_slug(train)
    end
  end

  test "[unit] the lane names a train's forming claim as that train's next release" do
    assert_equal "the next release", Release::LaneLease.send(:release_name, "__forming__")
    assert_equal "the next turf-monster release", Release::LaneLease.send(:release_name, "__forming__:turf-monster")
    assert_equal "rel-x", Release::LaneLease.send(:release_name, "rel-x")
  end

  # --- archive ---------------------------------------------------------------------

  test "[unit] archive keeps each train's last shipped members" do
    hub_rel = Release.open!
    hub_member = task_on("hub shipped", repos: [ "mcritchie-studio" ])
    hub_rel.add(hub_member)
    turf_rel = Release.open!(train: TURF)
    turf_member = task_on("turf shipped", repos: [ TURF ])
    turf_rel.add(turf_member)
    [ hub_member, turf_member ].each { |t| t.update_columns(stage: "shipped") }
    [ hub_rel, turf_rel ].each { |r| r.update!(state: "shipped", shipped_at: Time.current) }

    archivable = Release::Conductor.archivable_completed_slugs
    refute_includes archivable, hub_member.slug
    refute_includes archivable, turf_member.slug, "a hub archive never empties the turf train's Last Release"
  end
end
