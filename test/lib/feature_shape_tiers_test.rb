# frozen_string_literal: true

# Guard test for config/feature_shapes.yml's `dor_tiers` — the contract that every tier
# a shape DEMANDS is a tier some lane actually RUNS.
#
# Why this test exists: until 2026-07-13 the `e2e` tier (shapes ui+db, onchain-vertical)
# and `e2e_onchain` (shapes onchain, onchain-vertical) were demanded by the shape file
# and executed by NOTHING — not bin/fast-check, not bin/full-suite-check, not CI, not
# the G3/G4 release gates. The requirement was satisfied ENTIRELY by a builder typing an
# `[e2e] ...` string into devops.checks_run, which bin/dor-check then credited. The gate
# demanded evidence it never collected and accepted a self-declaration in its place —
# the exact disease catalogued in
# docs/agents/audits/release-gate-and-devops-process-review-2026-07-12.md. Here the gate
# never even had a mechanism to lie WITH: the tier was a label, and always was.
#
# What an uncollected tier costs, MEASURED (2026-07-13, this repo, on an untouched
# `release` checkout): the studio's 69-spec Playwright suite — the one the `e2e` tier
# names — was 18 SPECS RED. Nobody had run it in long enough for a quarter of it to rot,
# in precisely the areas that shipped that month (deployments-live, testing-gates,
# board-order). A tier nobody collects does not stay honest and unused; it DECAYS, and
# the first person to trust it inherits the decay. That is the concrete argument for
# this guard.
#
# THE INVARIANT, POSITIVE (the house lesson from ci_workflow_triggers_test.rb, whose
# blacklist was holed three times in review): this file does not enumerate the ways a
# tier might go uncollected. It asserts the tier IS collected — some REAL RUNNER must
# invoke a command that executes it. A tier that no runner runs fails, whatever the
# reason, including reasons nobody has thought of yet.
#
# WHAT COUNTS AS A RUNNER — read before "fixing" a failure here by widening this list.
# A runner is a file that EXECUTES a command in the pipeline:
#   · .github/workflows/ci.yml   — the CI verdict (G2), every PR and both shippable tips
#   · bin/full-suite-check       — the CI-independent local cert (G1)
#   · bin/fast-check             — the builder's default cert (G1)
#
# `config/devops_test_suites.yml` is deliberately NOT a runner. It is a CATALOG, and
# trusting it is how this bug hides: that file has ALWAYS carried an entry
# `studio_local_e2e` (tier: e2e, command: `npx playwright test`) — a lane no runner has
# ever invoked. A guard that resolved tiers against the catalog would have passed, every
# day, through the whole period the tier collected nothing. The catalog describes; only
# a runner runs. Resolve against the thing that EXECUTES, never the thing that DECLARES
# — that is the entire lesson of the 2026-07-12 wave, restated as a test.
#
# SCOPE — honest about its reach. The runners above are the ones that live in THIS repo,
# so this guard speaks for mcritchie-studio. `dor_tiers` is ecosystem-wide config, and a
# lane is a per-REPO capability: the same `ui+db` shape is honest in turf-monster (whose
# ci.yml runs a real 3-shard `playwright` job) and was a lie here. Each satellite needs
# its own copy of this guard against its own ci.yml; that is filed, not done here. What
# this file guarantees is narrower and still worth having: the studio cannot DEMAND a
# tier the studio cannot RUN.
#
# Run directly:
#   ruby -Itest test/lib/feature_shape_tiers_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Two tiers (backend shape):
#   [unit]        tier extraction from shape YAML and command→tier matching, over
#                 fixtures — including the catalog-is-not-a-runner trap above.
#   [integration] the REAL committed feature_shapes.yml demands only tiers the REAL
#                 committed runners execute.

require "minitest/autorun"
require "yaml"

class FeatureShapeTiersTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FEATURE_SHAPES = File.join(ROOT, "config/feature_shapes.yml")
  CI_YML = File.join(ROOT, ".github/workflows/ci.yml")
  FAST_CHECK = File.join(ROOT, "bin/fast-check")
  FULL_SUITE_CHECK = File.join(ROOT, "bin/full-suite-check")

  # A tier → the command that CONSTITUTES running it. This is the load-bearing table:
  # get a pattern wrong and the guard passes vacuously, asserting a lane that never
  # existed (the failure mode ci_workflow_triggers_test.rb pins for its TEST_COMMAND).
  # Every pattern here is matched against a runner's real command string below, and
  # test_unit_every_known_tier_has_a_command_pattern keeps the table total.
  #
  #   unit/component/integration — all three live in test/**, and the ARGLESS
  #     `bin/rails test` sweep (CI's `test` job; bin/full-suite-check's full lane) runs
  #     every file there. One pattern, three tiers: the minitest suite does not
  #     distinguish them, and neither can a command matcher. The tier TAG is the
  #     builder's claim about WHICH file they wrote; the LANE is what proves the file
  #     runs. This guard is about the lane.
  #   e2e — Playwright. Needs a booted server, so it can never be a bare argless rails
  #     lane; it is its own job.
  #   e2e_onchain — a FRESH devnet run against a real cluster for the change under test.
  #     No pattern, because no runner: see the constant below.
  TIER_COMMANDS = {
    "unit" => %r{bin/rails\b[^\n]*\btest\b},
    "component" => %r{bin/rails\b[^\n]*\btest\b},
    "integration" => %r{bin/rails\b[^\n]*\btest\b},
    "e2e" => /\bplaywright\s+test\b/
  }.freeze

  # e2e_onchain has NO command pattern ON PURPOSE, and this constant is the reason,
  # written down so the next person does not "fix" the failure by inventing one.
  #
  # The tier means what the shape file says it means: "a FRESH devnet run for this
  # change — do not rely on last night's nightly." That is not a lane and cannot become
  # one on a cert or a CI runner. It needs a funded bot wallet, a real cluster, SOL for
  # a program deploy (~3◎ for a new program id), and minutes of settle time. A CI job
  # that pretends to it would be the same lie one level down.
  #
  # It was demanded by the `onchain` and `onchain-vertical` shapes — the two
  # highest-consequence shapes in the ecosystem, the ones that move real money — and it
  # was collected NOWHERE, and never had been:
  #   · turf-vault (the Anchor program itself) has NO .github/workflows AT ALL.
  #   · turf-monster's devnet-nightly.yml — the only workflow that could serve — is
  #     gated `if: vars.DEVNET_NIGHTLY_ENABLED == 'true'`, every scheduled run has
  #     completed `skipped`, and its own ci.yml says so in terms: "It has never run. Do
  #     not read this pin as 'covered elsewhere' — it is covered nowhere today."
  # So the strictest-LOOKING tier in the system was the emptiest, on the shapes where
  # emptiness costs the most. It is removed from dor_tiers rather than left as a
  # requirement satisfiable by typing: on-chain verification is real, but it is an
  # operator/QA-stop act, in the same category the shape file already carves out for
  # `manual` — NOT a pre-submit tier a builder self-certifies.
  #
  # To bring it BACK: build the lane first (a per-change devnet job, or re-enable and
  # fund devnet-nightly), add its pattern to TIER_COMMANDS, and only then re-add the
  # tier to a shape. This guard will hold you to that order — which is the point.
  UNRUNNABLE_TIERS = %w[e2e_onchain].freeze

  # ---- extraction ------------------------------------------------------------------

  # Every tier any shape DEMANDS, deduplicated. This is the demand side of the contract.
  def required_tiers(yaml_text)
    YAML.safe_load(yaml_text).fetch("shapes", {}).values.flat_map { |shape| Array(shape["dor_tiers"]) }.uniq.sort
  end

  # Every command string a RUNNER actually executes. `run:` steps in ci.yml, plus the
  # cert scripts' own text (their lanes are shell strings in Ruby — matching the file
  # body is coarse, and deliberately so: it cannot go stale against a refactor the way a
  # hardcoded lane list would, and a false PASS here needs the command to literally
  # appear in the file).
  def ci_run_commands(yaml_text)
    YAML.safe_load(yaml_text).fetch("jobs", {}).select { |_n, j| j.is_a?(Hash) }
        .flat_map { |_n, job| Array(job["steps"]).grep(Hash).map { |step| step["run"].to_s } }
        .reject(&:empty?)
  end

  # The runner corpus: what the pipeline EXECUTES. Note what is absent —
  # config/devops_test_suites.yml. See the header.
  def runner_commands
    ci_run_commands(File.read(CI_YML)) + [File.read(FAST_CHECK), File.read(FULL_SUITE_CHECK)]
  end

  # Which runner, if any, executes this tier.
  def lanes_running(tier, commands)
    pattern = TIER_COMMANDS[tier]
    return [] unless pattern

    commands.select { |command| command.match?(pattern) }
  end

  # --- [unit] extraction and matching ------------------------------------------------

  def test_unit_reads_the_union_of_tiers_every_shape_demands
    yaml = <<~YML
      shapes:
        ui-only:
          dor_tiers: [component]
        ui+db:
          dor_tiers: [unit, component, integration, e2e]
        backend:
          dor_tiers: [unit, integration]
    YML
    assert_equal %w[component e2e integration unit], required_tiers(yaml)
  end

  def test_unit_a_shape_with_no_tiers_demands_nothing
    assert_empty required_tiers("shapes:\n  chore:\n    description: no tests\n")
  end

  def test_unit_recognizes_the_argless_rails_suite_as_the_minitest_lane
    # The other half of the vacuity trap: if these patterns do not match the REAL
    # commands, every assertion below passes over an empty set and this guard is
    # decorative — which is the bug it exists to prevent, committed by its own author.
    commands = ["bin/rails db:test:prepare test test:system"]

    refute_empty lanes_running("unit", commands)
    refute_empty lanes_running("integration", commands)
    refute_empty lanes_running("component", commands)
  end

  def test_unit_recognizes_a_playwright_invocation_as_the_e2e_lane
    assert_equal 1, lanes_running("e2e", ["npx playwright test --project=chromium"]).size
    assert_equal 1, lanes_running("e2e", ["npm ci && npx playwright test --shard=1/3"]).size
  end

  def test_unit_a_rails_lane_does_not_satisfy_the_e2e_tier
    # e2e needs a booted browser against a booted server. The minitest sweep is not it,
    # and a matcher loose enough to think otherwise would paper over exactly this bug.
    assert_empty lanes_running("e2e", ["bin/rails db:test:prepare test test:system"])
  end

  def test_unit_a_tier_with_no_command_pattern_is_run_by_nothing
    # e2e_onchain, structurally: there is no command that constitutes running it on a
    # runner, so no corpus can satisfy it. A shape that demands it can never be honest.
    UNRUNNABLE_TIERS.each do |tier|
      assert_nil TIER_COMMANDS[tier], "#{tier} must not have a command pattern — see UNRUNNABLE_TIERS"
      assert_empty lanes_running(tier, ["bin/rails test", "npx playwright test", "anchor test"]),
                   "#{tier} must not be satisfiable by any command"
    end
  end

  def test_unit_a_catalog_entry_is_not_a_runner
    # THE TRAP THIS WHOLE FILE IS BUILT AROUND. config/devops_test_suites.yml has always
    # catalogued `studio_local_e2e` with `command: npx playwright test` — and no runner
    # has ever invoked it. Resolving tiers against the catalog would have passed every
    # day this bug was live. Pin the distinction: a declared command is not an executed
    # one. If a future refactor makes the catalog a runner, it must do so by having a
    # runner READ it, and this test should then be updated deliberately.
    catalog = YAML.safe_load(File.read(File.join(ROOT, "config/devops_test_suites.yml")))
    studio_suites = catalog.fetch("apps").fetch("mcritchie-studio").fetch("suites")
    catalogued_e2e = studio_suites.select { |suite| suite["tier"].to_s == "e2e" }

    refute_empty catalogued_e2e,
                 "the catalog still lists an e2e suite for the studio — if it no longer does, this " \
                 "trap is stale, but do NOT delete the principle: resolve tiers against runners."
    refute_includes runner_commands, catalogued_e2e.first.fetch("command"),
                    "a CATALOG entry's command string must never be mistaken for a runner's. This " \
                    "guard resolves tiers against ci.yml and the cert scripts — the files that " \
                    "EXECUTE — precisely so a brochure entry cannot satisfy a gate."
  end

  # --- [integration] the real committed config vs. the real committed runners ---------

  # ==== THE PRIMARY GUARD =============================================================
  # Positive. Every tier the shape file demands must be RUN by a real runner. A tier
  # that nothing executes is a requirement satisfied by typing — a gate that demands
  # evidence it never collects, which is how every check in the 2026-07-12 wave came to
  # lie. If this fails: either WIRE THE LANE, or STOP ASKING FOR THE TIER. Those are the
  # only two honest moves, and no third one should be invented to make this green.
  def test_integration_every_required_tier_is_run_by_a_real_lane
    commands = runner_commands
    tiers = required_tiers(File.read(FEATURE_SHAPES))

    refute_empty tiers, "feature_shapes.yml demands no tiers at all — the shape gate is vacuous"

    uncollected = tiers.reject { |tier| lanes_running(tier, commands).any? }

    assert_empty uncollected,
                 "config/feature_shapes.yml demands tier(s) #{uncollected.inspect} that NO RUNNER " \
                 "EXECUTES. Nothing in .github/workflows/ci.yml, bin/fast-check, or " \
                 "bin/full-suite-check runs them, so the requirement is satisfied ENTIRELY by a " \
                 "builder typing '[#{uncollected.first}] ...' into devops.checks_run and " \
                 "bin/dor-check crediting the tag. That is a gate that demands evidence it never " \
                 "collects and accepts a self-declaration in its place. Two honest fixes, no " \
                 "third: (a) COLLECT IT — add a lane to a runner and register its command in " \
                 "TIER_COMMANDS; or (b) STOP ASKING — remove the tier from the shape. Do not " \
                 "make this pass by pointing the guard at a catalog: config/devops_test_suites.yml " \
                 "DECLARES lanes, it does not run them."
  end
  # ====================================================================================

  def test_integration_no_shape_demands_a_structurally_unrunnable_tier
    # Defense in depth behind the primary guard, and a louder error for the specific case
    # we KNOW recurs: a tier that cannot be a lane at all. The primary guard would catch
    # it, but a reader who hits it deserves to be told WHY it can never be wired, rather
    # than going off to build a devnet job on a GitHub runner.
    tiers = required_tiers(File.read(FEATURE_SHAPES))
    demanded = tiers & UNRUNNABLE_TIERS

    assert_empty demanded,
                 "shape(s) demand #{demanded.inspect}, which CANNOT be run by any cert or CI lane " \
                 "(it needs a funded wallet, a real cluster, and SOL — see UNRUNNABLE_TIERS). It " \
                 "was demanded by the onchain shapes and collected nowhere, which made the " \
                 "strictest-looking tier in the system the emptiest, on the changes that move real " \
                 "money. On-chain verification is an operator/QA-stop act, like `manual` — not a " \
                 "pre-submit tier a builder self-certifies. Build the lane BEFORE re-adding it."
  end

  def test_integration_the_e2e_lane_runs_the_studio_playwright_suite
    # The `e2e` tier's lane, asserted by NAME. The primary guard proves *a* command runs
    # playwright; this proves it is a CI job (not, say, a stray mention in a cert script's
    # comments) — so the tier's evidence is collected on every PR and both shippable tips,
    # where a reviewer's gate-zero can actually read the verdict.
    lanes = ci_run_commands(File.read(CI_YML)).select { |command| command.match?(TIER_COMMANDS.fetch("e2e")) }

    refute_empty lanes,
                 "no CI step runs the Playwright suite. The `e2e` tier (shapes ui+db, " \
                 "onchain-vertical) would go back to being collected by nothing — and the suite " \
                 "would go back to rotting unobserved: it was 18/69 RED on an untouched release " \
                 "checkout when this guard was written, having gone unrun long enough for a " \
                 "quarter of it to decay."
  end
end
