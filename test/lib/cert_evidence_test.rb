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

  # --- THE REPO DIMENSION: a two-repo task keeps a cert PER REPO ----------------
  #
  # The defect (2026-08-13): the namespace was the LANE alone, so on a task naming
  # two repos the SECOND repo's cert silently erased the FIRST's, and dor-check then
  # called a genuinely green cert STALE. These assert the PROPERTY — both certs
  # survive — rather than "a cert was recorded", which passes blind: recording one
  # cert was never the broken part.

  def hub_full(fp = FP)  = CertEvidence.evidence_line("full-suite", fp, "bin/rails test (6034 runs, 0 failures)", repo: "mcritchie-studio")
  def turf_full(fp = FP) = CertEvidence.evidence_line("full-suite", fp, "bin/rails test (2041 runs, 0 failures)", repo: "turf-monster")

  def test_certifying_the_second_repo_keeps_the_first_repos_cert
    # The NATURAL order — root repo first, satellite second — which is exactly the
    # order that used to lose evidence. (The undocumented workaround was to certify
    # satellites first and the dor-check root repo last.)
    after_hub = CertEvidence.preserve(prior: ["[unit] plan"], incoming: [hub_full])
    after_turf = CertEvidence.preserve(prior: after_hub, incoming: [turf_full(OLD_FP)])

    assert_includes after_turf, hub_full,
                    "certifying the second repo destroyed the FIRST repo's cert — the whole bug"
    assert_includes after_turf, turf_full(OLD_FP)
    assert_includes after_turf, "[unit] plan", "the author namespace still survives an evidence write"
  end

  def test_recertifying_one_repo_supersedes_only_that_repo
    prior = ["[unit] plan", hub_full(OLD_FP), turf_full]

    merged = CertEvidence.preserve(prior: prior, incoming: [hub_full])

    assert_includes merged, hub_full, "the fresh cert must be stored"
    refute_includes merged, hub_full(OLD_FP), "a re-cert must still replace its OWN repo's stale line"
    assert_includes merged, turf_full, "a re-cert of one repo must not touch the other repo's cert"
  end

  def test_an_author_checks_update_preserves_every_repos_cert
    prior = ["[unit] old", hub_full, turf_full(OLD_FP)]

    merged = CertEvidence.preserve(prior: prior, incoming: ["[unit] new", "[integration] new"])

    assert_includes merged, hub_full
    assert_includes merged, turf_full(OLD_FP)
  end

  def test_a_scoped_write_never_destroys_an_unscoped_legacy_cert
    # An unscoped line's repo is UNKNOWABLE, so retiring it on a scoped write could
    # destroy the other repo's evidence — the bug, one rollout later. It is its own
    # namespace: only an unscoped write supersedes it.
    legacy = full_line(OLD_FP)

    merged = CertEvidence.preserve(prior: [legacy], incoming: [turf_full])
    assert_includes merged, legacy, "a scoped cert write destroyed an unscoped cert"

    replaced = CertEvidence.preserve(prior: [legacy], incoming: [full_line])
    refute_includes replaced, legacy, "an UNSCOPED write still supersedes the unscoped slot"
  end

  def test_the_repo_scope_is_parsed_off_the_line
    assert_equal "turf-monster", CertEvidence.repo_of(turf_full)
    assert_nil CertEvidence.repo_of(full_line), "an unscoped line carries no repo"
    assert_nil CertEvidence.repo_of("[unit] bin/rails test"), "a tier tag carries no repo"
    assert_equal ["full-suite", "turf-monster"], CertEvidence.namespace_of(turf_full)
    assert_equal ["full-suite", nil], CertEvidence.namespace_of(full_line)
    assert_nil CertEvidence.namespace_of("[unit] bin/rails test")
  end

  def test_a_scoped_line_still_parses_for_every_pre_repo_reader
    # The repo rides AFTER the fingerprint precisely so this holds: a checkout that
    # predates the repo dimension reads a scoped line as a correct lane+fingerprint,
    # so neither direction of the rollout can manufacture a false STALE.
    assert_equal FP, CertEvidence.extract_fingerprint(turf_full, "full-suite")
    assert_equal "full-suite", CertEvidence.lane_of(turf_full)
    assert_match CertEvidence::EVIDENCE_RE, turf_full
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
    assert CertEvidence.scoped_to?(turf_full, "turf-monster")
    refute CertEvidence.scoped_to?(turf_full, "mcritchie-studio")
    assert CertEvidence.scoped_to?(turf_full, "McRitchie-Studio/turf-monster"), "owner-qualified still matches"
    assert CertEvidence.scoped_to?(full_line, "turf-monster"), "an unscoped cert answers for any repo"
    assert CertEvidence.scoped_to?(turf_full, nil), "a reader naming no repo reads every line"
  end

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

  # --- the coupling #preserve's safety RESTS on, asserted rather than believed ---
  # A pure-evidence write is recognized by CONTENT SHAPE (there is no intent flag
  # on the wire), so the author namespace is protected only while every evidence
  # writer emits lines #lane_of can parse. Pin that: #evidence_line output must
  # classify as evidence for EVERY lane, including the degenerate fingerprints a
  # broken writer might produce — #lane_of is prefix-keyed precisely so a
  # malformed fingerprint still counts as evidence instead of silently becoming
  # an "author" line that licenses a wipe.
  def test_every_evidence_line_this_module_builds_is_recognized_as_evidence
    CertEvidence::EVIDENCE_LANES.each do |lane|
      ["abc1234", "0" * 40, "", "not-hex"].each do |fingerprint|
        [nil, "turf-monster", "McRitchie-Studio/turf-monster"].each do |repo|
          line = CertEvidence.evidence_line(lane, fingerprint, "whatever ran", repo: repo)
          assert_equal lane, CertEvidence.lane_of(line),
                       "#{line.inspect} must classify as #{lane} evidence — a writer's line that fails to " \
                       "parse would be treated as an AUTHOR line and could wipe the tier tags"
          # The repo half of the same coupling: a SCOPED line whose scope does not
          # parse would fall into the unscoped namespace, and two repos' certs would
          # start superseding each other again — silently, exactly as before.
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
    merged = CertEvidence.preserve(prior: ["[unit] plan"], incoming: [fast_line, "warning: junk"])

    refute_includes merged, "[unit] plan",
                    "documented: a write carrying ANY non-evidence line replaces the author namespace — " \
                    "which is why a cert must emit evidence lines and nothing else"
    assert_includes merged, fast_line
  end

  # --- the format contract (moved out of FullSuiteGate, must stay identical) ---

  def test_lane_of_reads_the_lane_from_an_evidence_line
    assert_equal "full-suite", CertEvidence.lane_of(full_line)
    assert_equal "rubocop", CertEvidence.lane_of(rubocop_line)
    assert_equal "fast-cert", CertEvidence.lane_of(fast_line)
    assert_nil CertEvidence.lane_of("[unit] bin/rails test"), "a tier tag is NOT evidence"
    assert_nil CertEvidence.lane_of("[full-suite-bypass] infra outage"), "a bypass record is NOT evidence"
  end

end
