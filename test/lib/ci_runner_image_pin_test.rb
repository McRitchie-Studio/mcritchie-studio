# frozen_string_literal: true

# Guard: every CI job runs on a PINNED runner image, never the floating label. `ubuntu-latest`
# is a moving alias; a pinned image moves only by a reviewed PR. The rule: every job that names
# a runner names PIN, and no file under .github mentions `ubuntu-latest` at all (matrix entries,
# reusable workflows, composite actions). A job calling a reusable workflow (`uses:`) has no
# runner and is skipped; the workflow is checked in its own right. To move the pin, change PIN
# here and every runs-on in the same PR.
# History: task pin-ci-runner-image.
require "minitest/autorun"
require "yaml"

class CiRunnerImagePinTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PIN = "ubuntu-24.04"
  WORKFLOW_GLOB = File.join(ROOT, ".github/workflows/*.{yml,yaml}")

  def workflows
    paths = Dir[WORKFLOW_GLOB].sort
    refute_empty paths, "no workflows at #{WORKFLOW_GLOB}: this guard is looking in the wrong place"
    paths
  end

  def test_every_job_runs_on_the_pinned_image
    offenders = []
    checked = 0
    workflows.each do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.each do |name, job|
        next if job.key?("uses") && !job.key?("runs-on")
        checked += 1
        runner = job["runs-on"]
        offenders << "#{File.basename(path)}:#{name} runs-on #{runner.inspect}" unless runner == PIN
      end
    end
    assert_operator checked, :>, 0, "found no jobs with a runner: the YAML walk is broken"
    assert_empty offenders, "every CI job must run on #{PIN}:\n  #{offenders.join("\n  ")}"
  end

  def test_no_file_under_github_names_the_floating_label
    hits = Dir[File.join(ROOT, ".github/**/*")].select { |p| File.file?(p) }.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{path.delete_prefix("#{ROOT}/")}:#{i + 1}" if line.include?("ubuntu-latest")
      end
    end
    assert_empty hits, "ubuntu-latest floats to new images unannounced; pin #{PIN}:\n  #{hits.join("\n  ")}"
  end
end
