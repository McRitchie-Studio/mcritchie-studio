# frozen_string_literal: true

# [integration] test for the test-only SHAPE NOTE that bin/session-preflight
# PRINTS — the sentence a builder reads at the moment they decide what to run.
#
# WHY THIS EXISTS AS A RUN, not another source grep. Its sibling assertion in
# test/docs/zap_control_lane_docs_test.rb reads this script's SOURCE and refuses
# the falsified wording there. That pins the string but not the path: the note is
# printed from inside a `claimable_when == "test_only_diff"` branch, so a source
# that says the right thing still proves nothing about whether this shape reaches
# it. This drives the real script with a real task record and reads what came out
# of the branch.
#
# WHAT IT IS GUARDING AGAINST, measured 2026-09-22. Until this file existed
# bin/session-preflight was read by NO test at all, and it carried the falsified
# claim that `test-only` owes the full suite outright long after the four agent
# docs had been corrected — the one surface a docs-shaped correction could not
# reach, and the costliest one to be wrong on. A file with no test is how prose
# outlives the thing it describes.
#
# Run directly:
#   ruby -Itest test/lib/session_preflight_shape_note_test.rb

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"

class SessionPreflightShapeNoteTest < Minitest::Test
  REPO_ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(REPO_ROOT, "bin", "session-preflight")

  # The falsified claim, assembled whitespace-tolerantly. Every surface that
  # states this rule wraps its prose, so a literal-space pattern reads clean over
  # text that is plainly there — that wrap is what hid two sites from an earlier
  # sweep of the same phrase.
  OWES_THE_FULL_SUITE = /owes\s+the\s+full[-\s]*suite\s+cert/i

  def run_preflight(devops)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "data" => {
          "slug" => "probe-task", "title" => "Probe Task", "stage" => "building",
          "metadata" => { "devops" => devops }
        }
      ))
      out, err, _status = Open3.capture3(
        SCRIPT, "--file", path, "--no-gh", "--no-install-docs", "--no-fetch", chdir: REPO_ROOT
      )
      "#{out}\n#{err}"
    end
  end

  def test_only_devops
    {
      "shape" => "test-only", "repositories" => ["mcritchie-studio"], "risk_tags" => ["tests"],
      "acceptance" => ["the note matches the gate"], "test_plan" => ["[control] restore the wording, assert red"],
      "branch" => "feat/probe-task"
    }
  end

  def test_the_test_only_note_does_not_claim_the_full_suite_is_owed
    output = run_preflight(test_only_devops)

    assert_match(/claimable ONLY on a diff/, output,
                 "the test-only shape note did not print at all — this test is asserting about a branch " \
                 "it never reached, so every other assertion here would be vacuous.\n#{output}")

    refute_match(OWES_THE_FULL_SUITE, output,
                 "bin/session-preflight tells a builder test-only owes the full-suite cert. bin/dor-check's " \
                 "route ladder has no test-only branch and its fast route carries no review_role condition, " \
                 "so a fast cert plus a settled green CI satisfies the gate here exactly as for a feature. " \
                 "A builder briefed off this sentence on 2026-09-21 ran 11,004 tests the gate never asked " \
                 "for.\n#{output}")
  end

  def test_the_test_only_note_states_not_exempt_and_the_green_ci_condition
    output = run_preflight(test_only_devops)

    assert_match(/not exempt/i, output,
                 "the note no longer says test-only is NOT EXEMPT from the cert gate. That half is TRUE and " \
                 "load-bearing — `full_suite_gate: true` really does mean the gate applies, unlike `docs`, " \
                 "which waives it. Dropping it trades one wrong briefing for the opposite one.\n#{output}")

    assert_match(/green[^.]{0,30}\bCI\b/i, output,
                 "the note grants the fast route without its CONDITION. A fast cert satisfies this gate " \
                 "ALONGSIDE A SETTLED GREEN CI, which is what the REVIEW gate-zero requires — it is an " \
                 "allow-list, so red, pending and unreadable all refuse there.\n#{output}")

    # The other half of the same rule, and the half this note is read at. The
    # builder's own run credits that fast cert PROVISIONALLY on a pending CI
    # (bin/dor-check:2052, route `fast-provisional` at :3636 — the one branch
    # testing !review_role), so a note that stops at the green sends a builder to
    # a suite the gate has already waved through. Measured at 91e634d3: fast cert
    # only + pending CI = DoR MET, exit 0, for the builder.
    assert_match(/provisional/i, output,
                 "the note states the green condition but not the ROLE split, which is the half a BUILDER " \
                 "needs: at submit a fresh fast cert is credited PROVISIONALLY while CI is still pending, " \
                 "so a pending CI owes no local run. Stopping at the green is how the correction to the " \
                 "over-strict wording reproduced its cost one cell over.\n#{output}")
  end

  # RESTRAINT: the note is scoped to the shape that earns it. A shape whose
  # `claimable_when` is not `test_only_diff` must not start printing a cert rule
  # that does not apply to it.
  def test_the_note_is_scoped_to_the_test_only_shape
    output = run_preflight(test_only_devops.merge("shape" => "backend"))

    refute_match(/claimable ONLY on a diff/, output,
                 "the test-only claimability note printed for a `backend` task. It is gated on " \
                 "`claimable_when == \"test_only_diff\"` and describes a contract that shape does not " \
                 "carry.\n#{output}")
  end
end
