# frozen_string_literal: true

# [unit] tests for the TEST FAMILY hop in bin/lib/fast_cert.rb: a diff touching a tool reaches
# the tool's whole test family, not just its same-named twin. The convention hop stops at the
# twin and the grep fallback fires only when the twin is ABSENT, so without this hop
# dor_check_exempt_ci_test.rb (a self-checking registry over bin/dor-check's source) is
# unreachable from a bin/dor-check diff. Two directions are pinned: the family must be REACHED
# (below), and an ordinary source edit must not pull in unrelated files (see the guard tests).
# History: task dor-reads-settled-ci-verdict.

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

  # THE CASE THAT BIT, against the REAL repo: a fixture can only prove the rule, not that it
  # reaches the file. Derived from the tree, so a new dor_check test does not red-seal an
  # unrelated PR. The expectation is `present` MINUS what the ownership rule excludes, never
  # `present == selected`: the guard rightly withholds a sibling with its own source
  # (`bin/dor-check-foo`).
  # History: task convention-mapping-misses-test-family.
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
  # test/lib/desk_ledger_sync_test.rb in this fixture, but that file is the twin of
  # bin/lib/desk_ledger_sync.rb — a source file of its own the diff did not
  # touch. Without this guard, every desk_ledger edit runs an unrelated tool's
  # tests.
  def test_sibling_with_its_own_source_is_not_claimed
    with_tree(
      "bin/lib/desk_ledger.rb" => "module DeskLedger; end\n",
      "bin/lib/desk_ledger_sync.rb" => "module DeskLedgerSync; end\n",
      "test/lib/desk_ledger_test.rb" => "class A; end\n",
      "test/lib/desk_ledger_sync_test.rb" => "class B; end\n"
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
  # measured live on this repo (2026-09-07): bin/dor-check (15) + one more file = 16 = capped.
  # (Re-measured 2026-09-24: the family is 14, so it takes TWO co-changed files — see the
  # real-repo test below, which pins this task's own diff.)
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

  # THE GREP IS EXCLUDED FROM THE FALLBACK: the cap exists BECAUSE of the grep, since
  # config/initializers/studio.rb grepped "Studio" and matched 48 files. A file with no twin
  # contributes nothing. The fixture is a MODEL, not an initializer: a config file is named by
  # its PATH, so config/initializers/widget.rb cannot explode (#grep_tokens). A twin-less MODEL
  # still greps its bare constant. PROPERTY: whatever the grep matched, the fallback ignores it.
  # History: task capped-lane-falls-to-nothing.
  def test_the_fallback_never_reopens_the_grep_explosion
    files = { "app/models/widget.rb" => "class Widget; end\n" }
    20.times { |i| files["test/lib/wide_#{i}_test.rb"] = "Widget.reset\n" }

    with_tree(files) do |dir|
      changed = ["app/models/widget.rb"]
      mapped = FastCert.select_tests(dir, changed)
      assert_equal 20, mapped.size, "the grep fallback is what maps this diff"

      decision = FastCert.cap_decision(mapped, FastCert.mapping(dir, changed), cap: 15,
                                       twins: FastCert.convention_twins(dir, changed))

      assert decision[:capped]
      assert_empty decision[:fallback],
                   "an initializer has no convention twin — the grep must NOT be reused as the fallback"
      assert_equal 0, decision[:fallback_considered]

      # AND IT IS NOT TRUNCATION. "Take the first `cap` of whatever mapped" turns a grep
      # explosion into 15 arbitrary matches: a SHORTER CLIFF, not a slope. THE LINE BELOW CANNOT
      # BE THE ASSERTION THAT FIRES: the `assert_empty decision[:fallback]` one line ABOVE
      # reddens first. This is a NAMED restatement of the shape, not load-bearing. Delete the
      # redundancy if you like, never the property.
      # History: task fast-check-narration-misleads.
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
  # fallback moves the INPUT to that question, never its KEYING — so a capped run
  # with twins runs them, and a capped run WITHOUT twins runs no test lane and says
  # so. Both halves, from one shape.
  def test_what_will_run_keys_on_zero_not_on_the_cap
    files = { "bin/wide-tool" => "#!/usr/bin/env ruby\n", "test/lib/wide_tool_test.rb" => "class A; end\n" }
    20.times { |i| files["test/lib/wide_tool_aspect#{i}_test.rb"] = "class B#{i}; end\n" }

    with_tree(files) do |dir|
      mapped = FastCert.select_tests(dir, ["bin/wide-tool"])

      # WITH a twin, over an EMPTY spine (the satellite shape): real tests run.
      with_twin = FastCert.cap_decision(mapped, { "bin/wide-tool" => mapped }, cap: 15,
                                        twins: FastCert.convention_twins(dir, ["bin/wide-tool"]))
      assert_equal ["test/lib/wide_tool_test.rb"], FastCert.executed_test_paths(mapped, [], with_twin),
                   "a capped run RUNS its twin — that is what the pre-flight executes"

      # WITHOUT one, same cap, same empty spine: nothing runs, and bin/fast-check says so.
      no_twin = FastCert.cap_decision(mapped, { "bin/wide-tool" => mapped }, cap: 15, twins: [])
      assert_empty FastCert.executed_test_paths(mapped, [], no_twin), "no twin, no spine — no test lane"
    end
  end

  # --- the REAL repo, the shape that is live today ------------------------------
  # The registry test above is cap-INDEPENDENT: it asserts the SELECTION, so it stays green
  # while the lane runs nothing on a multi-file diff. This asserts the LANE, what would actually
  # execute, on the live shape: bin/dor-check + bin/lib/ci_status.rb + ci_gate.rb, over the cap,
  # runs its 2 twins.
  # History: task dor-reads-settled-ci-verdict.
  def test_real_repo_a_capped_multi_file_diff_still_runs_the_dor_check_twin
    changed = ["bin/dor-check", "bin/lib/ci_status.rb", "bin/lib/ci_gate.rb"]
    mapped = FastCert.select_tests(REPO_ROOT, changed)
    decision = FastCert.cap_decision(mapped, FastCert.mapping(REPO_ROOT, changed),
                                     twins: FastCert.convention_twins(REPO_ROOT, changed))

    assert decision[:capped],
           "bin/dor-check's family plus its two co-changed libs must exceed the cap of " \
           "#{FastCert::DEFAULT_MAPPED_CAP} (mapped #{mapped.size}) — re-measure before editing this"
    executed = FastCert.executed_test_paths(mapped, [], decision)
    assert_includes executed, "test/lib/dor_check_test.rb",
                    "the file the whole gate depends on must keep a local mapped lane"
    assert_includes executed, "test/lib/ci_status_test.rb",
                    "and so must the co-changed file that tripped the cap"
    refute_empty executed, "before this fallback, this exact diff executed ZERO mapped tests"
  end

  # --- WHICH EMPTY the twin fallback was ------------------------------------------
  # `:fallback_considered` is counted AFTER the spine dedupe, so a diff whose only twin is a
  # spine entry carries 0, the same as a diff with NO twin. One sentence for both is false for
  # the first, and a warning on a false negative teaches builders to ignore warnings. The
  # question is asked ONCE, here, so the two sentences cannot drift apart.
  # History: task fast-check-narration-misleads.

  def test_a_spine_covered_twin_is_not_a_missing_twin
    cause = FastCert.empty_fallback_cause({ cap: 15, fallback_considered: 0 },
                                          spine_covered_twins: ["test/controllers/tasks_controller_test.rb"])

    assert_equal :spine_covered, cause,
                 "the twin EXISTS and the spine is already running it — a different fact from having none"
  end

  def test_no_twin_anywhere_is_still_reported_as_a_missing_twin
    cause = FastCert.empty_fallback_cause({ cap: 15, fallback_considered: 0 }, spine_covered_twins: [])

    assert_equal :none, cause, "the dedupe dropped nothing, so there was nothing to drop"
  end

  # BOTH CAN HOLD AT ONCE, and the degradation is the more useful fact: it says the lane
  # HAD a fallback and gave it up for breadth. Order is the assertion here.
  def test_a_twin_set_over_the_cap_outranks_the_spine_covered_reason
    over = { cap: 15, fallback_considered: 20 }

    assert_equal :over_cap,
                 FastCert.empty_fallback_cause(over, spine_covered_twins: ["test/models/task_test.rb"]),
                 "20 twins over a cap of 15 is a degradation, whatever the spine also covered"
    assert_equal :over_cap, FastCert.empty_fallback_cause(over, spine_covered_twins: []),
                 "and it does not need a spine-covered twin to be the answer"
  end

  # A DEFAULT THAT FAILS TO THE OLD SENTENCE. A caller that has not been taught to pass
  # the dropped twins gets :none — the wording the fallback shipped with (f0cc947a) —
  # never a claim about a spine it never mentioned.
  def test_a_caller_that_names_no_spine_covered_twins_gets_the_old_answer
    assert_equal :none, FastCert.empty_fallback_cause({ cap: 15, fallback_considered: 0 })
  end

  # --- the fallback is INSIDE the mapped set --------------------------------------
  # #convention_twins is the union of the `existing` sets #mapping unions into its values, so
  # every twin is a mapped path, and bin/fast-check subtracts the identical spine set from both
  # sides. A changed TEST file's convention candidate IS itself. This is what notices if the
  # removed `(cap[:fallback] - mapped_only)` walk stops being dead. The two floors below keep it
  # honest: an empty-set subtraction is empty for the wrong reason, and a vanished sweep asserts
  # over nothing.
  # History: task fast-check-narration-misleads.
  def test_the_convention_twins_are_always_a_subset_of_the_mapped_set
    cases = {
      "a harness family" => [
        { "bin/wide-tool" => "#!/usr/bin/env ruby\n",
          "test/lib/wide_tool_test.rb" => "class A; end\n",
          "test/lib/wide_tool_aspect_test.rb" => "class B; end\n" },
        ["bin/wide-tool"]
      ],
      "a model and its twin" => [
        { "app/models/widget.rb" => "class Widget; end\n",
          "test/models/widget_test.rb" => "class A; end\n" },
        ["app/models/widget.rb"]
      ],
      "a view through its controller test" => [
        { "app/views/tasks/_board.html.erb" => "board\n",
          "test/controllers/tasks_controller_test.rb" => "class A; end\n" },
        ["app/views/tasks/_board.html.erb"]
      ],
      "a changed test file, which is its own twin" => [
        { "test/lib/thing_test.rb" => "class A; end\n",
          "test/lib/thing_extra_test.rb" => "class B; end\n" },
        ["test/lib/thing_test.rb"]
      ],
      "a twin-less file, which greps and contributes no twin" => [
        { "app/models/gizmo.rb" => "class Gizmo; end\n",
          "test/lib/wide_test.rb" => "Gizmo.reset\n" },
        ["app/models/gizmo.rb"]
      ],
      "a multi-file diff mixing all of them" => [
        { "bin/wide-tool" => "#!/usr/bin/env ruby\n",
          "test/lib/wide_tool_test.rb" => "class A; end\n",
          "app/models/widget.rb" => "class Widget; end\n",
          "test/models/widget_test.rb" => "class B; end\n",
          "app/models/gizmo.rb" => "class Gizmo; end\n",
          "test/lib/wide_test.rb" => "Gizmo.reset\n" },
        ["bin/wide-tool", "app/models/widget.rb", "app/models/gizmo.rb"]
      ]
    }

    with_twins = 0
    cases.each do |name, (files, changed)|
      with_tree(files) do |dir|
        twins = FastCert.convention_twins(dir, changed)

        assert_empty twins - FastCert.select_tests(dir, changed),
                     "#{name}: a convention twin landed OUTSIDE the mapped set"
        with_twins += 1 if twins.any?
      end
    end

    assert_equal 6, cases.size, "the LIST is the assertion — a case that quietly vanishes is a hole"
    assert_operator with_twins, :>=, 5,
                    "only #{with_twins} of #{cases.size} cases had a twin at all; a subset assertion " \
                    "over empty sets proves nothing"
  end

  # AND ON THE REAL TREE, whose shapes are not the ones a fixture remembers to build.
  def test_real_repo_every_convention_twin_is_inside_the_mapped_set
    changed = %w[
      bin/dor-check
      bin/lib/ci_status.rb
      app/models/task.rb
      app/views/tasks/_board.html.erb
      test/lib/fast_cert_family_test.rb
    ]

    twins = FastCert.convention_twins(REPO_ROOT, changed)

    assert_operator twins.size, :>=, 4,
                    "swept #{twins.size} twins on the real tree — too few for the subtraction to mean anything"
    assert_empty twins - FastCert.select_tests(REPO_ROOT, changed),
                 "a twin outside the mapped set would make the removed --list pass load-bearing again"
  end
end
