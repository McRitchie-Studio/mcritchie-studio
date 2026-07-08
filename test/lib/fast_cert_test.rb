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

  def test_bin_script_maps_to_underscored_harness_test
    assert_equal ["test/lib/fast_check_test.rb"], FastCert.convention_candidates("bin/fast-check")
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

  def test_grep_token_camelizes_ruby_basenames
    assert_equal "GateRun", FastCert.grep_token("app/models/gate_run.rb")
    assert_equal "FullSuiteGate", FastCert.grep_token("bin/lib/full_suite_gate.rb")
  end

  def test_grep_token_uses_the_script_name_for_bin_tools
    assert_equal "fast-check", FastCert.grep_token("bin/fast-check")
  end

  def test_grep_token_uses_the_basename_for_config_yml
    assert_equal "fast_cert_spine", FastCert.grep_token("config/fast_cert_spine.yml")
  end

  def test_grep_token_is_nil_for_views_and_docs
    assert_nil FastCert.grep_token("app/views/tasks/_gates.html.erb")
    assert_nil FastCert.grep_token("docs/agents/sop.md")
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

  def test_default_diff_base_prefers_origin_release
    with_git_repo do |dir, git|
      assert_equal "origin/main", FastCert.default_diff_base(dir)
      sha = `git -C #{dir} rev-parse HEAD`.strip
      git.call("update-ref refs/remotes/origin/release #{sha}")
      assert_equal "origin/release", FastCert.default_diff_base(dir)
    end
  end
end
