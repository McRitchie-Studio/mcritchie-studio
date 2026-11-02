# frozen_string_literal: true

# Guard for config/feature_shapes.yml's `dor_tiers`: every tier a shape DEMANDS is a tier some
# lane RUNS. Positive: a tier no real runner runs fails, whatever the reason. WHAT COUNTS AS A
# RUNNER, read before "fixing" a failure by widening this list: a file that EXECUTES a
# command, .github/workflows/ci.yml (G2) or bin/fast-check (G1). config/devops_test_suites.yml
# is deliberately NOT a runner: it is a CATALOG. Resolve against what EXECUTES, never what
# DECLARES. SCOPE: mcritchie-studio only; each satellite needs its own copy against its own
# ci.yml. [unit] runs over fixtures; [integration] runs real config vs real runners.
# History: task e2e-tiers-are-decorative.

require "minitest/autorun"
require "yaml"

class FeatureShapeTiersTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FEATURE_SHAPES = File.join(ROOT, "config/feature_shapes.yml")
  # The lanes live in the called workflow; ci.yml only calls it.
  CI_YML = File.join(ROOT, ".github/workflows/reusable-ci.yml")
  FAST_CHECK = File.join(ROOT, "bin/fast-check")

  # The CANONICAL SPEC — the doc an agent actually reads to size its testing. It carries its
  # own copy of the shape→tiers matrix, and a second copy of a truth is a second place for it
  # to rot. See test_integration_the_canonical_spec_matches_the_shipped_config.
  DESIGN_DOC = File.join(ROOT, "docs/agents/system/devops-cycle-design.md")

  # A tier maps to the command that CONSTITUTES running it. Load-bearing: a wrong pattern passes
  # vacuously. Patterns are matched against real runner commands below;
  # test_unit_every_known_tier_has_a_command_pattern keeps the table total.
  # unit/component/integration share one pattern: the minitest sweep runs all of test/**
  # (audited by bin/rails-executed-set-check), so the tier TAG is the builder's claim and the
  # LANE proves the file runs. e2e: Playwright needs a booted server, so it is its own job,
  # never a bare argless rails lane. e2e_onchain: no pattern, no runner: see the constant below.
  # History: task e2e-tiers-are-decorative.
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
  #   · turf-monster's scheduled devnet workflow — the only one that could have served —
  #     was gated on a repo variable, completed `skipped` on every scheduled run, and was
  #     deleted on 2026-10-24 without ever executing. The devnet signal is now the
  #     per-release `contest-rehearsal` gauntlet, an operator/QA act.
  # So the strictest-LOOKING tier in the system was the emptiest, on the shapes where
  # emptiness costs the most. It is removed from dor_tiers rather than left as a
  # requirement satisfiable by typing: on-chain verification is real, but it is an
  # operator/QA-stop act, in the same category the shape file already carves out for
  # `manual` — NOT a pre-submit tier a builder self-certifies.
  #
  # To bring it BACK: build the lane first (a per-change devnet job, or a funded
  # scheduled devnet workflow that runs), add its pattern to TIER_COMMANDS, and only then re-add the
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
    ci_run_commands(File.read(CI_YML)) + [File.read(FAST_CHECK)]
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

  # Named for the command it actually matches: the rake-routed suite line, not an argless
  # one. Nothing runs `bin/rails test` bare in this ecosystem's lanes.
  def test_unit_recognizes_the_rake_routed_rails_suite_as_the_minitest_lane
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
    # THE TABLE'S TOTALITY. Every tier this repo KNOWS ABOUT has a command pattern (a lane can run
    # it) XOR is declared structurally unrunnable. A tier in NEITHER set gets [] from
    # `lanes_running`, and the primary guard reports "no runner executes it", burying that nobody
    # told the table. Force the classification at the table, where it is one line to fix.
    # History: task e2e-tiers-are-decorative.
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
  # Every tier the shape file demands must be RUN by a real runner. If this fails: either WIRE
  # THE LANE, or STOP ASKING FOR THE TIER. No third move should be invented to make this green.
  # THE NAME SAYS `_in_this_repo` AND MEANS IT: config/feature_shapes.yml is ECOSYSTEM-WIDE, but
  # RUNNER_FILES below are MCRITCHIE-STUDIO's, so this proves nothing about sibling repos (rolio
  # has no Playwright lane while `ui+db` demands `e2e`). The audit block in that config holds
  # the per-repo picture and the condition that lifts this qualifier. NO TASK CARRIES THAT WORK.
  # History: task e2e-tiers-are-decorative.
  def test_integration_every_required_tier_is_run_by_a_real_lane_in_this_repo
    commands = runner_commands
    tiers = required_tiers(File.read(FEATURE_SHAPES))

    refute_empty tiers, "feature_shapes.yml demands no tiers at all — the shape gate is vacuous"

    uncollected = tiers.reject { |tier| lanes_running(tier, commands).any? }

    assert_empty uncollected,
                 "config/feature_shapes.yml demands tier(s) #{uncollected.inspect} that NO RUNNER " \
                 "EXECUTES. Nothing in .github/workflows/ci.yml or bin/fast-check runs them, " \
                 "so the requirement is satisfied ENTIRELY by a " \
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
  # bin/dor-check must not choose FULL-suite + rubocop evidence by asking `!dor_tiers.empty?`:
  # that welds "which tiers do you owe" to "must your code be certified at all". `docs` ships
  # prose; `test-only` has NO tiers and ships EXECUTABLE CODE.
  # History: task add-test-only-shape.

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
  # devops-cycle-design.md §3.2 ("Required tiers (DoR contract)") carries its own matrix, which
  # a guard reading only config/feature_shapes.yml cannot see. Grepping the doc for one spelling
  # is another blacklist. The doc's tier names are backticked, and this asserts the two copies
  # are the SAME SET, both directions, for every shape: the doc may not demand a tier the config
  # does not, nor drop one it does.
  # History: task e2e-tiers-are-decorative.
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
  # `claimable_when` makes a zero-tier shape safe: the lighter contract is EARNED from the
  # observed diff. A rule bin/dor-check does not implement reads as protection and enforces
  # nothing. dor-check also refuses an unrecognized rule at RUNTIME; this catches the typo
  # earlier, in CI. STRUCTURAL, NOT A GREP FOR THE NAME: rule names appear in prose comments, so
  # it parses the `case claim_rule` dispatch and reads its `when` literals.
  # History: task docs-shape-admits-test-code.
  DOR_CHECK = File.join(ROOT, "bin/dor-check")

  def implemented_claim_rules(source)
    body = source[/^\s*case claim_rule\s*$(.*?)^  end\s*$/m, 1]
    return [] if body.nil?

    body.scan(/^\s*when\s+"([a-z0-9_]+)"/).flatten
  end

  # Guard catalog row 2.6: the config is schema-checked against CLAIM_RULES at load,
  # so the constant must name exactly the `when` arms the dispatch implements.
  def test_unit_claim_rules_names_exactly_the_implemented_arms
    source = File.read(DOR_CHECK)
    declared = source[/^CLAIM_RULES = %w\[([^\]]*)\]/, 1].to_s.split

    assert_equal implemented_claim_rules(source).sort, declared.sort
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
  # is caught the day it is written — the same reasoning as the tier
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
             "that earns this shape (test_only_diff / doc_only_diff / docs_with_guards_diff), and implement it in bin/dor-check."
    end
  end
end
