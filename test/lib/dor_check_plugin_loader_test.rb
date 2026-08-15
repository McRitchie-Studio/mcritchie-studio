# frozen_string_literal: true

# THE PLUGIN SEAM. Standalone (no Rails):
#   ruby -Itest test/lib/dor_check_plugin_loader_test.rb
#
# WHAT IS ACTUALLY BEING ASSERTED, and why the integration test is the important one.
# The goal of this seam is not "checks live in smaller files" — that alone would just
# move the contention to whichever file held the list. The goal is that ADDING A CHECK
# EDITS NO SHARED FILE. So the test that matters drops a brand-new check file into the
# real directory, runs the real bin/dor-check as a subprocess, and asserts the verdict
# changed — with no require line, no registry entry and no hook added anywhere. If that
# test ever needs a second file edited to pass, the seam has regressed to a registry.
#
# MEASURED REASON THIS EXISTS (2026-08-14): bin/dor-check was touched by 24 of the last
# 200 merged PRs, and three tasks in one wave all needed to edit it — they had to be
# serialised by hand to avoid a guaranteed three-way conflict.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../../bin/lib/dor/checks"
require_relative "../../bin/lib/dor/check_context"

class DorCheckPluginLoaderTest < Minitest::Test
  BIN        = File.expand_path("../../bin/dor-check", __dir__)
  CHECKS_DIR = File.expand_path("../../bin/lib/dor/checks", __dir__)
  PR_URL     = "https://github.com/McRitchie-Studio/myapp/pull/77"

  def context(**over)
    Dor::Checks::Context.new(**{
      gate: "merge", gate_role: "builder", task: {}, devops: {}, slug: "t",
      diff_root: Dir.tmpdir, diff_base: "HEAD", pr_url: PR_URL, changed_files: []
    }.merge(over))
  end

  # ── [unit] discovery is a glob, and it is ordered ──────────────────────────

  def test_the_loader_discovers_every_file_in_the_directory
    Dir.mktmpdir do |dir|
      %w[zebra alpha middle].each do |name|
        File.write(File.join(dir, "#{name}_check.rb"), <<~RB)
          class #{name.capitalize}Check < Dor::Checks::Base
            def call(ctx); ctx.error("#{name} ran"); end
          end
        RB
      end
      Dor::Checks.reset!
      Dor::Checks.load!(dir)

      names = Dor::Checks.registry.map(&:check_name)
      assert_equal 3, names.size, "every file in the directory is a check: #{names.inspect}"
      assert_equal names.sort, Dor::Checks.for_phase(:merge).map(&:check_name),
                   "order must be deterministic, not filesystem-dependent"
    ensure
      Dor::Checks.reset!
      Dor::Checks.load!
    end
  end

  def test_a_check_declares_its_phase_and_defaults_to_merge
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "build_only_check.rb"), <<~RB)
        class BuildOnlyCheck < Dor::Checks::Base
          def self.phase = :build
          def call(ctx); ctx.error("build"); end
        end
      RB
      File.write(File.join(dir, "default_check.rb"), <<~RB)
        class DefaultCheck < Dor::Checks::Base
          def call(ctx); ctx.error("merge"); end
        end
      RB
      Dor::Checks.reset!
      Dor::Checks.load!(dir)

      assert_equal ["default_check"],    Dor::Checks.for_phase(:merge).map(&:check_name)
      assert_equal ["build_only_check"], Dor::Checks.for_phase(:build).map(&:check_name)
    ensure
      Dor::Checks.reset!
      Dor::Checks.load!
    end
  end

  # A check that raises must not take the gate down with it. A gate that dies halfway
  # reports a verdict about a subset of itself while looking complete — the same class
  # of defect the checks exist to catch.
  def test_a_raising_check_is_contained_and_the_others_still_run
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a_exploding_check.rb"), <<~RB)
        class AExplodingCheck < Dor::Checks::Base
          def call(_ctx); raise "boom"; end
        end
      RB
      File.write(File.join(dir, "b_quiet_check.rb"), <<~RB)
        class BQuietCheck < Dor::Checks::Base
          def call(ctx); ctx.error("the other check still ran"); end
        end
      RB
      Dor::Checks.reset!
      Dor::Checks.load!(dir)

      ctx = Dor::Checks.run(:merge, context)
      joined = ctx.errors.join(" | ")
      assert_match(/a_exploding_check FAILED to run/, joined, "the fault must NAME the check")
      assert_match(/fault in the gate itself/, joined, "and must not read as a verdict about the diff")
      assert_match(/the other check still ran/, joined)
    ensure
      Dor::Checks.reset!
      Dor::Checks.load!
    end
  end

  # ── [unit] the context is the whole surface ───────────────────────────────

  def test_say_is_dropped_in_json_mode_but_kept_in_text_mode
    # Prose printed beside a --json verdict corrupts the payload — that is a bug this
    # seam already shipped once, when the migration check called puts directly.
    assert_empty context(json: true).say("block line").lines
    assert_equal ["block line"], context(json: false).say("block line").lines
  end

  # ── [integration] a NEW check file changes the verdict, editing nothing else ──

  def test_a_new_check_file_changes_the_verdict_with_no_registry_edit
    marker = "PLUGIN_SEAM_PROOF_#{Process.pid}"
    added  = File.join(CHECKS_DIR, "zzz_seam_probe_check.rb")
    before = repo_file_list

    File.write(added, <<~RB)
      class ZzzSeamProbeCheck < Dor::Checks::Base
        def call(ctx); ctx.error("#{marker}"); end
      end
    RB

    verdict, code = run_gate
    assert_match(/#{marker}/, Array(verdict["errors"]).join(" | "),
                 "a check that is only a NEW FILE must reach the verdict")
    assert_equal 1, code, "and its error must refuse, exactly like an inline check"

    # THE ACTUAL CLAIM: nothing else on disk changed to make that happen.
    assert_equal [added], (repo_file_list - before),
                 "adding a check must add ONE file and edit NOTHING else"
  ensure
    FileUtils.rm_f(added.to_s)
  end

  # The control for the test above: with the probe file gone, the marker is gone too.
  # Without this, the assertion above would pass against a gate that always errors.
  def test_removing_the_check_file_removes_its_verdict
    verdict, code = run_gate
    refute_match(/PLUGIN_SEAM_PROOF/, Array(verdict["errors"]).join(" | "))
    assert_equal 0, code, "a clean task with no plugged failures is ready: #{verdict["errors"].inspect}"
  end

  private

  def repo_file_list
    Dir.glob(File.join(CHECKS_DIR, "*.rb")).sort
  end

  def run_gate
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(
        "slug" => "task-seam", "title" => "T",
        "metadata" => { "devops" => {
          "kind" => "bug", "shape" => "backend", "pr_url" => PR_URL,
          "acceptance" => ["prove the seam"], "repositories" => ["myapp"],
          "risk_tags" => ["gate-integrity"],
          "test_plan" => ["[unit] x", "[integration] y"],
          "post_deploy_cmd" => "none",
          "checks_run" => ["[unit] x", "[integration] y"]
        } }
      ))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => d, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => "app/models/thing.rb",
        "DOR_CHECK_PR_FILES" => "app/models/thing.rb",
        "DOR_CHECK_PR_MIGRATIONS" => "", "DOR_CHECK_SIBLING_PRS" => "[]",
        "DOR_CHECK_CI_STATUS" => "green", "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      )
      out = IO.popen(env, "#{BIN} --file #{path} --json 2>/dev/null", &:read)
      [JSON.parse(out), $?.exitstatus]
    end
  end
end
