# frozen_string_literal: true

# The EXEMPT (doc-only) path must read CI. Standalone — no Rails; the integration
# tier shells bin/dor-check with --file fixtures:
#   ruby -Itest test/lib/dor_check_exempt_ci_test.rb
#
# THE BUG (/tasks/gate-zero-skips-docs-ci). bin/dor-check's exempt-kind branch ended
# in a bare `exit 0`, and that `exit` sat ABOVE two things: the CI allow-list (whose
# own comment says ":green is the ONLY state that advances a review") and the
# gate-verdict emit. So `--gate-role review` — the run the pipeline calls THE
# AUTHORITATIVE CI VERDICT — never evaluated CI on a doc-only diff. --json returned
# ready=true, exempt=true, errors=[] with no `ci` key at all, and no `dor_review`
# attempt was written. Three doc-shaped PRs cleared gate-zero that way (turf-vault
# #9/#10, mcritchie-studio #1204); every one happened to be green, so the exposure
# was the next one.
#
# THE NULL ATTEMPT WAS THE SAME FACT, TWICE MISREAD. `dor_review` reading null on
# docs-shaped PRs was logged twice and filed as a cosmetic gap in the record. It was
# not a missing record: the gate had not run. So test_the_exempt_verdict_records_a
# _gate_attempt_in_both_directions is not a nicety — it pins the only observable the
# defect ever produced.
#
# WHAT MUST *NOT* CHANGE, and why this is a split rather than a moved block. Two
# unrelated guards lived below that `exit`, and only one of them should be skipped
# here: the shape/TEST-TIER gate is correctly waived (a prose diff owes no unit
# tier), while the CI allow-list never had any business being skipped — this repo's
# CI GRADES PROSE (doc-link checks, generated-doc drift, entry-doc guards, rubocop
# over bin/). "Ships no behavior" is not "cannot fail CI".
# test_the_tier_gate_is_still_waived_on_a_green_exempt_diff and its code-carrying
# control are what hold that line: relocating the CI block above the exit would pass
# every OTHER test in this file and fail those two.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../bin/lib/ci_gate"

class DorCheckExemptCiTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/7"
  DOC_DIFF = "docs/agents/modules/deployment.md"
  CODE_DIFF = "app/models/thing.rb"

  # An exempt KIND with a doc-only diff — the shape the gate waives tiers for.
  def devops(overrides = {})
    {
      "kind" => "docs", "pr_url" => PR_URL,
      "acceptance" => ["Runbook names the deploy strategy"],
      "repositories" => ["myapp"], "risk_tags" => ["docs"],
      "test_plan" => ["[unit] n/a"], "post_deploy_cmd" => "none"
    }.merge(overrides)
  end

  # Runs dor-check against an in-memory task, returns [parsed_json, exitcode].
  # STDOUT only: the child inherits bundler's env under `bin/rails test` and emits
  # rubygems warnings on STDERR, which would corrupt the --json parse if merged.
  def check(devops_payload, ci: nil, role: "review", changed: DOC_DIFF, gate_bin: nil, args: "--json")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "exempt-task", "title" => "T",
                                     "metadata" => { "devops" => devops_payload }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => changed, "DOR_CHECK_PR_FILES" => changed,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_GATE_BIN" => gate_bin
      }.compact)
      out = IO.popen(env, "#{BIN} exempt-task --file #{path} #{args} --gate-role #{role} 2>/dev/null", &:read)
      code = $?.exitstatus
      args.include?("--json") ? [JSON.parse(out), code] : [out, code]
    end
  end

  def errors_of(verdict) = Array(verdict["errors"]).join(" | ")

  # A recording stub for the gate CLI: every invocation's argv, one line per call.
  # This is the ONLY way to observe the durable attempt — --json and --file both
  # skip the board write by design, so a gate that records nothing and a gate that
  # records a pass are otherwise indistinguishable from a test.
  def with_gate_stub
    Dir.mktmpdir do |dir|
      log = File.join(dir, "gate-calls.log")
      bin = File.join(dir, "gate-stub")
      File.write(bin, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "#{log}"
      SH
      FileUtils.chmod(0o755, bin)
      yield bin, -> { File.exist?(log) ? File.readlines(log, chomp: true) : [] }
    end
  end

  # ── [unit] CiGate — the decision table both paths now share ─────────────────
  #
  # Pure: no subprocess, no ENV, no board. The exempt path's whole fix is that it
  # asks THIS instead of asking nothing, so the states it must refuse are asserted
  # here directly rather than inferred from a verdict's prose.

  def test_unit_green_is_the_only_state_that_advances_a_review
    error, = CiGate.verdict({ state: :green }, review_role: true, pr_url: PR_URL, slug: "t")
    assert_nil error, "green must advance"
  end

  def test_unit_every_non_green_state_refuses_a_review
    %i[red pending conflicted ci_less closed merged none unreadable unverified no_pr].each do |state|
      error, = CiGate.verdict({ state: state }, review_role: true, pr_url: PR_URL, slug: "t")
      refute_nil error, "#{state} must refuse a review"
    end
  end

  # THE ALLOW-LIST PROPERTY, not a longer deny-list: a state this gate has never
  # heard of refuses too. Testing only the real tokens cannot tell an allow-list
  # from a deny-list, and the difference is a live false pass.
  def test_unit_an_unclassified_state_refuses_rather_than_falling_through
    error, clears = CiGate.verdict({ state: :teal }, review_role: true, pr_url: PR_URL, slug: "t")
    assert_includes error.to_s, "does not classify"
    refute clears, "an unclassified state is not the no-verdict family and no cert clears it"
  end

  def test_unit_a_blank_pr_url_refuses_and_no_cert_can_clear_it
    error, clears = CiGate.verdict({ state: :no_pr }, review_role: true, pr_url: "", slug: "t")
    assert_includes error.to_s, "BLANK"
    refute clears, "the missing thing is the SUBJECT, not the evidence"
  end

  # The role split is load-bearing and must survive the extraction: the builder's
  # submit-side run is provisional by construction, so a pending CI is a note there
  # and a refusal in review.
  def test_unit_a_pending_ci_notes_for_the_builder_and_refuses_for_review
    error, _clears, notes = CiGate.verdict({ state: :pending, pending: ["ci"] },
                                           review_role: false, pr_url: PR_URL, slug: "t")
    assert_nil error
    assert_includes notes.join(" "), "NO LONGER blocks"

    review_error, = CiGate.verdict({ state: :pending, pending: ["ci"] },
                                   review_role: true, pr_url: PR_URL, slug: "t")
    assert_includes review_error.to_s, "still RUNNING"
  end

  def test_unit_gate_row_names_ci_as_the_failing_sop_when_ci_is_why_it_failed
    assert_equal "pass", CiGate.gate_row({ state: :green }, review_role: true, review_refused: false)
    assert_equal "fail", CiGate.gate_row({ state: :red }, review_role: true, review_refused: true)
    assert_equal "fail", CiGate.gate_row({ state: :pending }, review_role: true, review_refused: true)
    assert_equal "pending", CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)
    assert_equal "fail", CiGate.gate_row({ state: :unreadable }, review_role: true, review_refused: true)
    assert_nil CiGate.gate_row(nil, review_role: true, review_refused: false)
  end

  # ── [integration] the exempt path, end to end through bin/dor-check ─────────

  # THE REGRESSION. Written first, and it failed against the old `exit 0`:
  # ready=true, exempt=true, errors=[], no `ci` key.
  def test_a_red_ci_refuses_an_exempt_doc_only_review
    verdict, code = check(devops, ci: "red")

    assert_equal 1, code, "a red CI must refuse an exempt diff"
    refute verdict["ready"], "ready must follow the CI verdict, not the exemption"
    assert verdict["exempt"], "the TIER waiver is unchanged — only the CI verdict refuses"
    assert_includes errors_of(verdict), "GitHub CI is RED"
    assert_equal "red", verdict.dig("ci", "state")
  end

  # THE FIELD WHOSE ABSENCE MADE THE DEFECT INVISIBLE. An exempt verdict carried no
  # `ci` key at all, so no monitor could tell a green from a gate that never looked.
  def test_an_exempt_pass_still_publishes_the_ci_verdict_it_read
    verdict, code = check(devops, ci: "green")

    assert_equal 0, code
    assert verdict["ready"]
    assert verdict["exempt"]
    assert_equal "green", verdict.dig("ci", "state")
    assert_equal "pass", verdict["ci_gate_result"]
    assert_empty Array(verdict["errors"])
  end

  # THE NEIGHBOURS, not just red. The documented allow-list refuses each of these,
  # and an exempt task is no different.
  def test_pending_unreadable_and_unclassified_ci_all_refuse_an_exempt_review
    {
      "pending" => "still RUNNING",
      "unreadable" => "UNREADABLE",
      "unverified" => "no verdict yet",
      "none" => "no verdict yet",
      "conflicted" => "gate-zero",
      "closed" => "not an OPEN review target",
      "state:teal" => "does not classify"
    }.each do |injected, expected|
      verdict, code = check(devops, ci: injected)

      assert_equal 1, code, "#{injected} must refuse"
      assert_includes errors_of(verdict), expected
      assert_equal "fail", verdict["ci_gate_result"], "#{injected} must record CI as the failing sop"
    end
  end

  # A BLANK pr_url resolves to :no_pr WITHOUT any injection — the real path, and the
  # state whose silent fall-through is what the allow-list was written to close.
  def test_a_blank_pr_url_refuses_an_exempt_review
    verdict, code = check(devops("pr_url" => ""))

    assert_equal 1, code
    assert_includes errors_of(verdict), "devops.pr_url is BLANK"
    assert_equal "no_pr", verdict.dig("ci", "state")
  end

  # The builder's submit-side run stays provisional: review re-reads it, so a
  # pending CI is a note and a missing PR is silent. A fix that blocked BOTH roles
  # would stall every docs handoff on an hour-old token.
  def test_the_builder_role_keeps_its_provisional_treatment
    pending, code = check(devops, ci: "pending", role: "builder")
    assert_equal 0, code, "submit-side pending must not block"
    assert_includes Array(pending["suggestions"]).join(" "), "NO LONGER blocks"

    no_pr, no_pr_code = check(devops("pr_url" => ""), role: "builder")
    assert_equal 0, no_pr_code, "submit-side runs before the PR exists"
    assert_empty Array(no_pr["errors"])

    red, red_code = check(devops, ci: "red", role: "builder")
    assert_equal 1, red_code, "a RED CI blocks in BOTH roles"
    assert_includes errors_of(red), "GitHub CI is RED"
  end

  # ── the half that must stay skipped ────────────────────────────────────────

  # THE SCOPE GUARD. The task carries NO checks_run and no shape, and still passes on
  # a green CI: the tier gate is waived exactly as before. Relocating the CI block
  # above the exit instead of splitting the path passes the CI tests above and fails
  # this one, because the tier gate would come with it.
  def test_the_tier_gate_is_still_waived_on_a_green_exempt_diff
    verdict, code = check(devops, ci: "green")

    assert_equal 0, code
    assert_empty Array(verdict["missing_tiers"]), "a prose diff owes no unit tier"
    assert_empty Array(verdict["missing_metadata"])
    refute_includes errors_of(verdict), "tier"
  end

  # THE CONTROL for the line above: the exemption is EARNED FROM THE DIFF, so a
  # code-carrying diff under the same exempt kind falls through to the full gate and
  # IS asked for tiers. Without this, "no tier was demanded" could mean the gate is
  # waiving them for everyone.
  def test_a_code_carrying_diff_under_an_exempt_kind_is_still_gated
    verdict, code = check(devops, ci: "green", changed: CODE_DIFF)

    assert_equal 1, code
    refute verdict["exempt"], "code in the diff loses the exemption"
    assert_includes errors_of(verdict), "ships a code diff"
  end

  # ── the durable attempt ────────────────────────────────────────────────────

  # ACCEPTANCE 2. `dor_review` read null on every docs-shaped PR because the exempt
  # path exited above the emit. Both directions are asserted: a gate that only
  # records its refusals leaves the same hole for every green.
  def test_the_exempt_verdict_records_a_gate_attempt_in_both_directions
    with_gate_stub do |stub, calls|
      _out, code = check(devops, ci: "green", gate_bin: stub, args: "")
      assert_equal 0, code
      green_calls = calls.call
      assert(green_calls.any? { |c| c.start_with?("open task exempt-task dor_review") },
             "a green exempt review must OPEN a dor_review attempt — got #{green_calls.inspect}")
      assert(green_calls.any? { |c| c.start_with?("close task exempt-task dor_review --success") },
             "and close it successful — got #{green_calls.inspect}")
    end

    with_gate_stub do |stub, calls|
      _out, code = check(devops, ci: "red", gate_bin: stub, args: "")
      assert_equal 1, code
      red_calls = calls.call
      assert(red_calls.any? { |c| c.start_with?("close task exempt-task dor_review --failed") },
             "a refused exempt review must record a FAILED attempt — got #{red_calls.inspect}")
      assert(red_calls.any? { |c| c.include?('"sop":"ci"') && c.include?('"result":"fail"') },
             "and CI must be named as the failing sop — got #{red_calls.inspect}")
    end
  end

  # The builder's run closes `dor`, not `dor_review` — one verdict per gate. A
  # single emit that always wrote dor_review would make every submit look like a
  # review verdict on the gates card.
  def test_the_builder_role_records_the_dor_gate_not_dor_review
    with_gate_stub do |stub, calls|
      check(devops, ci: "green", role: "builder", gate_bin: stub, args: "")
      recorded = calls.call
      assert(recorded.any? { |c| c.start_with?("open task exempt-task dor ") || c == "open task exempt-task dor" },
             "builder-side must open `dor` — got #{recorded.inspect}")
      refute(recorded.any? { |c| c.include?("dor_review") }, "…and never dor_review — got #{recorded.inspect}")
    end
  end

  # The waiver is SAID OUT LOUD, in the text verdict a human actually reads. The old
  # line named only the skipped tier gate, so "no tier was demanded" and "no CI was
  # read" printed identically.
  def test_the_text_verdict_names_the_ci_state_behind_an_exempt_pass
    out, code = check(devops, ci: "green", args: "")

    assert_equal 0, code
    assert_includes out, "shape/test-tier gate skipped"
    assert_includes out, "GitHub CI: GREEN"
  end

  def test_the_text_refusal_says_the_tier_gate_was_still_waived
    out, code = check(devops, ci: "red", args: "")

    assert_equal 1, code
    assert_includes out, "the shape/test-tier gate IS waived"
    assert_includes out, "GitHub CI is RED"
  end

  # The build gate resolves no diff and must not shell `gh` — so it reads no CI and
  # writes no attempt. Leniency there cannot disarm anything: at design time no code
  # exists yet and the build gate enforces no tiers either way.
  def test_the_build_gate_reads_no_ci_on_an_exempt_task
    verdict, code = check(devops, ci: "red", args: "--json --gate build")

    assert_equal 0, code, "the build gate has no CI verdict to give"
    assert_nil verdict["ci"]
  end
end
