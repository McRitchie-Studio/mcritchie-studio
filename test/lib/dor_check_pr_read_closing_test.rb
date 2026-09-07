# frozen_string_literal: true

# bin/dor-check's PR-READ ALERT, and the sentence it used to BORROW from the CI gate.
# Standalone (no Rails — it drives the script with --file fixtures):
#   ruby -Itest test/lib/dor_check_pr_read_closing_test.rb
#
# THE DEFECT (/tasks/pr-read-alert-overstates-green). When the PR FILE-LIST read is
# :unreadable, `pr_read_alert` ends with CiStatus.unreadable_remedy's cert_route:false
# closing. On the exempt path that closing was "Fixing the credential is the only route
# — this gate advances on a GREEN CI and nothing else."
#
# It is falsest exactly where it printed. Driven through `--gate-role review` with
# DOR_CHECK_CI_STATUS=green and the PR read REFUSED: ci.state="green", ready=false,
# exit=1, ONE error — and that one error closed by telling the reader a green CI is all
# this gate wants. The CI was green. The error printing the sentence WAS the refusal,
# and the sentence sent the reader to look at the one thing that had nothing wrong with
# it. Same species as /tasks/gate-sentence-outlived-truth, one printer over.
#
# EVERY TEST HERE DRIVES THE GATE. The unit that matters is not the string builder —
# a formatter test passes happily while the caller never hands it the list, which is
# mutation B of the predecessor's proof. So the alert is read out of a real
# `bin/dor-check --json` run, and `ci.state` is read back from that same payload to
# prove the CI seam LANDED (a green assertion against a run whose CI was never green
# proves nothing about a sentence that talks about green).
#
# THE RETIREMENT PIN IS A PROPERTY, NOT A SPELLING, and that is deliberate. The
# obvious `refute_includes message, "advances on a GREEN CI and nothing else"` is
# satisfied by any reinstatement that picks different words — measured on this exact
# family, where one such refutation admitted a reworded twin of the claim it retired.
# So the pin is GREEN_NEEDS_A_LIMIT below: in a REFUSAL, green may only be spoken of
# with a limit attached. Any wording that re-asserts green's sufficiency violates it,
# whatever words it chooses.
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class DorCheckPrReadClosingTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/7"
  DOC_DIFF = "docs/agents/modules/testing.md"

  # The derived closing's two halves, as the gate prints them.
  NAMES_ITS_OWN_REFUSAL = "the refused PR file-list read this alert reports, which left the artifact this " \
                          "gate judges unread"
  REFUTES_GREEN = "and no CI result clears that"

  # WHAT accepted PRINTED, TO THE BYTE — the sentence that is still correct wherever
  # this alert refuses nothing (the builder role, and the merge gate submit-side). Its
  # survival is half the fix: a closing that changed everywhere would be a rewrite, not
  # a derivation.
  UNREFUSING_CLOSING = "Fixing the credential is the only route — this gate advances on a GREEN CI and " \
                       "nothing else."

  # THE CLAIM, PINNED AS A PROPERTY. Every sentence that mentions green must also carry
  # a limit on what green buys. Three limits are legitimate today:
  #   * "NOT SUFFICIENT"        — the derived closing's own qualifier
  #   * "no CI result clears"   — its refutation clause
  #   * "it can actually read"  — the FAST-cert sentence, which claims green is
  #                               NECESSARY for a cert, never sufficient for the gate
  # A sentence mentioning green with none of them is asserting sufficiency in SOME
  # wording, which is the claim this task retired. If a future sentence legitimately
  # needs to mention green, give it its limit or add the limit here on purpose — the
  # point is that nobody reinstates the claim by accident or by paraphrase.
  GREEN_LIMITS = [/NOT SUFFICIENT/, /no CI result clears/, /it can actually read/].freeze

  def sentences(text)
    text.to_s.split(/(?<=\.)\s+/)
  end

  def unlimited_green_sentences(text)
    sentences(text).select { |s| s.match?(/green/i) && GREEN_LIMITS.none? { |lim| s.match?(lim) } }
  end

  # ── the harness ─────────────────────────────────────────────────────────────

  def devops(extra = {})
    { "kind" => "docs", "shape" => "docs", "pr_url" => PR_URL,
      "acceptance" => ["Prose explains the new gate"],
      "repositories" => ["myapp"], "risk_tags" => ["docs"],
      "test_plan" => ["[docs] prose"], "checks_run" => ["[docs] prose read"],
      "post_deploy_cmd" => "none" }.merge(extra)
  end

  # Drives the REAL gate. DOR_CHECK_PR_FILES injects at the PR file read and
  # DOR_CHECK_CI_STATUS at CiStatus.evaluate — both replace a `gh` call, neither
  # replaces the alert under measurement.
  def drive(ci:, role: "review", pr_files: "unreadable", diff: DOC_DIFF, cert: "ok")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "pr-read-task", "title" => "T",
                                     "metadata" => { "devops" => devops }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => diff, "DOR_CHECK_PR_FILES" => pr_files,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_SUITE_EVIDENCE" => cert
      })
      out = IO.popen(env, "#{BIN} pr-read-task --file #{path} --json --gate-role #{role} 2>/dev/null", &:read)
      code = $?.exitstatus
      refute_empty out.to_s.strip, "the gate produced no JSON at all — nothing below read anything"
      [JSON.parse(out), code]
    end
  end

  # `--gate build` reads no CI, so this helper takes the PR-files seam and NOT the CI
  # one. It is not "neither seam": DOR_CHECK_PR_FILES is what puts the refused read in
  # front of the alert, and the run below would have nothing to measure without it.
  def drive_build_gate
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "pr-read-task", "title" => "T",
                                     "metadata" => { "devops" => devops }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => DOC_DIFF, "DOR_CHECK_PR_FILES" => "unreadable",
        "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      })
      out = IO.popen(env, "#{BIN} pr-read-task --file #{path} --json --gate build " \
                          "--gate-role review 2>/dev/null", &:read)
      code = $?.exitstatus
      refute_empty out.to_s.strip, "the build gate produced no JSON at all — nothing below read anything"
      [JSON.parse(out), code]
    end
  end

  def pr_read_line(verdict)
    (Array(verdict["errors"]) + Array(verdict["suggestions"]))
      .find { |line| line.include?("did NOT read the PR") }
  end

  # ── the defect, driven ──────────────────────────────────────────────────────

  def test_a_refused_pr_read_on_a_green_ci_names_its_own_refusal_not_ci
    verdict, code = drive(ci: "green")

    # THE SEAM LANDED. Read back from the payload, not assumed: every assertion below
    # is about what a GREEN CI makes this sentence say, so a run whose CI was not
    # actually green would certify nothing.
    assert_equal "green", verdict.dig("ci", "state"),
                 "DOR_CHECK_CI_STATUS did not reach CiStatus.evaluate — this case is not the one under test"
    refute verdict["ready"], "a refused PR file-list read must refuse the review verdict"
    assert_equal 1, code, "...and exit non-zero"

    alert = pr_read_line(verdict)
    refute_nil alert, "the PR-read refusal did not print at all:\n#{verdict.inspect}"
    assert_includes Array(verdict["errors"]), alert, "in the review role it must land as an ERROR"

    assert_includes alert, NAMES_ITS_OWN_REFUSAL,
                    "the closing must name THIS refusal — the PR file read — not borrow a sentence about " \
                    "CI:\n#{alert}"
    assert_includes alert, REFUTES_GREEN,
                    "...and must say plainly that no CI result clears it, because the CI here is GREEN:\n#{alert}"
  end

  # THE PROPERTY, not the spelling. A reinstatement in ANY wording puts green in a
  # sentence with no limit on it; that is what this refuses.
  def test_a_refusing_alert_never_speaks_of_green_without_a_limit
    verdict, = drive(ci: "green")
    alert = pr_read_line(verdict)
    refute_nil alert, "no alert to scan — see the anti-vacuity control below"

    offenders = unlimited_green_sentences(alert)

    assert_empty offenders,
                 "a REFUSAL asserted something about a GREEN CI with no limit attached. That is the retired " \
                 "claim, whatever words it wears: this gate refused a verdict whose CI was green, so any " \
                 "sentence promising what green buys is false here. Give the sentence its limit, or retire " \
                 "it:\n#{offenders.join("\n")}"
  end

  # ANTI-VACUITY. A scanner that reads nothing passes everything, and a property test
  # whose predicate can never fire is a comment. So the SAME predicate is run against
  # the sentence accepted actually printed, and it must FLAG it.
  def test_the_green_limit_scanner_flags_the_sentence_this_task_retired
    offenders = unlimited_green_sentences(UNREFUSING_CLOSING)

    assert_equal [UNREFUSING_CLOSING], offenders,
                 "the scanner used by the test above cannot detect the very claim it exists to keep out — " \
                 "so its green run means nothing"
    assert_empty unlimited_green_sentences("A GREEN CI is NECESSARY AND NOT SUFFICIENT here."),
                 "...and it must not flag a green sentence that DOES carry its limit, or it would forbid the fix"
  end

  # ── the paths that must not have moved ──────────────────────────────────────

  # THE BUILDER KEEPS THE SENTENCE OPERATORS KNOW, to the byte. Submit-side this alert
  # is a SUGGESTION: nothing here is refusing the verdict, so nothing about the closing
  # was false, and a fix that rewrote it everywhere would be a rewrite wearing a
  # derivation's clothes.
  def test_the_builder_side_suggestion_still_prints_the_original_closing
    verdict, code = drive(ci: "green", role: "builder")

    assert_equal "green", verdict.dig("ci", "state"), "the CI seam must land in this role too"
    alert = pr_read_line(verdict)
    refute_nil alert, "the submit-side alert must still print — it is loud, just not fatal"
    assert_includes Array(verdict["suggestions"]), alert,
                    "submit-side the local view is the honest near-twin of the PR, so this is a SUGGESTION"
    assert_equal 0, code, "...and it must not refuse the builder's verdict"

    assert alert.end_with?(UNREFUSING_CLOSING),
           "the non-refusing closing must be byte-identical to what accepted printed:\n#{alert}"
    refute_includes alert, NAMES_ITS_OWN_REFUSAL,
                    "nothing is refusing this verdict, so the alert must not claim something is"
  end

  # THE BUILD GATE MAKES NO REFUSAL EITHER, and this half of the predicate was INERT
  # until it was mutated for. `pr_read_refuses_verdict?` is `@review_role && !@build_gate`;
  # deleting the `@build_gate` assignment leaves the ivar nil, which reads as "not the
  # build gate", and the DoR-to-Build run in the review role silently acquires a closing
  # that names a refusal it never makes. The suite stayed green at 6 runs / 51 assertions
  # through exactly that mutation, so the role half was pinned and the gate half was a
  # constant nobody had noticed. It is a real run, and the reason nothing here can refuse
  # is the BUILD GATE MAKING NO REFUSAL — `pr_read_refuses_verdict?` is false — not any
  # claim that this path stays away from `gh`. It does not: driven 2026-09-07 with a
  # recording `gh` on PATH and no DOR_CHECK_PR_FILES, `--gate build --gate-role review`
  # shells `gh api …/pulls/<n>/files` exactly once. This sentence used to carry the
  # "must not shell `gh`" claim that bin/dor-check's exempt caller corrects three lines
  # above `pr_read_refusal = pr_read_alert(cert_route: false)`; correcting one copy and
  # leaving the other is how the next reader re-derives the guard from the false half.
  def test_the_build_gate_never_acquires_a_refusal_it_does_not_make
    verdict, = drive_build_gate

    alert = pr_read_line(verdict)
    refute_nil alert, "the build gate still prints the alert — this test is about its CLOSING, not its absence"
    assert_includes Array(verdict["suggestions"]), alert,
                    "at the build gate the PR-read alert can only ever be a suggestion"
    assert alert.end_with?(UNREFUSING_CLOSING),
           "the build gate refuses nothing, so its closing must be byte-identical to accepted's:\n#{alert}"
    refute_includes alert, NAMES_ITS_OWN_REFUSAL,
                    "a gate that made no refusal must not name one:\n#{alert}"
  end

  # AN :unverified READ IS A DIFFERENT FACT AND KEEPS ITS OWN SENTENCE. gh missing, a
  # 404, a transport error — none of them is a credential refusal, and describing one
  # as a credential fault was its own defect on this family. This alert never reaches
  # the remedy at all, so the fix must be invisible to it.
  def test_an_unverified_pr_read_is_untouched_and_still_not_called_a_credential_fault
    verdict, = drive(ci: "green", pr_files: "unverified")
    alert = pr_read_line(verdict)

    refute_nil alert, "the :unverified alert must still print"
    assert_includes alert, "this is NOT a credential refusal, so the LOCAL view was graded instead",
                    "the :unverified wording is not this task's to move:\n#{alert}"
    refute_includes alert, NAMES_ITS_OWN_REFUSAL,
                    "the derived closing belongs to the :unreadable branch only:\n#{alert}"
    assert_empty unlimited_green_sentences(alert),
                 "and it must not have acquired an unlimited green claim either:\n#{alert}"
  end

  # THE CO-FIRE STILL READS AS TWO REFUSALS, NOT ONE. When one stale token refuses the
  # PR read AND the check read, the CI half names the PR read (the merged
  # `also_refused` derivation) and the PR half now names itself. Neither may fall back
  # to promising that green alone carries the path.
  def test_the_co_fire_leaves_both_halves_naming_what_actually_refused
    verdict, = drive(ci: "unreadable")
    errors = Array(verdict["errors"])

    ci_half = errors.find { |e| e.include?("GitHub CI is UNREADABLE") }
    pr_half = errors.find { |e| e.include?("did NOT read the PR") }
    refute_nil ci_half, "the CI refusal must still print:\n#{errors.inspect}"
    refute_nil pr_half, "the PR-read refusal must still print:\n#{errors.inspect}"

    assert_includes ci_half, "the PR's own file list going unread",
                    "the CI half's merged co-fire derivation must be untouched:\n#{ci_half}"
    assert_includes pr_half, NAMES_ITS_OWN_REFUSAL, "the PR half must name itself:\n#{pr_half}"
    errors.each do |e|
      assert_empty unlimited_green_sentences(e), "an unlimited green claim survived in:\n#{e}"
    end
  end
end
