# frozen_string_literal: true

# Unit tests for the machine-owned evidence namespace inside devops.checks_run
# (lib/cert_evidence.rb) — the write rule BOTH the CLI (bin/task) and the board
# (Task#preserve_cert_evidence) enforce, so an author's `--checks` update can no
# longer destroy a fingerprint-bound certification.
#
# Pure functions over string lists — nothing shells out, nothing boots Rails.
#
#   ruby -Itest test/lib/cert_evidence_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../lib/cert_evidence"

class CertEvidenceTest < Minitest::Test
  FP = "1512171634558ef1234567890abcdef123456789"
  OLD_FP = "0000000000000000000000000000000000000000"

  def full_line(fp = FP)    = "[full-suite@#{fp}] bin/rails test (782 runs, 0 failures)"
  def rubocop_line(fp = FP) = "[rubocop@#{fp}] bin/rubocop (clean)"
  def fast_line(fp = FP)    = "[fast-cert@#{fp}] fast cert green: 4 mapped + 3 spine test path(s)"

  # --- the regression: an author --checks update must not wipe the cert ---

  def test_author_checks_update_preserves_every_evidence_lane
    prior = ["[unit] bin/rails test test/models/task_test.rb", full_line, rubocop_line]
    incoming = ["[unit] bin/rails test test/models/task_test.rb",
                "[integration] bin/rails test test/controllers"]

    merged = CertEvidence.preserve(prior: prior, incoming: incoming)

    assert_includes merged, full_line, "an author --checks update destroyed the full-suite evidence"
    assert_includes merged, rubocop_line, "an author --checks update destroyed the rubocop evidence"
    assert_equal incoming, merged.first(2), "the author's own lines are still replaced verbatim, in order"
  end

  def test_author_update_preserves_fast_cert_evidence
    merged = CertEvidence.preserve(prior: [fast_line, "[unit] old"], incoming: ["[unit] new"])

    assert_equal ["[unit] new", fast_line], merged
  end

  def test_author_update_drops_author_lines_it_omits
    merged = CertEvidence.preserve(prior: ["[unit] stale plan", full_line], incoming: ["[unit] fresh plan"])

    refute_includes merged, "[unit] stale plan", "author lines are author-owned — --checks still REPLACES them"
    assert_includes merged, full_line
  end

  # A bypass is an author RECORD, not machine evidence: it must stay removable,
  # or a task could never leave a recorded bypass behind.
  def test_bypass_record_is_author_owned_and_not_forcibly_preserved
    merged = CertEvidence.preserve(prior: ["[full-suite-bypass] infra outage", full_line],
                                   incoming: ["[unit] bin/rails test"])

    refute_includes merged, "[full-suite-bypass] infra outage"
    assert_includes merged, full_line
  end

  # --- lane-scoped supersede: you may only overwrite a lane you SUPPLY ---

  def test_supplying_a_lane_supersedes_that_lane_only
    prior = ["[unit] plan", full_line(OLD_FP), rubocop_line(OLD_FP)]

    merged = CertEvidence.preserve(prior: prior, incoming: ["[unit] plan", full_line])

    assert_includes merged, full_line, "the fresh full-suite line wins"
    refute_includes merged, full_line(OLD_FP), "the superseded full-suite line is gone"
    assert_includes merged, rubocop_line(OLD_FP), "an unaddressed lane is carried over untouched"
  end

  def test_preserve_is_idempotent
    lines = ["[unit] plan", full_line, rubocop_line]

    assert_equal lines, CertEvidence.preserve(prior: lines, incoming: lines)
  end

  def test_preserve_with_no_prior_evidence_is_a_passthrough
    assert_equal ["[unit] plan"], CertEvidence.preserve(prior: [], incoming: ["[unit] plan"])
    assert_equal ["[unit] plan"], CertEvidence.preserve(prior: nil, incoming: ["[unit] plan"])
  end

  # An emptied list still cannot take the cert down with it.
  def test_clearing_checks_still_preserves_evidence
    assert_equal [full_line], CertEvidence.preserve(prior: ["[unit] plan", full_line], incoming: [])
  end

  # --- the reverse regression (2026-07-20, fast-check-preserves-checks): a CERT
  # WRITER's pure-evidence write must not wipe the author's tier tags. bin/fast-check
  # read the task's checks_run to merge, the read missed the builder's freshly
  # recorded tier lines, and its update then carried ONLY the evidence line — and
  # preserve let it supersede the whole author namespace with nothing, while the
  # script's output claimed "tier tags preserved". The rule is now symmetric: a
  # writer supersedes ONLY a namespace it supplies lines for, and the author
  # namespace counts as a namespace. (An explicitly EMPTY incoming list keeps its
  # documented meaning — a deliberate author-namespace clear — see below.)

  def test_pure_evidence_fast_write_carries_author_lines
    prior = ["[unit] bin/rails test test/models/task_test.rb",
             "[integration] bin/rails test test/controllers"]

    merged = CertEvidence.preserve(prior: prior, incoming: [fast_line])

    assert_equal prior + [fast_line], merged,
                 "a pure-evidence fast-cert write wiped the builder's tier tags"
  end

  def test_pure_evidence_full_write_carries_author_lines_and_unaddressed_lanes
    prior = ["[unit] plan", "[full-suite-bypass] infra outage", fast_line(OLD_FP)]

    merged = CertEvidence.preserve(prior: prior, incoming: [full_line, rubocop_line])

    assert_includes merged, "[unit] plan", "tier tag wiped by a pure-evidence full-cert write"
    assert_includes merged, "[full-suite-bypass] infra outage",
                    "the bypass record is author-owned — a pure-evidence write addresses no author line"
    assert_includes merged, fast_line(OLD_FP), "an unaddressed evidence lane is still carried"
    assert_includes merged, full_line
    assert_includes merged, rubocop_line
  end

  def test_pure_evidence_write_still_supersedes_its_own_lane
    merged = CertEvidence.preserve(prior: ["[unit] plan", fast_line(OLD_FP)], incoming: [fast_line])

    assert_equal ["[unit] plan", fast_line], merged,
                 "carrying the author namespace must not stop a re-cert from replacing its own stale line"
  end

  # --- the format contract (moved out of FullSuiteGate, must stay identical) ---

  def test_lane_of_reads_the_lane_from_an_evidence_line
    assert_equal "full-suite", CertEvidence.lane_of(full_line)
    assert_equal "rubocop", CertEvidence.lane_of(rubocop_line)
    assert_equal "fast-cert", CertEvidence.lane_of(fast_line)
    assert_nil CertEvidence.lane_of("[unit] bin/rails test"), "a tier tag is NOT evidence"
    assert_nil CertEvidence.lane_of("[full-suite-bypass] infra outage"), "a bypass record is NOT evidence"
  end

  def test_merge_evidence_supersedes_only_the_lanes_supplied
    existing = ["[unit] plan", full_line(OLD_FP), rubocop_line(OLD_FP), fast_line(OLD_FP)]

    merged = CertEvidence.merge_evidence(existing, [full_line, rubocop_line])

    assert_equal ["[unit] plan", fast_line(OLD_FP), full_line, rubocop_line], merged
  end

  def test_merge_evidence_honors_an_explicit_lane_list
    existing = ["[unit] plan", full_line, rubocop_line, fast_line(OLD_FP)]

    merged = CertEvidence.merge_evidence(existing, [fast_line], lanes: [CertEvidence::FAST_LANE])

    assert_equal ["[unit] plan", full_line, rubocop_line, fast_line], merged
  end
end
