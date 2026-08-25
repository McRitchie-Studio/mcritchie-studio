require "test_helper"
require Rails.root.join("bin/lib/full_suite_gate").to_s

# A REPO MAY DECLARE THAT IT HAS NO LINT LANE. It may never be INFERRED to.
#
# studio-engine ships no rubocop — not in the Gemfile, not in the gemspec, no
# .rubocop.yml, and `bundle exec rubocop` fails outright. Its static gate is
# `ruby -c` inside bin/release-check. Before this, the cert gate demanded a
# rubocop cert per named repo, so a task naming the engine could NEVER be
# certified: the only way through was pointing FULL_SUITE_RUBOCOP_CMD at a no-op,
# which records a rubocop pass for a lint that never ran. That was refused on
# 2026-08-24 and the task was scoped down instead; this is the honest fix.
#
# THE DISTINCTION THIS FILE DEFENDS is declared-vs-inferred. Waiving the lane
# because no rubocop BINARY is present would turn every broken rubocop install
# into a silently skipped lane — the self-declaration disease config/e2e_lane.yml
# exists to prevent. The waiver must be a reviewable line in a registry.
class CertLintLaneWaiverTest < ActiveSupport::TestCase
  TEST = FullSuiteGate::TEST_LANE
  RUBOCOP = FullSuiteGate::RUBOCOP_LANE

  test "a repo that declares no lint lane owes only the suite" do
    assert_equal [TEST], FullSuiteGate.required_lanes("studio-engine"),
                 "studio-engine declares lint_lane: none, so a rubocop cert is not owed"
  end

  test "every other repo still owes BOTH lanes" do
    %w[mcritchie-studio turf-monster solana-studio].each do |repo|
      assert_equal FullSuiteGate::LANES, FullSuiteGate.required_lanes(repo),
                   "#{repo} has not declared a waiver and must still owe a rubocop cert"
    end
  end

  # FAIL CLOSED. A gate that waives a lane for an input it does not recognise is
  # worse than one that never waives: a typo'd slug would silently drop a lane.
  test "an unknown repo, a blank one, and nil all owe EVERYTHING" do
    [nil, "", "   ", "not-a-repo", "studio_engine"].each do |repo|
      assert_equal FullSuiteGate::LANES, FullSuiteGate.required_lanes(repo),
                   "#{repo.inspect} must not waive a lane — only a declared repo may"
    end
  end

  # The declaration is the ONLY thing that waives. This is the anti-inference
  # guard: if someone later makes the gate probe for a rubocop binary, the
  # registry stops being the source of truth and this test should be the thing
  # that objects.
  test "the waiver comes from the registry, not from probing the environment" do
    registry = Rails.root.join("config/release_repos.yml")
    declared = YAML.safe_load_file(registry).fetch("gems").fetch("studio-engine")

    assert_equal "none", declared["lint_lane"],
                 "the waiver must be a reviewable line in config/release_repos.yml"
    source = Rails.root.join("bin/lib/full_suite_gate.rb").read
    assert_no_match(/which\s+rubocop|rubocop\s+--version|File\.exist\?\(.*rubocop/, source,
                    "the gate must NOT probe for a rubocop binary — a waiver inferred from a " \
                    "missing install turns every broken rubocop into a silently skipped lane")
  end

  # Guard the guard: LANES must actually contain the rubocop lane, or every
  # assertion above is comparing two identical lists and proves nothing.
  test "the rubocop lane is genuinely one of the full-cert lanes" do
    assert_includes FullSuiteGate::LANES, RUBOCOP
    assert_includes FullSuiteGate::LANES, TEST
  end
end
