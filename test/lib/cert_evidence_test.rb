# frozen_string_literal: true

# Unit tests for the machine-owned evidence namespace inside devops.checks_run
# (lib/cert_evidence.rb) — the write rule BOTH the CLI (bin/task) and the board
# (Task#preserve_cert_evidence) enforce, so an author's `--checks` update cannot
# destroy the `test-only` shape's fingerprint-bound control stamp.
#
# ONE LANE IS LEFT. Until DevOps v3 phase 2b (/tasks/retire-local-cert-evidence)
# this namespace also carried the local cert receipts (`[full-suite@fp]`,
# `[rubocop@fp]`, `[fast-cert@fp]`, `[cert-deferred@fp]`). Those writers are gone
# and a leftover line is author prose to this module, which the last tests pin.
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

  def control_line(fp = FP, repo: nil)
    CertEvidence.evidence_line("control", fp, "NECESSARY — replayed test/models/a_test.rb", repo: repo)
  end

  def hub_control(fp = FP)  = control_line(fp, repo: "mcritchie-studio")
  def turf_control(fp = FP) = control_line(fp, repo: "turf-monster")

  # --- the regression: an author --checks update must not wipe the stamp --------

  def test_author_checks_update_preserves_the_control_stamp
    prior = ["[unit] bin/rails test test/models/task_test.rb", control_line]
    incoming = ["[unit] bin/rails test test/models/task_test.rb",
                "[integration] bin/rails test test/controllers"]

    merged = CertEvidence.preserve(prior: prior, incoming: incoming)

    assert_includes merged, control_line, "an author --checks update destroyed the control stamp"
    assert_equal incoming, merged.first(2), "the author's own lines are still replaced verbatim, in order"
  end

  def test_author_update_drops_author_lines_it_omits
    merged = CertEvidence.preserve(prior: ["[unit] stale plan", control_line], incoming: ["[unit] fresh plan"])

    refute_includes merged, "[unit] stale plan", "author lines are author-owned — --checks still REPLACES them"
    assert_includes merged, control_line
  end

  def test_clearing_checks_still_preserves_the_stamp
    assert_equal [control_line], CertEvidence.preserve(prior: ["[unit] plan", control_line], incoming: [])
  end

  def test_preserve_is_idempotent
    lines = ["[unit] plan", control_line]

    assert_equal lines, CertEvidence.preserve(prior: lines, incoming: lines)
  end

  def test_preserve_with_no_prior_evidence_is_a_passthrough
    assert_equal ["[unit] plan"], CertEvidence.preserve(prior: [], incoming: ["[unit] plan"])
    assert_equal ["[unit] plan"], CertEvidence.preserve(prior: nil, incoming: ["[unit] plan"])
  end

  # --- the reverse regression: a pure-evidence write must not wipe the tier tags -

  def test_pure_evidence_write_carries_author_lines
    prior = ["[unit] bin/rails test test/models/task_test.rb",
             "[integration] bin/rails test test/controllers"]

    merged = CertEvidence.preserve(prior: prior, incoming: [control_line])

    assert_equal prior + [control_line], merged,
                 "a pure-evidence control write wiped the builder's tier tags"
  end

  def test_pure_evidence_write_still_supersedes_its_own_lane
    merged = CertEvidence.preserve(prior: ["[unit] plan", control_line(OLD_FP)], incoming: [control_line])

    assert_equal ["[unit] plan", control_line], merged,
                 "carrying the author namespace must not stop a re-run from replacing its own stale stamp"
  end

  # --- THE REPO DIMENSION: a two-repo task keeps a stamp PER REPO ---------------

  def test_stamping_the_second_repo_keeps_the_first_repos_stamp
    after_hub = CertEvidence.preserve(prior: ["[unit] plan"], incoming: [hub_control])
    after_turf = CertEvidence.preserve(prior: after_hub, incoming: [turf_control(OLD_FP)])

    assert_includes after_turf, hub_control, "stamping the second repo destroyed the FIRST repo's stamp"
    assert_includes after_turf, turf_control(OLD_FP)
    assert_includes after_turf, "[unit] plan", "the author namespace still survives an evidence write"
  end

  def test_restamping_one_repo_supersedes_only_that_repo
    prior = ["[unit] plan", hub_control(OLD_FP), turf_control]

    merged = CertEvidence.preserve(prior: prior, incoming: [hub_control])

    assert_includes merged, hub_control
    refute_includes merged, hub_control(OLD_FP), "a re-run must still replace its OWN repo's stale line"
    assert_includes merged, turf_control, "a re-run for one repo must not touch the other repo's stamp"
  end

  def test_a_scoped_write_never_destroys_an_unscoped_stamp
    legacy = control_line(OLD_FP)

    merged = CertEvidence.preserve(prior: [legacy], incoming: [turf_control])
    assert_includes merged, legacy, "a scoped write destroyed an unscoped stamp"

    replaced = CertEvidence.preserve(prior: [legacy], incoming: [control_line])
    refute_includes replaced, legacy, "an UNSCOPED write still supersedes the unscoped slot"
  end

  def test_the_repo_scope_is_parsed_off_the_line
    assert_equal "turf-monster", CertEvidence.repo_of(turf_control)
    assert_nil CertEvidence.repo_of(control_line), "an unscoped line carries no repo"
    assert_nil CertEvidence.repo_of("[unit] bin/rails test"), "a tier tag carries no repo"
    assert_equal %w[control turf-monster], CertEvidence.namespace_of(turf_control)
    assert_equal ["control", nil], CertEvidence.namespace_of(control_line)
    assert_nil CertEvidence.namespace_of("[unit] bin/rails test")
  end

  def test_a_scoped_line_still_parses_lane_and_fingerprint
    assert_equal FP, CertEvidence.extract_fingerprint(turf_control, "control")
    assert_equal "control", CertEvidence.lane_of(turf_control)
    assert_match CertEvidence::EVIDENCE_RE, turf_control
  end

  def test_a_scoped_control_stamp_never_satisfies_the_author_control_tier
    # Why the repo is NOT written as "[control:<repo>@fp]": dor-check's
    # tier_satisfied? terminates a tier tag on `[\]:]`, so that spelling would have
    # let the MACHINE's control stamp satisfy the AUTHOR's required [control] tier.
    stamp = CertEvidence.evidence_line("control", FP, "replayed", repo: "moms-app")
    tier_re = /\A\s*\[\s*control\s*[\]:]/i

    refute_match tier_re, stamp, "a machine control stamp must never read as the author's [control] tier tag"
    assert_match tier_re, "[control] hub_test.rb bites at the diff base"
  end

  def test_scoped_to_answers_per_repo
    assert CertEvidence.scoped_to?(turf_control, "turf-monster")
    refute CertEvidence.scoped_to?(turf_control, "mcritchie-studio")
    assert CertEvidence.scoped_to?(turf_control, "McRitchie-Studio/turf-monster"), "owner-qualified still matches"
    assert CertEvidence.scoped_to?(control_line, "turf-monster"), "an unscoped stamp answers for any repo"
    assert CertEvidence.scoped_to?(turf_control, nil), "a reader naming no repo reads every line"
  end

  # --- lane_status: the grading bin/dor-check does ------------------------------

  def test_lane_status_grades_fresh_stale_and_missing
    assert_equal :fresh, CertEvidence.lane_status([control_line], "control", FP)
    assert_equal :stale, CertEvidence.lane_status([control_line(OLD_FP)], "control", FP)
    assert_equal :missing, CertEvidence.lane_status(["[unit] plan"], "control", FP)
    assert_equal :missing, CertEvidence.lane_status([], "control", FP)
  end

  def test_lane_status_reads_only_the_lines_that_answer_for_the_repo
    checks = [hub_control(OLD_FP), turf_control]

    assert_equal :fresh, CertEvidence.lane_status(checks, "control", FP, repo: "turf-monster")
    assert_equal :stale, CertEvidence.lane_status(checks, "control", FP, repo: "mcritchie-studio"),
                 "the other repo's fresh stamp must not answer for this one"
    assert_equal :fresh, CertEvidence.lane_status(checks, "control", FP),
                 "a reader naming no repo reads every line"
  end

  # --- the coupling #preserve's safety RESTS on, asserted rather than believed ---
  # A pure-evidence write is recognized by CONTENT SHAPE (there is no intent flag
  # on the wire), so the author namespace is protected only while every evidence
  # writer emits lines #lane_of can parse — including the degenerate fingerprints a
  # broken writer might produce.
  def test_every_evidence_line_this_module_builds_is_recognized_as_evidence
    CertEvidence::EVIDENCE_LANES.each do |lane|
      ["abc1234", "0" * 40, "", "not-hex"].each do |fingerprint|
        [nil, "turf-monster", "McRitchie-Studio/turf-monster"].each do |repo|
          line = CertEvidence.evidence_line(lane, fingerprint, "whatever ran", repo: repo)
          assert_equal lane, CertEvidence.lane_of(line),
                       "#{line.inspect} must classify as #{lane} evidence — a writer's line that fails to " \
                       "parse would be treated as an AUTHOR line and could wipe the tier tags"
          next if repo.nil?

          assert_equal repo, CertEvidence.repo_of(line),
                       "#{line.inspect} must carry its repo scope, or #preserve keys it as unscoped"
        end
      end
    end
  end

  # The mixed-write footgun, pinned as KNOWN behavior so a future change has to
  # face it deliberately: evidence + one unparseable line is an AUTHOR write.
  def test_a_mixed_write_is_an_author_write_and_replaces_the_author_namespace
    merged = CertEvidence.preserve(prior: ["[unit] plan"], incoming: [control_line, "warning: junk"])

    refute_includes merged, "[unit] plan",
                    "documented: a write carrying ANY non-evidence line replaces the author namespace — " \
                    "which is why bin/control-check must emit its stamp and nothing else"
    assert_includes merged, control_line
  end

  # --- the retired receipts are author prose now --------------------------------

  def test_the_namespace_holds_the_control_lane_alone
    assert_equal ["control"], CertEvidence::EVIDENCE_LANES,
                 "a new machine-owned lane needs a writer AND a reader; the local cert receipts retired " \
                 "with theirs (/tasks/retire-local-cert-evidence)"
  end

  def test_a_leftover_cert_receipt_is_author_owned
    receipts = ["[fast-cert@#{OLD_FP}] fast cert green", "[full-suite@#{OLD_FP}] bin/rails test",
                "[rubocop@#{OLD_FP}] clean", "[cert-deferred@#{OLD_FP}] capped", "[full-suite-bypass] outage"]
    receipts.each do |line|
      assert_nil CertEvidence.lane_of(line), "#{line.inspect} names a lane nothing records any more"
    end

    merged = CertEvidence.preserve(prior: receipts + [control_line], incoming: ["[unit] fresh plan"])
    assert_equal ["[unit] fresh plan", control_line], merged,
                 "an author --checks update clears a leftover receipt like any other author line, and " \
                 "still carries the control stamp"
  end

  def test_lane_of_reads_the_lane_from_an_evidence_line
    assert_equal "control", CertEvidence.lane_of(control_line)
    assert_nil CertEvidence.lane_of("[unit] bin/rails test"), "a tier tag is NOT evidence"
    assert_nil CertEvidence.lane_of("[control] hub_test.rb bites"), "the author's [control] tier tag is NOT evidence"
  end
end
