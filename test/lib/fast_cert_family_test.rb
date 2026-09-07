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

  # THE CASE THAT BIT, against the REAL repo rather than a fixture — a fixture
  # can only prove the rule, not that the rule reaches the file that reddened CI.
  # Derived from the tree rather than hard-listed, so adding a sixteenth
  # dor_check test does not red-seal an unrelated PR.
  def test_real_repo_dor_check_diff_reaches_the_registry_test
    selected = FastCert.select_tests(REPO_ROOT, ["bin/dor-check"])

    assert_includes selected, "test/lib/dor_check_exempt_ci_test.rb",
                    "the self-checking registry over bin/dor-check's own source must be reachable " \
                    "from a diff that touches bin/dor-check"

    # The twin AND the suffixed family — the brace glob is what the twin-only
    # convention hop used to miss.
    present = Dir.glob("test/lib/dor_check{,_*}_test.rb", base: REPO_ROOT).sort
    assert_operator present.size, :>=, 10, "expected bin/dor-check to still have a test FAMILY"
    assert_equal present, selected.sort, "every dor_check test file must map from bin/dor-check"
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
end
