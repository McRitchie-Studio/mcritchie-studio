# frozen_string_literal: true

# [unit] tests for the TEST FAMILY hop in bin/lib/fast_cert.rb — the widening
# that lets a diff touching a tool reach the tool's whole test family, not just
# its same-named twin.
#
# THE DEFECT THIS PINS, measured 2026-09-06 from the task desk:
#
#   FAST_CHECK_CHANGED_FILES=bin/dor-check bin/fast-check --list
#   -> 1 changed file(s) -> 1 mapped test path(s)
#   -> mapped  test/lib/dor_check_test.rb
#
# There are fifteen test/lib/dor_check_*_test.rb files. Fourteen were unreachable
# from a diff touching only bin/dor-check, because the convention hop stopped at
# the twin and the grep fallback fires only when the twin is ABSENT. Among the
# fourteen is dor_check_exempt_ci_test.rb, which holds a self-checking registry
# over bin/dor-check's own source — so the one test guaranteed to notice a new
# call site was the one test the local cert could never run. It reddened PR
# #1236's first push in CI instead.
#
# Two directions are pinned here, because a widening is only as good as its
# restraint: the family must be REACHED (below), and an ordinary source edit must
# not suddenly pull in unrelated files (see the guard tests).
#
# Run directly:
#   ruby -Itest test/lib/fast_cert_family_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/fast_cert"

