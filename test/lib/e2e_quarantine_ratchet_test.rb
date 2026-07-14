# frozen_string_literal: true

# THE EXECUTED SET of the Playwright `e2e` lane — PINNED, arithmetically.
#
#     69 specs committed  −  18 quarantined  ==  51 the lane runs
#
# That identity is this file. Every assertion below exists to make it TRUE, and to make any
# way of breaking it RED.
#
# WHY THE SET AND NOT THE COMMAND. The first version of this guard (and of its sibling,
# test/lib/ci_workflow_triggers_test.rb) bound the ci.yml COMMAND: it proved the `playwright`
# job runs unconditionally, over the whole suite, with no positional path and no positive
# `--grep`. All true, all still asserted over there — and all defeated in review of #543 by
# ONE WORD. Committing `test.only` on a single healthy spec collapsed the lane from 51 specs
# to 1, ENTIRELY GREEN: shard 1/3 ran that one test and passed, shards 2/3 and 3/3 selected
# ZERO tests and **exited 0, silently** (sharding suppresses playwright's own "No tests
# found" guard, which unsharded would have exited 1 and failed safe). The ci.yml command was
# byte-identical the whole time. So was the ratchet's @quarantine count. Every guard in the
# repo stayed green while the lane covered 1/51st of what its green check claimed.
#
# The lesson is the one this PR was written to teach, turned back on the PR itself: a guard
# that enumerates the ways to cheat will always miss one. `@quarantine` was the spelling we
# imagined. `.only` was not. `.skip` and `.fixme` were not. So this file stopped enumerating
# spellings and started asserting the PROPERTY — the executed set is exactly the committed
# set minus the quarantined set, and NOTHING ELSE removes a spec from the lane. Under that
# invariant `.only`, `.skip`, `.fixme`, `.fail`, a `testDir`/`testIgnore` narrowing, a
# deleted spec file, an empty shard, and the spellings nobody has thought of yet are all
# red, because they all break the same arithmetic.
#
# The rule that makes it airtight is DEFAULT-DENY (see INERT_MODIFIERS): a spec declaration
# must be a BARE `test(...)`. Every dotted form is refused BY NAME unless it is on a short
# allowlist of modifiers that provably cannot change WHICH specs run (`describe`, the hooks,
# `use`, `step`, `setTimeout`, `slow`). A modifier Playwright ships next year lands on the
# deny side by default, which is the only side a guard may default to.
#
# THE @quarantine HOLE, which this file also bounds. CI runs the lane with
# `--grep-invert @quarantine` (.github/workflows/ci.yml), excluding the 18 specs that were
# already RED on an untouched `release` checkout the day the lane was switched on. That
# exclusion buys the healthy 51 a real lane TODAY instead of holding them hostage to a
# repair — but it is a hole, and until this file existed it was UNBOUNDED. The count may
# fall; it may never rise.
#
# TO REPAIR A SPEC: drop its ` @quarantine` tag, and move BOTH counters below in the same
# commit (CEILING down by one, LANE_SPECS up by one; TOTAL_SPECS does not move). The
# assertions will tell you the numbers. When CEILING reaches 0, delete the
# `--grep-invert @quarantine` flag from ci.yml — the suite is whole, and only the
# executed-set half of this file is still load-bearing. Repair is ticketed at
# /tasks/repair-rotted-e2e-specs.
#
# Run directly:
#   ruby -Itest test/lib/e2e_quarantine_ratchet_test.rb
#
# Two tiers (backend shape):
#   [unit]        the spec/quarantine/modifier scanners, over fixture spec text.
#   [integration] the REAL committed e2e/ suite, ci.yml, and playwright.config.js.

require "minitest/autorun"

