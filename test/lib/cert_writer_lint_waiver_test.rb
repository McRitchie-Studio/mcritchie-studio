require "test_helper"
require Rails.root.join("bin/lib/full_suite_gate").to_s

# THE WRITER HALF of the lint-lane waiver. The reader (FullSuiteGate#required_lanes)
# stopped DEMANDING a rubocop cert from a repo that declares `lint_lane: none`;
# this asserts bin/full-suite-check stops trying to PRODUCE one.
#
# Without both halves the waiver is useless: dor-check would accept a suite-only
# cert that the cert writer could never generate, because running `bin/rubocop` in
# studio-engine fails outright (no rubocop in the Gemfile, none in the gemspec, no
# .rubocop.yml).
#
# THE PROPERTY THAT MATTERS MOST IS AN ABSENCE. A waived run must record NO
# "[rubocop@<fp>]" line. Writing one would be a stamp for a lint that never ran —
# the manufactured evidence this entire change exists to avoid, and the thing that
# was refused on 2026-08-24 when the only way through was pointing
# FULL_SUITE_RUBOCOP_CMD at a no-op.
class CertWriterLintWaiverTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/full-suite-check").read

  test "the writer consults the DECLARATION, not the environment" do
    assert_match(/FullSuiteGate\.lint_waived\?\(cert_repo\)/, SCRIPT,
                 "the waiver must come from the registry via the shared reader")
    assert_no_match(/which\s+rubocop|rubocop\s+--version|File\.exist\?\(.*rubocop/, SCRIPT,
                    "the writer must NOT probe for a rubocop binary — a waiver inferred from a " \
                    "missing install turns every broken rubocop into a silently skipped lane")
  end

  test "a waived run never records a rubocop evidence line" do
    # `lanes` is what evidence lines are built from, so the lane must be OMITTED
    # from it rather than added with a synthetic pass.
    assert_match(/lanes = \{ FullSuiteGate::TEST_LANE => test_res \}/, SCRIPT,
                 "the waived run must start from the suite lane alone")
    assert_match(/unless lint_waived\s*\n\s*lanes\[FullSuiteGate::RUBOCOP_LANE\]/, SCRIPT,
                 "the rubocop lane may only join `lanes` when it actually ran")
  end

  test "the repo is resolved BEFORE the lanes run" do
    repo_at  = SCRIPT.index("cert_repo = CertRootGuard.repo_of_checkout(root)")
    lanes_at = SCRIPT.index('test_res = run_lane("full-suite"')

    assert repo_at, "the writer must still resolve which repo it is certifying"
    assert_operator repo_at, :<, lanes_at,
                    "whether this repo owes a lint lane has to be known before deciding what to run"
  end

  # The two halves must agree on the SAME registry key, or a repo could be waived
  # by one and demanded by the other.
  test "reader and writer read one declaration" do
    gate = Rails.root.join("bin/lib/full_suite_gate.rb").read

    assert_match(/lint_lane/, gate, "the reader resolves the waiver from lint_lane")
    assert_equal "none", YAML.safe_load_file(Rails.root.join("config/release_repos.yml"))
                             .fetch("gems").fetch("studio-engine")["lint_lane"]
  end

  # Guard the guard: if lint_waived? disappeared or stopped answering, every
  # assertion above would still pass while the waiver did nothing.
  test "the shared reader actually waives the declared repo and nothing else" do
    assert FullSuiteGate.lint_waived?("studio-engine")
    assert_not FullSuiteGate.lint_waived?("turf-monster")
    assert_not FullSuiteGate.lint_waived?(nil)
  end
end