class FastCertFamilyTest < Minitest::Test
  REPO_ROOT = File.expand_path("../..", __dir__)

  # A repo-shaped fixture directory (files only; no git needed for selection).
  def with_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      yield dir
    end
  end

  # --- the family is reached ---------------------------------------------------

  def test_bin_script_reaches_its_suffixed_siblings
    with_tree(
      "bin/dor-check" => "#!/usr/bin/env ruby\n",
      "test/lib/dor_check_test.rb" => "class A; end\n",
      "test/lib/dor_check_exempt_ci_test.rb" => "class B; end\n",
      "test/lib/dor_check_stale_ci_test.rb" => "class C; end\n"
    ) do |dir|
      assert_equal %w[
        test/lib/dor_check_exempt_ci_test.rb
        test/lib/dor_check_stale_ci_test.rb
        test/lib/dor_check_test.rb
      ], FastCert.select_tests(dir, ["bin/dor-check"])
    end
  end

  def test_bin_lib_source_reaches_its_family_too
    with_tree(
      "bin/lib/release_presence.rb" => "module ReleasePresence; end\n",
      "test/lib/release_presence_test.rb" => "class A; end\n",
      "test/lib/release_presence_wiring_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal %w[
        test/lib/release_presence_test.rb
        test/lib/release_presence_wiring_test.rb
      ], FastCert.select_tests(dir, ["bin/lib/release_presence.rb"])
    end
  end

  # Every test/lib/ sibling in `present` that is SOMEBODY ELSE'S twin — i.e. a source
  # file named after it exists. The rule is spelled out here rather than called through
  # FastCert.source_twins DELIBERATELY: a guard that derives its expectation from the
  # code it guards asserts only that the code equals itself. `subject` is the source
  # under test, which owns its own twin and must not count as an outside owner.
  def owned_by_another_source(present, subject)
    present.select do |test_path|
      stem = test_path[%r{\Atest/lib/(.+)_test\.rb\z}, 1]
      ["lib/#{stem}.rb", "bin/lib/#{stem}.rb", "bin/#{stem}", "bin/#{stem.tr('_', '-')}"]
        .reject { |src| src == subject }
        .any? { |src| File.file?(File.join(REPO_ROOT, src)) }
    end
  end

  # THE CASE THAT BIT, against the REAL repo rather than a fixture — a fixture
  # can only prove the rule, not that the rule reaches the file that reddened CI.
  # Derived from the tree rather than hard-listed, so adding a sixteenth
  # dor_check test does not red-seal an unrelated PR.
  #
  # AND IT NO LONGER RED-SEALS AN EXCLUDED ONE. This asserted `present == selected`
  # EXACTLY, where `present` is a raw glob. The ownership guard correctly withholds a
  # sibling that has its own source — so the day somebody adds `bin/dor-check-foo` with
  # a `test/lib/dor_check_foo_test.rb`, the glob counts it, the guard rightly refuses to
  # claim it, and THIS test fails on an unrelated PR that did nothing wrong. A guard
  # that fires on correct behaviour trains people to edit the guard. The expectation is
  # now `present` MINUS what the ownership rule excludes, stated independently above.
  def test_real_repo_dor_check_diff_reaches_the_registry_test
    selected = FastCert.select_tests(REPO_ROOT, ["bin/dor-check"])

    assert_includes selected, "test/lib/dor_check_exempt_ci_test.rb",
                    "the self-checking registry over bin/dor-check's own source must be reachable " \
                    "from a diff that touches bin/dor-check"

    # The twin AND the suffixed family — the brace glob is what the twin-only
    # convention hop used to miss.
    present = Dir.glob("test/lib/dor_check{,_*}_test.rb", base: REPO_ROOT).sort
    assert_operator present.size, :>=, 10, "expected bin/dor-check to still have a test FAMILY"
    expected = present - owned_by_another_source(present, "bin/dor-check")
    assert_equal expected, selected.sort,
                 "every dor_check test file that is nobody else's twin must map from bin/dor-check"
  end

  # THE OTHER HALF OF THAT RED-SEAL, as a fixture so it is provable rather than
  # hypothetical: a sibling backed by a `bin/<stem>-<suffix>` SCRIPT (not a lib file) is
  # excluded too. This is the exact shape the assertion above would have tripped over,
  # and nothing in this file covered it — the two existing exclusion tests both use a
  # bin/lib/*.rb owner.
  def test_sibling_with_its_own_bin_script_is_not_claimed
    with_tree(
      "bin/dor-check" => "#!/usr/bin/env ruby\n",
      "bin/dor-check-foo" => "#!/usr/bin/env ruby\n",
      "test/lib/dor_check_test.rb" => "class A; end\n",
      "test/lib/dor_check_foo_test.rb" => "class B; end\n",
      "test/lib/dor_check_stale_ci_test.rb" => "class C; end\n"
    ) do |dir|
      assert_equal %w[test/lib/dor_check_stale_ci_test.rb test/lib/dor_check_test.rb],
                   FastCert.select_tests(dir, ["bin/dor-check"]),
                   "dor_check_foo_test.rb is bin/dor-check-foo's twin, not part of dor-check's family"
    end
  end

  # --- restraint: the family hop must not over-widen ----------------------------

  # PREFIX IS NOT PARENTHOOD. bin/lib/desk_ledger.rb's stem prefixes
  # test/lib/desk_ledger_import_test.rb, but that file is the twin of
  # bin/lib/desk_ledger_import.rb — a source file of its own the diff did not
  # touch. Without this guard, every desk_ledger edit runs an unrelated tool's
  # tests.
  def test_sibling_with_its_own_source_is_not_claimed
    with_tree(
      "bin/lib/desk_ledger.rb" => "module DeskLedger; end\n",
      "bin/lib/desk_ledger_import.rb" => "module DeskLedgerImport; end\n",
      "test/lib/desk_ledger_test.rb" => "class A; end\n",
      "test/lib/desk_ledger_import_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal ["test/lib/desk_ledger_test.rb"],
                   FastCert.select_tests(dir, ["bin/lib/desk_ledger.rb"])
    end
  end

  def test_bin_script_does_not_claim_a_lib_backed_sibling
    with_tree(
      "bin/agent-worktree" => "#!/usr/bin/env ruby\n",
      "bin/lib/agent_worktree_cli.rb" => "module AgentWorktreeCli; end\n",
      "test/lib/agent_worktree_test.rb" => "class A; end\n",
      "test/lib/agent_worktree_cli_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal ["test/lib/agent_worktree_test.rb"],
                   FastCert.select_tests(dir, ["bin/agent-worktree"])
    end
  end

  # test/<layer>/ mirrors app/<layer>/ one file to one file, so a prefix sibling
  # there is a DIFFERENT subject's test. Only the harness namespace names its
  # files after a tool rather than after a class.
  def test_app_layers_get_no_family
    with_tree(
      "app/models/task.rb" => "class Task; end\n",
      "test/models/task_test.rb" => "class A; end\n",
      "test/models/task_event_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal ["test/models/task_test.rb"],
                   FastCert.select_tests(dir, ["app/models/task.rb"])
    end
  end

  # A changed test file is its own subject; expanding it would drag every sibling
  # into a one-line test edit.
  def test_changed_test_file_does_not_expand_to_its_family
    with_tree(
      "bin/dor-check" => "#!/usr/bin/env ruby\n",
      "test/lib/dor_check_test.rb" => "class A; end\n",
      "test/lib/dor_check_stale_ci_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal ["test/lib/dor_check_test.rb"],
                   FastCert.select_tests(dir, ["test/lib/dor_check_test.rb"])
    end
  end

  # --- the cap still governs the widened set ------------------------------------

  # THE WIDENING MUST NOT BUY ITSELF AN EXEMPTION. An uncapped mapped lane on a
  # broad diff is the ~31-minute local suite the fast lane exists to avoid, so a
  # family large enough to exceed the cap is CAPPED exactly as any other mapping
  # would be — it does not get a pass for having arrived via the family hop.
  def test_a_family_over_the_cap_is_still_capped
    files = { "bin/wide-tool" => "#!/usr/bin/env ruby\n", "test/lib/wide_tool_test.rb" => "class A; end\n" }
    20.times { |i| files["test/lib/wide_tool_aspect#{i}_test.rb"] = "class B#{i}; end\n" }

    with_tree(files) do |dir|
      mapped = FastCert.select_tests(dir, ["bin/wide-tool"])
      assert_equal 21, mapped.size

      decision = FastCert.cap_decision(mapped, { "bin/wide-tool" => mapped }, cap: 15)
      assert decision[:capped], "a 21-path family must trip the cap like any other mapping"
      assert_equal 21, decision[:count]
    end
  end

  # --- the cap FALLBACK: capped degrades to the twins, not to nothing ------------
  #
  # CROSSING THE CAP WAS A CLIFF. The capped lane ran NOTHING, so one co-changed file
  # took a diff from fifteen mapped tests to zero — strictly worse than before the
  # family hop existed, which ran the twins. These pin the slope that replaces it:
  # full mapped set → convention twins → spine only.

  # A FAMILY PAST THE CAP STILL RUNS ITS TWIN. The headline acceptance criterion.
  def test_a_family_over_the_cap_falls_back_to_its_twin
    files = { "bin/wide-tool" => "#!/usr/bin/env ruby\n", "test/lib/wide_tool_test.rb" => "class A; end\n" }
    20.times { |i| files["test/lib/wide_tool_aspect#{i}_test.rb"] = "class B#{i}; end\n" }

    with_tree(files) do |dir|
      changed = ["bin/wide-tool"]
      mapped = FastCert.select_tests(dir, changed)
      twins = FastCert.convention_twins(dir, changed)
      decision = FastCert.cap_decision(mapped, { "bin/wide-tool" => mapped }, cap: 15, twins: twins)

      assert decision[:capped], "21 paths is over the cap"
      assert_equal ["test/lib/wide_tool_test.rb"], decision[:fallback],
                   "the capped lane must fall back to the twin, not to nothing"
      assert_equal ["test/lib/wide_tool_test.rb"],
                   FastCert.executed_test_paths(mapped, [], decision),
                   "and the zero-evidence guard must SEE the twin as executed"
    end
  end

  # THE FALLBACK IS THE PRE-WIDENING SET — one twin per changed file, and the
  # co-changed file that pushed it over the cap gets its twin too. This is the shape
  # measured live on this repo: bin/dor-check (15) + one more file = 16 = capped.
  def test_the_co_changed_file_that_tripped_the_cap_still_gets_its_twin
    files = {
      "bin/wide-tool" => "#!/usr/bin/env ruby\n",
      "bin/lib/helper.rb" => "module Helper; end\n",
      "test/lib/wide_tool_test.rb" => "class A; end\n",
      "test/lib/helper_test.rb" => "class H; end\n"
    }
    20.times { |i| files["test/lib/wide_tool_aspect#{i}_test.rb"] = "class B#{i}; end\n" }

    with_tree(files) do |dir|
      changed = ["bin/wide-tool", "bin/lib/helper.rb"]
      mapped = FastCert.select_tests(dir, changed)
      decision = FastCert.cap_decision(mapped, FastCert.mapping(dir, changed), cap: 15,
                                       twins: FastCert.convention_twins(dir, changed))

      assert decision[:capped]
      assert_equal %w[test/lib/helper_test.rb test/lib/wide_tool_test.rb], decision[:fallback]
    end
  end

  # THE GREP IS EXCLUDED FROM THE FALLBACK, and this is the whole reason the fallback
  # is bounded. The cap exists BECAUSE of the grep — config/initializers/studio.rb has
  # no convention target, greps "Studio" and matched 48 files at 39m34s. Degrading to
  # "twins OR grep" would re-run exactly that. A file with no twin contributes nothing.
  def test_the_fallback_never_reopens_the_grep_explosion
    files = { "config/initializers/widget.rb" => "Widget.configure\n" }
    20.times { |i| files["test/lib/wide_#{i}_test.rb"] = "Widget.reset\n" }

    with_tree(files) do |dir|
      changed = ["config/initializers/widget.rb"]
      mapped = FastCert.select_tests(dir, changed)
      assert_equal 20, mapped.size, "the grep fallback is what maps this diff"

      decision = FastCert.cap_decision(mapped, FastCert.mapping(dir, changed), cap: 15,
                                       twins: FastCert.convention_twins(dir, changed))

      assert decision[:capped]
      assert_empty decision[:fallback],
                   "an initializer has no convention twin — the grep must NOT be reused as the fallback"
      assert_equal 0, decision[:fallback_considered]

      # AND IT IS NOT TRUNCATION. The lazy shape of this fix — "take the first `cap`
      # of whatever mapped" — would pass every other test in this file while turning
      # a 20-file grep explosion into 15 arbitrary grep matches: a SHORTER CLIFF, not
      # a slope, since which 15 you get is alphabetical accident. Measured over the
      # hub 2026-09-07, ALL 23 single-file cap-trippers are grep-driven with ZERO
      # twins, so truncation is the failure mode that would actually bite.
      refute_equal mapped.first(15), decision[:fallback],
                   "the fallback must be the convention twins, never the mapped set truncated"
    end
  end

  # THE SLOPE MUST TERMINATE, or the fallback is a second unbounded lane. Twins are
  # 1-2 paths per CHANGED FILE, so a wide-enough diff has more twins than the cap; that
  # degrades again, to the spine, rather than buying itself an exemption.
  def test_a_twin_set_that_is_itself_over_the_cap_degrades_again
    files = {}
    changed = []
    20.times do |i|
      files["bin/lib/tool#{i}.rb"] = "module Tool#{i}; end\n"
      files["test/lib/tool#{i}_test.rb"] = "class T#{i}; end\n"
      changed << "bin/lib/tool#{i}.rb"
    end

    with_tree(files) do |dir|
      mapped = FastCert.select_tests(dir, changed)
      decision = FastCert.cap_decision(mapped, FastCert.mapping(dir, changed), cap: 15,
                                       twins: FastCert.convention_twins(dir, changed))

      assert decision[:capped]
      assert_empty decision[:fallback], "20 twins is over the cap of 15 — the lane degrades to the spine"
      assert_equal 20, decision[:fallback_considered],
                   "and the receipt can still say WHICH empty this was"
    end
  end

  # AN ORDINARY DIFF IS UNTOUCHED — the fallback is inert below the cap. A degradation
  # that changes the normal case is not a degradation, it is a rewrite.
  def test_an_uncapped_diff_carries_no_fallback
    with_tree(
      "bin/lib/release_presence.rb" => "module ReleasePresence; end\n",
      "test/lib/release_presence_test.rb" => "class A; end\n",
      "test/lib/release_presence_wiring_test.rb" => "class B; end\n"
    ) do |dir|
      changed = ["bin/lib/release_presence.rb"]
      mapped = FastCert.select_tests(dir, changed)
      decision = FastCert.cap_decision(mapped, FastCert.mapping(dir, changed), cap: 15,
                                       twins: FastCert.convention_twins(dir, changed))

      refute decision[:capped]
      assert_empty decision[:fallback], "below the cap the fallback must not exist"
      assert_equal mapped, FastCert.executed_test_paths(mapped, [], decision),
                   "an uncapped run executes its FULL mapped set, exactly as before"
    end
  end

  # THE FENCE (PR #1226): a run executing ZERO tests must not report green. The
  # fallback moves the INPUT to that guard, never its KEYING — so a capped run with
  # twins now certifies (it ran tests), and a capped run WITHOUT twins still defers
  # (it ran none). Both halves, from one shape.
  def test_the_zero_evidence_guard_still_keys_on_zero_not_on_the_cap
    files = { "bin/wide-tool" => "#!/usr/bin/env ruby\n", "test/lib/wide_tool_test.rb" => "class A; end\n" }
    20.times { |i| files["test/lib/wide_tool_aspect#{i}_test.rb"] = "class B#{i}; end\n" }

    with_tree(files) do |dir|
      mapped = FastCert.select_tests(dir, ["bin/wide-tool"])

      # WITH a twin, over an EMPTY spine (the satellite shape): real tests run, so
      # there is nothing to defer. This is the rung that changed.
      with_twin = FastCert.cap_decision(mapped, { "bin/wide-tool" => mapped }, cap: 15,
                                        twins: FastCert.convention_twins(dir, ["bin/wide-tool"]))
      assert_nil FastCert.zero_test_outcome(mapped, [], with_twin, slug: "t"),
                 "a capped run that RUNS its twin executes tests — it must not defer"

      # WITHOUT one, same cap, same empty spine: unchanged, still a deferral.
      no_twin = FastCert.cap_decision(mapped, { "bin/wide-tool" => mapped }, cap: 15, twins: [])
      outcome = FastCert.zero_test_outcome(mapped, [], no_twin, slug: "t")
      assert_equal :defer, outcome[:kind], "no twin, no spine, nothing ran — still deferred"
      assert_match(/convention-twin fallback was empty too/, outcome[:detail],
                   "and the receipt says WHY the fallback did not save it")
    end
  end

  # --- the REAL repo, the shape that is live today ------------------------------
  #
  # THE GUARD THAT COULD NOT SEE THE FAILURE NEXT TO IT. The registry test above is
  # cap-INDEPENDENT: it asserts the SELECTION, which is 15 either way, so it stayed
  # green while the real lane ran nothing at all on any multi-file diff. This asserts
  # the LANE — what would actually execute — against the exact live shape.
  #
  # Measured on this desk 2026-09-07:
  #   bin/dor-check alone                    → 15 mapped, at the cap  → ran 15
  #   bin/dor-check + bin/lib/ci_status.rb   → 16 mapped, over it     → ran 0 (PR #1236's shape)
  def test_real_repo_a_capped_multi_file_diff_still_runs_the_dor_check_twin
    changed = ["bin/dor-check", "bin/lib/ci_status.rb"]
    mapped = FastCert.select_tests(REPO_ROOT, changed)
    decision = FastCert.cap_decision(mapped, FastCert.mapping(REPO_ROOT, changed),
                                     twins: FastCert.convention_twins(REPO_ROOT, changed))

    assert decision[:capped],
           "bin/dor-check maps to the cap exactly, so any co-changed mapped file exceeds it"
    executed = FastCert.executed_test_paths(mapped, [], decision)
    assert_includes executed, "test/lib/dor_check_test.rb",
                    "the file the whole gate depends on must keep a local mapped lane"
    assert_includes executed, "test/lib/ci_status_test.rb",
                    "and so must the co-changed file that tripped the cap"
    refute_empty executed, "before this fallback, this exact diff executed ZERO mapped tests"
  end
end
