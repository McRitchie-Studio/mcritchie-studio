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
# HOW TO EXTEND THIS FILE — read before adding a vector.
#
# This guard was blocked THREE times in review, and every hole had the same shape: the
# guard enumerated the ways the suite might NOT run, and each reviewer found a spelling
# one level of nesting away from where the last one looked (`github.ref` → missed
# `event_name`; job-level → missed step-level). A blacklist only ever catches the
# vectors its author already imagined. It is a scoreboard, not a guard.
#
# So the PRIMARY guard here is POSITIVE and lives in
# `test_integration_the_suite_runs_UNCONDITIONALLY_on_a_release_push`: some step must
# actually invoke the suite (TEST_COMMAND), and the lane that does must carry NO `if:`
# at all. That closes the whole CLASS — `env.SKIP_TESTS`, `inputs.fast`, a matrix flag,
# and every spelling not yet invented fail it, without anyone having to predict them.
# The enumerated list below is DEFENSE IN DEPTH behind it. When you add a vector, ask
# first whether the positive invariant already covers it; prefer strengthening that.
#
# SEVEN ways the release tip loses its verdict while `branches: [main, release]` still
# reads correct in the file — all seven asserted, because a guard is only worth the
# regressions it actually catches:
#   1. the branch is dropped from the push trigger (the obvious one);
#   2. a job opts out via a job-level `if:` on the github event context — `github.ref`,
#      `github.event_name == 'pull_request'`, or `github.base_ref`. The job reports a
#      GREEN required check having run zero tests on the RC tip;
#   3. the same `if:` moves onto the load-bearing STEP — the worse spelling, because the
#      job's other steps still succeed, so the job (and the required check) stays green
#      over zero tests. Job-level detection alone misses it (hole found in the second
#      review pass of PR #512);
#   4. a `paths`/`paths-ignore` filter on the push trigger suppresses the workflow RUN
#      outright, so a docs-only release merge commit gets no CI at all;
#   5. a `concurrency:` group lets a rapid second release push cancel or supersede the
#      first SHA's run — `cancelled` reads as RED to a SHA-addressed auditor: a false
#      alarm on a healthy candidate. Back-to-back release pushes are normal (sweep
#      merge, then re-pin);
#   6. `continue-on-error: true` on the suite's job or step — the INVERSE trick: the lane
#      RUNS, the tests FAIL, and it reports GREEN anyway. Zero-tests-green and
#      failing-tests-green are the same lie told to the RC tip;
#   7. the suite COMMAND itself is gutted — `run: echo "skipping"`, the `test` job
#      deleted or renamed, the command narrowed to a single file. No `if:`, no filter, no
#      `continue-on-error`: there is NOTHING for a blacklist to match, which is precisely
#      why the positive invariant has to be the primary guard. (6 and 7 were both
#      mutation-confirmed FALSE-GREEN against the blacklist alone.)
#
# CONSIDERED AND DELIBERATELY NOT ASSERTED — do not add these without a reason:
#   · a `matrix:` whose `exclude` empties the job → zero job instances, so the check is
#     MISSING, not green. Missing is a no-verdict, which fails SAFE: required checks
#     block and the auditor sees no data. Only false GREEN is silent.
#   · a `needs:` on a job that never runs → the dependent is skipped transitively, but
#     the ROOT skip is already caught by vectors 2/3. Asserting the transitive case adds
#     nothing the root doesn't.
#   · `if:` on the `on:` block itself → GitHub Actions has no such construct. N/A.
#   · branch-protection / required-check configuration → real, and a genuine way to
#     accept a green-with-no-runs tip, but it lives in GitHub settings, not in this repo.
#     Out of this file's contract; worth its own audit.
#
# NOTE the DOUBLE RUN the trigger creates, so nobody "fixes" it into hole #5: a release
# SHA gets its run from `push: release`, then `bin/release ship` fast-forwards main to
# the byte-identical SHA and fires a SECOND full run (including the ~5min test +
# test:system lane). Benign — the SHA-addressed auditor folds a pending duplicate as
# no-data, never a block — and expected.
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

  # Everywhere a `concurrency:` block could sit: the workflow root and each job. ANY
  # group is a hazard here, not just `cancel-in-progress: true` — a group without it
  # still supersedes the QUEUED run when the next push lands, marking the first SHA
  # `cancelled`, and `cancelled` reads as RED to a SHA-addressed auditor.
  def concurrency_holders(yaml_text)
    doc = YAML.safe_load(yaml_text)
    holders = doc.key?("concurrency") ? ["workflow"] : []
    holders + doc.fetch("jobs", {}).select { |_name, job| job.is_a?(Hash) && job.key?("concurrency") }.keys
  end

  def jobs_skipping_release_push(yaml_text)
    YAML.safe_load(yaml_text).fetch("jobs", {}).select do |_name, job|
      next false unless job.is_a?(Hash)

      # Job-level `if:` AND every step-level `if:`. A skip on the load-bearing step is
      # the WORSE spelling: the other steps succeed, so the job — and the required
      # check — still reports green (hole #4, caught in the second review pass).
      conditions = [job["if"]] + Array(job["steps"]).grep(Hash).map { |step| step["if"] }
      conditions.any? { |condition| condition.to_s.match?(SKIP_CONTEXT_KEYS) }
    end.keys
  end

  # ---- the POSITIVE invariant's machinery --------------------------------------------

  # THE COMMAND THAT CONSTITUTES A VERDICT. If no lane runs this on a release push, the
  # RC tip's green check is backed by zero tests — and #514's SHA-addressed auditor
  # would read that empty-but-green run as a CLEAN verdict and certify it.
  TEST_COMMAND = %r{bin/rails\b[^\n]*\btest\b}

  def jobs_of(yaml_text)
    YAML.safe_load(yaml_text).fetch("jobs", {}).select { |_n, j| j.is_a?(Hash) }
  end

  def lane_label(job_name, step = nil)
    return "job `#{job_name}`" unless step

    "job `#{job_name}` → step `#{step["name"] || step["uses"] || "run"}`"
  end

  # Every [job_name, job, step] whose `run:` actually invokes the suite. Vector 7 (the
  # gutted command) is invisible to every blacklist in this file and lands only here.
  def suite_command_lanes(yaml_text)
    jobs_of(yaml_text).flat_map do |name, job|
      Array(job["steps"]).grep(Hash)
                         .select { |step| step["run"].to_s.match?(TEST_COMMAND) }
                         .map { |step| [name, job, step] }
    end
  end

  # Vector 6. `continue-on-error: true` on a job or step: it RUNS, it FAILS, it reports
  # GREEN. Checked at both levels for the same reason the `if:` walk is.
  def continue_on_error_lanes(yaml_text)
    jobs_of(yaml_text).flat_map do |name, job|
      lanes = []
      lanes << lane_label(name) if job["continue-on-error"] == true
      Array(job["steps"]).grep(Hash).each do |step|
        lanes << lane_label(name, step) if step["continue-on-error"] == true
      end
      lanes
    end
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

  def test_unit_detects_a_step_that_skips_itself_on_the_event_name
    # THE HOLE IN THE SECOND CUT OF THIS GUARD (caught in review of PR #512, second
    # pass). Same skip as the job-level spelling, moved one level down: the job carries
    # no `if:` at all, its load-bearing step does. The step is skipped, every OTHER step
    # (checkout, setup) succeeds, and the job — and with it the required check — reports
    # GREEN having run zero tests on the release tip. A matcher that reads only
    # `job["if"]` waves it straight through.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@v7
            - name: Run tests
              if: github.event_name == 'pull_request'
              run: bin/rails test
    YML
    assert_equal ["test"], jobs_skipping_release_push(yaml)
  end

  def test_unit_a_step_condition_unrelated_to_the_event_context_is_not_a_skip
    # ci.yml itself carries `if: failure()` on the screenshot-upload step — idiomatic,
    # and it cannot exclude a release push. Walking steps must not flag it.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: bin/rails test
            - name: Keep screenshots
              if: failure()
              run: echo saved
    YML
    assert_empty jobs_skipping_release_push(yaml)
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

  def test_unit_detects_a_concurrency_block_at_workflow_and_job_level
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      concurrency:
        group: ci-${{ github.ref }}
        cancel-in-progress: true
      jobs:
        test:
          runs-on: ubuntu-latest
          concurrency: deploy-lock
    YML
    assert_equal %w[workflow test], concurrency_holders(yaml)
  end

  def test_unit_a_workflow_without_concurrency_has_no_holders
    assert_empty concurrency_holders("on:\n  push:\n    branches: [ main ]\njobs:\n  test:\n    runs-on: ubuntu-latest\n")
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

  def test_unit_detects_continue_on_error_on_a_job_or_a_step
    # VECTOR 6, mutation-confirmed false-green against the blacklist alone: the suite
    # runs, the tests fail, the lane reports success. Nothing is skipped, so every `if:`
    # walk in this file sees a clean workflow.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              continue-on-error: true
              run: bin/rails db:test:prepare test test:system
        lint:
          continue-on-error: true
          runs-on: ubuntu-latest
    YML
    assert_equal ["job `test` → step `Run tests`", "job `lint`"], continue_on_error_lanes(yaml)
  end

  def test_unit_a_gutted_suite_command_leaves_no_test_lane
    # VECTOR 7, and the reason the positive invariant exists. No `if:`, no path filter, no
    # `continue-on-error`, no concurrency group — every blacklist in this file passes this
    # workflow clean, and it runs ZERO tests on the release tip. Deleting the `test` job,
    # renaming it, or narrowing the command to one file all land in exactly this hole.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: echo "suite skipped to save minutes"
    YML
    assert_empty jobs_skipping_release_push(yaml), "the blacklist sees nothing wrong here"
    assert_empty continue_on_error_lanes(yaml), "and neither does the continue-on-error walk"
    assert_empty suite_command_lanes(yaml), "but NO lane runs the suite — only this catches it"
  end

  def test_unit_recognizes_the_real_suite_command_as_a_test_lane
    # The other half of vector 7: TEST_COMMAND must actually MATCH the live command, or
    # the positive guard asserts a lane that never existed and passes vacuously — the
    # same failure mode as the `on:`-boolean trap at the top of this file.
    yaml = <<~YML
      on:
        push:
          branches: [ main, release ]
      jobs:
        test:
          runs-on: ubuntu-latest
          steps:
            - name: Run tests
              run: bin/rails db:test:prepare test test:system
    YML
    lanes = suite_command_lanes(yaml)

    assert_equal 1, lanes.size
    assert_equal "test", lanes.first[0]
  end

  # --- [integration] the real committed workflow ----------------------------------

  # ==== THE PRIMARY GUARD =============================================================
  # Positive, not a blacklist. Every other integration assertion in this file enumerates
  # a way the suite might NOT run; this one asserts that it DOES. On the lane that IS the
  # verdict, ANY condition fails — not merely the three `github.*` spellings a reviewer
  # happened to show me. That is the difference between a guard and a scoreboard.
  def test_integration_the_suite_runs_UNCONDITIONALLY_on_a_release_push
    lanes = suite_command_lanes(File.read(CI_YML))

    refute_empty lanes,
                 "NO step in ci.yml runs a command matching #{TEST_COMMAND.source}. A " \
                 "release push would produce GREEN checks having executed zero tests — " \
                 "and #514's SHA-addressed auditor would read that empty-but-green run " \
                 "as a clean verdict and certify an RC that CI never tested. A false RED " \
                 "wastes a day; a false GREEN ships. If the suite legitimately moved or " \
                 "the command changed, re-point TEST_COMMAND at it — do not delete this."

    lanes.each do |job_name, job, step|
      assert_nil job["if"],
                 "#{lane_label(job_name)} runs the suite but carries `if: #{job["if"]}`. " \
                 "The lane that IS the verdict must be UNCONDITIONAL on a release push. " \
                 "Any condition — event context, env var, workflow input, matrix flag — " \
                 "can silently exclude the RC tip. Prove it still runs on a push to " \
                 "refs/heads/release, then update this test deliberately."
      assert_nil step["if"],
                 "#{lane_label(job_name, step)} runs the suite but carries " \
                 "`if: #{step["if"]}`. A skipped STEP leaves the JOB REPORTING SUCCESS — " \
                 "a green required check over zero tests, invisible in the check " \
                 "conclusion and indistinguishable from a real pass to any auditor " \
                 "reading it by SHA. This is the worst failure mode in the file."
    end
  end

  def test_integration_no_lane_reports_green_over_failing_tests
    lanes = continue_on_error_lanes(File.read(CI_YML))

    assert_empty lanes,
                 "#{lanes.inspect} set `continue-on-error: true` — the lane RUNS, the " \
                 "tests FAIL, and it reports GREEN anyway. Zero-tests-green and " \
                 "failing-tests-green are the same lie told to the release candidate."
  end
  # ====================================================================================

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
                 "(#{SKIP_CONTEXT_KEYS.source}) on the job or on one of its steps. The " \
                 "release candidate earns a FULL verdict — no lane may be skipped on a " \
                 "release push for cost, whether spelled as a ref comparison, an " \
                 "event_name check, or a base_ref check, at the JOB or at the STEP " \
                 "level (a skipped step is the worse spelling: the job still reports " \
                 "green). If such a condition is genuinely needed, prove the tests " \
                 "still RUN on a push to refs/heads/release and update this test " \
                 "deliberately."
  end

  def test_integration_no_concurrency_block_can_cancel_a_release_run
    holders = concurrency_holders(File.read(CI_YML))

    assert_empty holders,
                 "#{holders.inspect} carry a `concurrency:` block. Back-to-back release " \
                 "pushes are NORMAL (sweep merge, then re-pin): a concurrency group lets " \
                 "the second push cancel or supersede the first SHA's run, and a " \
                 "`cancelled` conclusion reads as RED to a SHA-addressed CI auditor — a " \
                 "false alarm on a healthy release candidate. Every release SHA keeps " \
                 "its own run to completion."
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
