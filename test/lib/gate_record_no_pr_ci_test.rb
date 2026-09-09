# frozen_string_literal: true

# THE DURABLE GATE RECORD when there is NO PR AT ALL. Standalone (no Rails — it shells
# bin/dor-check with --file fixtures):
#   ruby -Itest test/lib/gate_record_no_pr_ci_test.rb
#
# THE DEFECT (/tasks/no-pr-records-as-fail). A blank devops.pr_url resolves to :no_pr,
# which rode CiGate.gate_row's `else` — the last NAMED state to do so after
# /tasks/gate-logs-auth-as-red and /tasks/refused-review-records-fail took the
# no-verdict family off it. The `else` answers differently depending on who asked, so
# ONE world was written TWO wrong ways:
#
#   review role  → {"sop":"ci","result":"fail"}        a red-CI bounce for a PR that
#                                                      does not exist
#   builder role → {"sop":"ci","result":"unverified"}  collides with the state where
#                                                      `gh` genuinely fell over
#
# MEASURED THROUGH THE LIVE CHAIN BEFORE THE FIX (2026-09-09), with a genuinely blank
# pr_url and no injection — both rows above, verbatim.
#
# THE BUILDER HALF IS THE SHARPER ONE, and it is why this is not an edge case:
# `bin/dor-check` runs BEFORE the PR exists, so :no_pr is the ORDINARY submit-side
# state. Submit-side the gate is silent on stdout by design (it re-runs after the
# push) — but it still wrote a durable row, and "unverified" is not a neutral word:
# /tasks/refused-review-records-fail gave it a documented REMEDY, "`gh` fell over —
# re-read, do NOT chase a credential" (docs/agents/modules/gates/g2-review.md). For a
# task whose PR is simply not open yet the fix is to PUSH ONE. So the record did not
# merely mislabel the state, it prescribed the wrong move, silently, on the common path.
#
# THE DESIGN QUESTION, ANSWERED HERE BECAUSE THE TESTS ENCODE THE ANSWER. The sharper
# framing raised with this task was not "which value" but whether an absent PR belongs
# under the `ci` sop at all — :none and :unverified are answers ABOUT CI, while :no_pr is
# the absence of the thing CI would answer about. That distinction is REAL and it is
# honoured, but it lands on a different set than it first appears to:
#
#   * :no_pr records a no-verdict ROW      (GATE_ROW_NO_VERDICT — paint it ⚠)
#   * :no_pr is NOT in CI_NO_VERDICT_STATES (the family a FULL local cert may stand in
#     for — a cert cannot conjure a PR)
#
# Both are pinned below, because the whole risk of this change is collapsing them back
# together: admitting :no_pr to the cert-waiver family would let a task with NO PR
# advance a review, the worst false green this gate can produce.
#
# WHY NOT OMIT THE ROW — the alternative that was seriously considered. Three reasons,
# each measured: (1) both callers append on `if ci`, not on gate_row's return
# (bin/dor-check:3930 and :2777), so a nil persists `"result":null`, and `nil.to_s` is
# "" — which falls to the gates card's ✓ DEFAULT, i.e. the omission route's failure mode
# IS the inversion trap; (2) an absent ci row already MEANS something else — `--gate
# build` writes none (bin/dor-check:3101); (3) omitting would make the fleet's most
# common gate run indistinguishable from a build gate and from a run that aborted early.
#
# WHY THESE TESTS READ THE RECORD AND NOT STDOUT. The review path's stdout printed the
# correct refusal in full ("devops.pr_url is BLANK…") while the row it persisted said
# `fail`, so an assertion on the printed refusal passes on the broken build. Every
# integration test here recovers the argv the gate CLI was actually handed and asserts
# on the `{"sop":"ci"}` entry parsed out of it — and refuses to conclude anything when
# no such entry was recorded at all (see ci_sop_entry).
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../bin/lib/ci_gate"

class GateRecordNoPrCiTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/77"
  CODE_FILE = "app/models/thing.rb"

  # ── [unit] the decision table ───────────────────────────────────────────────

  # THE HEADLINE. A review refused because there is no PR must not write a red CI into
  # the permanent record.
  def test_unit_a_missing_pr_is_not_recorded_as_a_ci_failure
    row = CiGate.gate_row({ state: :no_pr }, review_role: true, review_refused: true)

    assert_equal CiGate::GATE_ROW_NO_PR, row
    refute_equal "fail", row, "there was no PR, so there was no CI, so there was no red"
  end

  # THE OTHER FACE, and the normal path. Submit-side this recorded "unverified" — the
  # word reserved for `gh` falling over, whose recorded remedy is "re-read, do NOT chase
  # a credential". A builder with no PR yet must not be handed that instruction.
  def test_unit_the_builder_role_records_no_pr_rather_than_colliding_with_unverified
    builder = CiGate.gate_row({ state: :no_pr }, review_role: false, review_refused: false)

    assert_equal CiGate::GATE_ROW_NO_PR, builder
    refute_equal CiGate::GATE_ROW_UNVERIFIED, builder,
                 "`gh` fell over and `there is no PR` prescribe different moves"
    assert_equal CiGate.gate_row({ state: :no_pr }, review_role: true, review_refused: true), builder,
                 "whether a PR exists is a fact about the WORLD, not about who asked"
    assert_equal builder, CiGate.gate_row({ state: :no_pr }, review_role: true, review_refused: false)
  end

  # DISTINGUISHABLE FROM EVERY OTHER CAUSE. `result` is the whole record for these
  # states (CiStatus.gate_evidence rides state/cause/reason onto the :unreadable row
  # alone), so a shared value is an unrecoverable fact.
  def test_unit_no_pr_is_distinguishable_from_every_other_no_verdict_cause
    rows = %i[none unreadable unverified no_pr].map do |state|
      CiGate.gate_row({ state: state }, review_role: true, review_refused: true)
    end

    assert_equal 4, rows.uniq.size, "two causes share one row value: #{rows.inspect}"
    refute_includes rows, "fail"
  end

  # THE INVERSION TRAP, at the unit seam. The gates card's glyph chain ends in a ✓
  # DEFAULT, so a new result value that is not in this set is painted as a PASS —
  # trading a manufactured failure for a manufactured success. The card arm tests the
  # SET, so this membership is what makes the glyph correct.
  def test_unit_the_row_value_is_one_the_card_paints_amber
    assert_includes CiGate::GATE_ROW_NO_VERDICT,
                    CiGate.gate_row({ state: :no_pr }, review_role: true, review_refused: true),
                    "a value outside this set reaches the card's ✓ default and reads as a PASS"
  end

  # THE RULING'S OTHER HALF, and the assertion that stops this fix from becoming a far
  # worse bug. The row is amber, but the REFUSAL is still uncertifiable: :no_pr must
  # stay OUT of the family a full local cert stands in for, or a task with no PR at all
  # would advance a review on tier 2 of the allow-list.
  def test_unit_a_missing_pr_is_still_not_something_a_cert_can_clear
    refute_includes CiGate::CI_NO_VERDICT_STATES, :no_pr,
                    "a cert may stand in for missing EVIDENCE about a PR, never for a missing PR"

    _message, cert_clears = CiGate.unread_ci_refusal({ state: :no_pr }, "", "probe", cert_route: true)

    refute cert_clears, "review's job is to merge a PR; the missing thing is the SUBJECT, not the evidence"
  end

  # ── [integration] what actually lands in the record ─────────────────────────

  # THE REVIEW FACE, through the live chain. stdout is discarded on purpose.
  def test_integration_a_review_with_no_pr_records_no_pr_in_the_gate_record
    entry, = recorded_ci_row(role: :review, pr_url: "")

    assert_equal CiGate::GATE_ROW_NO_PR, entry["result"]
    refute_equal "fail", entry["result"],
                 "the permanent gate history would claim a red-CI bounce for a PR that never existed"
  end

  # THE BUILDER FACE — the common path, and the one that was silently wrong.
  def test_integration_a_builder_with_no_pr_records_no_pr_in_the_gate_record
    entry, = recorded_ci_row(role: :builder, pr_url: "")

    assert_equal CiGate::GATE_ROW_NO_PR, entry["result"]
    refute_equal CiGate::GATE_ROW_UNVERIFIED, entry["result"],
                 "submit-side this collided with `gh fell over`, whose recorded remedy is the wrong move here"
  end

  # THE COLLISION, PROVEN APART IN THE RECORD. Both runs refuse; the rows must differ.
  # Without this the fix could regress to one honest-looking word for two worlds.
  def test_integration_the_record_tells_no_pr_apart_from_a_genuine_gh_failure
    no_pr, = recorded_ci_row(role: :builder, pr_url: "")
    unverified, = recorded_ci_row(role: :builder, pr_url: PR_URL, gh_mode: "unverified")

    assert_equal CiGate::GATE_ROW_NO_PR, no_pr["result"]
    assert_equal CiGate::GATE_ROW_UNVERIFIED, unverified["result"]
    refute_equal no_pr["result"], unverified["result"],
                 "`push a PR` and `re-read, gh fell over` are different instructions"
  end

  # THE GATE SEMANTICS ARE UNCHANGED, which is the claim a reader will most want
  # checked: this task renamed a ROW, it did not soften a gate. The attempt still
  # closes FAILED, so a missing PR still refuses the review.
  def test_integration_the_attempt_itself_still_closes_failed
    _entry, calls = recorded_ci_row(role: :review, pr_url: "")
    close = calls.find { |call| call[0] == "close" }

    assert_includes close, "--failed", "a review with no PR must still refuse"
    assert_includes close, "dor_review", "the review role closes dor_review, not dor"
  end

  # ── harness ─────────────────────────────────────────────────────────────────

  # Drives one bin/dor-check with the gate CLI redirected to a recording stub, and
  # returns [the ci sops entry, every recorded call]. STDOUT IS DISCARDED ON PURPOSE —
  # see the header: the printed refusal was already correct on the broken build.
  def recorded_ci_row(role:, pr_url:, gh_mode: nil)
    with_stubs(gh_mode: gh_mode) do |dir, stub_env|
      gate_log = File.join(dir, "gate-calls.log")
      # One argument per line, records separated by a CALL marker: `"$*"` would be
      # unsplittable here, because one sop payload contains spaces inside a JSON string.
      gate = write_script(dir, "gate-stub", <<~SH)
        #!/bin/sh
        { printf 'CALL\\n'; for a in "$@"; do printf '%s\\n' "$a"; done; } >> "#{gate_log}"
      SH

      task_path = File.join(dir, "task.json")
      File.write(task_path, JSON.generate(task_fixture(pr_url)))

      env = SessionEnv.neutralized(stub_env.merge(
        "DOR_CHECK_DIFF_ROOT" => File.join(dir, "repo"),
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => CODE_FILE,
        "DOR_CHECK_PR_FILES" => CODE_FILE,
        "DOR_CHECK_GATE_BIN" => gate
      ).compact)

      cmd = +"#{BIN} record-probe --file #{task_path}"
      cmd << " --gate-role review" if role == :review
      IO.popen(env, "#{cmd} >/dev/null 2>&1", &:read)

      calls = parse_gate_calls(gate_log)
      [ci_sop_entry(calls), calls]
    end
  end

  # THE EMPTY READ IS REJECTED EXPLICITLY. If the gate recorded nothing — a stub that
  # never ran, a dor-check that aborted early — every `refute_equal "fail"` above would
  # pass on nothing at all, the same shape of false green these tests exist to catch.
  def ci_sop_entry(calls)
    close = calls.find { |call| call[0] == "close" }
    refute_nil close, "no gate CLOSE was recorded — the record is empty, which proves nothing. " \
                      "Calls: #{calls.inspect}"

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

  # A backend-shaped task carrying its tiers. `pr_url` is the variable under test: blank
  # is the :no_pr world, and it reaches CiStatus.evaluate's `return {state: :no_pr} if
  # pr.empty?` through the REAL path, with nothing injected.
  def task_fixture(pr_url)
    {
      "slug" => "record-probe", "title" => "Record Probe",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend", "pr_url" => pr_url,
        "acceptance" => ["an absent PR is not a CI failure"],
        "repositories" => ["myapp"], "risk_tags" => ["gates"],
        "test_plan" => ["[unit] gate_row", "[integration] the recorded row"],
        "checks_run" => ["[unit] gate_row — 6 runs, 0 failures",
                         "[integration] the recorded row — 4 runs, 0 failures"],
        "post_deploy_cmd" => "none", "local_url" => "http://localhost:3000/x"
      } }
    }
  end

  # A real git tree (the diff resolver needs one) plus, when a gh world is asked for,
  # the stub `gh` and a stub token broker. The broker cannot mint, so gh's ORIGINAL
  # answer is what the gate reasons about; it is stubbed even where nothing should try
  # to mint, because a leaked mint reaches real 1Password.
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

  # A transport fault on the first call. It must NOT match any UNREADABLE_CAUSES pattern
  # (no 401/403, no "bad credentials", no "requires authentication") or CiStatus
  # classifies it :unreadable — which has its own arm, and would make the collision test
  # above compare :no_pr against the wrong neighbour.
  def gh_stub_body(mode)
    raise ArgumentError, "unknown gh_mode #{mode.inspect}" unless mode == "unverified"

    <<~SH
      #!/bin/sh
      echo 'error connecting to api.github.com: dial tcp: lookup api.github.com: no such host' >&2
      exit 1
    SH
  end

  def write_script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end
end
