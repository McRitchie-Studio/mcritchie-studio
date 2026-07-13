# frozen_string_literal: true

# Guard test for .github/workflows/ci.yml's PUSH TRIGGERS — the contract that every
# SHIPPABLE TIP earns an independent clean-env CI verdict.
#
# Why this test exists: `pull_request` only certifies a PR's own head. The sweep
# (`bin/release prepare`) merges several approved PRs into `release`, producing a NEW
# merge-commit SHA whose COMBINED behavior no CI run has executed. That merge commit is
# what QA deploys and what `bin/release ship` fast-forwards into `main`. Until
# 2026-07-12 it was the one commit in the pipeline CI never ran — the local G3 gate was
# its only verdict. Dropping `release` from the push trigger silently restores that
# blind spot with no other test failing, so this asserts it directly.
#
# Run directly:
#   ruby -Itest test/lib/ci_workflow_triggers_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        the trigger-extraction logic, over fixture YAML — including the
#                 `on:`-parses-as-`true` trap that would make a naive guard vacuous.
#   [integration] the REAL committed ci.yml satisfies the contract (both tips covered,
#                 no job skipped out of a release push).

require "minitest/autorun"
require "yaml"

class CiWorkflowTriggersTest < Minitest::Test
  CI_YML = File.expand_path("../../.github/workflows/ci.yml", __dir__)

  # THE TRAP this helper exists for: in YAML 1.1 — which Ruby's Psych implements —
  # the bare key `on` is a BOOLEAN, so a workflow's `on:` block parses under the key
  # `true`, NOT `"on"`. A guard written as `yaml["on"]` reads nil, silently asserts
  # nothing, and passes forever even with the trigger deleted. Read both key forms so
  # this test keeps working if Psych ever moves to YAML 1.2 (where `on` stays a string).
  def push_branches(yaml_text)
    doc = YAML.safe_load(yaml_text)
    triggers = doc[true] || doc["on"] || {}
    push = triggers["push"]
    return [] unless push.is_a?(Hash)

    Array(push["branches"])
  end

  # Every job that does NOT skip itself on a release push. A job-level `if:` keyed on
  # `github.ref` is the one way to keep `release` in the trigger while gutting the
  # verdict it is supposed to produce.
  def jobs_skipped_by_ref(yaml_text)
    YAML.safe_load(yaml_text).fetch("jobs", {}).select do |_name, job|
      job.is_a?(Hash) && job["if"].to_s.include?("github.ref")
    end.keys
  end

  # --- [unit] trigger extraction -------------------------------------------------

  def test_unit_on_key_parses_as_boolean_true_not_the_string_on
    # Pin the trap itself. If this ever fails, Psych changed schema and the `doc["on"]`
    # fallback in push_branches is now the live path — the test still holds either way.
    doc = YAML.safe_load("on:\n  push:\n    branches: [ main ]\n")
    assert doc.key?(true), "expected Psych to parse the `on:` key as boolean true (YAML 1.1)"
    refute doc.key?("on"), "Psych now keeps `on` as a string — push_branches handles both"
  end

  def test_unit_reads_branches_from_a_flow_sequence
    assert_equal %w[main release], push_branches("on:\n  push:\n    branches: [ main, release ]\n")
  end

  def test_unit_reads_branches_from_a_block_sequence
    assert_equal %w[main release],
                 push_branches("on:\n  push:\n    branches:\n      - main\n      - release\n")
  end

  def test_unit_a_pull_request_only_workflow_has_no_push_branches
    # The pre-2026-07-12 blind spot, in miniature: PR-only coverage certifies no tip.
    assert_empty push_branches("on:\n  pull_request:\n")
  end

  def test_unit_detects_a_job_that_skips_itself_on_a_ref
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: github.ref != 'refs/heads/release'
          runs-on: ubuntu-latest
        lint:
          runs-on: ubuntu-latest
    YML
    assert_equal ["test"], jobs_skipped_by_ref(yaml)
  end

  # --- [integration] the real committed workflow ----------------------------------

  def test_integration_ci_runs_on_pushes_to_both_shippable_tips
    branches = push_branches(File.read(CI_YML))

    assert_includes branches, "main",
                    "ci.yml must run on pushes to main — the shipped tip"
    assert_includes branches, "release",
                    "ci.yml must run on pushes to release. The sweep's merge commit is the " \
                    "artifact QA deploys and ship fast-forwards; without this trigger it is " \
                    "the one commit CI never runs, leaving the local G3 gate as its only verdict."
  end

  def test_integration_ci_still_runs_on_pull_requests
    triggers = YAML.safe_load(File.read(CI_YML))[true]

    assert triggers.key?("pull_request"),
           "adding the release push trigger must not displace per-PR coverage"
  end

  def test_integration_no_job_opts_out_of_the_release_push_verdict
    skipped = jobs_skipped_by_ref(File.read(CI_YML))

    assert_empty skipped,
                 "job(s) #{skipped.inspect} carry a github.ref condition. The release " \
                 "candidate earns a FULL verdict — no lane may be skipped on a release " \
                 "push for cost. If a ref condition is genuinely needed, prove the job " \
                 "still runs on refs/heads/release and update this test deliberately."
  end
end
