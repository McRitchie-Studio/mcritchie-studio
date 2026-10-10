# frozen_string_literal: true

# [unit] CiSuiteWorkflow — the reader of the two shapes a repo's `CI` workflow takes
# (inline jobs, or a call to the hub's reusable-ci.yml), and of the suite as a call
# with given inputs runs it.
#
# Run directly:
#   ruby -Itest test/lib/ci_suite_workflow_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/ci_suite_workflow"

class CiSuiteWorkflowTest < Minitest::Test
  HUB = "McRitchie-Studio/mcritchie-studio/.github/workflows/reusable-ci.yml"

  SUITE = <<~YAML
    on:
      workflow_call:
        inputs:
          playwright: { type: boolean, default: true }
          system: { type: boolean, default: true }
          gem-audit-command: { type: string, default: "" }
          system-command: { type: string, default: "bin/rails db:test:prepare test:system" }
    jobs:
      static:
        runs-on: ubuntu-latest
        steps:
          - run: bin/brakeman --no-pager
          - if: ${{ always() && inputs.gem-audit-command != '' }}
            run: ${{ inputs.gem-audit-command }}
      playwright:
        if: ${{ inputs.playwright }}
        runs-on: ubuntu-latest
        steps:
          - run: npx playwright test --shard=${{ matrix.shard }}/${{ strategy.job-total }}
      gate:
        if: ${{ always() && inputs.playwright }}
        runs-on: ubuntu-latest
        steps: [{ run: bin/e2e-executed-set-check }]
      system:
        if: ${{ inputs.system }}
        runs-on: ubuntu-latest
        steps:
          - run: ${{ inputs.system-command }}
  YAML

  def caller(uses, with = nil)
    job = { "uses" => uses }
    job["with"] = with if with
    { "name" => "CI", "jobs" => { "ci" => job } }.to_yaml
  end

  def jobs(text) = YAML.safe_load(text).fetch("jobs")

  # ---- call / suite_call? ----

  def test_a_local_call_and_a_remote_call_parse
    assert_equal({ nwo: nil, path: ".github/workflows/reusable-ci.yml", ref: nil },
                 CiSuiteWorkflow.call("./.github/workflows/reusable-ci.yml"))
    assert_equal({ nwo: "McRitchie-Studio/mcritchie-studio", path: ".github/workflows/reusable-ci.yml", ref: "main" },
                 CiSuiteWorkflow.call("#{HUB}@main"))
  end

  def test_an_action_a_refless_remote_and_a_blank_are_not_calls
    assert_nil CiSuiteWorkflow.call("actions/checkout@v7")
    assert_nil CiSuiteWorkflow.call(HUB), "a remote call names a ref"
    assert_nil CiSuiteWorkflow.call("./.github/workflows/reusable-ci.yml@main"), "a local call names none"
    assert_nil CiSuiteWorkflow.call(nil)
  end

  def test_only_the_hubs_suite_file_is_a_suite_call
    assert CiSuiteWorkflow.suite_call?("./.github/workflows/reusable-ci.yml")
    assert CiSuiteWorkflow.suite_call?("#{HUB}@main")
    assert CiSuiteWorkflow.suite_call?("#{HUB}@0123abc")
    refute CiSuiteWorkflow.suite_call?("./.github/workflows/reusable-prod-deploy.yml")
    refute CiSuiteWorkflow.suite_call?("Someone-Else/mcritchie-studio/.github/workflows/reusable-ci.yml@main")
  end

  def test_caller_job_finds_the_calling_job_beside_inline_ones
    both = { "jobs" => { "test" => { "steps" => [{ "run" => "bin/rails test" }] }, "ci" => { "uses" => "#{HUB}@main" } } }.to_yaml

    assert_equal "ci", CiSuiteWorkflow.caller_job(both).first
    assert_nil CiSuiteWorkflow.caller_job({ "jobs" => { "test" => { "steps" => [] } } }.to_yaml)
    assert_nil CiSuiteWorkflow.caller_job(nil)
  end

  # ---- inputs / as_called ----

  def test_inputs_reads_type_and_default_and_a_bare_call_declares_none
    assert_equal({ "type" => "boolean", "default" => true }, CiSuiteWorkflow.inputs(SUITE).fetch("playwright"))
    assert_equal "", CiSuiteWorkflow.inputs(SUITE).dig("gem-audit-command", "default")
    assert_empty CiSuiteWorkflow.inputs("on:\n  workflow_call:\njobs: {}\n")
  end

  def test_a_bare_call_runs_every_default
    run = jobs(CiSuiteWorkflow.as_called(SUITE))

    assert_equal true, run.dig("playwright", "if")
    assert_equal "${{ always() && true }}", run.dig("gate", "if")
    assert_equal "bin/rails db:test:prepare test:system", run.dig("system", "steps", 0, "run")
    assert_equal "${{ always() && '' != '' }}", run.dig("static", "steps", 1, "if")
    assert_nil run.dig("static", "steps", 1, "run"), "an empty default leaves an empty run"
  end

  def test_an_expression_with_no_input_is_left_byte_for_byte
    assert_includes CiSuiteWorkflow.as_called(SUITE), "--shard=${{ matrix.shard }}/${{ strategy.job-total }}"
  end

  def test_a_callers_with_overrides_the_defaults
    run = jobs(CiSuiteWorkflow.as_called(SUITE, with: { "playwright" => false, "system-command" => "bin/rails test",
                                                         "gem-audit-command" => "bin/bundler-audit" }))

    assert_equal false, run.dig("playwright", "if")
    assert_equal "${{ always() && false }}", run.dig("gate", "if")
    assert_equal "bin/rails test", run.dig("system", "steps", 0, "run")
    assert_equal "${{ always() && 'bin/bundler-audit' != '' }}", run.dig("static", "steps", 1, "if")
    assert_equal true, run.dig("system", "if"), "an input the caller did not pass keeps its default"
  end

  def test_a_reference_to_an_undeclared_input_raises
    assert_raises(CiSuiteWorkflow::UndeclaredInput) do
      CiSuiteWorkflow.as_called(SUITE.sub("${{ inputs.system }}", "${{ inputs.fast }}"))
    end
  end

  # ---- caller_suite_command ----

  def test_the_callers_command_wins_and_the_default_fills_in
    assert_equal "bin/rails db:test:prepare test test:system",
                 CiSuiteWorkflow.caller_suite_command(caller("#{HUB}@main", "system-command" => "bin/rails db:test:prepare test test:system"))
    assert_equal "bin/rails db:test:prepare test:system",
                 CiSuiteWorkflow.caller_suite_command(caller("./.github/workflows/reusable-ci.yml"), suite_yaml: SUITE)
  end

  def test_no_command_for_a_non_caller_a_switched_off_lane_or_an_unknown_default
    assert_nil CiSuiteWorkflow.caller_suite_command({ "jobs" => { "test" => { "steps" => [{ "run" => "bin/rails test" }] } } }.to_yaml)
    assert_nil CiSuiteWorkflow.caller_suite_command(caller("#{HUB}@main", "system" => false, "system-command" => "bin/rails test"))
    assert_nil CiSuiteWorkflow.caller_suite_command(caller("#{HUB}@main")), "the default needs the suite text"
    assert_nil CiSuiteWorkflow.caller_suite_command(": : not yaml [")
  end

  # ---- the live files ----

  def test_the_hubs_own_ci_yml_is_a_caller_of_the_live_suite
    root = File.expand_path("../..", __dir__)
    ci = File.read(File.join(root, ".github/workflows/ci.yml"))
    suite = File.read(File.join(root, CiSuiteWorkflow::SUITE_PATH))

    assert_equal "ci", CiSuiteWorkflow.caller_job(ci).first
    assert_equal "bin/rails db:test:prepare test:system", CiSuiteWorkflow.caller_suite_command(ci, suite_yaml: suite)
    assert_equal ["bin/test-js"], CiSuiteWorkflow.runs(CiSuiteWorkflow.as_called(suite), "javascript")
  end
end
