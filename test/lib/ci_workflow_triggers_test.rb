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
# THREE ways the release tip loses its verdict while `branches: [main, release]` still
# reads correct in the file — all three are asserted, because a guard is only worth the
# regressions it actually catches:
#   1. the branch is dropped from the push trigger (the obvious one);
#   2. a job opts out via a job-level `if:` on the github event context — `github.ref`,
#      `github.event_name == 'pull_request'`, or `github.base_ref`. The job reports a
#      GREEN required check having run zero tests on the RC tip;
#   3. a `paths`/`paths-ignore` filter on the push trigger suppresses the workflow RUN
#      outright, so a docs-only release merge commit gets no CI at all.
#
# Two tiers (backend shape):
#   [unit]        the trigger-extraction and skip-detection logic, over fixture YAML —
#                 including the `on:`-parses-as-`true` trap that makes a naive guard
#                 vacuous, and each opt-out spelling above.
#   [integration] the REAL committed ci.yml satisfies the contract (both tips covered,
#                 pull_request intact, no job skipped, no path filter).

require "minitest/autorun"
require "yaml"

class CiWorkflowTriggersTest < Minitest::Test
  CI_YML = File.expand_path("../../.github/workflows/ci.yml", __dir__)

  # THE TRAP this helper exists for: in YAML 1.1 — which Ruby's Psych implements —
  # the bare key `on` is a BOOLEAN, so a workflow's `on:` block parses under the key
  # `true`, NOT `"on"`. A guard written as `yaml["on"]` reads nil, silently asserts
  # nothing, and passes forever even with the trigger deleted. Read both key forms so
  # this test keeps working if Psych ever moves to YAML 1.2 (where `on` stays a string).
  # The `on:` block. EVERY reader goes through here — reaching for `doc[true]` directly
  # anywhere else re-opens the trap for whichever accessor forgot.
  def triggers(yaml_text)
    doc = YAML.safe_load(yaml_text)
    doc[true] || doc["on"] || {}
  end

  def push_trigger(yaml_text)
    push = triggers(yaml_text)["push"]
    push.is_a?(Hash) ? push : {}
  end

  def push_branches(yaml_text)
    Array(push_trigger(yaml_text)["branches"])
  end

  # Every job that opts OUT of the release-push verdict via a job-level `if:`.
  #
  # There is no single spelling of this skip, and assuming there was is how the first
  # cut of this guard shipped with a hole. A cost-conscious engineer reaches for
  # `github.event_name == 'pull_request'` at least as readily as a `github.ref`
  # comparison — and either one keeps `release` in the trigger while producing a job
  # that runs NOTHING on the release tip: a green required check over zero tests, which
  # is the exact failure this workflow change exists to eliminate, one level up.
  # `github.base_ref` (set only on pull_request events) is a third spelling of the same
  # opt-out. Match the whole family; a new context key is the way this regresses next.
  SKIP_CONTEXT_KEYS = /github\.(ref|event_name|base_ref)/

  # A path filter on the PUSH trigger is a second, quieter way to strand the RC tip: it
  # suppresses the workflow RUN, so there are no jobs to skip and no checks to go green
  # — the release merge commit simply gets no CI at all.
  PATH_FILTER_KEYS = %w[paths paths-ignore].freeze

  def jobs_skipping_release_push(yaml_text)
    YAML.safe_load(yaml_text).fetch("jobs", {}).select do |_name, job|
      job.is_a?(Hash) && job["if"].to_s.match?(SKIP_CONTEXT_KEYS)
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
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_detects_a_job_that_skips_itself_on_the_event_name
    # THE HOLE IN THE FIRST CUT OF THIS GUARD (caught in review of PR #512). This skip
    # is the MORE natural way to write a cost saving than a `github.ref` comparison, and
    # a matcher keyed only on `github.ref` waved it straight through: `release` stays in
    # the trigger, every other assertion passes, and the job runs on PRs only — so the
    # release tip gets a green check backed by zero tests.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: github.event_name == 'pull_request'
          runs-on: ubuntu-latest
    YML
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_detects_a_job_that_skips_itself_on_base_ref
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: github.base_ref == 'release'
          runs-on: ubuntu-latest
    YML
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_a_job_condition_unrelated_to_the_event_context_is_not_a_skip
    # The matcher must not flag every `if:`. A condition that does not consult the event
    # context (e.g. gating on a previous job's output) cannot exclude a release push.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          if: needs.build.outputs.changed == 'true'
          runs-on: ubuntu-latest
    YML
    assert_empty jobs_skipping_release_push(yaml)
  end

  def test_unit_a_paths_filter_on_the_push_trigger_is_visible
    # A docs-only release merge commit under `paths-ignore` triggers NO workflow run at
    # all — no jobs, no checks, nothing to skip. `branches: [main, release]` is still
    # right there in the file, so every branch assertion passes while the RC tip ships
    # unverified. The filter must be absent, not merely benign-looking.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
          paths-ignore: [ 'docs/**' ]
    YML
    assert_equal ["paths-ignore"], push_trigger(yaml).keys & PATH_FILTER_KEYS
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
    assert triggers(File.read(CI_YML)).key?("pull_request"),
           "adding the release push trigger must not displace per-PR coverage"
  end

  def test_integration_no_job_opts_out_of_the_release_push_verdict
    skipped = jobs_skipping_release_push(File.read(CI_YML))

    assert_empty skipped,
                 "job(s) #{skipped.inspect} carry a github event-context condition " \
                 "(#{SKIP_CONTEXT_KEYS.source}). The release candidate earns a FULL " \
                 "verdict — no lane may be skipped on a release push for cost, whether " \
                 "spelled as a ref comparison or an event_name check. If such a " \
                 "condition is genuinely needed, prove the job still RUNS on a push to " \
                 "refs/heads/release and update this test deliberately."
  end

  def test_integration_no_path_filter_strands_the_release_tip
    filters = push_trigger(File.read(CI_YML)).keys & PATH_FILTER_KEYS

    assert_empty filters,
                 "the push trigger carries #{filters.inspect}. A path filter suppresses " \
                 "the workflow RUN, not just a job — a docs-only merge commit on release " \
                 "would get NO CI verdict at all while `branches: [main, release]` still " \
                 "reads correct. Every release tip is shipped; every release tip is run."
  end
end
