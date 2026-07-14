# frozen_string_literal: true

# THE DECLARED SET of the Playwright `e2e` lane — the STATIC half of a two-part guard.
#
#     69 specs committed  −  18 quarantined  ==  51 the lane should run
#
# READ THIS FIRST, BECAUSE THE FILE'S NAME OVERSELLS IT. This file reads the SOURCE. It can
# tell you how many specs are DECLARED and not quarantined. It CANNOT tell you how many specs
# RAN — those are different questions, and every escape hatch that has beaten this PR lived in
# the gap between them. What closes that gap is the RECEIPT:
#
#     bin/e2e-executed-set-check  — reads Playwright's OWN JSON report after the lane runs and
#                                   asserts the set it ACTUALLY EXECUTED == config/e2e_lane.yml
#
# Both halves read the same contract (config/e2e_lane.yml), so they can never certify two
# different suites. This half is the FAST one: it fails in the unit lane in milliseconds,
# before anyone burns six minutes of CI on a suite that is already provably wrong. The other
# half is the DURABLE one: it is the only one that generalizes to the spellings nobody has
# imagined yet. Keep both; do not mistake this one for sufficient.
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
# repair — but it is a hole, and until this file existed it was UNBOUNDED.
#
# The count may fall; it may never rise — and "may never rise" is ENFORCED, not asserted in a
# comment: the ceiling is compared against its value on `origin/release` (see BASELINE_REF), a
# number no edit in this working tree can reach. The first version of this guard compared the
# ceiling to the contract file the author was editing, which is a PIN wearing a ratchet's
# name; review proved it by tagging a 19th spec, bumping the contract, and watching every
# guard in the repo — this one and the receipt both — go green over a suite that had just
# shrunk. Read test_integration_the_quarantine_ceiling_never_rises before touching this.
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
require "yaml"
require "open3"

