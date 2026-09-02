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

  # The CANONICAL SPEC — the doc an agent actually reads to size its testing. It carries its
  # own copy of the shape→tiers matrix, and a second copy of a truth is a second place for it
  # to rot. See test_integration_the_canonical_spec_matches_the_shipped_config.
  DESIGN_DOC = File.join(ROOT, "docs/agents/system/devops-cycle-design.md")

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

  def test_unit_every_known_tier_has_a_command_pattern
    # THE TABLE'S TOTALITY, and — until this PR — a test that DID NOT EXIST. The header
    # above cited it by name as the thing "keeping the table total" while the only match in
    # the repo was the citation itself. A guard file whose entire thesis is "a declaration
    # is not evidence" cannot afford to declare a test it does not have; that is the bug,
    # committed in the guard's own prose. Written now rather than deleted, because the
    # invariant it claimed is a real one and worth holding.
    #
    # The claim: every tier this repo KNOWS ABOUT is classified — it has a command pattern
    # (a lane can run it) XOR it is declared structurally unrunnable (no lane ever can). A
    # tier in NEITHER set is the dangerous middle: `lanes_running` returns [] for it, which
    # the primary guard reports as "no runner executes it" — true, but it buries the real
    # story (nobody ever TOLD the table about this tier) under a message about wiring a
    # lane. Force the classification at the table, where it is one line to fix.
    known = (required_tiers(File.read(FEATURE_SHAPES)) + UNRUNNABLE_TIERS + TIER_COMMANDS.keys).uniq

    refute_empty known, "no tiers known at all — this guard would be vacuous"

    known.each do |tier|
      has_pattern = TIER_COMMANDS.key?(tier)
      declared_unrunnable = UNRUNNABLE_TIERS.include?(tier)

      assert has_pattern ^ declared_unrunnable,
             "tier #{tier.inspect} is #{if has_pattern && declared_unrunnable
                                          "BOTH in TIER_COMMANDS and in UNRUNNABLE_TIERS — " \
                                          "pick one: either a lane can run it or none ever can"
                                        else
                                          "in NEITHER TIER_COMMANDS nor UNRUNNABLE_TIERS. A " \
                                          "shape demands it and this table has never heard of " \
                                          "it, so no corpus can satisfy it and the tier is " \
                                          "collected by a builder typing the tag. Classify it: " \
                                          "add the command that CONSTITUTES running it to " \
                                          "TIER_COMMANDS, or declare (with the reason) why no " \
                                          "lane can, in UNRUNNABLE_TIERS"
                                        end}"
    end
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
  #
  # THE NAME SAYS `_in_this_repo` AND IT MEANS IT — that suffix is the guard's honest
  # confession of its own blind spot, and it was added the day I audited my own PR and found
  # the disease alive behind it. config/feature_shapes.yml is ECOSYSTEM-WIDE (bin/dor-check
  # reads it for a task in any repo), but RUNNER_FILES below are MCRITCHIE-STUDIO's runners,
  # because sibling repos are not checked out in this repo's CI and cannot be. So this proves
  # "every demanded tier has a lane HERE" and proves nothing whatsoever about rolio — which
  # has no Playwright lane and no e2e/ directory, while `ui+db` demands `e2e` of it.
  # An unqualified name here would be the same lie one level up, in the guard built to hunt it.
  # See the audit block in config/feature_shapes.yml, and /tasks/dor-check-tiers-per-repo.
  def test_integration_every_required_tier_is_run_by_a_real_lane_in_this_repo
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

  # ==== A ZERO-TIER SHAPE MUST CHOOSE ITS SUITE GATE ON PURPOSE =======================
  # The near-miss this pins, found 2026-08-11 while adding `test-only`. bin/dor-check
  # used to decide whether to demand FULL-suite + rubocop evidence by asking
  # `!dor_tiers.empty?`. That was right for the only zero-tier shape that existed —
  # `docs` ships prose, there is no suite to certify — and it silently welded two
  # unrelated questions together: "which tiers do you owe" and "must your code be
  # certified at all".
  #
  # `test-only` is the shape that breaks the weld. It has NO tiers (a diff with no
  # behavior has nothing for a tier to be evidence of) and it ships EXECUTABLE CODE.
  # Under the inference it would have inherited a full-suite exemption nobody chose,
  # invisible in the diff, on the change most able to break the suite quietly — a
  # zero-tier shape with no executed evidence of any kind, which is precisely the
  # "shape every under-tested change claims" this taxonomy must never grow.
  #
  # So the key is explicit and DEFAULTS TO TRUE (fail-closed), and a shape with no
  # tiers has to say which it is. The assertion is deliberately about the SHAPES
  # THAT COULD INHERIT THE BUG — not a hardcoded list of today's two — so the next
  # zero-tier shape is caught the day it is written.
  def test_integration_a_shape_with_no_tiers_declares_its_full_suite_gate
    shapes = YAML.safe_load(File.read(FEATURE_SHAPES)).fetch("shapes")
    tierless = shapes.reject { |_name, shape| Array(shape["dor_tiers"]).any? }

    refute_empty tierless,
                 "no zero-tier shape exists any more — if that is deliberate, delete this guard; do NOT " \
                 "delete the principle that a suite exemption is chosen, never inherited."

    tierless.each do |name, shape|
      assert shape.key?("full_suite_gate"),
             "shape #{name.inspect} demands NO tiers and does not declare `full_suite_gate`. " \
             "bin/dor-check defaults it to TRUE, so nothing is broken right now — but the choice would " \
             "be invisible, and it used to be INFERRED from the empty tier list, which is how a shape " \
             "that ships executable code could inherit a full-suite exemption nobody picked. Declare it: " \
             "`full_suite_gate: false` if this shape ships no code to certify (see `docs`), `true` if it " \
             "does (see `test-only`)."
    end
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

  # ==== THE SAME LIE, IN THE OTHER COPY ===============================================
  # This file resolved tiers against config/feature_shapes.yml and declared victory. But the
  # doc an agent actually READS to size its testing — devops-cycle-design.md §3.2, in a table
  # whose column is headed literally "Required tiers (DoR contract)" — carried its OWN copy of
  # the matrix, and that copy still demanded `devnet E2E (nightly)` of `onchain` and
  # `onchain-vertical` AFTER this PR deleted `e2e_onchain` from the config. A required tier
  # with no lane behind it, sitting in the canonical spec, on the two shapes that move real
  # money. The guard above could not see it: IT READS CONFIG, AND THE LIE HAD MOVED TO PROSE.
  #
  # THE STRUCTURAL FIX is not "also grep the doc for devnet" — that is another blacklist of
  # another spelling, and it would miss the next one. It is to stop keeping TWO INDEPENDENT
  # COPIES of one truth. The doc's tier names are backticked; this asserts the two copies are
  # the SAME SET, both directions, for every shape. The doc may not demand a tier the config
  # does not (the bug), and it may not quietly drop one the config does (the inverse bug).
  DOC_TIER_ROW = /^\|\s*\*\*(?<shape>[a-z+-]+)\*\*\s*\|[^|]*\|(?<tiers>[^|]*)\|/

  def doc_dor_tiers(markdown)
    markdown.lines.filter_map do |line|
      match = line.match(DOC_TIER_ROW)
      next unless match

      # Only the canonical list, which sits BEFORE the em-dash. Prose after it is free text
      # (and legitimately contains backticks — `release` is a branch, not a tier).
      # `[a-z0-9_]` — the digit is load-bearing. `[a-z_]+` cannot match `e2e`, so the scanner
      # silently dropped the one tier this whole PR is about and the guard passed vacuously on
      # a doc that agreed. A guard that cannot see the thing it guards is worse than none.
      canonical = match[:tiers].split("—").first.to_s
      [match[:shape], canonical.scan(/`([a-z0-9_]+)`/).flatten.sort]
    end.to_h
  end

  def config_dor_tiers(yaml_text)
    YAML.safe_load(yaml_text).fetch("shapes").transform_values { |shape| Array(shape["dor_tiers"]).sort }
  end

  def test_integration_the_canonical_spec_matches_the_shipped_config
    doc = doc_dor_tiers(File.read(DESIGN_DOC))
    config = config_dor_tiers(File.read(FEATURE_SHAPES))

    refute_empty doc,
                 "found NO shape rows in #{File.basename(DESIGN_DOC)} §3.2. Either the table " \
                 "moved or its format changed — and a guard that silently matches nothing is " \
                 "worse than no guard. Re-point DOC_TIER_ROW; do not delete this."

    assert_equal config, doc,
                 "the shape→tiers matrix in docs/agents/system/devops-cycle-design.md §3.2 " \
                 "DISAGREES with config/feature_shapes.yml.\n" \
                 "  config: #{config.inspect}\n" \
                 "  doc:    #{doc.inspect}\n" \
                 "These are two copies of ONE truth and the doc is the one agents read to " \
                 "decide how much to test. When they drifted last time, the doc kept demanding " \
                 "a devnet E2E tier that NOTHING RUNS — on the onchain shapes, the ones that " \
                 "move real money. Fix the copy that is wrong. If you are changing what a " \
                 "shape requires, change BOTH in the same commit."
  end
  # ====================================================================================

  # Every tier the canonical spec demands must be a tier some lane RUNS — the same positive
  # invariant as the config guard, applied to the prose. Belt for the assertion above: even if
  # someone edits BOTH copies in lockstep to re-add an uncollected tier, this still fires.
  def test_integration_the_canonical_spec_demands_no_unrunnable_tier
    demanded = doc_dor_tiers(File.read(DESIGN_DOC)).values.flatten.uniq

    demanded.each do |tier|
      assert TIER_COMMANDS.key?(tier),
             "devops-cycle-design.md §3.2 demands the `#{tier}` tier, which NO RUNNER RUNS " \
             "(it is not in TIER_COMMANDS). That is the exact bug this PR exists to kill — a " \
             "gate demanding evidence nobody collects — and re-introducing it in the canonical " \
             "spec is how it comes back. WIRE THE LANE, or STOP ASKING FOR THE TIER."
    end
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

  # ==== [unit] EVERY `claimable_when` IS A RULE THE GATE ACTUALLY IMPLEMENTS ==========
  #
  # `claimable_when` is what makes a zero-tier shape safe: it says the lighter
  # contract must be EARNED from the observed diff rather than unlocked by typing the
  # shape's name. That protection is worth exactly nothing if bin/dor-check does not
  # implement the rule the config names — a shape would then carry a guard that reads
  # as protection and enforces nothing, which is a WORSE state than declaring no
  # guard at all, because the reviewer stops looking.
  #
  # This is the same class of drift test_integration_the_canonical_spec_matches_the_
  # shipped_config catches between the config and the design doc: two files, one
  # truth. Here the second copy is CODE.
  #
  # dor-check also refuses an unrecognized rule at RUNTIME (its `else` branch), so a
  # typo fails closed rather than granting the claim. This guard is the earlier half:
  # it catches the typo in CI, on the commit that introduces it, instead of on some
  # future task that happens to claim the shape.
  #
  # STRUCTURAL, NOT A GREP FOR THE NAME. Both rule names appear in prose comments in
  # that file (and in this one), so a substring search would match the DOCUMENTATION
  # of a rule that was never wired up — the exact "assertion matches the comment"
  # failure this repo has been bitten by. So it parses the `case claim_rule`
  # dispatch and reads its `when` literals: the only place a rule is actually
  # implemented.
  DOR_CHECK = File.join(ROOT, "bin/dor-check")

  def implemented_claim_rules(source)
    body = source[/^\s*case claim_rule\s*$(.*?)^\s*else\s*$/m, 1]
    return [] if body.nil?

    body.scan(/^\s*when\s+"([a-z0-9_]+)"/).flatten
  end

  def test_unit_every_claimable_when_in_the_config_is_implemented_by_dor_check
    source = File.read(DOR_CHECK)
    implemented = implemented_claim_rules(source)

    refute_empty implemented,
                 "found NO `when \"<rule>\"` arms in bin/dor-check's `case claim_rule` dispatch. Either the " \
                 "dispatch moved or its shape changed — and a guard that silently matches nothing is worse " \
                 "than no guard. Re-point implemented_claim_rules; do not delete this."

    declared = YAML.safe_load(File.read(FEATURE_SHAPES)).fetch("shapes")
                   .filter_map { |name, shape| [name, shape["claimable_when"]] if shape["claimable_when"] }

    declared.each do |name, rule|
      assert_includes implemented, rule,
                      "shape #{name.inspect} declares `claimable_when: #{rule}`, which bin/dor-check does " \
                      "NOT implement (it dispatches on #{implemented.inspect}). The shape would carry a " \
                      "claim guard that reads as protection and enforces nothing — worse than declaring no " \
                      "guard, because the reviewer stops looking. Implement the rule in bin/dor-check's " \
                      "`case claim_rule` block, or fix the value here."
    end
  end

  # The zero-tier shapes are the ones whose contract is light enough that a wrong
  # claim costs real coverage, so each must say what earns it. Asserted about the
  # PROPERTY (no tiers) rather than today's two shapes, so the next zero-tier shape
  # is caught the day it is written — the same reasoning as the full_suite_gate
  # guard above, and the reason `docs` went five weeks unguarded: it predated the
  # rule and nothing asked it to catch up.
  def test_unit_a_shape_with_no_tiers_declares_what_earns_its_claim
    YAML.safe_load(File.read(FEATURE_SHAPES)).fetch("shapes").each do |name, shape|
      next unless Array(shape["dor_tiers"]).empty?

      assert shape["claimable_when"],
             "shape #{name.inspect} demands NO tiers and declares no `claimable_when`, so its lighter " \
             "contract is unlocked by TYPING its name — the declaration-over-evidence bug this taxonomy " \
             "exists to kill. MEASURED on `docs` (PR #1172, 2026-09-02): a docs-claimed diff carrying a " \
             "test file was told 'DoR-to-Merge met' with no tier and no cert demanded. Name the diff rule " \
             "that earns this shape (doc_only_diff / test_only_diff), and implement it in bin/dor-check."
    end
  end
end
