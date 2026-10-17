# frozen_string_literal: true

require "test_helper"

# Release::Trains — the routing rule behind per-app release trains
# (release-trains-design.md §2, task B), plus the real config/release_trains.yml held
# to the registry it must agree with.
class Release::TrainsTest < ActiveSupport::TestCase
  TRAINS = { "turf-monster" => { "repos" => [ "turf-monster" ] } }.freeze

  def task_naming(repos, stage: "reviewed")
    Task.create!(title: "train routing #{repos.join(' ')}", stage: stage,
                 metadata: { "devops" => { "shape" => "backend", "repositories" => repos } })
  end

  # --- routing -------------------------------------------------------------------

  test "[unit] a task naming only a listed app rides that app's train" do
    assert_equal "turf-monster", Release::Trains.train_for([ "turf-monster" ], TRAINS)
  end

  test "[unit] app plus engine rides the hub, where the gem publishes first" do
    assert_equal "hub", Release::Trains.train_for(%w[turf-monster studio-engine], TRAINS)
  end

  test "[unit] app plus hub, a gem alone, the hub alone and no repos all ride the hub" do
    assert_equal "hub", Release::Trains.train_for(%w[turf-monster mcritchie-studio], TRAINS)
    assert_equal "hub", Release::Trains.train_for([ "studio-engine" ], TRAINS)
    assert_equal "hub", Release::Trains.train_for([ "mcritchie-studio" ], TRAINS)
    assert_equal "hub", Release::Trains.train_for([], TRAINS)
  end

  test "[unit] an unlisted app rides the hub" do
    assert_equal "hub", Release::Trains.train_for([ "cyvasse" ], TRAINS)
  end

  test "[unit] with no trains configured everything rides the hub" do
    assert_equal "hub", Release::Trains.train_for([ "turf-monster" ], {})
  end

  test "[unit] Task#release_train reads the task's release repos" do
    Release::Trains.with_config(TRAINS) do
      assert_equal "turf-monster", task_naming([ "turf-monster" ]).release_train
      assert_equal "hub", task_naming(%w[turf-monster studio-engine]).release_train
      assert_equal "hub", task_naming([ "mcritchie-studio" ]).release_train
    end
  end

  test "[unit] Task#release_train is a reader; the retired devops release_train key is still refused" do
    Release::Trains.with_config(TRAINS) do
      assert_raises(ArgumentError) { Task.normalize_devops_metadata("release_train" => "rel-x", "kind" => "feature") }
      assert_equal "turf-monster", task_naming([ "turf-monster" ]).release_train
    end
  end

  test "[unit] Task#release_train counts a repo carried only by a PR url" do
    Release::Trains.with_config(TRAINS) do
      task = Task.create!(title: "train via pr url", stage: "reviewed",
                          metadata: { "devops" => { "shape" => "backend", "repositories" => [ "turf-monster" ],
                                                    "pr_urls" => { "studio-engine" => "https://github.com/McRitchie-Studio/studio-engine/pull/3" } } })
      assert_equal "hub", task.release_train, "the engine PR makes it an app-plus-engine task"
    end
  end

  # --- config ----------------------------------------------------------------------

  test "[unit] the hub constant mirrors Release::DEFAULT_TRAIN" do
    assert_equal Release::DEFAULT_TRAIN, Release::Trains::HUB
  end

  test "[unit] normalize refuses a listed hub, an empty train and a bad slug" do
    assert_raises(ArgumentError) { Release::Trains.normalize("hub" => { "repos" => [ "x" ] }) }
    assert_raises(ArgumentError) { Release::Trains.normalize("turf-monster" => { "repos" => [] }) }
    assert_raises(ArgumentError) { Release::Trains.normalize("Turf_Monster" => { "repos" => [ "turf-monster" ] }) }
    assert_raises(ArgumentError) { Release::Trains.normalize([ "turf-monster" ]) }
  end

  test "[unit] the real config lists no train until task C, so everything rides the hub" do
    assert_equal({}, Release::Trains.load_file(Release::Trains::CONFIG_PATH))
    assert_equal "hub", Release::Trains.train_for([ "turf-monster" ], Release::Trains.load_file(Release::Trains::CONFIG_PATH))
    train, error = Release::Trains.take_flag(%w[prepare --train turf-monster], Release::Trains.load_file(Release::Trains::CONFIG_PATH))
    assert_nil train
    assert_match(/unknown release train "turf-monster"/, error, "--train turf-monster is refused until task C lists it")
  end

  test "[unit] the commented example entry is a valid train on a three-rung app" do
    lines = File.read(Release::Trains::CONFIG_PATH).lines
    example = lines.drop_while { |line| !line.start_with?("# turf-monster:") }.map { |line| line.sub(/\A# ?/, "") }.join
    trains = Release::Trains.normalize(YAML.safe_load(example))
    assert_equal({ "turf-monster" => { "repos" => [ "turf-monster" ] } }, trains)
    trains.values.flat_map { |entry| entry["repos"] }.each do |repo|
      assert Release::Repos.app?(repo), "#{repo} must be an app in the Release::Repos registry"
      refute Release::Repos.gem?(repo), "#{repo}: gems publish only on the hub train"
      assert_equal "three-rung", Release::Repos.ladder(repo)
    end
  end

  test "[unit] with_config swaps the config for the block and restores it" do
    before = Release::Trains.config
    Release::Trains.with_config(TRAINS) { assert_equal "turf-monster", Release::Trains.train_for([ "turf-monster" ]) }
    assert_equal before, Release::Trains.config
  end

  # --- --train ---------------------------------------------------------------------

  test "[unit] take_flag defaults to the hub and consumes the flag in both spellings" do
    argv = %w[prepare --yes]
    assert_equal [ "hub", nil ], Release::Trains.take_flag(argv, TRAINS)
    assert_equal %w[prepare --yes], argv

    argv = %w[prepare --train turf-monster --yes]
    assert_equal [ "turf-monster", nil ], Release::Trains.take_flag(argv, TRAINS)
    assert_equal %w[prepare --yes], argv

    argv = %w[ship --train=hub]
    assert_equal [ "hub", nil ], Release::Trains.take_flag(argv, TRAINS)
    assert_equal %w[ship], argv
  end

  test "[unit] take_flag refuses a bare or unknown train instead of reading it as the hub" do
    train, error = Release::Trains.take_flag(%w[prepare --train], TRAINS)
    assert_nil train
    assert_match(/needs a train slug/, error)

    train, error = Release::Trains.take_flag(%w[prepare --train cyvasse], TRAINS)
    assert_nil train
    assert_match(/unknown release train "cyvasse"/, error)
  end

  # --- the app train's accepted guard ----------------------------------------------

  test "[unit] foreign_accepted_work names a hub-train task merged onto the app's accepted" do
    stranded = { "turf-monster" => [
      { "sha" => "aaa1111", "subject" => "Merge pull request #9 from McRitchie-Studio/feat/turf-only" },
      { "sha" => "bbb2222", "subject" => "Merge pull request #10 from McRitchie-Studio/feat/turf-plus-engine" },
      { "sha" => "ccc3333", "subject" => "fix a typo" },
      { "sha" => "ddd4444", "subject" => "Merge pull request #11 from McRitchie-Studio/feat/unknown-task" }
    ] }
    index = { "turf-only" => [ "turf-monster" ], "turf-plus-engine" => %w[turf-monster studio-engine] }

    foreign = Release::Trains.foreign_accepted_work(stranded, index, "turf-monster", TRAINS)

    assert_equal [ "turf-plus-engine" ], foreign.map { |f| f["slug"] }
    assert_equal({ "repo" => "turf-monster", "sha" => "bbb2222", "train" => "hub" },
                 foreign.first.slice("repo", "sha", "train"))
  end

  test "[unit] foreign_accepted_work is empty when accepted carries only this train's tasks" do
    stranded = { "turf-monster" => [ { "sha" => "a", "subject" => "Merge pull request #9 from o/feat/turf-only" } ] }
    assert_empty Release::Trains.foreign_accepted_work(stranded, { "turf-only" => [ "turf-monster" ] }, "turf-monster", TRAINS)
  end
end
