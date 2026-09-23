# frozen_string_literal: true

require "test_helper"

# The QA-dispatch leg's two operator-facing promises, exercised where they can be
# RUN and tripwired only where the seam is a 7,000-line script:
#
#   1. the remedy it prints RUNS AS PRINTED — measured twice on 2026-09-22 that it
#      did not (`bin/qa-server deploy … ` without `--yes` hits the deliberate
#      external-write confirmation and deploys nothing);
#   2. a baseline read that will not answer is refused with GH'S OWN WORDS and the
#      remedy those words support, instead of a fixed sentence that sent the
#      operator at the app.
class QaDispatchRemedyWiringTest < ActionDispatch::IntegrationTest
  RELEASE_SRC   = Rails.root.join("bin", "release.rb")
  QA_SERVER_SRC = Rails.root.join("bin", "qa-server")

  # bin/qa-server's OWN sentence decides what a runnable remedy must carry. Read
  # from the script rather than restated here: move that gate to a different flag
  # and this test reds, instead of drifting past it exactly as the remedy did.
  def confirmation_flag
    QA_SERVER_SRC.read[/Re-run with (--\S+) after reviewing/, 1]
  end

  # --- 1. the remedy runs as printed ---------------------------------------

  test "[integration] REGRESSION: the printed QA-deploy remedy carries the flag qa-server's gate demands" do
    flag = confirmation_flag
    assert_equal "--yes", flag, "bin/qa-server's external-write confirmation still asks for --yes"

    remedy = Release::QaDeployCommand.for(qa_app: "mcritchie-studio", branch: "release")

    assert_equal "bin/qa-server deploy mcritchie-studio origin/release --yes", remedy
    assert_includes remedy.split, flag,
      "the remedy an operator copies must satisfy the confirmation, or it deploys nothing"
  end

  test "[integration] CONTROL: the command as it was PRINTED fails this very assertion" do
    # The both-arms ablation. Without this, "the remedy contains --yes" is a
    # predicate that might hold of anything; here it is shown to REJECT the exact
    # string the sweep printed twice on 2026-09-22 and ACCEPT the one it prints now.
    drifted = "bin/qa-server deploy mcritchie-studio origin/release"

    assert_not_includes drifted.split, confirmation_flag,
      "the measured-broken remedy must FAIL the check that the fixed one passes"
    # Compared as ARGV, not as text: a producer that emitted the flag as an empty
    # string would differ from `drifted` by one trailing space and slip through.
    assert_not_equal drifted.split, Release::QaDeployCommand.for(qa_app: "mcritchie-studio", branch: "release").split
  end

  test "[integration] bin/release prints no hand-written qa-server command — both sites render from one producer" do
    # The drift was TWO copies of one command line, one with the flag and one
    # without. Deleting a copy is not the fix; having one producer is. An
    # interpolated `bin/qa-server deploy #{…}` is the shape both copies had.
    body = RELEASE_SRC.read

    assert_no_match(/bin\/qa-server deploy \#\{/, body,
      "render the command with Release::QaDeployCommand.for so the two sites cannot drift again")

    code = body.lines.reject { |line| line.strip.start_with?("#") }
    assert_equal 2, code.grep(/Release::QaDeployCommand\.for\(/).size,
      "exactly two render sites: the step that RUNS the deploy and the remedy that REPRINTS it"
  end

  # --- 2. the refusal says what gh said ------------------------------------

  test "[integration] a credential refusal is reported with gh's words AND the re-mint remedy" do
    # Verbatim from the real gh this lane runs, with a dead GH_TOKEN.
    output = "HTTP 401: Bad credentials (https://api.github.com/repos/McRitchie-Studio/mcritchie-studio/" \
             "actions/workflows/qa-deploy.yml)\nTry authenticating with:  gh auth login"

    message = Release::GhFailure.failure_message(
      headline: "  ⚠ qa-deploy.yml: `gh run list` never answered",
      output: output,
      fallback: "Re-run `bin/release prepare` — the sweep is idempotent."
    )

    assert_includes message, "gh said:"
    assert_includes message, "Bad credentials", "the operator must see WHAT gh answered"
    assert_includes message, "CREDENTIAL failure", "a 401 selects the credential remedy"
    assert_no_match(/the sweep is idempotent/, message,
      "a credential fault must NOT be answered with the generic retry — that is the wrong remedy")
  end

  test "[integration] CONTROL: a NON-credential failure gets the caller's fallback, not the re-mint" do
    # The other arm. Same composition, a failure that is not credential-shaped:
    # if this also printed the re-mint recipe, the test above would prove nothing
    # about classification.
    output = "error connecting to api.github.com: dial tcp: lookup api.github.com: no such host"

    message = Release::GhFailure.failure_message(
      headline: "  ⚠ qa-deploy.yml: `gh run list` never answered",
      output: output,
      fallback: "Re-run `bin/release prepare` — the sweep is idempotent."
    )

    assert_includes message, "no such host"
    assert_includes message, "the sweep is idempotent"
    assert_no_match(/CREDENTIAL failure/, message,
      "re-minting a token does not resolve a hostname — that remedy must not fire here")
  end

  # --- 3. the script seam (supplementary tripwire ONLY) --------------------

  test "[integration] dispatch_and_watch's snapshot rides the cause-split policy and carries the credential" do
    # Supplementary ONLY — the policy's behaviour is proven in
    # test/models/release/gh_read_retry_test.rb, including a Rails-free run. This
    # guards the one seam no unit test can see: that the SCRIPT calls it.
    body = RELEASE_SRC.read[/^def dispatch_and_watch.*?(?=^def )/m]
    assert body, "bin/release.rb defines dispatch_and_watch"

    assert_includes body, "Release::GhReadRetry.call", "the snapshot retries by CAUSE, not by clock"
    assert_includes body, "GhAuthRetry.mint", "a credential refusal re-mints rather than sleeping"
    assert_includes body, "$gh_lane_token = snapshot.token",
      "the recovered credential is carried to the dispatch and the watch"
    assert_includes body, "Release::GhFailure.failure_message", "the refusal quotes gh"
    assert_no_match(/^  5\.times do$/, body,
      "the blind sleep-loop is gone — it cleared neither measured instance")
    assert_includes body, "return false # gh never answered — do not watch a stale run",
      "the REFUSAL ITSELF STAYS: without a baseline, dispatching would read a prior run's verdict"
  end

  test "[integration] every gh call in the dispatch lane carries the lane credential" do
    # A token that rescued the baseline read and was then dropped would leave the
    # very next call failing on the credential just proven dead.
    body = RELEASE_SRC.read

    %w[watch view].each do |verb|
      assert_match(/gh_sh\("gh", "run", "#{verb}"/, body,
        "`gh run #{verb}` must ride the lane credential, not the ambient one")
      assert_no_match(/\bsh\("gh", "run", "#{verb}"/, body,
        "no bare sh() gh call may remain in the dispatch lane")
    end
    assert_includes body, "_, dispatched = gh_sh(*args, chdir: chdir)",
      "the dispatch itself rides the recovered credential"
  end
end
