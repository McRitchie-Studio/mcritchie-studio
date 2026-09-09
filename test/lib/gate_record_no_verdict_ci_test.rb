# frozen_string_literal: true

# THE DURABLE GATE RECORD for the REST of the no-verdict family. Standalone (no
# Rails — it shells bin/dor-check with --file fixtures):
#   ruby -Itest test/lib/gate_record_no_verdict_ci_test.rb
#
# THE DEFECT (/tasks/refused-review-records-fail). /tasks/gate-logs-auth-as-red
# moved ONE member of CiGate::CI_NO_VERDICT_STATES off the flat "fail": :unreadable.
# The other two stayed on it. So a `dor_review` gate-zero that refused a review
# because CI had NOTHING TO SAY closed its attempt with
#
#   {"sop":"ci","result":"fail"}
#
# for a PR whose CI was never red — :none is "the PR reports no checks YET" and
# :unverified is "`gh` itself fell over". Both are non-answers. Neither is a failure.
# `bin/gate show` prints `ci:fail` and the task's gates card paints a rose ✗, so the
# task's PERMANENT gate history claims a red-CI bounce that never happened.
#
# WHY IT IS THE DANGEROUS DIRECTION. Most defects in this family make a task look
# GREENER than it was. This one INVENTS A RED, in the one artifact that outlives
# Heroku's log retention — and an invented red is what a later auditor reads as "this
# task bounced on CI", concluding the builder shipped a broken tree.
#
# MEASURED BEFORE THE FIX (2026-09-09, through the live chain below): :none, :unverified
# and a genuinely RED CI all persisted the identical row `{"sop":"ci","result":"fail"}`.
# Three different facts, one word, no way back to which.
#
# THE SECOND HALF IS IN THE VIEW, and it is the half that inverts the bug rather than
# fixing it. The gates card's glyph chain is `fail → ✗`, `running → ◌`, DEFAULT → ✓, so
# a new result value with no arm of its own is painted with the PASS glyph — trading a
# manufactured failure for a manufactured success. That arm and its proof live in
# test/integration/gates_card_no_verdict_ci_test.rb, which can load both halves.
#
# WHY THESE TESTS READ THE RECORD AND NOT STDOUT. A gate that PRINTS the right thing
# and STORES the wrong thing is precisely this defect: dor-check's stdout already said
# "GitHub CI has produced no verdict yet" in full while the row it persisted said fail,
# so asserting the printed refusal passes on the broken build. Every integration test
# here recovers the argv the gate CLI was actually handed, parses the `{"sop":"ci"}`
# entry out of it, and asserts on that — and refuses to conclude anything when no such
# entry was recorded at all (see ci_sop_entry's guard: an absent row is not a passing
# row, and without that guard every `refute_equal "fail"` below passes vacuously).
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../bin/lib/ci_gate"

class GateRecordNoVerdictCiTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/77"
  CODE_FILE = "app/models/thing.rb"

  # `gh pr view` on an OPEN, MERGEABLE PR. CLEAN is a SETTLED merge state, so
  # CiStatus.combine reads mergeability as :affirmed and leaves a checkless PR as a
  # bare :none instead of upgrading it to :ci_less ("no CI will ever run"), which is a
  # settled negative and legitimately still records "fail".
  OPEN_VIEW = JSON.generate(
    "state" => "OPEN", "mergeStateStatus" => "CLEAN", "mergeable" => "MERGEABLE",
    "baseRefName" => "accepted", "headRefOid" => "deadbeef", "statusCheckRollup" => []
  ).freeze

  # ── [unit] the decision table ───────────────────────────────────────────────
  #
  # Pure: no subprocess, no ENV, no board. `gate_row` is the single function that
  # names the ci row, shared by the gated and the exempt path.

  # THE HEADLINE, both states. A review that refused because CI said NOTHING must not
  # write a red CI into the permanent record.
  def test_unit_a_refused_review_does_not_record_a_failure_for_the_no_verdict_family
    none = CiGate.gate_row({ state: :none }, review_role: true, review_refused: true)
    unverified = CiGate.gate_row({ state: :unverified }, review_role: true, review_refused: true)

    refute_equal "fail", none, "a PR that reported no checks is not a PR whose CI failed"
    refute_equal "fail", unverified, "a `gh` that could not reach GitHub is not a CI that failed"
    assert_equal CiGate::GATE_ROW_NO_CHECKS, none
    assert_equal CiGate::GATE_ROW_UNVERIFIED, unverified
  end

  # THE SECOND ACCEPTANCE CRITERION, at the unit seam: each cause is DISTINGUISHABLE.
  # Collapsing the family onto one honest value would make the record uniformly
  # useless instead of uniformly wrong — "CI has not reported yet" (wait) and "`gh`
  # fell over" (re-read) prescribe different moves, and the row is all a later auditor
  # has. :unreadable already carries state/cause/reason alongside it; these two carry
  # nothing but `result`, so `result` is the ONLY place the difference can live.
  def test_unit_every_no_verdict_cause_is_distinguishable_in_the_record
    rows = CiGate::CI_NO_VERDICT_STATES.map do |state|
      CiGate.gate_row({ state: state }, review_role: true, review_refused: true)
    end

    assert_equal CiGate::CI_NO_VERDICT_STATES.size, rows.uniq.size,
                 "two no-verdict states share one row value, so the record cannot say which: #{rows.inspect}"
    refute_includes rows, "fail", "no member of the no-verdict family may claim a CI failure"

    # CORRECTED BY /tasks/no-pr-records-as-fail, and the correction is the finding.
    # This used to read `assert_equal GATE_ROW_NO_VERDICT.sort, rows.sort` — an EQUALITY
    # between the row set and the STATE family, which held only because the three states
    # that arrived first happened to belong to both. :no_pr broke it on purpose: it
    # records a no-verdict ROW (there was no CI to have a verdict) while staying OUT of
    # CI_NO_VERDICT_STATES (no cert may stand in for a PR that was never opened). See
    # CiGate::GATE_ROW_NO_VERDICT for the full argument.
    #
    # THE GUARANTEE IS UNCHANGED, and is what this assertion still buys: no state that
    # produces a no-verdict row may fall through gate_row's `else`, and no value may be
    # DECLARED no-verdict that gate_row cannot actually produce — either drift paints a
    # CI-with-no-verdict green. It is now stated over the states that produce such a row
    # rather than over the cert-waiver family, which is the set it always meant.
    producing_states = CiGate::CI_NO_VERDICT_STATES + [:no_pr]
    produced = producing_states.map do |state|
      CiGate.gate_row({ state: state }, review_role: true, review_refused: true)
    end

    assert_equal CiGate::GATE_ROW_NO_VERDICT.sort, produced.sort,
                 "the declared no-verdict row values must be exactly the ones gate_row can produce — " \
                 "a state that records a no-verdict row without its own arm falls through to the " \
                 "`else` and is painted with the PASS glyph"
    assert_equal producing_states.size, produced.uniq.size,
                 "two no-verdict rows share one value, so the record cannot say which: #{produced.inspect}"
  end

  # THE SAME INVARIANT IN THE BUILDER ROLE, where the old answer was a flat
  # "unverified" — one word for two states, and a word the gates card paints ✓. One
  # fact, one name, whoever asked: the record is read later by someone who was not
  # here, and "who asked" is not a property of what CI reported.
  def test_unit_the_builder_role_names_each_state_the_same_way
    CiGate::CI_NO_VERDICT_STATES.each do |state|
      refused = CiGate.gate_row({ state: state }, review_role: true, review_refused: true)

      assert_equal refused, CiGate.gate_row({ state: state }, review_role: false, review_refused: false),
                   "#{state} is a fact about the READ, not about who asked"
      assert_equal refused, CiGate.gate_row({ state: state }, review_role: true, review_refused: false)
    end
  end

  # THE CONTROL, and the other half of "distinguishes the causes". If the states that
  # genuinely settled NEGATIVE also stopped saying "fail", the record would be
  # uniformly honest and uniformly useless. :ci_less is the near neighbour worth
  # pinning by name — "no CI will ever run" is an affirmative negative, not a
  # non-answer, and it is one `mergeStateStatus` away from the :none above.
  def test_unit_a_settled_negative_still_records_a_failure
    %i[red conflicted ci_less closed merged].each do |state|
      assert_equal "fail", CiGate.gate_row({ state: state }, review_role: true, review_refused: true),
                   "#{state} is a verdict, not a missing one"
    end
    assert_equal "fail", CiGate.gate_row({ state: :green }, review_role: true, review_refused: true),
                 "the stale-green refusal is a refusal about a CI that WAS read"
    assert_equal "pass", CiGate.gate_row({ state: :green }, review_role: true, review_refused: false)
  end

  # THE BOUNDARY, stated so the next reader does not mistake it for an oversight — and
  # MOVED by /tasks/no-pr-records-as-fail, because this test had it in the wrong place.
  #
  # It used to pin `:no_pr` here as the worked example of "outside the family, so it
  # keeps the `else`". The premise was half right and the conclusion was wrong. :no_pr
  # is indeed NOT a member of CI_NO_VERDICT_STATES (a cert cannot stand in for a PR that
  # was never opened) — but it does not follow that it belongs on the DEFAULT, and the
  # default is not a neutral place to leave a state: it answered "fail" to a reviewer
  # and "unverified" to a builder for the same world, so this assertion was pinning a
  # manufactured red. It now has its own arm and its own row value; the cert-waiver
  # question and the row-value question are answered separately (see
  # CiGate::GATE_ROW_NO_VERDICT).
  #
  # WHAT IS LEFT ON THE DEFAULT IS THE UNCLASSIFIED, and that is the boundary worth
  # pinning: an allow-list must default to refuse, so a state nobody has classified
  # answers with the failing words rather than a considered-looking amber.
  def test_unit_states_outside_the_no_verdict_family_keep_the_default
    assert_equal "fail", CiGate.gate_row({ state: :quantum_flux }, review_role: true, review_refused: true)
    assert_equal "unverified", CiGate.gate_row({ state: :quantum_flux }, review_role: false, review_refused: false),
                 "the builder-side default is unchanged for an UNKNOWN state"
    assert_nil CiGate.gate_row(nil, review_role: true, review_refused: false)

    # ...and the boundary that DOES still hold for :no_pr: it stays out of the family
    # whose refusal a full local cert clears. This is the assertion the old one should
    # have been.
    refute_includes CiGate::CI_NO_VERDICT_STATES, :no_pr,
                    "a cert may stand in for missing EVIDENCE about a PR, never for a missing PR"
    assert_includes CiGate::GATE_ROW_NO_VERDICT, CiGate::GATE_ROW_NO_PR,
                    "its ROW is still a no-verdict row — the two memberships are different questions"
  end

  # ── [integration] what actually lands in the record ─────────────────────────

  # THE HEADLINE, through the LIVE chain. `gh` is a stub, but nothing else is: the
  # subprocess, the stdout/stderr join, CiStatus.view_verdict, `combine`'s
  # mergeability upgrade, and the whole of bin/dor-check all run for real. That is the
  # only way to prove the classifier's answer reaches the PERSISTED row rather than
  # only the printed one — the distinction this defect is made of.
  def test_integration_a_checkless_pr_records_no_checks_in_the_gate_record
    entry, = recorded_ci_row(gh_mode: "none")

    refute_equal "fail", entry["result"],
                 "this is the false red the task exists to remove — got #{entry.inspect}"
    assert_equal CiGate::GATE_ROW_NO_CHECKS, entry["result"]
  end

  def test_integration_a_gh_failure_records_unverified_in_the_gate_record
    entry, = recorded_ci_row(gh_mode: "unverified")

    refute_equal "fail", entry["result"],
                 "a transport fault is not a red CI — got #{entry.inspect}"
    assert_equal CiGate::GATE_ROW_UNVERIFIED, entry["result"]
  end

  # THE CONTROL, in the record rather than in the decision table: the three causes
  # must be TELLABLE APART by the one field both readers render. Without this the fix
  # could have been "stop writing fail" and nobody would notice.
  def test_integration_the_record_tells_the_three_causes_apart
    none, = recorded_ci_row(gh_mode: "none")
    unverified, = recorded_ci_row(gh_mode: "unverified")
    red, = recorded_ci_row(injected_ci: "red")

    assert_equal "fail", red["result"], "a CI that ran and failed is still a failure"
    assert_equal 3, [none["result"], unverified["result"], red["result"]].uniq.size,
                 "one word for three facts is the bug: #{[none, unverified, red].inspect}"
  end

  # NOT AN OVER-CORRECTION. The review gate-zero still REFUSED — it cannot be the
  # authoritative CI verdict on a CI that reported nothing — so the ATTEMPT stays
  # FAILED. Only the ci row's NAME changed. Turning the attempt green would swap a
  # manufactured failure for a manufactured success, which is the direction every
  # other defect in this family runs.
  def test_integration_the_attempt_itself_still_closes_failed
    %w[none unverified].each do |mode|
      _entry, calls = recorded_ci_row(gh_mode: mode)
      close = calls.find { |call| call[0] == "close" }

      assert close, "the gate must still record an attempt for #{mode} — got #{calls.inspect}"
      assert_includes close, "--failed",
                       "a CI with no verdict does not clear the review gate-zero; only its recorded CAUSE changed"
      assert_includes close, "dor_review", "the review role closes dor_review, not dor"
    end
  end

  # ── harness ─────────────────────────────────────────────────────────────────

  # Drives one `bin/dor-check <slug> --gate-role review` with the gate CLI redirected
  # to a recording stub, and returns [the ci sops entry, every recorded call]. STDOUT
  # IS DISCARDED ON PURPOSE — see the header: the printed refusal was already correct
  # on the broken build, so reading it proves nothing.
  def recorded_ci_row(gh_mode: nil, injected_ci: nil)
    with_stubs(gh_mode: gh_mode) do |dir, stub_env|
      gate_log = File.join(dir, "gate-calls.log")
      # One argument per line, records separated by a CALL marker: `"$*"` would be
      # unsplittable here, because one of the sop payloads contains spaces inside a
      # JSON string ("cmd":"bin/dor-check … --gate merge").
      gate = write_script(dir, "gate-stub", <<~SH)
        #!/bin/sh
        { printf 'CALL\\n'; for a in "$@"; do printf '%s\\n' "$a"; done; } >> "#{gate_log}"
      SH

      task_path = File.join(dir, "task.json")
      File.write(task_path, JSON.generate(task_fixture))

      env = SessionEnv.neutralized(stub_env.merge(
        "DOR_CHECK_DIFF_ROOT" => File.join(dir, "repo"),
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => CODE_FILE,
        "DOR_CHECK_PR_FILES" => CODE_FILE,
        "DOR_CHECK_CI_STATUS" => injected_ci,
        "DOR_CHECK_GATE_BIN" => gate
      ).compact)

      IO.popen(env, "#{BIN} record-probe --file #{task_path} --gate-role review >/dev/null 2>&1", &:read)

      calls = parse_gate_calls(gate_log)
      [ci_sop_entry(calls), calls]
    end
  end

  # THE EMPTY READ IS REJECTED EXPLICITLY. If the gate recorded nothing — a stub that
  # never ran, a slug that disabled emission, a dor-check that aborted early — every
  # `refute_equal "fail"` in this file would pass on nothing at all, which is the same
  # shape of false green the tests are here to catch. So the absence fails loudly,
  # naming what WAS recorded.
  def ci_sop_entry(calls)
    close = calls.find { |call| call[0] == "close" }
    refute_nil close, "no gate CLOSE was recorded — the record is empty, which proves nothing. Calls: #{calls.inspect}"

    sops = close.each_with_index.filter_map do |arg, i|
      JSON.parse(close[i + 1]) if arg == "--sop-json"
    end
    entry = sops.find { |sop| sop["sop"] == "ci" }
    refute_nil entry, "no {\"sop\":\"ci\"} row was recorded, so nothing here is a verdict about CI. " \
                      "Recorded sops: #{sops.inspect}"
    entry
  end

  def parse_gate_calls(path)
    return [] unless File.exist?(path)

    File.read(path).split("CALL\n").reject(&:empty?).map { |block| block.split("\n") }
  end

  # A backend-shaped task carrying its tiers and a FULL cert claim it cannot honour —
  # the fixture only has to reach the CI row, and the ci row is written on every merge
  # gate verdict, passing or refusing.
  def task_fixture
    {
      "slug" => "record-probe", "title" => "Record Probe",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend", "pr_url" => PR_URL,
        "acceptance" => ["the record tells the causes apart"],
        "repositories" => ["myapp"], "risk_tags" => ["gates"],
        "test_plan" => ["[unit] gate_row", "[integration] the recorded row"],
        "checks_run" => ["[unit] gate_row — 5 runs, 0 failures",
                         "[integration] the recorded row — 4 runs, 0 failures"],
        "post_deploy_cmd" => "none", "local_url" => "http://localhost:3000/x"
      } }
    }
  end

  # A real git tree (the diff resolver needs one) plus the stub `gh` and the stub token
  # broker. `broker` cannot mint, so gh's ORIGINAL answer is what the gate reasons
  # about. NOTE the broker is stubbed even here, where nothing should try to mint: a
  # leaked mint reaches real 1Password, and the point of the "unverified" mode is that
  # it must NOT be classified as an auth failure.
  def with_stubs(gh_mode:)
    Dir.mktmpdir do |dir|
      root = File.join(dir, "repo")
      FileUtils.mkdir_p(File.join(root, File.dirname(CODE_FILE)))
      system("git -C #{root} init -q") || raise("git init failed")
      system("git -C #{root} config user.email t@example.com")
      system("git -C #{root} config user.name t")
      system("git -C #{root} commit -q --allow-empty -m init")
      File.write(File.join(root, CODE_FILE), "class Thing; end\n")

      env = {}
      if gh_mode
        gh = write_script(dir, "gh-stub", gh_stub_body(gh_mode))
        broker = write_script(dir, "gh-token-stub", <<~SH)
          #!/bin/sh
          echo 'no 1Password session' >&2
          exit 1
        SH
        env = { "CI_STATUS_GH_BIN" => gh, "GH_AUTH_TOKEN_BIN" => broker,
                "GH_TOKEN" => "stale-ambient-token" }
      end

      yield(dir, env)
    end
  end

  # The two `gh` worlds, in gh's own words.
  #
  #   none        — `pr view` answers (OPEN, MERGEABLE) and `pr checks` reports no
  #                 checks. CiStatus.parse matches /no checks/ → :none. It dispatches
  #                 on the SUBCOMMAND because both calls happen and they must answer
  #                 differently; a stub that failed both would land :unverified and
  #                 this test would silently be a duplicate of the one below.
  #   unverified  — a transport fault on the FIRST call. It must not match any
  #                 UNREADABLE_CAUSES pattern (no 401/403, no "bad credentials", no
  #                 "requires authentication") or CiStatus classifies it :unreadable,
  #                 which already has its own arm and would make this test inert.
  def gh_stub_body(mode)
    case mode
    when "none"
      <<~SH
        #!/bin/sh
        if [ "$2" = "view" ]; then printf '%s\\n' '#{OPEN_VIEW}'; exit 0; fi
        if [ "$2" = "checks" ]; then echo "no checks reported on the 'feat/probe' branch" >&2; exit 1; fi
        exit 1
      SH
    when "unverified"
      <<~SH
        #!/bin/sh
        echo 'error connecting to api.github.com: dial tcp: lookup api.github.com: no such host' >&2
        exit 1
      SH
    else
      raise ArgumentError, "unknown gh_mode #{mode.inspect}"
    end
  end

  def write_script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end
end
