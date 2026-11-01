# frozen_string_literal: true

# [integration] test for the test-only SHAPE NOTE that bin/session-preflight PRINTS. A RUN,
# not a source grep: the note prints inside a `claimable_when == "test_only_diff"` branch,
# so a source that says the right thing proves nothing about whether this shape reaches it.
# Coverage of a script is not coverage of every sentence it prints. Add a case HERE when the
# note changes; add one in test/commands/session_preflight_test.rb for the script's
# behaviour.
# History: task feature-shapes-overstates-test-only.

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

  # NAMED AWAY FROM `test_`, DELIBERATELY: do not rename this back. Minitest collects /^test_/
  # methods, so this fixture would run asserting nothing against
  # test/lib/test_health_ratchet_test.rb's zero `assertion_free`, passing only because the
  # detector finds /assert\w*/ in the fixture STRING below, "... assert red". THAT RATCHET'S
  # CONFIG IS NAMED IN WORDS, NOT SPELLED AS A PATH, deliberately: a literal mention adds this
  # file to its fast-cert mapped set and trips the exact-count clause in
  # test/lib/fast_cert_subject_test.rb, reddening CI while the local fast cert stays green.
  # History: task feature-shapes-overstates-test-only.
  def devops_for_test_only
    {
      "shape" => "test-only", "repositories" => ["mcritchie-studio"], "risk_tags" => ["tests"],
      "acceptance" => ["the note matches the gate"], "test_plan" => ["[control] restore the wording, assert red"],
      "branch" => "feat/probe-task"
    }
  end

  def test_the_test_only_note_does_not_claim_the_full_suite_is_owed
    output = run_preflight(devops_for_test_only)

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
    output = run_preflight(devops_for_test_only)

    assert_match(/not exempt/i, output,
                 "the note no longer says test-only is NOT EXEMPT from the cert gate. That half is TRUE and " \
                 "load-bearing — test-only really is NOT exempt from the CI gate, unlike `docs`, " \
                 "which waives it. Dropping it trades one wrong briefing for the opposite one.\n#{output}")

    assert_match(/green[^.]{0,30}\bCI\b/i, output,
                 "the note grants the fast route without its CONDITION. A fast cert satisfies this gate " \
                 "ALONGSIDE A SETTLED GREEN CI, which is what the REVIEW gate-zero requires — it is an " \
                 "allow-list, so red, pending and unreadable all refuse there.\n#{output}")

    # The other half of the same rule, and the half this note is read at: a CI
    # still running is a WAIT for the builder (bin/submit holds for it), never a
    # reason to run a local suite. Until /tasks/dor-reads-settled-ci-verdict this
    # asserted the PROVISIONAL fast-cert credit; that route is gone, and a note that
    # still promised it would send a builder to a hatch the gate no longer reads.
    assert_match(/WAITING/, output,
                 "the note states the green condition but not what a builder sees on a PENDING CI: " \
                 "a WAIT, held by bin/submit, owing no local run. Stopping at the green is how the " \
                 "correction to the over-strict wording reproduced its cost one cell over.\n#{output}")
    refute_match(/provisional/i, output,
                 "the note still promises the PROVISIONAL fast-cert credit, a route bin/dor-check no " \
                 "longer has.\n#{output}")
  end

  # RESTRAINT: the note is scoped to the shape that earns it. A shape whose
  # `claimable_when` is not `test_only_diff` must not start printing a cert rule
  # that does not apply to it.
  def test_the_note_is_scoped_to_the_test_only_shape
    output = run_preflight(devops_for_test_only.merge("shape" => "backend"))

    refute_match(/claimable ONLY on a diff/, output,
                 "the test-only claimability note printed for a `backend` task. It is gated on " \
                 "`claimable_when == \"test_only_diff\"` and describes a contract that shape does not " \
                 "carry.\n#{output}")
  end
end
