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
    %w[studio-engine solana-studio].each do |repo|
      assert_equal [TEST], FullSuiteGate.required_lanes(repo),
                   "#{repo} declares lint_lane: none, so a rubocop cert is not owed"
    end
  end

  test "every other repo still owes BOTH lanes" do
    %w[mcritchie-studio turf-monster].each do |repo|
      assert_equal FullSuiteGate::LANES, FullSuiteGate.required_lanes(repo),
                   "#{repo} has not declared a waiver and must still owe a rubocop cert"
    end
  end

  # bin/fast-check carries NO lint-waiver branch, and says so in a comment whose
  # reasoning is "every declaring repo is a gem, and the gem branch above already
  # omitted the lane". That is only true while it is true. Asserting it here means a
  # NON-gem repo declaring the waiver reddens this test instead of silently turning
  # that paragraph into a lie and leaving fast-check running `bin/rubocop` against a
  # repo the registry says has none.
  test "every repo declaring the waiver is a gem, which is what lets fast-check skip the branch" do
    registry = YAML.safe_load_file(Rails.root.join("config/release_repos.yml"))
    declaring = %w[gems apps].flat_map do |section|
      (registry[section] || {}).select { |_, row| row.is_a?(Hash) && row["lint_lane"].to_s == "none" }
                               .keys.map { |slug| [section, slug] }
    end

    assert declaring.any?, "the waiver must still be declared by someone, or every test here is vacuous"
    assert_equal [], declaring.reject { |section, _| section == "gems" },
                 "a NON-gem repo now declares lint_lane: none — bin/fast-check's gem branch no longer " \
                 "covers it, so give that script the waiver branch its comment defers"
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
  # UNCHANGED AND UNLOOSENED by the audit added on 2026-08-31. The audit
  # (bin/lib/lint_waiver_guard.rb) does read the tree, but it can only REVOKE a
  # waiver, never grant one — so it deliberately lives in its OWN file and this
  # assertion still bites, verbatim, on the module that DECIDES the waiver.
  # Moving any environment read into full_suite_gate.rb must still redden here.
  # The revoke-only direction is asserted in test/lib/lint_waiver_guard_test.rb.
  test "the waiver comes from the registry, not from probing the environment" do
    registry = Rails.root.join("config/release_repos.yml")
    gems = YAML.safe_load_file(registry).fetch("gems")

    %w[studio-engine solana-studio].each do |repo|
      assert_equal "none", gems.fetch(repo)["lint_lane"],
                   "#{repo}'s waiver must be a reviewable line in config/release_repos.yml"
    end
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