class E2eQuarantineRatchetTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  E2E_DIR = File.join(ROOT, "e2e")
  CONFIG_PATH = File.join(ROOT, "playwright.config.js")
  CI_PATH = File.join(ROOT, ".github", "workflows", "ci.yml")
  CONTRACT_REL = "config/e2e_lane.yml"
  CONTRACT_PATH = File.join(ROOT, CONTRACT_REL)

  # ==== THE CONTRACT ==================================================================
  # The numbers live in config/e2e_lane.yml — ONE file, so there is ONE line to bump and the
  # runtime gate (bin/e2e-executed-set-check) and this static guard can never drift apart and
  # certify two different suites. Verified against playwright's OWN view, not taken from prose:
  #   npx playwright test --list                           -> 69 tests in 27 files
  #   npx playwright test --list --grep-invert @quarantine -> 51 tests in 25 files
  CONTRACT       = YAML.safe_load_file(CONTRACT_PATH).freeze
  TOTAL_SPECS    = CONTRACT.fetch("total_specs")   # every `test(...)` committed under e2e/
  CEILING        = CONTRACT.fetch("quarantined")   # of those, the rotted ones carrying the tag
  LANE_SPECS     = CONTRACT.fetch("executed")      # TOTAL_SPECS - CEILING == what CI executes
  SHARDS         = CONTRACT.fetch("shards")
  QUARANTINE_TAG = CONTRACT.fetch("quarantine_tag")
  # ====================================================================================

  # ==== THE BASELINE — the one number this author's diff CANNOT move ==================
  # Round 4 of review killed the previous version of the ratchet with one measurement, and it
  # is worth stating plainly because the bug is subtle and it is THE BUG THIS WHOLE PR IS ABOUT:
  #
  #   The old assertion was `count == CEILING`, and CEILING is read from config/e2e_lane.yml —
  #   THE SAME FILE THE AUTHOR EDITS. So tagging a 19th spec and bumping the contract 18 -> 19
  #   passed with ZERO failures, and the receipt (50 == 50) went green right behind it. THE
  #   HOLE GREW WITH EVERY GUARD IN THE REPO GREEN. A "ratchet" whose reference value moves
  #   with the thing it is supposed to be restraining is a PIN, not a ratchet.
  #
  # This is the same disease as the receipt, one level up: a guard that reads only what the
  # author wrote can only ever confirm that the author wrote it. The cure is the same one —
  # read something OUTSIDE the diff. For the executed set that is Playwright's own report. For
  # the ceiling it is `origin/release`: the value as it stands on the branch this PR must merge
  # into, which no edit in this working tree can touch.
  #
  # FAIL CLOSED. If the baseline cannot be resolved, this guard goes RED — it does not shrug and
  # pass. A ratchet that cannot see its baseline cannot certify monotonicity, and a green light
  # it has no basis for is precisely the lie being hunted. (CI must therefore fetch the ref:
  # .github/workflows/ci.yml checks out the `test` job with `fetch-depth: 0`, pinned by
  # test/lib/ci_workflow_triggers_test.rb, so dropping it turns the lane RED and loud rather
  # than quietly demoting this back to a pin.)
  BASELINE_REF = "origin/release"
  # ====================================================================================

  # A SPEC is a BARE `test(` / `it(` call with a title. No modifier. That is the only form
  # this suite is allowed to use, and the only form that contributes to the counts.
  SPEC_DECLARATION = /^\s*(?:test|it)\s*\(\s*(?<q>["'`])(?<title>.*?)\k<q>/

  # A GROUP is `test.describe(` / `describe(` with a title. It runs specs; it is not one.
  GROUP_DECLARATION = /^\s*(?:test\.describe|describe)\s*\(\s*(?<q>["'`])(?<title>.*?)\k<q>/

  # ==== TWO AXES OF DEFAULT-DENY ======================================================
  # A guard is only as good as its DEFAULT, and this file has now been beaten twice by a
  # default that was "allow" on an axis nobody was watching.
  #
  # AXIS 1 — THE MODIFIER. Any dotted call on test/it/describe. Default-deny against an
  # ALLOWLIST of provably inert modifiers, so a modifier Playwright ships next year lands on
  # the deny side. (This axis holds: review invented `test.slow.only(...)`, a chain nobody
  # enumerated, and the greedy dotted capture refuses it — `slow.only` is not inert `slow`.)
  MODIFIER_CALL = /\b(?<callee>test|it|describe)\.(?<modifier>\w+(?:\.\w+)*)\s*\(/

  INERT_MODIFIERS = %w[
    describe
    describe.configure
    beforeEach afterEach beforeAll afterAll
    use step setTimeout slow info
  ].freeze

  # AXIS 2 — THE RECEIVER. Axis 1 anchors its receiver to `test|it|describe`, which made the
  # RECEIVER an enumeration — the exact shape this file spent two rounds eliminating one axis
  # over. Playwright's documented TestInfo API produces the IDENTICAL runtime skip from a
  # different receiver, and it walked straight past the guard above:
  #
  #     test("landing page loads", async ({ page }, testInfo) => {
  #       testInfo.skip();     // MEASURED on this repo: exit 0, "1 skipped", every guard GREEN
  #
  # So the verbs are refused on ANY receiver: `testInfo.skip()`, `test.info().skip()`, an
  # aliased `const t = test; t.skip()`. The receiver is no longer a list to keep up to date.
  #
  # THIS AXIS CANNOT BE CLOSED AT THE SOURCE, AND THAT IS THE POINT. A destructured
  # `const { skip } = testInfo; skip()`, or a helper in another file that calls `ti.skip()`
  # for you, has no `.skip(` in the spec at all — no regex on this text can see it. That is
  # not a hole to be plugged with a cleverer regex; it is PROOF that a source-level guard is
  # the wrong instrument for this question. It is closed at RUNTIME, where a skipped spec is
  # a skipped spec whatever the syntax: bin/e2e-executed-set-check reads Playwright's own
  # report and refuses a lane with any skip in it. This axis is mutation-proved in BOTH
  # directions — the destructured vector is GREEN here and RED there, deliberately.
  # The receiver class must include `(` and `)`, or `test.info().skip()` matches with the
  # receiver read as a bare `)` — it still FIRES (the verb is what is being denied), but it
  # names the offender uselessly, and a guard whose failure message is gibberish is a guard
  # somebody deletes. Caught by test_unit_refuses_a_runtime_skip_through_test_info.
  SELECTION_VERBS = %w[only skip fixme fail].freeze
  SELECTION_CALL = /(?<receiver>[\w$()\].]+)\s*\.\s*(?<verb>#{Regexp.union(SELECTION_VERBS)})\s*\(/
  # ====================================================================================

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

  # The tag comes from the CONTRACT, never from a literal. The file's whole claim is that both
  # halves of the guard read ONE contract; a hardcoded "@quarantine" here would have made that
  # claim false the day someone changed `quarantine_tag:` — the static half would have kept
  # counting the old spelling while the runtime half excluded the new one, and they would have
  # certified two different suites while agreeing on the number. Small, but it is the same
  # disease: a claim ("one contract") outrunning the mechanism (a literal).
  def quarantined_titles(source)
    spec_titles(source).select { |title| title.include?(QUARANTINE_TAG) }
  end

  # BOTH axes, unioned, reported as written (`test.only`, `test.describe.skip`,
  # `testInfo.skip`, `test.info().skip`, …) so a failure names the offender exactly.
  def selection_modifiers(source)
    clean = strip_comments(source)

    by_modifier = clean.scan(MODIFIER_CALL).filter_map do |callee, modifier|
      "#{callee}.#{modifier}" unless INERT_MODIFIERS.include?(modifier)
    end

    by_receiver = clean.scan(SELECTION_CALL).map { |receiver, verb| "#{receiver}.#{verb}" }

    (by_modifier + by_receiver).uniq
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

  # ---- the baseline ------------------------------------------------------------------

  # `quarantined` out of a contract BLOB (not the working file). Returns nil for anything we
  # cannot read as the contract — a truncated blob, a renamed key, a YAML error. nil means
  # UNKNOWN, and every caller treats UNKNOWN as RED: see baseline_ceiling.
  def ceiling_in(yaml_text)
    value = YAML.safe_load(yaml_text.to_s)
    return nil unless value.is_a?(Hash)

    ceiling = value["quarantined"]
    ceiling.is_a?(Integer) ? ceiling : nil
  rescue Psych::Exception
    nil
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", ROOT, *args)
    status.success? ? out : nil
  end

  # The ceiling as it stands OUTSIDE this working tree. Returns [ceiling, provenance], or
  # [nil, why_not] — and [nil, …] is a RED, never a pass.
  #
  # TWO SOURCES, IN ORDER, AND THE SECOND ONE IS NOT A LOOPHOLE:
  #
  #   1. THE RELEASED CEILING — `origin/release:config/e2e_lane.yml`. Once the contract is on
  #      release this is the only baseline, forever. Nothing in a feature branch can move it.
  #
  #   2. THE INTRODUCING COMMIT — for the ONE branch that ADDS the contract (this one: the file
  #      does not exist on release yet). There is no released value to ratchet against, so the
  #      baseline is the value at the commit that first added the file on this branch.
  #
  #      Without case 2 the bootstrap branch would have NO baseline, and "no baseline" would
  #      have to mean either RED (this PR can never be green — absurd) or PASS (the ratchet is
  #      decorative on the exact PR that introduces it — which is the bug, shipped one level up,
  #      and is precisely how I would have re-committed the offense I am fixing). Case 2 is what
  #      makes the mutation vector — tag a 19th spec, bump the contract — go RED **today**,
  #      on this branch, rather than someday after merge.
  #
  #      What it does NOT do is let the ceiling drift up inside this branch: a later commit that
  #      raises it is measured against the introducing commit and goes RED. The initial value is
  #      the one thing case 2 cannot police, and it does not need to — a brand-new contract file
  #      is a wholly-added diff, and its ceiling is a reviewed line on it. After merge, case 1
  #      takes over and case 2 can never fire for this file again.
  def baseline_ceiling
    return [nil, "git cannot read #{ROOT} (not a repository?)"] unless git("rev-parse", "--git-dir")

    unless git("rev-parse", "--verify", "--quiet", "#{BASELINE_REF}^{commit}")
      return [nil, "`#{BASELINE_REF}` does not resolve — run `git fetch origin release`"]
    end

    released = git("show", "#{BASELINE_REF}:#{CONTRACT_REL}")
    if released
      ceiling = ceiling_in(released)
      return [nil, "`#{BASELINE_REF}:#{CONTRACT_REL}` has no readable `quarantined:`"] if ceiling.nil?

      return [ceiling, "#{BASELINE_REF}:#{CONTRACT_REL}"]
    end

    # Case 2: the contract is NEW to release. Find the commit that added it on this branch.
    log = git("log", "#{BASELINE_REF}..HEAD", "--diff-filter=A", "--format=%H", "--", CONTRACT_REL)
    introduced = log.to_s.split("\n").map(&:strip).reject(&:empty?).last
    if introduced.nil?
      return [nil, "#{CONTRACT_REL} is on neither `#{BASELINE_REF}` nor any commit in " \
                   "`#{BASELINE_REF}..HEAD` — commit it before this guard can baseline it"]
    end

    ceiling = ceiling_in(git("show", "#{introduced}:#{CONTRACT_REL}"))
    return [nil, "#{introduced[0, 8]}:#{CONTRACT_REL} has no readable `quarantined:`"] if ceiling.nil?

    [ceiling, "#{introduced[0, 8]}:#{CONTRACT_REL} (the commit that ADDED the contract; it is " \
              "not on `#{BASELINE_REF}` yet)"]
  end

  # Files carrying at least one spec the lane actually runs. Playwright keeps a file's specs
  # together when sharding, so this — not the spec count alone — is what floors a shard.
  def committed_lane_file_count
    each_spec_file.count do |_path, source|
      spec_titles(source).any? { |title| !title.include?(QUARANTINE_TAG) }
    end
  end

  # The shard matrix, read from ci.yml in EITHER YAML sequence style. The first version of
  # this reached straight into a flow-sequence regex and called `.split` on the result — so
  # rewriting the matrix as a BLOCK sequence (`shard:\n  - 1\n  - 2`), which is the same YAML,
  # raised NoMethodError on nil instead of asserting. It failed safe, but it failed as an
  # ERROR, and an error is a worse gate than an assertion: it reads as "the test is broken",
  # which is the kind of red people rerun rather than investigate. Parse the YAML.
  def shard_matrix
    doc = YAML.safe_load_file(CI_PATH, aliases: true, permitted_classes: [Date])
    shards = doc.dig("jobs", "playwright", "strategy", "matrix", "shard")
    Array(shards)
  end

  def shard_total = shard_matrix.size

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

  # ---- AXIS 2: THE RECEIVER ----------------------------------------------------------
  # The vector that beat round 3. Playwright's DOCUMENTED TestInfo API, identical runtime
  # effect, different receiver — so a guard anchored to `test|it|describe` never saw it.
  def test_unit_refuses_a_runtime_skip_on_the_testinfo_receiver
    source = <<~JS
      test("landing page loads", async ({ page }, testInfo) => {
        testInfo.skip();
        await page.goto("/");
      });
    JS
    assert_equal ["testInfo.skip"], selection_modifiers(source)
  end

  # A NEW VECTOR, invented here: `test.info()` returns the TestInfo without ever destructuring
  # the fixture argument, so the receiver is a CALL EXPRESSION rather than an identifier. Any
  # "fix" for the blocker above that just widened the callee list to `test|it|describe|testInfo`
  # would wave this straight through — which is precisely how the last three rounds went.
  def test_unit_refuses_a_runtime_skip_through_test_info
    source = <<~JS
      test("landing page loads", async ({ page }) => {
        test.info().skip();
        await page.goto("/");
      });
    JS
    assert_includes selection_modifiers(source), "test.info().skip"
  end

  # A NEW VECTOR: alias the receiver. `const t = test` defeats ANY enumeration of receiver
  # names, however long the list gets — which is the argument for denying the VERB on any
  # receiver rather than policing the receiver.
  def test_unit_refuses_a_selection_verb_on_an_aliased_receiver
    assert_equal ["t.skip"], selection_modifiers('const t = test; t.skip("rotted spec", () => {});')
  end

  # ==== THE HONEST LIMIT OF EVERY SOURCE-LEVEL GUARD ==================================
  # This test asserts that this file CANNOT catch something. That is not a defect to be
  # patched with a cleverer regex — it is the whole reason the runtime gate exists, pinned
  # here so nobody deletes bin/e2e-executed-set-check believing the static scan covers it.
  #
  # Destructure the method off TestInfo and there is no `.skip(` in the spec at all. Put it in
  # a helper module and the spec file is clean as a whistle. No regex over this text can see
  # either one. The lane still loses the spec, silently, exit 0.
  #
  # RED at runtime, GREEN here — and that asymmetry is mutation-proved in both directions.
  def test_unit_a_destructured_skip_is_INVISIBLE_to_this_file_and_that_is_why_the_receipt_exists
    source = <<~JS
      test("landing page loads", async ({ page }, testInfo) => {
        const { skip } = testInfo;
        skip();
        await page.goto("/");
      });
    JS

    assert_empty selection_modifiers(source),
                 "if this ever starts catching the destructured form, GOOD — but do not " \
                 "conclude the source scan is sufficient. A helper in another file " \
                 "(`maybeSkip(testInfo)`) has no skip token in the spec at all, and never " \
                 "will. The executed set is decided at RUNTIME and can only be checked there."

    # And here is the thing that DOES catch it: the receipt. Same spec, as Playwright reports
    # it — one test, status `skipped`. bin/e2e-executed-set-check refuses this outright.
    skipped_in_report = { "title" => "landing page loads", "status" => "skipped" }
    refute_equal "expected", skipped_in_report["status"],
                 "the runtime gate keys on exactly this: a spec that did not reach a verdict"
  end
  # ====================================================================================

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

  # --- [unit] the baseline parser --------------------------------------------------------
  # The ratchet is only as good as its baseline, and the baseline arrives as a git BLOB — a
  # string that may be anything at all. `nil` means UNKNOWN and every caller turns UNKNOWN into
  # RED, so these cases are the difference between a ratchet that fails closed and one that
  # quietly waves a bad blob through.

  def test_unit_reads_the_ceiling_from_a_contract_blob
    assert_equal 18, ceiling_in("total_specs: 69\nquarantined: 18\nexecuted: 51\n")
  end

  def test_unit_an_unparseable_baseline_is_unknown_not_zero
    # Zero would be the WORST possible default: `CEILING <= 0` fails every non-empty ceiling,
    # which LOOKS strict — and then someone "fixes the flaky guard" by relaxing it. nil is
    # honest: we do not know, so we do not certify.
    assert_nil ceiling_in("\tthis: is: not: yaml\n[")
    assert_nil ceiling_in("")
    assert_nil ceiling_in(nil)
  end

  def test_unit_a_baseline_missing_the_key_is_unknown
    assert_nil ceiling_in("total_specs: 69\nexecuted: 51\n")
  end

  def test_unit_a_non_integer_ceiling_is_unknown
    # `quarantined: eighteen` would make `CEILING <= "eighteen"` raise ArgumentError — an
    # ERROR, which reads as "the test is broken" and gets rerun, not investigated. Caught here
    # so it reads as what it is: a baseline we cannot trust.
    assert_nil ceiling_in("quarantined: eighteen\n")
    assert_nil ceiling_in("quarantined:\n")
  end

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
      group_titles(source).select { |title| title.include?(QUARANTINE_TAG) }
                          .map { |title| "#{File.basename(path)}: #{title}" }
    end

    assert_empty offenders,
                 "a `describe` block is tagged #{QUARANTINE_TAG}:\n  #{offenders.join("\n  ")}\n" \
                 "`--grep-invert` drops EVERY spec in that block, but the ceiling counts " \
                 "specs individually — so the hole would grow by N while the counter moved " \
                 "by 0. Tag the individual specs instead."
  end

  # ==== THE PIN — the source agrees with the contract =================================
  # Exact equality, both directions, zero headroom: the tags actually committed under e2e/
  # must be the number the contract declares. This keeps the two halves of the guard honest
  # about the SAME suite — but note what it CANNOT do, because for three rounds it was
  # mistaken for the thing below: it compares the author's tags to the author's contract.
  # Move both together and it is green. That is a PIN. The ratchet is the next test.
  def test_integration_the_declared_quarantine_set_matches_the_contract
    count = committed_quarantine_count

    assert_equal CEILING, count,
                 "#{count} specs under e2e/ carry #{QUARANTINE_TAG}; the contract " \
                 "(#{CONTRACT_REL}) declares #{CEILING}.\n" \
                 "If you ADDED a tag: CI runs the e2e lane with `--grep-invert " \
                 "#{QUARANTINE_TAG}`, so every tag SILENTLY DELETES a spec from the only lane " \
                 "that runs it — the check stays green over less and less. Tagging a spec to " \
                 "green a PR is the exact self-declaration disease this lane was built to " \
                 "cure. Two honest moves, no third: FIX the spec, or BLOCK on it. (And the " \
                 "ratchet below will refuse the contract bump anyway.)\n" \
                 "If you REPAIRED #{CEILING - count} spec(s) — thank you — now lower " \
                 "`quarantined` to #{count} and raise `executed` to #{TOTAL_SPECS - count} in " \
                 "THIS commit. When `quarantined` hits 0, drop the `--grep-invert " \
                 "#{QUARANTINE_TAG}` flag from .github/workflows/ci.yml: the suite is whole. " \
                 "(/tasks/repair-rotted-e2e-specs)"
  end

  # ==== THE RATCHET — and this one actually ratchets ==================================
  # The ceiling is measured against `origin/release` (see BASELINE_REF), NOT against the copy
  # in this working tree. That is the whole difference between a ratchet and a pin, and it is
  # the difference review MEASURED: with the old assertion, tagging a 19th spec and bumping
  # the contract 18 -> 19 was GREEN — every guard in the repo, plus the receipt, all green,
  # while the hole grew.
  #
  # The name promises exactly what is enforced and no more: the ceiling NEVER RISES. Nothing
  # here forces it DOWN — a ratchet prevents backsliding, it does not do the work. Driving 18
  # to 0 is /tasks/repair-rotted-e2e-specs, and this guard is what stops the number from
  # quietly wandering back up while that ticket waits.
  def test_integration_the_quarantine_ceiling_never_rises
    baseline, provenance = baseline_ceiling

    refute_nil baseline,
               "THE RATCHET CANNOT SEE ITS BASELINE, so it cannot certify anything: " \
               "#{provenance}.\n" \
               "This is RED ON PURPOSE. The ceiling is monotonic only if it is compared to a " \
               "value OUTSIDE this working tree (`#{BASELINE_REF}`); a guard that silently " \
               "passed when it could not read that value would be a green light with nothing " \
               "behind it — the exact failure this lane exists to prevent. Fetch the ref " \
               "(`git fetch origin release`) and run it again."

    assert_operator CEILING, :<=, baseline,
                    "THE QUARANTINE HOLE IS GROWING. The contract (#{CONTRACT_REL}) now " \
                    "declares `quarantined: #{CEILING}`; the baseline is #{baseline} " \
                    "(#{provenance}).\n" \
                    "Every increment here PERMANENTLY DELETES a spec from the only lane that " \
                    "runs it, and the receipt will happily go green over the smaller suite — " \
                    "50 == 50 is just as green as 51 == 51. That is why this number may not " \
                    "rise: it is the one thing no other guard in this PR can see.\n" \
                    "You are #{CEILING - baseline} over. Two honest moves, no third: FIX the " \
                    "spec(s) you were about to tag, or BLOCK your task on " \
                    "/tasks/repair-rotted-e2e-specs. If you genuinely believe the ceiling must " \
                    "rise, that is a REVIEW decision, not a green build: say so in the PR and " \
                    "let a human agree to give up the coverage."
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
    config = strip_comments(File.read(CONFIG_PATH))

    assert_match(%r{testDir:\s*"\./e2e"}, config,
                 "playwright.config.js no longer collects the whole ./e2e directory. " \
                 "Narrowing testDir drops specs from the lane WITHOUT changing the spec " \
                 "count, so the ratchet above would stay green over a suite that no longer " \
                 "runs.")

    # NOT line-anchored. The first version of this used /^\s*#{key}:/, which only sees a key
    # at the start of a line — so an INLINE `grep:` tucked into the projects array
    # (`{ name: "chromium", grep: /@smoke/ }`) slipped straight past it, on one line, and
    # deselected the suite with every guard green. Same class of bug as everything else this
    # file has been bounced for: the guard watched one SPELLING of the thing, not the thing.
    # Comments are stripped first — this file's own prose names every one of these keys.
    %w[testIgnore testMatch grep grepInvert].each do |key|
      refute_match(/\b#{key}\s*:/, config,
                   "playwright.config.js sets `#{key}` (anywhere — top level, or inline " \
                   "inside a project), which silently deselects specs the executed-set " \
                   "assertion still counts as running. The ONE sanctioned exclusion is " \
                   "`--grep-invert @quarantine` in ci.yml, pinned to that exact value by " \
                   "test/lib/ci_workflow_triggers_test.rb and bounded by the ceiling above. " \
                   "Do not open a second, unbounded one here.")
    end
  end

  # THE CONTRACT IS THE ONE NUMBER. Both halves of this guard — the static scan here and the
  # runtime gate in bin/e2e-executed-set-check — read config/e2e_lane.yml. If its arithmetic
  # is internally inconsistent, the two halves certify two different suites and the whole
  # structure is theatre.
  def test_integration_the_contract_arithmetic_is_internally_consistent
    assert_equal LANE_SPECS, TOTAL_SPECS - CEILING,
                 "config/e2e_lane.yml does not add up: total_specs(#{TOTAL_SPECS}) − " \
                 "quarantined(#{CEILING}) != executed(#{LANE_SPECS}). The executed set is " \
                 "DEFINED as everything committed that is not quarantined. If that is no " \
                 "longer true, the lane has grown a second way to drop a spec and neither " \
                 "half of this guard is bounding it."

    assert_operator CEILING, :>=, 0, "config/e2e_lane.yml: quarantined cannot be negative"
    assert_operator LANE_SPECS, :>, 0,
                    "config/e2e_lane.yml pins the executed set at #{LANE_SPECS}. A lane that " \
                    "runs zero specs is the failure this whole PR exists to make impossible."
  end

  # NO SHARD MAY BE EMPTY. This is the mechanism that hid `.only` in the first place: an
  # empty shard exits 0 in silence. The arithmetic above is what stops the executed set from
  # collapsing, but state the floor outright — if the lane ever shrinks below one spec (and
  # one FILE, since playwright keeps a file's specs on the same shard) per shard, a shard
  # goes empty, exits 0, and this lane starts lying again.
  def test_integration_the_lane_cannot_produce_an_empty_shard
    shards = shard_total

    # A NEW VECTOR, invented this round: DROP A SHARD FROM THE MATRIX. Change `shard: [1, 2, 3]`
    # to `[1, 2]` while the command still says `--shard=N/3` and shard 3's ~17 specs are never
    # run by anybody — every remaining job GREEN, the ci.yml command byte-identical, the spec
    # count in the source unchanged, the @quarantine ceiling unchanged. Nothing in the repo
    # said a word about it before this line. (The receipt catches it too, and catches it
    # harder: bin/e2e-executed-set-check demands one report per shard AND sums them to 51.)
    assert_equal SHARDS, shards,
                 "ci.yml runs the e2e lane across #{shards} shard(s); config/e2e_lane.yml " \
                 "pins the matrix at #{SHARDS}. Dropping a shard from the matrix while the " \
                 "command still divides by the old total leaves that shard's specs UNRUN and " \
                 "every remaining job GREEN. If you are deliberately resharding, say so in " \
                 "config/e2e_lane.yml in the same commit."

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
