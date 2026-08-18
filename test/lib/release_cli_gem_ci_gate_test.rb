# frozen_string_literal: true

# bin/release.rb's CLEAN-ENV GATE in front of the gem publish. Standalone:
#   ruby -Itest test/lib/release_cli_gem_ci_gate_test.rb
#
# WHAT IT DEFENDS. publish_gem authorised itself from a LOCAL `bin/release-check
# --build` — whatever bundle, whatever Ruby, whatever half-installed state the
# conductor's laptop happens to carry — and then pushed to RubyGems, which can
# NEVER be un-pushed. Every other shippable tip in this ecosystem earns a
# clean-env CI verdict before it moves; the gem's did not, and the gem is the one
# artifact with no rollback.
#
# THE VERDICT ALREADY EXISTED AND WAS NEVER READ. engine-ci.yml builds `release`,
# so the tip being published already carries a GitHub run — a clean-env verdict
# that nothing consults protects nothing. Verified before building: publish_gem's
# only authorisation was run_test_scope("gem_release_check", ...), a local shell.
#
# A NEW FILE ON PURPOSE: test/lib/release_cli_test.rb is frozen at its size by
# config/test_health.yml so new work lands somewhere else.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "rbconfig"

class ReleaseCliGemCiGateTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # One gem, not already live, not dry — the shape publish_gems_for_qa gates.
  def plan_line
    %([{ "repo" => "studio-engine", "version" => "0.60.0", "tip" => "abc1234", ) +
      %("already_live" => false, "dry" => false }])
  end

  # Drive the REAL script with the injection seams set, then evaluate `call`.
  # RELEASE_CI_STATUS is the same seam the pre-QA gate's tests use.
  # PROJECTS_DIR IS PINNED TO AN EMPTY DIRECTORY, and that is the fix for a test
  # that was green here and RED ON CI.
  #
  # release.rb resolves sibling repos under the projects root. On a developer
  # machine studio-engine sits there, so the run gets as far as checkout_detached
  # ("could not checkout <sha>"); on a runner it does not exist at all and the run
  # stops earlier at publish_gem's own check ("gem repo not found"). A test that
  # asserted the first message passed locally and failed on CI — it had pinned a
  # message that depended on the filesystem around it.
  #
  # Tolerating BOTH messages would have made it pass everywhere while still
  # exercising a different code path per machine, so the environment is CONTROLLED
  # instead: every run sees the same empty root and the same one path.
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

  # --- the gate's verdict -------------------------------------------------------

  def test_a_green_clean_env_verdict_lets_the_publish_through
    out = run_release(%(gem_ci_gate("studio-engine", "abc1234", "0.60.0")),
                      { "RELEASE_CI_STATUS" => "green" })

    refute_includes out, "REFUSED", "a green CI verdict must authorise the publish"
  end

  # THE WHOLE POINT. A local release-check can be green on the conductor's machine
  # while the clean-env build is red; before this gate that combination published.
  def test_a_red_clean_env_verdict_refuses
    out = run_release(%(gem_ci_gate("studio-engine", "abc1234", "0.60.0")),
                      { "RELEASE_CI_STATUS" => "red" })

    assert_includes out, "REFUSED"
  end

  # NOT-YET-BUILT IS NOT PERMISSION. The sweep reaches publish within a minute or
  # two of pushing the promote commit, so "no verdict yet" is the NORMAL state —
  # and the tempting reading of it ("nothing is failing") is exactly the hole this
  # gate exists to close. With the poll window exhausted it must fail CLOSED.
  def test_an_unverified_verdict_refuses_rather_than_shrugging
    out = run_release(%(gem_ci_gate("studio-engine", "abc1234", "0.60.0")),
                      { "RELEASE_CI_STATUS" => "unverified" })

    assert_includes out, "REFUSED", "no verdict must never read as permission to publish"
  end

  def test_a_pending_verdict_that_never_concludes_refuses
    out = run_release(%(gem_ci_gate("studio-engine", "abc1234", "0.60.0")),
                      { "RELEASE_CI_STATUS" => "pending" })

    assert_includes out, "REFUSED", "a poll that times out must fail closed, not open"
  end

  # A DRY RUN MUST NOT GATE, for the same reason it must not publish: it is a
  # rehearsal against SHAs that may carry no run at all, and a dry run that aborts
  # on a missing verdict can never rehearse a release.
  def test_a_dry_run_skips_the_gate_entirely
    out = run_release(%(gem_ci_gate("studio-engine", "abc1234", "0.60.0")),
                      { "RELEASE_CI_STATUS" => "red" }, argv: ["--help", "--dry-run"])

    refute_includes out, "REFUSED", "a dry run must rehearse, not gate"
  end

  # --- what the operator is told ------------------------------------------------

  # A GATE THAT STOPS AN IRREVERSIBLE STEP OWES AN EXPLANATION. The operator needs
  # to know the version is still free — otherwise the natural assumption after an
  # abort mid-release is that something was already pushed.
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

  # AND MUST NOT OFFER THE LOCAL RUN AS A WAY AROUND ITSELF. The acceptance is
  # that a local run alone cannot authorise a publish; a message hinting otherwise
  # would be the first thing a hurried conductor reached for.
  def test_the_refusal_does_not_offer_the_local_run_as_an_override
    out = run_release(
      %(puts gem_ci_abort("studio-engine", "abc1234def", "0.60.0", { state: :red, failing: ["ci"] }))
    )

    refute_match(/--force|skip the gate|RELEASE_SKIP/i, out,
                 "the refusal must not advertise a bypass for an irreversible step")
  end

  # --- ordering: the gate is IN FRONT of the push -------------------------------

  # THE LOAD-BEARING CLAIM, and the first version of it PASSED WITH THE GATE
  # DELETED. It asserted "refused, and never printed `gem build:`" — but with the
  # gate gone the run aborts a step later at checkout_detached ("could not
  # checkout"), which is also a refusal and also never reaches `gem build`. The
  # assertion could not tell the gate's refusal from any other, so removing the
  # gate entirely, and moving it AFTER the push, both stayed green.
  #
  # Ordering is only observable as a PAIR: red must stop AT the gate and get no
  # further, and green must get PAST it to the next step. Either alone is
  # satisfiable by an unrelated abort.
  def test_a_red_verdict_stops_the_publish_at_the_gate
    out = run_release(%(publish_gems_for_qa(#{plan_line})), { "RELEASE_CI_STATUS" => "red" })

    assert_includes out, "NOTHING WAS PUBLISHED",
                     "the refusal must be THE GATE's, not some later step's"
    refute_match(/could not checkout/, out,
                 "the run reached checkout_detached — the gate is not in front of it")
    refute_match(/gem build:|gem push:/, out)
  end

  # THE "GOT PAST IT" HALF, and its first version was GREEN LOCALLY AND RED ON CI.
  #
  # It asserted the run reached `could not checkout` — which is what
  # checkout_detached says when the sibling clone EXISTS but lacks the SHA. That
  # is true on a developer machine, where studio-engine sits beside the hub at the
  # projects root, and false on a runner, where it does not exist at all and the
  # run aborts earlier with `gem repo not found`. The test pinned a message that
  # depended on the filesystem around it.
  #
  # With the root pinned empty (see run_release), the step after the gate is
  # always publish_gem's own repo check — one path, one message, every machine.
  PAST_THE_GATE = /gem repo not found/
  def test_a_green_verdict_carries_the_publish_past_the_gate
    out = run_release(%(publish_gems_for_qa(#{plan_line})), { "RELEASE_CI_STATUS" => "green" })

    refute_includes out, "NOTHING WAS PUBLISHED", "green must not be refused by the gate"
    assert_match(PAST_THE_GATE, out,
                 "the run never reached the step AFTER the gate — the gate is not being passed, " \
                 "so the red case above proves nothing about ordering")
  end

  # AN ALREADY-PUBLISHED VERSION SKIPS BOTH, so an idempotent re-run after an abort
  # is not blocked by a verdict for a tip whose artifact is already live.
  def test_an_already_live_gem_is_not_gated_again
    plan = plan_line.sub('"already_live" => false', '"already_live" => true')
    out = run_release(%(publish_gems_for_qa(#{plan})), { "RELEASE_CI_STATUS" => "red" })

    refute_includes out, "REFUSED", "a re-run must not re-gate a version that is already live"
    assert_match(/already live/, out)
  end
end
