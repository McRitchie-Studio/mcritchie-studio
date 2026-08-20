# frozen_string_literal: true

# bin/release.rb's CLEAN-ENV VERDICT in front of the gem publish. Standalone:
#   ruby -Itest test/lib/release_cli_gem_ci_gate_test.rb
#
# WHAT IT DEFENDS. publish_gem authorised itself from a LOCAL `bin/release-check
# --build` — whatever bundle, whatever Ruby, whatever half-installed state the
# conductor's laptop happens to carry — and then pushed to RubyGems, which can
# NEVER be un-pushed. Every other shippable tip in this ecosystem earns a
# clean-env verdict before it moves; the gem's did not. The verdict already
# EXISTED (engine-ci.yml builds `release`) and was simply never read.
#
# IT LIVES IN PHASE 1, and that placement is a fix rather than a detail. Review
# found the first version sitting in the publish LOOP: a studio-engine +
# solana-studio sweep pushed studio-engine to RubyGems and THEN aborted on the
# second gem — a partial publish of the one artifact that cannot be un-pushed,
# which is exactly what this task exists to prevent. validate_gems_for_qa holds
# one invariant and says so in its own abort text: every swept gem validates
# before the first irreversible push.
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class ReleaseCliGemCiGateTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # PROJECTS_DIR IS PINNED TO AN EMPTY DIRECTORY, and that is the fix for a test
  # that was green here and RED ON CI. release.rb resolves sibling repos under the
  # projects root: on a developer machine studio-engine sits there, so a run gets
  # as far as checkout_detached; on a runner it does not exist at all and stops
  # earlier. A test that asserted the first message passed locally and failed on
  # CI. Tolerating BOTH would still exercise a different path per machine, so the
  # environment is CONTROLLED — every run sees the same empty root.
  def run_release(call, env = {}, argv: ["--help"])
    script = %(ARGV.replace(#{argv.inspect}); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             %(begin; #{call}; rescue SystemExit; puts "REFUSED"; end)
    Dir.mktmpdir do |empty_root|
      out, = Open3.capture2e(
        { "RELEASE_CI_POLL_INTERVAL" => "0", "RELEASE_CI_POLL_TIMEOUT" => "0",
          "PROJECTS_DIR" => empty_root }.merge(env),
        RbConfig.ruby, "-e", script
      )
      return out
    end
  end

  def verdict(repo, state, version: "0.60.0", argv: ["--help"])
    run_release(%(puts gem_ci_failure("#{repo}", "abc1234", "#{version}").inspect),
                { "RELEASE_CI_STATUS" => state }, argv: argv)
  end

  # --- the verdict --------------------------------------------------------------

  def test_a_green_clean_env_verdict_contributes_no_failure
    assert_includes verdict("studio-engine", "green"), "nil"
  end

  # THE WHOLE POINT. A local release-check can be green on the conductor's machine
  # while the clean-env build is red; before this gate that combination published.
  def test_a_red_clean_env_verdict_fails_the_gem
    assert_includes verdict("studio-engine", "red"), "NOTHING WAS PUBLISHED"
  end

  # NOT-YET-BUILT IS NOT PERMISSION. The sweep reaches this within a minute or two
  # of pushing the promote commit, so "no verdict yet" is the NORMAL state — and
  # reading it as "nothing is failing" is the hole this closes.
  def test_an_unverified_verdict_fails_rather_than_shrugging
    assert_includes verdict("studio-engine", "unverified"), "NOTHING WAS PUBLISHED"
  end

  def test_a_pending_verdict_that_never_concludes_fails
    assert_includes verdict("studio-engine", "pending"), "NOTHING WAS PUBLISHED"
  end

  def test_a_dry_run_never_gates
    assert_includes verdict("studio-engine", "red", argv: ["--help", "--dry-run"]), "nil"
  end

  # --- the CI-less gem, which the first version BRICKED --------------------------
  #
  # The first version of this gate folded a CI-less gem's absent verdict to :none,
  # polled the FULL window, and then told the operator to go and watch a run that
  # does not and never will exist. Any sweep carrying such a member could never
  # complete — a publish that worked before that change became impossible after it.
  #
  # solana-studio was the live example until 2026-08-20, when it shipped a Rails
  # engine and declared a "Gem CI" lane. NO registered gem declares nil today, so
  # these three STUB the declaration in the subprocess rather than borrow it from
  # the registry — the branch still runs for the next gem onboarded without a
  # suite, and a test that needed some real gem to stay CI-less was testing the
  # map, not the gate.

  # Same as `verdict`, with GemCiWorkflows stubbed so `repo` reads as DECLARED
  # CI-less. Injected after the load, so nothing in bin/release.rb grows a
  # test-only seam for it.
  def ci_less_verdict(repo, state, version: "0.60.0")
    stub = %(module GemCiWorkflows; def self.declared_ci_less?(r) = r.to_s == "#{repo}"; end; )
    run_release(stub + %(puts gem_ci_failure("#{repo}", "abc1234", "#{version}").inspect),
                { "RELEASE_CI_STATUS" => state })
  end

  def test_a_declared_ci_less_gem_is_skipped_not_waited_on
    out = ci_less_verdict("quiet-gem", "unverified")

    assert_includes out, "nil", "a gem with no suite workflow must not fail the sweep"
    assert_match(/declares no suite workflow/, out, "and must SAY it skipped, not skip silently")
  end

  # AND MUST NOT MISDIRECT. The refusal text sends the operator to watch a run;
  # for such a repo there is none to watch, so the refusal must not appear at all.
  def test_a_ci_less_gem_is_never_told_to_watch_a_run_that_cannot_exist
    out = ci_less_verdict("quiet-gem", "red")

    refute_includes out, "NOTHING WAS PUBLISHED"
    refute_match(/Watch the run/, out)
  end

  # The live registry's own claim — so the stub above cannot drift from reality.
  # A gem that ships a lane must be GATED by it, never skipped.
  def test_solana_studio_is_now_gated_by_its_own_declared_lane
    out = verdict("solana-studio", "red")

    assert_includes out, "NOTHING WAS PUBLISHED",
                     "solana-studio declares Gem CI now — a red verdict must stop the publish"
    refute_match(/declares no suite workflow/, out)
  end

  # AN UNMAPPED GEM IS NOT EXEMPT. Absence of a declaration is not a declaration
  # of absence — a gem nobody added to the map is BLIND, and blind fails closed,
  # or the next gem to arrive inherits a silent bypass.
  def test_an_unmapped_gem_is_blind_and_still_gated
    out = verdict("some-unregistered-gem", "unverified")

    assert_includes out, "NOTHING WAS PUBLISHED",
                     "an unmapped gem must fail closed — it is blind, not exempt"
  end

  # The two never collapse into each other.
  def test_declared_ci_less_and_unmapped_are_different_answers
    assert_includes ci_less_verdict("quiet-gem", "unverified"), "nil"
    assert_includes verdict("some-unregistered-gem", "unverified"), "NOTHING WAS PUBLISHED"
  end

  # --- what the operator is told -------------------------------------------------

  def test_the_refusal_says_nothing_was_published_and_names_the_tip
    out = run_release(
      %(puts gem_ci_abort("studio-engine", "abc1234def", "0.60.0", { state: :red, failing: ["ci"] }))
    )

    assert_includes out, "studio-engine"
    assert_includes out, "0.60.0"
    assert_includes out, "abc1234", "the exact tip must be named so the run can be found"
    assert_includes out, "NOTHING WAS PUBLISHED"
    assert_match(/still free/, out, "the operator must know the version can be re-used")
  end

  # AND MUST NOT OFFER THE LOCAL RUN AS A WAY AROUND ITSELF.
  def test_the_refusal_does_not_offer_a_bypass
    out = run_release(
      %(puts gem_ci_abort("studio-engine", "abc1234def", "0.60.0", { state: :red, failing: ["ci"] }))
    )

    refute_match(/--force|skip the gate|RELEASE_SKIP/i, out)
  end
end

# --- phase 1: NO gem publishes if ANY gem's verdict is bad ----------------------
#
# THE DEFECT REVIEW FOUND. With the verdict in the publish LOOP, a studio-engine
# + solana-studio sweep pushed studio-engine to RubyGems and THEN aborted on the
# second gem — a partial publish of the one artifact that cannot be un-pushed,
# which is precisely what this task exists to prevent. In validate_gems_for_qa the
# failure is COLLECTED alongside every other gem precondition and the sweep aborts
# with zero pushes.
#
# ASSERTED ON THE SOURCE, and that is a deliberate retreat rather than laziness.
# The behavioural version was written first and PASSED FOR THE WRONG REASON: with
# PROJECTS_DIR pinned to an empty root (which every other test here needs, so
# local and CI exercise one path), validate_gems_for_qa aborts at "gem repo not
# found" long before it reaches the verdict. The test saw ABORTED, no "gem push:",
# and reported success about a code path it never ran — the same false-pass shape
# as the ordering test in the first round of this task.
#
# Making it behavioural needs a real sibling git repo per gem (see
# release_gem_allocation_test's build_projects_root). That fixture is worth having
# and is NOT worth growing this lap by; the verdict's own behaviour is covered
# above, and what is left to pin is WHERE it is called from.
class ReleaseCliGemCiPhaseOneTest < Minitest::Test
  SOURCE = File.read(File.expand_path("../../bin/release.rb", __dir__))

  def body_of(method)
    SOURCE[/^def #{Regexp.escape(method)}\b.*?^end$/m] or flunk("#{method} not found in bin/release.rb")
  end

  def test_the_verdict_is_consulted_from_the_phase_one_validator
    assert_includes body_of("validate_gems_for_qa"), "gem_ci_failure(",
                    "the clean-env verdict is not consulted in phase 1 — a bad gem would only be " \
                    "caught after an earlier gem had already been pushed"
  end

  # AND NOT FROM THE PUBLISH LOOP, which is where it was and what made a partial
  # publish reachable.
  def test_the_verdict_is_not_consulted_beside_the_push
    refute_includes body_of("publish_gems_for_qa"), "gem_ci_failure(",
                        "the verdict is back in the publish loop — the first gem pushes before the " \
                        "second is judged"
  end

  # IT IS COLLECTED, NOT RAISED. validate_gems_for_qa gathers every precondition
  # into `failures` and aborts once with all of them; a verdict that called abort!
  # itself would stop at the first bad gem and hide the rest.
  def test_the_verdict_is_collected_into_failures_like_every_other_precondition
    body = body_of("validate_gems_for_qa")

    assert_match(/failures << ci_failure/, body,
                 "the verdict must join `failures`, so one abort names every problem gem")
  end
end