class E2eQuarantineRatchetTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  E2E_DIR = File.join(ROOT, "e2e")
  CONFIG_PATH = File.join(ROOT, "playwright.config.js")
  CI_PATH = File.join(ROOT, ".github", "workflows", "ci.yml")

  # ==== THE EXECUTED SET ==============================================================
  # Verified against playwright's OWN view of the suite, not taken from prose:
  #   npx playwright test --list                           -> 69 tests in 27 files
  #   npx playwright test --list --grep-invert @quarantine -> 51 tests in 25 files
  # Keep these three in lockstep with that command. They are a PIN, not a bound: the lane
  # runs exactly LANE_SPECS specs, and if it ever runs a different number, something has
  # silently changed what the green `playwright` check covers.
  TOTAL_SPECS = 69   # every `test(...)` committed under e2e/
  CEILING     = 18   # of those, the rotted ones carrying ` @quarantine` in the title
  LANE_SPECS  = 51   # TOTAL_SPECS - CEILING == what CI actually executes
  # ====================================================================================

  # A SPEC is a BARE `test(` / `it(` call with a title. No modifier. That is the only form
  # this suite is allowed to use, and the only form that contributes to the counts.
  SPEC_DECLARATION = /^\s*(?:test|it)\s*\(\s*(?<q>["'`])(?<title>.*?)\k<q>/

  # A GROUP is `test.describe(` / `describe(` with a title. It runs specs; it is not one.
  GROUP_DECLARATION = /^\s*(?:test\.describe|describe)\s*\(\s*(?<q>["'`])(?<title>.*?)\k<q>/

  # ANY dotted call on test/it/describe, titled or not. `test.skip()` with NO arguments,
  # sitting inside a spec body, is a runtime skip — it suppresses that spec and reports it
  # as skipped, exit 0. A title-based scanner never sees it. This one does.
  MODIFIER_CALL = /\b(?<callee>test|it|describe)\.(?<modifier>\w+(?:\.\w+)*)\s*\(/

  # DEFAULT-DENY. These modifiers provably cannot change WHICH specs run: they group, hook,
  # configure options, or stretch a timeout. Everything else — `only`, `skip`, `fixme`,
  # `fail`, and whatever Playwright ships next — is refused by name. A guard's default must
  # be to refuse the thing it has not been taught about, or it is just an enumeration of the
  # cheats we happened to imagine, which is the exact failure this file exists to correct.
  INERT_MODIFIERS = %w[
    describe
    describe.configure
    beforeEach afterEach beforeAll afterAll
    use step setTimeout slow info
  ].freeze

  # Comments are not code. `// do not use test.skip here` must not turn the suite red, or the
  # first false alarm gets this guard weakened — and a weakened guard is worse than none.
  def strip_comments(source)
    source.gsub(%r{/\*.*?\*/}m, "").gsub(%r{//[^\n]*}, "")
  end

  def spec_titles(source)
    strip_comments(source).lines.filter_map { |line| line.match(SPEC_DECLARATION)&.[](:title) }
  end

  def group_titles(source)
    strip_comments(source).lines.filter_map { |line| line.match(GROUP_DECLARATION)&.[](:title) }
  end

  def quarantined_titles(source)
    spec_titles(source).select { |title| title.include?("@quarantine") }
  end

  # Every dotted form in the source that is NOT on the inert allowlist, reported as written
  # (`test.only`, `test.describe.skip`, …) so a failure names the offender.
  def selection_modifiers(source)
    strip_comments(source).scan(MODIFIER_CALL).filter_map do |callee, modifier|
      "#{callee}.#{modifier}" unless INERT_MODIFIERS.include?(modifier)
    end
  end

  def spec_files
    Dir.glob(File.join(E2E_DIR, "**", "*.spec.js")).sort
  end

  def each_spec_file
    spec_files.map { |path| [path, File.read(path)] }
  end

  def committed_spec_count
    each_spec_file.sum { |_path, source| spec_titles(source).size }
  end

  def committed_quarantine_count
    each_spec_file.sum { |_path, source| quarantined_titles(source).size }
  end

  # Files carrying at least one spec the lane actually runs. Playwright keeps a file's specs
  # together when sharding, so this — not the spec count alone — is what floors a shard.
  def committed_lane_file_count
    each_spec_file.count do |_path, source|
      spec_titles(source).any? { |title| !title.include?("@quarantine") }
    end
  end

  def shard_total
    File.read(CI_PATH)[/^\s*shard:\s*\[(?<list>[^\]]*)\]/, :list].split(",").size
  end

  # --- [unit] the scanners -------------------------------------------------------------

  def test_unit_counts_a_bare_spec_and_reads_its_tag
    source = <<~JS
      test("board shows the card @quarantine", async ({ page }) => {});
      test("board filters by agent", async ({ page }) => {});
    JS
    assert_equal 2, spec_titles(source).size
    assert_equal ["board shows the card @quarantine"], quarantined_titles(source)
  end

  def test_unit_ignores_the_word_outside_a_title
    # The flag in ci.yml and the prose in playwright.config.js both contain the literal
    # string. A naive `grep -c @quarantine` over the tree counts those and reads high — a
    # ratchet with slack in it, which would let a real tag slip in under the ceiling.
    source = <<~JS
      // Never tag a spec @quarantine to get a PR green.
      test("board filters by agent", async ({ page }) => {});
    JS
    assert_empty quarantined_titles(source)
    assert_equal 1, spec_titles(source).size
  end

  def test_unit_a_group_is_not_a_spec
    source = <<~JS
      test.describe("live updates", () => {
        test("streams a new card", async () => {});
        test("removes a closed card", async () => {});
      });
    JS
    assert_equal 2, spec_titles(source).size
    assert_equal ["live updates"], group_titles(source)
    assert_empty selection_modifiers(source)
  end

  # ==== THE MUTATIONS, AS UNIT TESTS ==================================================
  # Each of these is a way to drop a spec out of the lane while every other guard in the
  # repo stays green. `.only` is the one that got past review. The rest are its siblings.

  def test_unit_refuses_only
    assert_equal ["test.only"], selection_modifiers('test.only("healthy spec", async () => {});')
  end

  def test_unit_refuses_skip_and_fixme
    source = <<~JS
      test.skip("rotted spec", async () => {});
      test.fixme("other rotted spec", async () => {});
    JS
    assert_equal ["test.skip", "test.fixme"], selection_modifiers(source)
  end

  def test_unit_refuses_a_bare_runtime_skip_inside_a_spec_body
    # No title, so no title-scanner sees it — and the spec silently reports as skipped.
    source = <<~JS
      test("healthy spec", async ({ page }) => {
        test.skip();
        await page.goto("/");
      });
    JS
    assert_equal ["test.skip"], selection_modifiers(source)
  end

  def test_unit_refuses_a_modifier_on_a_group
    # `test.describe.only` deselects every OTHER file in the suite at once — the blast
    # radius of `.only`, one level up.
    source = <<~JS
      test.describe.only("live updates", () => {
        test("streams a new card", async () => {});
      });
    JS
    assert_equal ["test.describe.only"], selection_modifiers(source)
  end

  def test_unit_refuses_a_modifier_nobody_has_invented_yet
    # THE POINT OF THE ALLOWLIST. This file cannot know what Playwright will ship, so it
    # refuses what it has not been taught. A blocklist of {only, skip, fixme, fail} waves
    # this straight through — and a blocklist is exactly how `.only` got past the first
    # version of this guard.
    assert_equal ["test.mothballed"],
                 selection_modifiers('test.mothballed("healthy spec", async () => {});')
  end

  def test_unit_permits_the_inert_forms
    source = <<~JS
      test.describe("suite", () => {
        test.setTimeout(45_000);
        test.beforeEach(async ({ page }) => { await page.goto("/"); });
        test.use({ locale: "en-GB" });
        test("a spec", async () => {});
      });
    JS
    assert_empty selection_modifiers(source)
    assert_equal 1, spec_titles(source).size
  end
  # ====================================================================================

  # --- [integration] the real committed suite ------------------------------------------

  # ==== THE EXECUTED-SET INVARIANT ====================================================
  # The one assertion this whole file is for. It is arithmetic, so it cannot be satisfied by
  # a spelling: every change to what the lane executes lands here.
  def test_integration_the_lane_executes_exactly_the_specs_it_claims_to
    total = committed_spec_count
    quarantined = committed_quarantine_count
    executed = total - quarantined

    assert_equal TOTAL_SPECS, total,
                 "e2e/ holds #{total} specs but TOTAL_SPECS is #{TOTAL_SPECS}. If you ADDED " \
                 "a spec, raise TOTAL_SPECS and LANE_SPECS by one and confirm CI runs it " \
                 "(`npx playwright test --list`). If you DELETED one — or deleted a whole " \
                 "spec file — say so here in the same commit, because a spec that quietly " \
                 "leaves the tree leaves the green `playwright` check covering less than it " \
                 "did yesterday, and nothing else in the repo will mention it."

    assert_equal LANE_SPECS, executed,
                 "the lane executes #{executed} specs (#{total} committed − #{quarantined} " \
                 "quarantined) but LANE_SPECS pins it at #{LANE_SPECS}. The green " \
                 "`playwright` check now covers a DIFFERENT SET than the one this repo " \
                 "signed off on. Reconcile the numbers deliberately — do not just move the " \
                 "constant to match, which is the self-declaration disease this lane exists " \
                 "to cure."

    assert_equal LANE_SPECS, TOTAL_SPECS - CEILING,
                 "the constants no longer add up: TOTAL_SPECS(#{TOTAL_SPECS}) − " \
                 "CEILING(#{CEILING}) != LANE_SPECS(#{LANE_SPECS}). The executed set is " \
                 "DEFINED as everything committed that is not quarantined. If that is no " \
                 "longer true, the lane has grown a second way to drop a spec and this file " \
                 "has stopped bounding it."
  end

  # THE DEFAULT-DENY GATE. This is what makes the arithmetic above honest: with no selection
  # modifier anywhere, "committed minus quarantined" IS "executed", and there is no third way
  # out. `.only` collapses the lane to one spec across three green shards; `.skip` and
  # `.fixme` drop a spec with every other guard green; a bare `test.skip()` in a body does it
  # with no title to grep for at all. All of them die here, by name.
  def test_integration_no_spec_is_deselected_by_a_modifier
    offenders = each_spec_file.flat_map do |path, source|
      selection_modifiers(source).map { |modifier| "#{File.basename(path)}: #{modifier}" }
    end

    assert_empty offenders,
                 "these e2e specs carry a SELECTION MODIFIER, which silently changes which " \
                 "specs the lane runs while the ci.yml command, the shard matrix and the " \
                 "@quarantine count all stay byte-identical:\n  #{offenders.join("\n  ")}\n" \
                 "`.only` collapses the whole lane to the marked spec — and the other shards " \
                 "select ZERO tests and EXIT 0, so CI goes green over nothing. `.skip` and " \
                 "`.fixme` drop the spec outright. If a spec is rotted there are two honest " \
                 "moves and no third: FIX it, or ` @quarantine` it (which the ceiling below " \
                 "makes you account for) and BLOCK on /tasks/repair-rotted-e2e-specs. If you " \
                 "need a genuinely inert modifier, add it to INERT_MODIFIERS and say why."
  end

  # A tag on a GROUP excludes every spec inside it — an unknown number — while the spec
  # counter above dutifully counts them one by one. That would break the arithmetic silently,
  # which is the one thing the arithmetic may not do.
  def test_integration_no_group_is_quarantined
    offenders = each_spec_file.flat_map do |path, source|
      group_titles(source).select { |title| title.include?("@quarantine") }
                          .map { |title| "#{File.basename(path)}: #{title}" }
    end

    assert_empty offenders,
                 "a `describe` block is tagged @quarantine:\n  #{offenders.join("\n  ")}\n" \
                 "`--grep-invert` drops EVERY spec in that block, but the ceiling counts " \
                 "specs individually — so the hole would grow by N while the counter moved " \
                 "by 0. Tag the individual specs instead."
  end

  # ==== THE RATCHET ===================================================================
  # Exact equality, both directions, zero headroom: tag one more spec and this is red;
  # repair one and this MAKES YOU lower the ceiling in the same commit, so the hole cannot
  # quietly grow back to where it started. Bounded is not the same as shrinking.
  def test_integration_the_quarantine_hole_never_grows_and_ratchets_down
    count = committed_quarantine_count

    assert_equal CEILING, count,
                 "#{count} specs under e2e/ carry @quarantine; CEILING is #{CEILING}.\n" \
                 "If you ADDED a tag: CI runs the e2e lane with `--grep-invert @quarantine`, " \
                 "so every tag SILENTLY DELETES a spec from the only lane that runs it — the " \
                 "check stays green over less and less. Tagging a spec to green a PR is the " \
                 "exact self-declaration disease this lane was built to cure. Two honest " \
                 "moves, no third: FIX the spec, or BLOCK on it.\n" \
                 "If you REPAIRED #{CEILING - count} spec(s) — thank you — now lower CEILING " \
                 "to #{count} and raise LANE_SPECS to #{TOTAL_SPECS - count} in THIS commit. " \
                 "Otherwise the hole you just shrank can quietly grow back and no guard will " \
                 "say a word. When CEILING hits 0, drop the `--grep-invert @quarantine` flag " \
                 "from .github/workflows/ci.yml: the suite is whole. " \
                 "(/tasks/repair-rotted-e2e-specs)"
  end
  # ====================================================================================

  # --- [integration] the config and the shards -----------------------------------------

  def test_integration_playwright_forbids_only_under_ci
    config = File.read(CONFIG_PATH)

    assert_match(/forbidOnly:\s*!!process\.env\.CI/, config,
                 "playwright.config.js has no `forbidOnly: !!process.env.CI`. Without it a " \
                 "committed `test.only` collapses the lane to a single spec and all three " \
                 "shards go GREEN — the empty ones exit 0, because sharding suppresses " \
                 "playwright's own zero-test guard. The executed-set assertion above is the " \
                 "durable catch; this is the cheap hard stop at the lane itself, and both " \
                 "are cheap enough to keep.")
  end

  # The other end of the pipe. The specs can be perfect and the count exact, and a one-word
  # edit HERE still narrows what runs — `testDir: "./e2e/smoke"`, or a `testIgnore`. The spec
  # count would not move, because the specs are all still committed; they would just stop
  # being collected. The executed-set arithmetic only means something if the config still
  # points at the whole directory.
  def test_integration_playwright_config_does_not_narrow_the_test_set
    config = File.read(CONFIG_PATH)

    assert_match(%r{testDir:\s*"\./e2e"}, config,
                 "playwright.config.js no longer collects the whole ./e2e directory. " \
                 "Narrowing testDir drops specs from the lane WITHOUT changing the spec " \
                 "count, so the ratchet above would stay green over a suite that no longer " \
                 "runs.")

    %w[testIgnore testMatch grep grepInvert].each do |key|
      refute_match(/^\s*#{key}:/, config,
                   "playwright.config.js sets `#{key}`, which silently deselects specs the " \
                   "executed-set assertion still counts as running. The ONE sanctioned " \
                   "exclusion is `--grep-invert @quarantine` in ci.yml, and the ceiling above " \
                   "bounds it. Do not open a second, unbounded one here.")
    end
  end

  # NO SHARD MAY BE EMPTY. This is the mechanism that hid `.only` in the first place: an
  # empty shard exits 0 in silence. The arithmetic above is what stops the executed set from
  # collapsing, but state the floor outright — if the lane ever shrinks below one spec (and
  # one FILE, since playwright keeps a file's specs on the same shard) per shard, a shard
  # goes empty, exits 0, and this lane starts lying again.
  def test_integration_the_lane_cannot_produce_an_empty_shard
    shards = shard_total

    assert_operator LANE_SPECS, :>=, shards,
                    "the lane runs #{LANE_SPECS} specs across #{shards} shards. A shard with " \
                    "no tests EXITS 0 SILENTLY — playwright's 'No tests found' guard does not " \
                    "fire when sharded — so an empty shard is a green check over nothing."

    assert_operator committed_lane_file_count, :>=, shards,
                    "#{committed_lane_file_count} spec files carry a non-quarantined spec, " \
                    "across #{shards} shards. Playwright shards keep a file's specs together, " \
                    "so fewer files than shards leaves a shard empty — and an empty shard " \
                    "exits 0 without a word."
  end
end
