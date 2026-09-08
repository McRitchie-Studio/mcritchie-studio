# frozen_string_literal: true

# [unit] tests for bin/lib/fast_cert.rb — the PURE selection half of the G1 fast
# cert (bin/fast-check): diff → test-file mapping (path convention + class-name
# grep fallback), the always-run spine, and the changed-files rubocop scope.
# No processes are spawned here except git fixture setup; the ORCHESTRATION
# (lanes, gate emits, evidence) is covered by test/lib/fast_check_test.rb.
# Run directly:
#   ruby -Itest test/lib/fast_cert_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/fast_cert"

class FastCertTest < Minitest::Test
  REPO_ROOT = File.expand_path("../..", __dir__)

  # The real config/fast_cert_spine.yml shape: five hub-anchored entries. Used as the
  # DECLARED set in the satellite tests below, where none of them exist in the checkout.
  SPINE_FIVE = %w[
    test/models/task_test.rb test/models/release_test.rb test/models/gate_run_test.rb
    test/controllers/tasks_controller_test.rb test/controllers/api/v1
  ].freeze

  # --- convention mapping ------------------------------------------------------

  def test_model_maps_to_model_test
    assert_equal ["test/models/task_test.rb"], FastCert.convention_candidates("app/models/task.rb")
  end

  def test_nested_controller_maps_with_namespace
    assert_equal ["test/controllers/api/v1/tasks_controller_test.rb"],
                 FastCert.convention_candidates("app/controllers/api/v1/tasks_controller.rb")
  end

  def test_helper_job_service_map_through_their_layers
    assert_equal ["test/helpers/application_helper_test.rb"],
                 FastCert.convention_candidates("app/helpers/application_helper.rb")
    assert_equal ["test/jobs/avi_sizing_job_test.rb"],
                 FastCert.convention_candidates("app/jobs/avi_sizing_job.rb")
    assert_equal ["test/services/avi_sizer_test.rb"],
                 FastCert.convention_candidates("app/services/avi_sizer.rb")
  end

  def test_view_partial_maps_to_controller_and_mailer_tests
    assert_equal ["test/controllers/tasks_controller_test.rb", "test/mailers/tasks_test.rb"],
                 FastCert.convention_candidates("app/views/tasks/_gates.html.erb")
  end

  def test_namespaced_view_maps_to_namespaced_controller_test
    assert_includes FastCert.convention_candidates("app/views/api/v1/tasks/show.json.jbuilder"),
                    "test/controllers/api/v1/tasks_controller_test.rb"
  end

  def test_lib_and_bin_lib_map_to_test_lib
    assert_equal ["test/lib/feature_marker_test.rb"], FastCert.convention_candidates("lib/feature_marker.rb")
    assert_equal ["test/lib/fast_cert_test.rb"], FastCert.convention_candidates("bin/lib/fast_cert.rb")
  end

  # BOTH harness namespaces, because there are two: test/lib/ and test/commands/
  # each name their files after the tool under test. Existence is the caller's
  # filter, so a candidate list naming both costs nothing when only one exists.
  def test_bin_script_maps_to_underscored_harness_tests_in_both_namespaces
    assert_equal %w[test/lib/fast_check_test.rb test/commands/fast_check_test.rb],
                 FastCert.convention_candidates("bin/fast-check")
  end

  def test_changed_test_file_maps_to_itself
    assert_equal ["test/models/task_test.rb"], FastCert.convention_candidates("test/models/task_test.rb")
  end

  def test_unmappable_paths_yield_no_candidates
    assert_empty FastCert.convention_candidates("docs/agents/sop.md")
    assert_empty FastCert.convention_candidates("README.md")
    assert_empty FastCert.convention_candidates("db/migrate/20260708_add_widgets.rb")
    assert_empty FastCert.convention_candidates("app/assets/stylesheets/app.css")
  end

  # --- grep fallback tokens ----------------------------------------------------
  #
  # The token is the SUBJECT'S IDENTITY, not its basename as a word — see
  # #grep_tokens and the fuller pinning in fast_cert_subject_test.rb.

  def test_grep_tokens_camelize_ruby_basenames
    assert_equal ["GateRun"], FastCert.grep_tokens(REPO_ROOT, "app/models/gate_run.rb")
    assert_equal ["FullSuiteGate"], FastCert.grep_tokens(REPO_ROOT, "bin/lib/full_suite_gate.rb")
  end

  # A script is named two ways: by path in code that runs it, and as a bare quoted
  # command name in the registries that enumerate bin/.
  def test_grep_tokens_name_a_bin_tool_by_path_and_by_quoted_command
    assert_equal ["bin/fast-check", %("fast-check")], FastCert.grep_tokens(REPO_ROOT, "bin/fast-check")
  end

  # A config is named two ways as well: by path, and by the QUOTED BASENAME that
  # File.join(ROOT, "config", "x.yml") splits it into. The extension rides along, so
  # the quoted form is a filename and can never be an English word.
  def test_grep_tokens_name_a_config_file_by_path_and_by_quoted_basename
    assert_equal ["config/fast_cert_spine.yml", %("fast_cert_spine.yml")],
                 FastCert.grep_tokens(REPO_ROOT, "config/fast_cert_spine.yml")
  end

  def test_grep_tokens_are_empty_for_views_and_docs
    assert_empty FastCert.grep_tokens(REPO_ROOT, "app/views/tasks/_gates.html.erb")
    assert_empty FastCert.grep_tokens(REPO_ROOT, "docs/agents/sop.md")
  end

  # --- grep fallback + select_tests over a fixture tree -------------------------

  # A repo-shaped fixture directory (files only; git added where needed).
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

  def test_grep_finds_word_bounded_class_mentions_only
    with_tree(
      "test/lib/widget_flow_test.rb" => "class WidgetFlowTest\n  Widget.create!\nend\n",
      "test/lib/other_test.rb" => "class OtherTest\n  WidgetRegistry.reset\nend\n"
    ) do |dir|
      # "Widget" matches the whole word, NOT the "WidgetRegistry" substring.
      assert_equal ["test/lib/widget_flow_test.rb"], FastCert.grep_tests(dir, "Widget")
      assert_empty FastCert.grep_tests(dir, "Gadget")
      assert_empty FastCert.grep_tests(dir, nil)
    end
  end

  def test_select_prefers_an_existing_convention_target_over_grep
    with_tree(
      "app/models/widget.rb" => "class Widget; end\n",
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "test/lib/mentions_widget_test.rb" => "Widget everywhere\n"
    ) do |dir|
      # The convention target exists → grep is NOT consulted (no mentions file).
      assert_equal ["test/models/widget_test.rb"],
                   FastCert.select_tests(dir, ["app/models/widget.rb"])
    end
  end

  def test_select_falls_back_to_grep_when_no_convention_target_exists
    with_tree(
      "app/services/charger.rb" => "class Charger; end\n",
      "test/integration/billing_flow_test.rb" => "Charger.charge!\n"
    ) do |dir|
      assert_equal ["test/integration/billing_flow_test.rb"],
                   FastCert.select_tests(dir, ["app/services/charger.rb"])
    end
  end

  def test_select_dedupes_and_sorts_across_changed_files
    with_tree(
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "app/models/widget.rb" => "class Widget; end\n"
    ) do |dir|
      changed = ["app/models/widget.rb", "test/models/widget_test.rb", "docs/notes.md"]
      assert_equal ["test/models/widget_test.rb"], FastCert.select_tests(dir, changed)
    end
  end

  # --- spine ---------------------------------------------------------------------

  def test_spine_loads_existing_entries_and_skips_missing_ones
    with_tree(
      "test/models/task_test.rb" => "x\n",
      "test/controllers/api/v1/tasks_controller_test.rb" => "x\n",
      "spine.yml" => "spine:\n  - test/models/task_test.rb\n  - test/controllers/api/v1\n  - test/models/missing_test.rb\n"
    ) do |dir|
      assert_equal ["test/models/task_test.rb", "test/controllers/api/v1"],
                   FastCert.spine(dir, File.join(dir, "spine.yml"))
    end
  end

  def test_spine_is_empty_for_a_missing_or_blank_config
    Dir.mktmpdir do |dir|
      assert_empty FastCert.spine(dir, File.join(dir, "nope.yml"))
      File.write(File.join(dir, "empty.yml"), "")
      assert_empty FastCert.spine(dir, File.join(dir, "empty.yml"))
    end
  end

  def test_covered_by_spine_matches_exact_files_and_directory_members
    spine = ["test/models/task_test.rb", "test/controllers/api/v1"]
    assert FastCert.covered_by_spine?("test/models/task_test.rb", spine)
    assert FastCert.covered_by_spine?("test/controllers/api/v1/tasks_controller_test.rb", spine)
    refute FastCert.covered_by_spine?("test/models/release_test.rb", spine)
    # A sibling that merely SHARES the directory prefix string is NOT covered.
    refute FastCert.covered_by_spine?("test/controllers/api/v1_legacy_test.rb", spine)
  end

  # --- rubocop scope ---------------------------------------------------------------

  def test_lintable_files_keeps_ruby_and_ruby_shebang_bin_scripts_only
    with_tree(
      "app/models/widget.rb" => "class Widget; end\n",
      "Gemfile" => "source 'https://rubygems.org'\n",
      "bin/ruby-tool" => "#!/usr/bin/env ruby\nputs 1\n",
      "bin/shell-tool" => "#!/bin/sh\necho hi\n",
      "docs/notes.md" => "notes\n",
      "app/views/tasks/_gates.html.erb" => "<div></div>\n"
    ) do |dir|
      changed = ["app/models/widget.rb", "Gemfile", "bin/ruby-tool", "bin/shell-tool",
                 "docs/notes.md", "app/views/tasks/_gates.html.erb", "app/models/deleted.rb"]
      assert_equal ["app/models/widget.rb", "Gemfile", "bin/ruby-tool"],
                   FastCert.lintable_files(dir, changed)
    end
  end

  # --- changed-file collection over a real git repo --------------------------------

  def with_git_repo
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("commit -q --allow-empty -m init")
      yield dir, git
    end
  end

  def test_changed_files_unions_staged_unstaged_untracked_and_committed
    with_git_repo do |dir, git|
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      base_sha = `git -C #{dir} rev-parse HEAD`.strip

      write.call("app/models/committed.rb", "x\n")
      git.call("add -A")
      git.call("commit -q -m committed")
      write.call("app/models/staged.rb", "x\n")
      git.call("add app/models/staged.rb")
      write.call("app/models/untracked.rb", "x\n")

      files = FastCert.changed_files(dir, base_sha)
      assert_includes files, "app/models/committed.rb"
      assert_includes files, "app/models/staged.rb"
      assert_includes files, "app/models/untracked.rb"
    end
  end

  # --- classifiable_paths: the CLASSIFICATION view of the same diff ----------------
  #
  # THE ONE THING #changed_files CANNOT SEE. `git diff --name-only` collapses
  # `R100 bin/deploy.sh docs/notes.md` to the DESTINATION alone, so a commit that
  # renames an executable INTO a .md presents as one prose file while having deleted a
  # script from bin/. That is correct for SELECTION (the old path has no test to run)
  # and a fail-green for CLASSIFICATION, which is what the no-suite-owed waiver in
  # bin/fast-check asks. See the "BOTH SIDES OF A RENAME" block in bin/lib/code_diff.rb.

  def test_classifiable_paths_shows_BOTH_sides_of_a_rename
    with_git_repo do |dir, git|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/deploy.sh"), "#!/bin/sh\necho ship\n")
      git.call("add -A")
      git.call("commit -q -m script")
      base_sha = `git -C #{dir} rev-parse HEAD`.strip
      git.call("mv bin/deploy.sh notes.md")
      git.call("commit -q -m rename")

      selection = FastCert.changed_files(dir, base_sha)
      classification = FastCert.classifiable_paths(dir, base_sha)

      assert_equal ["notes.md"], selection,
                   "the SELECTION view is right to carry only the destination"
      assert_includes classification, "notes.md"
      assert_includes classification, "bin/deploy.sh",
                      "the DELETED half is the behaviour change, and it is invisible in the new path"
    end
  end

  def test_classifiable_paths_unions_staged_unstaged_untracked_and_committed
    with_git_repo do |dir, git|
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      base_sha = `git -C #{dir} rev-parse HEAD`.strip

      write.call("app/models/committed.rb", "x\n")
      git.call("add -A")
      git.call("commit -q -m committed")
      write.call("app/models/staged.rb", "x\n")
      git.call("add app/models/staged.rb")
      write.call("app/models/untracked.rb", "x\n")

      paths = FastCert.classifiable_paths(dir, base_sha)
      %w[app/models/committed.rb app/models/staged.rb app/models/untracked.rb].each do |f|
        assert_includes paths, f, "the classification view must see every view #changed_files does"
      end
    end
  end

  def test_default_diff_base_prefers_origin_release
    with_git_repo do |dir, git|
      assert_equal "origin/main", FastCert.default_diff_base(dir)
      sha = `git -C #{dir} rev-parse HEAD`.strip
      git.call("update-ref refs/remotes/origin/release #{sha}")
      assert_equal "origin/release", FastCert.default_diff_base(dir)
    end
  end

  # origin/accepted (the v2 integration branch feature PRs target) is preferred
  # over origin/release when present — the base-flip regression.
  def test_default_diff_base_prefers_origin_accepted_over_release
    with_git_repo do |dir, git|
      sha = `git -C #{dir} rev-parse HEAD`.strip
      git.call("update-ref refs/remotes/origin/release #{sha}")
      assert_equal "origin/release", FastCert.default_diff_base(dir)
      git.call("update-ref refs/remotes/origin/accepted #{sha}")
      assert_equal "origin/accepted", FastCert.default_diff_base(dir)
    end
  end

  # --- the mapped cap -----------------------------------------------------------
  #
  # WHY THERE IS A CAP AT ALL. There was none, and a fast lane that can silently
  # become a full suite is worse than a slow one: the builder cannot tell which
  # they are in. Observed live 2026-08-15 — a diff touching
  # config/initializers/studio.rb mapped to 45 test files and bin/fast-check was
  # still running at 39m34s against a lane g1-cert.md budgets at ~1 minute, which
  # bin/ship runs by default.

  def test_mapping_reports_what_each_changed_file_maps_to
    with_tree(
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "test/lib/other_test.rb" => "class OtherTest; end\n"
    ) do |dir|
      result = FastCert.mapping(dir, ["app/models/widget.rb", "app/models/ghost.rb"])

      assert_equal ["test/models/widget_test.rb"], result["app/models/widget.rb"]
      assert_empty result["app/models/ghost.rb"], "a path that maps nowhere still gets an entry"
    end
  end

  # select_tests IS the union of mapping, and must stay so — the cap reads the
  # per-file breakdown to name a culprit, and it can only be trusted if the two
  # come from the same pass.
  def test_select_tests_is_the_union_of_the_mapping
    with_tree(
      "test/models/widget_test.rb" => "class WidgetTest; end\n",
      "test/models/gadget_test.rb" => "class GadgetTest; end\n"
    ) do |dir|
      changed = ["app/models/widget.rb", "app/models/gadget.rb"]

      assert_equal FastCert.mapping(dir, changed).values.flatten.uniq.sort,
                   FastCert.select_tests(dir, changed)
    end
  end

  def test_the_cap_defaults_low_and_reads_the_env
    assert_equal 15, FastCert::DEFAULT_MAPPED_CAP

    with_env("FAST_CHECK_MAPPED_CAP" => "3") { assert_equal 3, FastCert.mapped_cap }
  end

  # A MALFORMED OVERRIDE MUST NOT DISABLE THE CAP. "0", "" and "banana" all mean
  # "I did not say anything usable" — and `to_i` turns every one of them into 0,
  # which as a cap would skip the mapped lane on EVERY diff. That is a silent
  # cert-shaped hole, which is the exact disease this task exists to close.
  def test_a_useless_cap_override_falls_back_to_the_default
    ["0", "", "   ", "banana", "-4"].each do |raw|
      with_env("FAST_CHECK_MAPPED_CAP" => raw) do
        assert_equal FastCert::DEFAULT_MAPPED_CAP, FastCert.mapped_cap,
                     "#{raw.inspect} disabled the cap instead of falling back"
      end
    end
  end

  def test_a_narrow_diff_is_not_capped
    decision = FastCert.cap_decision(["test/models/widget_test.rb"],
                                     { "app/models/widget.rb" => ["test/models/widget_test.rb"] })

    refute decision[:capped]
    assert_equal 1, decision[:count]
  end

  # THE CULPRIT IS NAMED, not just the total. "48 files, too many" sends the
  # builder through their whole diff; "this one file mapped 44" names the cause,
  # and the cause is almost always one file whose grep token is too generic.
  def test_a_capped_decision_names_the_widest_mapping
    breakdown = {
      "app/models/widget.rb" => ["test/models/widget_test.rb"],
      "config/initializers/studio.rb" => (1..40).map { |i| "test/lib/t#{i}_test.rb" }
    }
    decision = FastCert.cap_decision(breakdown.values.flatten.uniq.sort, breakdown)

    assert decision[:capped]
    assert_equal 15, decision[:cap]
    assert_equal 41, decision[:count]
    assert_equal "config/initializers/studio.rb", decision[:worst_path]
    assert_equal 40, decision[:worst_count]
  end

  # THE CAP IS ABOUT EXTRA WORK, so it reads the set AFTER the spine dedupe. A
  # mapped test the spine already runs costs this lane nothing, and capping the
  # raw union would refuse diffs whose mapping is entirely redundant — punishing
  # exactly the diffs the spine already covers well.
  def test_the_cap_counts_what_it_is_given_not_the_raw_union
    breakdown = { "config/initializers/studio.rb" => (1..40).map { |i| "test/lib/t#{i}_test.rb" } }
    after_spine_dedupe = ["test/lib/t1_test.rb", "test/lib/t2_test.rb"]

    decision = FastCert.cap_decision(after_spine_dedupe, breakdown)

    refute decision[:capped],
           "the cap tripped on the raw mapping — 38 of those 40 are already in the spine"
    assert_equal 2, decision[:count]
  end

  # --- [unit] the zero-evidence guard -------------------------------------------
  #
  # THE DEFECT, verbatim from turf-monster PR #549's checks_run:
  #   "fast cert green: 0 mapped (CAPPED: 26 > 15; spine only) + 0 spine test
  #    path(s), rubocop on 3 changed file(s)"
  # The mapped lane was capped, the spine resolved to nothing, and the cert
  # reported GREEN having executed no test at all — rubocop was the only lane, and
  # a linter cannot observe behaviour.

  # THE SET IS WHAT WILL RUN, NOT WHAT MAPPED. A capped mapped lane contributes
  # NOTHING here — that difference is the whole guard, and reading `mapped_only`
  # regardless is exactly how the green cert was issued.
  def test_a_capped_mapped_lane_contributes_no_executed_paths
    mapped = (1..20).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "config/initializers/studio.rb" => mapped })

    assert_equal ["test/models/spine_core_test.rb"],
                 FastCert.executed_test_paths(mapped, ["test/models/spine_core_test.rb"], capped),
                 "the capped lane runs nothing, so only the spine is executed"
    assert_empty FastCert.executed_test_paths(mapped, [], capped),
                 "capped mapped lane + empty spine = no test file is executed at all"
  end

  def test_an_uncapped_mapped_lane_contributes_its_paths
    mapped = ["test/models/widget_test.rb"]
    decision = FastCert.cap_decision(mapped, { "app/models/widget.rb" => mapped })

    assert_equal ["test/models/widget_test.rb", "test/models/spine_core_test.rb"],
                 FastCert.executed_test_paths(mapped, ["test/models/spine_core_test.rb"], decision)
    assert_equal ["test/models/widget_test.rb"],
                 FastCert.executed_test_paths(mapped, [], decision),
                 "an empty spine is survivable — the mapped lane still executed a test"
  end

  # A path in BOTH lanes is executed once, so the count of executed paths cannot be
  # inflated by the dedupe's leftovers.
  def test_executed_paths_are_deduped_across_the_two_lanes
    mapped = ["test/models/widget_test.rb"]
    decision = FastCert.cap_decision(mapped, { "app/models/widget.rb" => mapped })

    assert_equal ["test/models/widget_test.rb"],
                 FastCert.executed_test_paths(mapped, ["test/models/widget_test.rb"], decision)
  end

  # --- the tri-state verdict -----------------------------------------------------
  #
  # WHERE THE REFUSAL LANDS IS THE BUG THIS SPLIT FIXES. bin/fast-check runs at ship
  # step 2 of 8, before the push and before any PR exists — so refusing a CAPPED diff
  # left the builder with no PR, no CI, and one remedy: a local full suite measured at
  # ~30 minutes against CI's ~9 for the identical command. The refusal was right; its
  # POSITION was not. A capped diff now DEFERS (records a receipt, exits 2, and
  # bin/dor-check demands a GREEN CI); a diff mapping to NOTHING still REFUSES.

  def test_a_capped_lane_over_an_empty_spine_DEFERS_and_names_the_culprit
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })

    outcome = FastCert.zero_test_outcome(mapped, [], capped, slug: "some-task")

    refute_nil outcome, "the PR #549 shape must NOT certify"
    assert_equal :defer, outcome[:kind],
                 "a capped diff mapped to MORE tests than the cap, and CI runs every one of them"
    assert_match(/NOT CERTIFIED/, outcome[:message], "it is still not a certification")
    assert_match(/ZERO test files/, outcome[:message])
    assert_match(/CAPPED — 26 mapped path\(s\) over the cap of 15/, outcome[:message],
                 "the builder is told what tripped it")
    assert_match(%r{widest: app/services/solana/config\.rb}, outcome[:message], "and which file caused it")
    assert_match(/FAST_CHECK_MAPPED_CAP=26/, outcome[:message], "the deliberate override stays discoverable")
    assert_match(%r{bin/full-suite-check some-task}, outcome[:message],
                 "and certifying locally is still offered, for THIS task")
  end

  # THE RECEIPT IS THE DEFERRAL. A message the builder reads is not evidence — what
  # dor-check grades is `detail`, so it must carry the WHOLE cause on its own: no
  # local lane could run, why, and the rule that will be applied to it.
  def test_the_deferral_detail_is_a_standalone_record_of_the_cause
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })

    detail = FastCert.zero_test_outcome(mapped, [], capped, slug: "some-task")[:detail]

    assert_match(/DEFERRED to GitHub CI/, detail)
    assert_match(/CAPPED — 26 mapped path\(s\) over the cap of 15/, detail)
    assert_match(/GREEN CI/, detail, "the rule that will be applied rides on the record itself")
    assert_match(/never provisionally/, detail,
                 "the asymmetry with the fast lane is part of the record, not folklore")
  end

  # DEFERRING IS NOT SKIPPING, said in the message the builder actually reads. A
  # builder who is told "continuing" and not told what still has to be true will read
  # the later dor-check refusal as a new fault rather than as the gate working.
  def test_the_deferral_message_states_the_fence_it_is_deferring_to
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })

    message = FastCert.zero_test_outcome(mapped, [], capped, slug: "some-task")[:message]

    assert_match(/REFUSES the submit unless CI is GREEN/, message)
    assert_match(/deferring is not skipping/i, message)
  end

  # THE SECOND-RUNG DEFERRAL, and the sentence inside it that contradicted the receipt
  # carrying it. #fallback_note has exactly ONE caller — #defer_outcome — which is
  # reached only over a spine this checkout resolves NONE of, and whose detail says so
  # two clauses earlier. Its over-cap branch then offered "the lane degraded a second
  # time, to the spine": a rung the reader has just been told does not exist here. The
  # branch was untested anywhere, which is how two halves of one paragraph came to
  # disagree without anything going red.
  def test_a_twin_set_over_the_cap_does_not_offer_a_spine_the_checkout_lacks
    mapped = (1..40).map { |i| "test/lib/t#{i}_test.rb" }
    twins = (1..20).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "bin/wide-tool" => mapped }, twins: twins)

    assert_equal 20, capped[:fallback_considered], "the fixture must REACH the over-cap branch"
    assert_empty capped[:fallback], "…which is the branch where 20 twins is itself over the cap of 15"

    detail = FastCert.zero_test_outcome(mapped, [], capped, slug: "some-task")[:detail]

    assert_match(/20 twin\(s\) is ITSELF over the cap of 15/, detail,
                 "the receipt still names WHICH empty this was")
    assert_match(/resolves NONE of/, detail,
                 "and the same receipt still says this checkout has no spine — that is the contradiction")
    refute_match(/degraded a second time, to the spine\./, detail,
                 "a receipt cannot degrade to a spine it has just said resolves nowhere here")
    assert_match(/which this checkout resolves none of/, detail,
                 "so the rung is named AND placed: it is why the run ends in a deferral, not a cert")
  end

  # THE OTHER BRANCH OF THE SAME NOTE IS CORRECT AND STAYS. A deferral presupposes an
  # empty spine, so `0 considered` there really does mean no changed file has a twin —
  # the spine-covered case that made the identical wording FALSE in bin/fast-check's
  # narration cannot arise where there is no spine to cover anything.
  def test_the_no_twin_branch_of_the_deferral_receipt_is_unchanged
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })

    detail = FastCert.zero_test_outcome(mapped, [], capped, slug: "some-task")[:detail]

    assert_equal 0, capped[:fallback_considered]
    assert_match(/no changed file has an existing test twin/, detail,
                 "correct HERE, because a deferral is only reached over a spine that resolves nothing")
  end

  # THE OTHER DOOR INTO THE SAME ROOM, AND IT DOES NOT MOVE. Keyed on the CAP, a
  # satellite diff mapping to 26 test files would be refused while one mapping to NONE
  # — strictly LESS evidence — would certify green on rubocop alone. The guard stays
  # keyed on the zero, and this half stays a REFUSAL: "nothing in the suite reads this
  # code" is a fact about the DIFF, not about our local budget, and deferring it would
  # delete the guard for one of its two doors rather than relocate its evidence.
  def test_a_diff_that_maps_to_nothing_over_an_empty_spine_is_still_REFUSED
    outcome = FastCert.zero_test_outcome([], [], FastCert.cap_decision([], {}), slug: "some-task")

    refute_nil outcome, "zero executed tests is zero evidence however it was reached"
    assert_equal :refuse, outcome[:kind], "this door is not a deferral — it is the refusal, unchanged"
    assert_match(/REFUSING TO CERTIFY/, outcome[:message])
    assert_match(/maps to NO test file/, outcome[:message], "the reason given must be the REAL one, not the cap")
    refute_match(/CAPPED/, outcome[:message], "no cap was involved — saying so would misdirect the builder")
    refute_match(/FAST_CHECK_MAPPED_CAP/, outcome[:message],
                 "raising a cap that never tripped fixes nothing; offering it is a dead end")
    refute_match(/DEFER/i, outcome[:message], "and it must not advertise a route it is not taking")
    assert_match(%r{bin/full-suite-check some-task}, outcome[:message])
  end

  # WITHOUT A SLUG (bin/fast-check --print, or a hook) the remedy still has to be
  # copyable, so it degrades to the placeholder rather than to "bin/full-suite-check ".
  def test_both_verdicts_without_a_slug_still_print_a_usable_command
    refusal = FastCert.zero_test_outcome([], [], FastCert.cap_decision([], {}))
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })
    deferral = FastCert.zero_test_outcome(mapped, [], capped)

    assert_match(%r{bin/full-suite-check <task>}, refusal[:message])
    assert_match(%r{bin/full-suite-check <task>}, deferral[:message])
  end

  # THE SIGNAL IS NON-ZERO, and that is the whole safety property. Every caller
  # reaches bin/fast-check through `system(...)`, whose truthiness is "exited 0" — so
  # a caller that has never heard of deferral keeps reading it as "not certified".
  # Exiting 0 would have been one line and would have recreated PR #1226's fail-green.
  def test_the_deferred_exit_status_is_not_success
    refute_equal 0, FastCert::DEFERRED_EXIT,
                 "a deferral must be FALSY to every system() caller — it is not a certification"
    assert_equal 2, FastCert::DEFERRED_EXIT, "and it must be distinguishable from a plain refusal (1)"
  end

  # AND THE HALF THAT MUST NOT MOVE. A capped run whose SPINE still ran executed real
  # tests: it is a NARROWER cert, honestly labelled by the existing "0 mapped
  # (CAPPED: ...)" evidence, and degrading it would hurt builds that legitimately
  # certified. This is the any-cap-degrades ruling, rejected, pinned as a test — and
  # it must not become a DEFERRAL either, which would be the same degradation wearing
  # a new name.
  def test_a_capped_lane_with_a_LIVE_spine_still_certifies
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })

    assert_nil FastCert.zero_test_outcome(mapped, ["test/models/task_test.rb"], capped),
               "the spine ran real tests — a cap alone must neither refuse NOR defer"
  end

  def test_an_ordinary_diff_is_never_refused_or_deferred
    mapped = ["test/models/widget_test.rb"]
    decision = FastCert.cap_decision(mapped, { "app/models/widget.rb" => mapped })

    assert_nil FastCert.zero_test_outcome(mapped, ["test/models/task_test.rb"], decision)
    assert_nil FastCert.zero_test_outcome(mapped, [], decision),
               "a mapped lane that runs is evidence, spine or no spine"
    assert_nil FastCert.zero_test_outcome([], ["test/models/task_test.rb"], decision),
               "a spine that runs is evidence, mapping or no mapping"
  end


  # --- the SATELLITE door: a checkout that resolves NO declared spine -----------------
  #
  # MEASURED 2026-09-07 (re-derived; the 2026-09-06 figure held): config/fast_cert_spine.yml
  # declares FIVE entries and the hub resolves 5/5 while turf-monster, rolio, turf-vault,
  # studio-engine and solana-studio each resolve 0/5. So the SAME docs-only diff certifies
  # GREEN in the hub (the spine runs) and is REFUSED on a satellite (the spine resolves to
  # nothing) — a verdict decided by WHERE THE BUILDER IS STANDING, not by the diff. The old
  # refusal message asserted the opposite in so many words ("the diff maps to NO test file"),
  # which is why this went unnoticed for a day.
  #
  # WHY DEFER AND NOT CERTIFY. What the hub's spine buys on a docs-only diff is a TREE-HEALTH
  # SMOKE TEST — the task/release/gate models still pass — never coverage of the markdown that
  # changed. A satellite cannot run that smoke test, but CI runs the satellite's WHOLE suite on
  # this exact tree. Deferring therefore demands strictly MORE evidence than the hub's green,
  # not less; it is the capped case's argument with the same shape.
  def test_a_docs_only_diff_on_a_satellite_DEFERS_instead_of_refusing
    outcome = FastCert.zero_test_outcome([], [], FastCert.cap_decision([], {}), slug: "some-task",
                                                                               declared_spine: SPINE_FIVE)

    refute_nil outcome, "zero executed tests is still zero evidence — the guard must fire"
    assert_equal :defer, outcome[:kind],
                 "the spine resolving to NOTHING is a fact about the CHECKOUT; CI covers this tree"
    refute_match(/CAPPED/, outcome[:message], "no cap was involved — naming one would misdirect")
    assert_match(/resolves NONE/i, outcome[:message], "it must name the REAL cause: the unresolved spine")
    assert outcome[:detail].to_s.length.positive?, "a deferral with no receipt detail is a shrug"
    assert_match(/5/, outcome[:detail], "the receipt must name how many entries went unresolved")
  end

  # THE HALF THAT MUST NOT MOVE — and the one a lazy fix deletes. With NO spine declared at
  # all (a missing, empty or unparseable config) there is no satellite story to tell: the
  # cert's configured core has vanished, and that is worth stopping for rather than deferring
  # every diff in the ecosystem forever.
  def test_no_spine_DECLARED_at_all_still_REFUSES
    outcome = FastCert.zero_test_outcome([], [], FastCert.cap_decision([], {}), slug: "some-task",
                                                                               declared_spine: [])

    assert_equal :refuse, outcome[:kind], "nothing declared, nothing mapped — refuse, do not defer"
    assert_match(/REFUSING TO CERTIFY/, outcome[:message])
  end

  # THE DEFAULT IS THE STRICT ONE. Every caller that has not been taught to pass the declared
  # spine keeps the OLD refusal, so this can never loosen a lane by omission.
  def test_the_declared_spine_defaults_to_the_strict_refusal
    outcome = FastCert.zero_test_outcome([], [], FastCert.cap_decision([], {}), slug: "some-task")

    assert_equal :refuse, outcome[:kind], "omitting declared_spine must fail CLOSED, not open"
  end

  # A LIVE SPINE IS STILL EVIDENCE. Declared AND resolved means the hub, and the hub runs it.
  def test_a_declared_spine_that_RESOLVES_is_neither_refused_nor_deferred
    assert_nil FastCert.zero_test_outcome([], ["test/models/task_test.rb"], FastCert.cap_decision([], {}),
                                          slug: "some-task", declared_spine: SPINE_FIVE)
  end

  # THE CAP STILL WINS WHEN BOTH ARE TRUE, so a capped satellite run keeps naming the cap —
  # the number the builder can actually act on (FAST_CHECK_MAPPED_CAP).
  def test_a_capped_satellite_run_still_reports_the_CAP_as_its_cause
    mapped = (1..26).map { |i| "test/lib/t#{i}_test.rb" }
    capped = FastCert.cap_decision(mapped, { "app/services/solana/config.rb" => mapped })
    outcome = FastCert.zero_test_outcome(mapped, [], capped, slug: "t", declared_spine: SPINE_FIVE)

    assert_equal :defer, outcome[:kind]
    assert_match(/CAPPED/, outcome[:detail], "the cap is the actionable cause when it tripped")
  end

  # --- the REMEDY: a command the checkout can actually RUN ---------------------------
  #
  # MEASURED 2026-09-07: bin/full-suite-check exists ONLY in the hub. Every satellite —
  # turf-monster, rolio, turf-vault, studio-engine, solana-studio — has no such file, so the
  # remedy every zero-evidence verdict printed ("bin/full-suite-check <task>") was, verbatim,
  # a command the reader's repo could not execute. The fix is the hub's ABSOLUTE path, and only
  # that — see test_the_remedy_never_offers_a_bypass for the branch that was written, measured
  # against turf-vault, and deliberately removed.
  def test_the_hub_remedy_stays_the_plain_relative_command
    line = FastCert.remedy("some-task", root: "/x/mcritchie-studio", hub_root: "/x/mcritchie-studio")

    assert_equal "bin/full-suite-check some-task", line
  end

  def test_a_satellite_remedy_names_the_HUB_ABSOLUTE_path
    line = FastCert.remedy("some-task", root: "/x/turf-monster", hub_root: "/x/mcritchie-studio")

    assert_equal "/x/mcritchie-studio/bin/full-suite-check some-task", line
    refute_match(%r{\Abin/full-suite-check}, line,
                 "a satellite has no bin/full-suite-check of its own — a relative path is not runnable there")
  end

  # BOTH VERDICTS CARRY THE SAME REMEDY, because a builder reading either one has the same
  # question. Stating it twice is how the two drift apart.
  def test_the_satellite_remedy_reaches_the_deferral_message
    outcome = FastCert.zero_test_outcome([], [], FastCert.cap_decision([], {}), slug: "some-task",
                                                                               declared_spine: SPINE_FIVE,
                                                                               remedy: "/hub/bin/full-suite-check some-task")

    assert_match(%r{/hub/bin/full-suite-check some-task}, outcome[:message])
  end

  def test_the_satellite_remedy_reaches_the_refusal_message
    outcome = FastCert.zero_test_outcome([], [], FastCert.cap_decision([], {}), slug: "some-task",
                                                                               remedy: "/hub/bin/full-suite-check some-task")

    assert_equal :refuse, outcome[:kind]
    assert_match(%r{/hub/bin/full-suite-check some-task}, outcome[:message])
  end

  # --- declared_spine: the fact the script feeds in ---------------------------------

  # declared_spine counts what the CONFIG asks for; spine() counts what the CHECKOUT has.
  # The gap between the two IS the satellite signal, so they must not collapse into one read.
  def test_declared_spine_lists_entries_the_checkout_does_not_have
    Dir.mktmpdir do |tmp|
      config = File.join(tmp, "spine.yml")
      File.write(config, "spine:\n  - test/models/task_test.rb\n  - test/models/release_test.rb\n")

      assert_equal ["test/models/task_test.rb", "test/models/release_test.rb"], FastCert.declared_spine(config)
      assert_empty FastCert.spine(tmp, config), "…and NONE of them exist here — that is the satellite gap"
    end
  end

  def test_declared_spine_is_empty_when_the_config_is_missing_or_broken
    Dir.mktmpdir do |tmp|
      assert_empty FastCert.declared_spine(File.join(tmp, "nope.yml"))
      broken = File.join(tmp, "broken.yml")
      File.write(broken, "spine: [\n")
      assert_empty FastCert.declared_spine(broken), "an unparseable config declares nothing — fail CLOSED"
    end
  end

  def with_env(pairs)
    previous = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
