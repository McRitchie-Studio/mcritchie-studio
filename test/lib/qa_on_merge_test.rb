# frozen_string_literal: true

# The opt-in QA-on-merge trigger (task release-sub-hour-pipeline): a reviewed merge
# starts `bin/release prepare --task <slug> --yes` only when the switch is on and no
# release is active. It stops at QA. Run directly:
#   ruby -Itest test/lib/qa_on_merge_test.rb

require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/qa_on_merge"

class QaOnMergeTest < Minitest::Test
  def config(dir, body)
    path = File.join(dir, "release_builder.yml")
    File.write(path, body)
    path
  end

  def test_it_is_off_by_default_and_in_the_committed_config
    refute QaOnMerge.enabled?(env: {}), "the committed config keeps the trigger off"
    Dir.mktmpdir do |dir|
      refute QaOnMerge.enabled?(env: {}, config_path: config(dir, "production_ship:\n  mode: timed\n"))
      refute QaOnMerge.enabled?(env: {}, config_path: File.join(dir, "missing.yml")), "an unreadable config is off"
    end
  end

  def test_the_config_or_the_env_flag_turns_it_on_and_the_flag_wins
    Dir.mktmpdir do |dir|
      on = config(dir, "qa_on_merge:\n  enabled: true\n")
      assert QaOnMerge.enabled?(env: {}, config_path: on)
      refute QaOnMerge.enabled?(env: { "RELEASE_QA_ON_MERGE" => "off" }, config_path: on), "the flag turns it off"
      assert QaOnMerge.enabled?(env: { "RELEASE_QA_ON_MERGE" => "1" }), "the flag turns it on"
      refute QaOnMerge.enabled?(env: { "RELEASE_QA_ON_MERGE" => "maybe" }), "an unknown flag falls to the config"
    end
  end

  def test_it_launches_a_task_scoped_prepare_only_with_no_active_release
    assert_equal [:launch, %w[prepare --task t-fast --yes]], QaOnMerge.decide(slug: "t-fast", enabled: true, active: "")
    assert_equal [:launch, %w[prepare --task t-fast --yes]], QaOnMerge.decide(slug: "t-fast", enabled: true, active: nil)

    verdict, reason = QaOnMerge.decide(slug: "t-fast", enabled: true, active: "rel-1")
    assert_equal :skip, verdict
    assert_includes reason, "rides the next release"

    assert_equal :skip, QaOnMerge.decide(slug: "t-fast", enabled: false, active: "").first
    assert_equal :skip, QaOnMerge.decide(slug: " ", enabled: true, active: "").first
  end

  def test_the_launch_never_names_a_ship
    _, argv = QaOnMerge.decide(slug: "t-fast", enabled: true, active: "")
    refute_includes argv, "ship"
    refute_includes argv, "cycle"
    refute(argv.any? { |a| a.include?("clearance") })
  end
end
