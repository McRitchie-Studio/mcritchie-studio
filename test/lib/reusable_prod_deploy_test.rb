# frozen_string_literal: true

# Guard test for .github/workflows/reusable-prod-deploy.yml: the hub-hosted production
# deploy an app can call, and the fact that nothing calls it.
#
# The file ships ahead of its first caller. Its interface is pinned here (an app's
# dispatching workflow is written against it), and so is the absence of a caller. The
# registry half lives in test/models/release/repos_test.rb: no row names this file,
# and every app's deploy strategy is pinned repo by repo.
#
# Run directly:
#   ruby -Itest test/lib/reusable_prod_deploy_test.rb

require "minitest/autorun"
require "yaml"

class ReusableProdDeployTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOWS = File.join(ROOT, ".github/workflows")
  DEPLOY = File.join(WORKFLOWS, "reusable-prod-deploy.yml")
  FILE_NAME = "reusable-prod-deploy.yml"

  def doc = YAML.safe_load_file(DEPLOY)
  def on = doc[true] || doc["on"]

  # Every `uses:` value in a workflow text, jobs and steps alike.
  def uses_in(text)
    jobs = (YAML.safe_load(text) || {}).fetch("jobs", {}).values.grep(Hash)
    jobs.flat_map { |job| [job["uses"]] + Array(job["steps"]).grep(Hash).map { |step| step["uses"] } }.compact
  end

  def callers_of(texts) = texts.select { |_path, text| uses_in(text).any? { |uses| uses.include?(FILE_NAME) } }.keys

  def test_it_is_a_called_workflow_and_nothing_else
    assert_equal ["workflow_call"], on.keys, "a second trigger would let it deploy with no caller"
  end

  def test_its_interface_is_three_required_inputs_and_the_heroku_key
    call = on.fetch("workflow_call")

    assert_equal %w[inputs secrets], call.keys.sort
    assert_equal %w[heroku-app sha smoke-url], call["inputs"].keys.sort
    call["inputs"].each do |name, spec|
      assert_equal [true, "string"], spec.values_at("required", "type"), "input `#{name}`"
      refute spec.key?("default"), "input `#{name}` carries a default: a deploy names its target"
    end
    assert_equal({ "HEROKU_API_KEY" => true }, call["secrets"].transform_values { |spec| spec["required"] })
  end

  def test_the_one_job_is_bounded_and_runs_under_the_production_environment
    jobs = doc.fetch("jobs")

    assert_equal ["deploy"], jobs.keys
    assert_equal "production", jobs.dig("deploy", "environment")
    assert_kind_of Integer, jobs.dig("deploy", "timeout-minutes")
    refute jobs["deploy"].key?("if"), "a conditional deploy reports success having deployed nothing"
  end

  def test_no_input_or_secret_is_interpolated_into_a_script
    scripts = doc.dig("jobs", "deploy", "steps").filter_map { |step| step["run"] }

    refute_empty scripts
    scripts.each { |script| refute_match(/\$\{\{/, script, "pass values through `env:`") }
  end

  def test_the_smoke_is_a_hard_gate
    smoke = doc.dig("jobs", "deploy", "steps").find { |step| step["run"].to_s.include?("/up") }

    refute_nil smoke
    refute smoke.key?("continue-on-error")
    assert_match(/exit 1\s*\z/, smoke["run"])
  end

  # ---- unused ----

  def test_no_workflow_in_this_repo_calls_it
    texts = Dir[File.join(WORKFLOWS, "*.{yml,yaml}")].to_h { |path| [File.basename(path), File.read(path)] }

    assert_operator texts.size, :>=, 5, "the workflow directory was not read"
    assert_empty callers_of(texts)
  end

  def test_unit_a_calling_job_is_seen
    calling = "jobs:\n  deploy:\n    uses: McRitchie-Studio/mcritchie-studio/.github/workflows/#{FILE_NAME}@main\n"

    assert_equal ["prod-deploy.yml"], callers_of("prod-deploy.yml" => calling)
    assert_empty callers_of("ci.yml" => "jobs:\n  ci:\n    uses: ./.github/workflows/reusable-ci.yml\n")
  end
end
