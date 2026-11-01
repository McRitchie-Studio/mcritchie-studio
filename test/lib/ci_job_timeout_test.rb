# frozen_string_literal: true

# Guard: EVERY workflow job declares a wall-clock bound. No `timeout-minutes` inherits GitHub's
# SIX-HOUR default, and GitHub refuses `gh run rerun` on an incomplete run, so a hang blocks the
# single retry too.
# WHY 45 MINUTES, AND WHY UNIFORM: ~4.5x the slowest routine lane, ~2.6x the worst observed
# SUCCESS. Tightness is NOT the goal: a bound that bites a slow run manufactures a false red.
# ASSERTED POSITIVELY over every workflow file, not today's jobs: a lane added tomorrow fails
# here without enrolling.
# History: task bound-hung-ci-steps.
require "minitest/autorun"
require "yaml"

class CiJobTimeoutTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW_GLOB = File.join(ROOT, ".github/workflows/*.yml")
  CEILING = 120 # a "bound" of six hours is the absence this guard exists to remove

  def workflows
    paths = Dir[WORKFLOW_GLOB].sort
    refute_empty paths, "no workflows at #{WORKFLOW_GLOB} — this guard is looking in the wrong place"
    paths
  end

  # A job that calls a local workflow takes its bounds from the called file's jobs:
  # GitHub refuses `timeout-minutes` beside `uses:`. The called file must be one this
  # guard reads, so its jobs are bounded here too. A call into another repo is not
  # exempt: nothing here can read its bounds.
  def bounded_by_a_local_call?(job, paths)
    called = job["uses"].to_s[%r{\A\./\.github/workflows/([^/@]+\.yml)\z}, 1]
    !called.nil? && paths.map { |path| File.basename(path) }.include?(called)
  end

  def test_a_call_into_a_local_workflow_is_bounded_by_the_called_jobs
    paths = ["/repo/.github/workflows/reusable-ci.yml"]

    assert bounded_by_a_local_call?({ "uses" => "./.github/workflows/reusable-ci.yml" }, paths)
    refute bounded_by_a_local_call?({ "uses" => "./.github/workflows/missing.yml" }, paths),
           "a call to a file this guard cannot read is unbounded"
    refute bounded_by_a_local_call?({ "uses" => "McRitchie-Studio/mcritchie-studio/.github/workflows/reusable-ci.yml@main" }, paths),
           "a call into another repo is unbounded here"
    refute bounded_by_a_local_call?({ "runs-on" => "ubuntu-latest" }, paths), "a job with steps declares its own bound"
  end

  def test_every_job_declares_a_wall_clock_bound
    unbounded = []
    checked = 0

    workflows.each do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.each do |name, job|
        next unless job.is_a?(Hash)
        next if bounded_by_a_local_call?(job, workflows)

        checked += 1
        bound = job["timeout-minutes"]
        unbounded << "#{File.basename(path)} :: #{name}" if bound.nil?
      end
    end

    assert_empty unbounded,
                 "these jobs declare no `timeout-minutes`, so they inherit GitHub's SIX HOUR default — " \
                 "a hang there never fails, and an incomplete run cannot be re-run:\n  " +
                 unbounded.join("\n  ")

    # Vacuity guard: green must mean "every job checked", never "no jobs found".
    assert_operator checked, :>=, 1,
                    "found no jobs in #{WORKFLOW_GLOB} — the workflows moved and this guard now asserts nothing"
  end

  def test_no_bound_is_so_large_it_is_not_a_bound
    too_large = []

    workflows.each do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.each do |name, job|
        next unless job.is_a?(Hash)

        bound = job["timeout-minutes"]
        too_large << "#{File.basename(path)} :: #{name} (#{bound}m)" if bound.is_a?(Numeric) && bound > CEILING
      end
    end

    assert_empty too_large,
                 "a bound above #{CEILING} minutes is not a bound — the hangs this guards against ran " \
                 "99 and 234 minutes, so a ceiling that generous would have caught neither:\n  " +
                 too_large.join("\n  ")
  end
end
