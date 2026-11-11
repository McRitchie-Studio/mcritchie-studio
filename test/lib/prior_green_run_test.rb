# frozen_string_literal: true

# The rules reusable-ci.yml's `prior_green` job applies before any lane (task
# release-sub-hour-pipeline): a push to main or release skips the suite ONLY when a
# completed PUSH run of the same workflow already concluded success on the exact commit.
# Every other shape runs the suite. Run directly:
#   ruby -Itest test/lib/prior_green_run_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require_relative "../../.github/scripts/prior-green-run"

class PriorGreenRunTest < Minitest::Test
  SCRIPT = File.expand_path("../../.github/scripts/prior-green-run.rb", __dir__)
  SHA = "2a2430c23aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  REPO = "McRitchie-Studio/mcritchie-studio"
  ENV_PUSH = {
    "GITHUB_EVENT_NAME" => "push",
    "GITHUB_REF" => "refs/heads/release",
    "GITHUB_SHA" => SHA,
    "GITHUB_RUN_ID" => "900",
    "GITHUB_REPOSITORY" => REPO,
    "GITHUB_WORKFLOW_REF" => "#{REPO}/.github/workflows/ci.yml@refs/heads/release"
  }.freeze

  # The accepted push run that concluded green at 08:22 on rel-20261110-0123f9.
  def green_run(**over)
    { "id" => 800, "path" => ".github/workflows/ci.yml", "head_sha" => SHA, "head_branch" => "accepted",
      "event" => "push", "status" => "completed", "conclusion" => "success",
      "repository" => { "full_name" => REPO } }.merge(over.transform_keys(&:to_s))
  end

  def body(*runs) = JSON.generate("total_count" => runs.size, "workflow_runs" => runs)

  def decide(runs_body, env = ENV_PUSH) = PriorGreenRun.decide(env, runs_body)

  def test_a_completed_green_push_run_on_the_same_commit_skips_the_suite
    skips, reason = decide(body(green_run))
    assert skips
    assert_includes reason, "run 800 (accepted) already concluded success on 2a2430c"
  end

  def test_a_push_to_main_is_credited_the_same_way
    skips, = decide(body(green_run), ENV_PUSH.merge("GITHUB_REF" => "refs/heads/main"))
    assert skips
  end

  def test_only_pushes_to_main_and_release_may_skip
    [{ "GITHUB_REF" => "refs/heads/accepted" },
     { "GITHUB_REF" => "refs/heads/feat/x" },
     { "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_REF" => "refs/pull/1/merge" },
     { "GITHUB_EVENT_NAME" => "workflow_dispatch" },
     { "GITHUB_EVENT_NAME" => "" }].each do |over|
      skips, reason = decide(body(green_run), ENV_PUSH.merge(over))
      refute skips, "#{over.inspect} must run the suite"
      assert_includes reason, "always runs the suite"
    end
  end

  def test_every_mismatch_runs_the_suite
    {
      "this same run" => { id: 900 },
      "another workflow" => { path: ".github/workflows/ui-budget.yml" },
      "another commit" => { head_sha: "b" * 40 },
      "a fork's run" => { repository: { "full_name" => "someone/mcritchie-studio" } },
      "a pull_request run (it tested a merge ref)" => { event: "pull_request" },
      "a schedule run" => { event: "schedule" },
      "a run still in progress" => { status: "in_progress", conclusion: nil },
      "a failed run" => { conclusion: "failure" },
      "a cancelled run" => { conclusion: "cancelled" },
      "a skipped run" => { conclusion: "skipped" }
    }.each do |label, over|
      skips, = decide(body(green_run(**over)))
      refute skips, "#{label} must not be credited"
    end
  end

  def test_unreadable_or_incomplete_input_runs_the_suite
    ["", "not json", "{}", '{"message":"Resource not accessible by integration"}', "[]"].each do |raw|
      skips, = decide(raw)
      refute skips, "#{raw.inspect} must run the suite"
    end
    %w[GITHUB_SHA GITHUB_RUN_ID GITHUB_REPOSITORY GITHUB_WORKFLOW_REF].each do |key|
      skips, = decide(body(green_run), ENV_PUSH.except(key))
      refute skips, "no #{key} must run the suite"
    end
  end

  def test_the_workflow_path_comes_from_the_workflow_ref
    assert_equal ".github/workflows/ci.yml", PriorGreenRun.workflow_path("o/r/.github/workflows/ci.yml@refs/heads/main")
    assert_equal "", PriorGreenRun.workflow_path("garbage")
  end

  # [integration] The script as the job runs it: prints exactly the two output lines and
  # exits 0, both when it skips and when the runs file is missing.
  def test_the_script_prints_its_outputs_and_always_exits_zero
    Dir.mktmpdir do |dir|
      runs = File.join(dir, "runs.json")
      File.write(runs, body(green_run))
      out, status = Open3.capture2(ENV_PUSH, RbConfig.ruby, SCRIPT, runs)
      assert status.success?
      assert_match(/\Askip=true\nreason=run 800/, out)

      out, status = Open3.capture2(ENV_PUSH, RbConfig.ruby, SCRIPT, File.join(dir, "missing.json"))
      assert status.success?, "a missing runs file still exits 0"
      assert_match(/\Askip=false\nreason=/, out)
    end
  end
end
