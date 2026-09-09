# frozen_string_literal: true

# THE DURABLE GATE RECORD, when the token expired mid-gate. Standalone (no Rails —
# it shells bin/dor-check with --file fixtures):
#   ruby -Itest test/lib/gate_record_unreadable_ci_test.rb
#
# THE DEFECT (/tasks/gate-logs-auth-as-red). A `dor_review` gate-zero whose GitHub
# read was REFUSED on credentials closed its attempt with the sops row
#
#   {"sop":"ci","result":"fail","state":"unreadable","cause":"credentials", ...}
#
# and both readers of that record show `result` alone — `bin/gate show` prints
# `ci:fail`, and the task's gates card paints a rose ✗. So the task's PERMANENT gate
# history said a red CI bounced this PR. The PR's CI was never red. Nobody read it.
#
# WHY IT IS WORSE THAN A MISPRINT. Installation tokens live ~1 hour BY DESIGN in
# this fleet, so this is not a race — every gate run straddling an expiry wrote one,
# into the one artifact a later auditor has left after Heroku's log retention is
# gone. And it inverts the usual direction: the rest of CiGate's decision table
# guards against a green credited for work nobody verified; this row MANUFACTURED a
# failure.
#
# THE VOCABULARY IS NOT NEW. CiStatus.gate_evidence has ridden `state:"unreadable"`
# + cause + reason into this very entry since PR #865, and
# /tasks/builder-reads-remedy-twice established UNREADABLE as distinct from no-CI in
# the refusal prose. Only `result` — the field the readers render — collapsed it.
#
# WHY THESE TESTS READ THE RECORD AND NOT STDOUT. A gate that PRINTS the right thing
# and STORES the wrong thing is precisely this defect: dor-check's stdout already
# said "GitHub CI is UNREADABLE … CREDENTIAL fault, NOT a missing CI" in full while
# the row it persisted said fail. Asserting the printed refusal would have passed on
# the broken build. So every integration test here recovers the argv the gate CLI
# was actually handed, parses the `{"sop":"ci"}` entry out of it, and asserts on
# that — and refuses to conclude anything when no such entry was recorded at all
# (an absent row is not a passing row; see ci_sop_entry's guard).
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../bin/lib/ci_gate"

class GateRecordUnreadableCiTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/77"
  CODE_FILE = "app/models/thing.rb"

  # ── [unit] the decision table ───────────────────────────────────────────────
  #
  # Pure: no subprocess, no ENV, no board. `gate_row` is the single function that
  # names the ci row, shared by the gated and the exempt path, so the states it
  # must keep apart are asserted here directly rather than inferred from prose.

  def test_unit_a_refused_read_is_recorded_as_unreadable_not_as_a_failure
    assert_equal "unreadable", CiGate.gate_row({ state: :unreadable }, review_role: true, review_refused: true),
                 "a token the gate could not use is not a CI that failed"
  end

  # The SAME fact in the builder role, where the old answer was "unverified" — a
  # value the gates card paints with the pass glyph. One fact, one name, whoever
  # asked: a record is read later by someone who was not here.
  def test_unit_the_builder_role_names_it_the_same_way
    assert_equal "unreadable", CiGate.gate_row({ state: :unreadable }, review_role: false, review_refused: false)
    assert_equal "unreadable", CiGate.gate_row({ state: :unreadable }, review_role: true, review_refused: false)
  end

  # THE OTHER HALF OF "DISTINGUISHES BOTH CAUSES". If :red also stopped saying
  # "fail", the record would be uniformly honest and uniformly useless.
  def test_unit_a_genuinely_red_ci_still_records_a_failure
    assert_equal "fail", CiGate.gate_row({ state: :red }, review_role: true, review_refused: true)
    assert_equal "fail", CiGate.gate_row({ state: :ci_less }, review_role: true, review_refused: true)
    assert_equal "fail", CiGate.gate_row({ state: :conflicted }, review_role: true, review_refused: true)
  end

  # THIS TEST PINNED THE DEFECT ITS OWN PREMISE FORBADE, and it is kept (renamed,
  # corrected) rather than deleted so the correction is legible.
  #
  # The premise was right: :none ("nothing reported"), :unverified ("gh itself fell
  # over") and :unreadable ("GitHub refused my credential") are three different
  # non-answers, and the row stays 1:1 with the CI state. The assertions said the
  # opposite — they froze :none and :unverified onto the SAME flat "fail" a genuinely
  # red CI writes, which is neither 1:1 nor a non-answer. Scoping the arm to
  # :unreadable left two thirds of the family manufacturing a failure in permanent
  # gate history, and this test held that in place until 2026-09-09.
  #
  # Corrected by /tasks/refused-review-records-fail, which gave the other two their own
  # arms by this file's own rule. Their coverage — the live chain, the persisted argv,
  # the distinctness invariant — is in test/lib/gate_record_no_verdict_ci_test.rb; what
  # stays here is the neighbour check that this file's :unreadable arm did not swallow
  # them.
  def test_unit_the_rest_of_the_no_verdict_family_names_itself_too
    none = CiGate.gate_row({ state: :none }, review_role: true, review_refused: true)
    unverified = CiGate.gate_row({ state: :unverified }, review_role: true, review_refused: true)

    assert_equal CiGate::GATE_ROW_NO_CHECKS, none
    assert_equal CiGate::GATE_ROW_UNVERIFIED, unverified
    refute_equal CiGate::GATE_ROW_UNREADABLE, none, "the :unreadable arm must not swallow its neighbours"
    refute_equal CiGate::GATE_ROW_UNREADABLE, unverified
    assert_equal none, CiGate.gate_row({ state: :none }, review_role: false, review_refused: false),
                 "one fact, one name, whoever asked — the rule the :unreadable arm above is written to"
    assert_equal "pass", CiGate.gate_row({ state: :green }, review_role: true, review_refused: false)
  end

  # ── [integration] what actually lands in the record ─────────────────────────

  # THE HEADLINE. The 401 is delivered by a stub `gh` through CiStatus's own seam —
  # no DOR_CHECK_CI_STATUS injection — so the whole live chain runs: subprocess,
  # stderr capture, GhAuthRetry classification, the mint that cannot happen, and the
  # verdict. That is the chain an expired installation token walks at 11:05 on a PR
  # that read fine at 10:00, and it is the only way to prove the classifier's answer
  # reaches the persisted row rather than only the printed one.
  def test_integration_a_credential_refusal_records_unreadable_in_the_gate_record
    entry, = recorded_ci_row(gh_mode: "hard401")

    assert_equal "unreadable", entry["result"],
                 "the PERMANENT record must not call an unread CI a failed one — got #{entry.inspect}"
    refute_equal "fail", entry["result"], "this is the false red the task exists to remove"
    assert_equal "unreadable", entry["state"]
    assert_equal "credentials", entry["cause"],
                 "the cause GitHub actually gave has ridden this row since PR #865 — it must survive"
    assert_match(/Bad credentials/, entry["reason"].to_s)
    assert_equal "McRitchie-Studio/myapp", entry["repo"]
  end

  # THE CONTROL, and the second acceptance criterion: a real red CI must still be
  # distinguishable IN THE RECORD from a read that never happened. Without this the
  # fix could have been "stop writing fail" and nobody would notice.
  def test_integration_a_red_ci_still_records_fail_so_the_two_causes_differ
    unreadable, = recorded_ci_row(gh_mode: "hard401")
    red, = recorded_ci_row(injected_ci: "red")

    assert_equal "fail", red["result"], "a CI that ran and failed is still a failure"
    refute_equal red["result"], unreadable["result"],
                 "the record must tell 'CI is red' from 'I could not read CI' — that is the whole bug"
    assert_nil red["state"], "gate_evidence rides only the unreadable row, so a red row carries no state"
  end

  # NOT AN OVER-CORRECTION. The review gate-zero still REFUSED — it cannot be the
  # authoritative CI verdict on a CI it never saw — so the ATTEMPT stays FAILED.
  # Only the ci row's NAME changed. Turning this attempt green would swap a
  # manufactured failure for a manufactured success, which is the direction every
  # other defect in this family runs.
  def test_integration_the_attempt_itself_still_closes_failed
    _entry, calls = recorded_ci_row(gh_mode: "hard401")
    close = calls.find { |call| call[0] == "close" }

    assert close, "the gate must still record an attempt — got #{calls.inspect}"
    assert_includes close, "--failed",
                     "an unread CI does not clear the review gate-zero; only its recorded CAUSE changed"
    assert_includes close, "dor_review", "the review role closes dor_review, not dor"
  end

  # ── harness ─────────────────────────────────────────────────────────────────

  # Drives one `bin/dor-check <slug> --gate-role review` with the gate CLI redirected
  # to a recording stub, and returns [the ci sops entry, every recorded call].
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
  # the fixture only has to reach the CI row, and the ci row is written on every
  # merge-gate verdict, passing or refusing.
  def task_fixture
    {
      "slug" => "record-probe", "title" => "Record Probe",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend", "pr_url" => PR_URL,
        "acceptance" => ["the record tells the two causes apart"],
        "repositories" => ["myapp"], "risk_tags" => ["gates"],
        "test_plan" => ["[unit] gate_row", "[integration] the recorded row"],
        "checks_run" => ["[unit] gate_row — 4 runs, 0 failures",
                         "[integration] the recorded row — 3 runs, 0 failures"],
        "post_deploy_cmd" => "none", "local_url" => "http://localhost:3000/x"
      } }
    }
  end

  # A real git tree (the diff resolver needs one) plus the stub `gh` and the stub
  # token broker. `broker` cannot mint, so gh's ORIGINAL refusal is what the gate has
  # to reason about — the live shape when 1Password is locked or the quota is spent.
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
        gh = write_script(dir, "gh-stub", <<~SH)
          #!/bin/sh
          echo 'gh: Bad credentials (HTTP 401)' >&2
          exit 1
        SH
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

  def write_script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end
end
