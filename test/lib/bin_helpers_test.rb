# frozen_string_literal: true

# Tests for bin/lib/bin_helpers.rb — bin_for (helper-binary resolution shared by
# bin/conductor, bin/pr-review) and safe_filename (shared by bin/pr-review,
# bin/devops-cycle). Only exact-match duplicates were folded here.
#   ruby -Itest test/lib/bin_helpers_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "open3"
require "tmpdir"

require File.expand_path("../../bin/lib/bin_helpers", __dir__)

class BinHelpersTest < Minitest::Test
  ENV_KEY = "BIN_HELPERS_TEST_BIN"

  def teardown
    ENV.delete(ENV_KEY)
  end

  # ── [unit] bin_for ───────────────────────────────────────────────────────────

  def test_unit_env_override_wins
    ENV[ENV_KEY] = "/tmp/fake-task"
    assert_equal "/tmp/fake-task", BinHelpers.bin_for(ENV_KEY, "task")
  end

  def test_unit_blank_override_falls_back_to_the_sibling_script
    ENV[ENV_KEY] = "   "
    assert_equal File.join(BinHelpers::BIN_DIR, "task"), BinHelpers.bin_for(ENV_KEY, "task")
  end

  def test_unit_default_is_the_sibling_script_in_bin
    assert_equal File.expand_path("../../bin/task", __dir__), BinHelpers.bin_for(ENV_KEY, "task")
  end

  # Regression — 2026-07-19 pr-review wave: GH_BIN defaulted to bin/gh, which
  # does not ship (gh is the external GitHub CLI), so every gh write ENOENT'd
  # and merge-ready verdicts stranded unstamped. No sibling ⇒ bare name, so
  # the spawn resolves the real CLI through PATH.
  def test_unit_default_falls_back_to_path_when_no_sibling_ships
    refute File.exist?(File.join(BinHelpers::BIN_DIR, "gh")), "bin/gh now ships — revisit this regression pin"
    assert_equal "gh", BinHelpers.bin_for(ENV_KEY, "gh")
  end

  def test_unit_sibling_wins_over_path_when_it_ships
    Dir.mktmpdir do |dir|
      sibling = File.join(dir, "gh")
      File.write(sibling, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, sibling)
      assert_equal sibling, BinHelpers.bin_for(ENV_KEY, "gh", dir: dir)
    end
  end

  def test_unit_missing_sibling_falls_back_to_bare_name_for_path_lookup
    Dir.mktmpdir do |dir|
      assert_equal "gh", BinHelpers.bin_for(ENV_KEY, "gh", dir: dir)
    end
  end

  def test_unit_non_executable_sibling_is_ignored
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "gh"), "not runnable")
      File.chmod(0o644, File.join(dir, "gh"))
      assert_equal "gh", BinHelpers.bin_for(ENV_KEY, "gh", dir: dir)
    end
  end

  def test_unit_env_override_wins_even_when_a_sibling_ships
    Dir.mktmpdir do |dir|
      sibling = File.join(dir, "gh")
      File.write(sibling, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, sibling)
      ENV[ENV_KEY] = "/tmp/fake-gh"
      assert_equal "/tmp/fake-gh", BinHelpers.bin_for(ENV_KEY, "gh", dir: dir)
    end
  end

  # ── [integration] bin_for → spawn ────────────────────────────────────────────

  # The failure mode was at the exec boundary (mise: "couldn't exec process: No
  # such file or directory"), so cross it: resolve gh exactly as bin/pr-review
  # does (real BIN_DIR, no override) and spawn the result under a controlled
  # PATH holding a fake gh. Under the broken resolution this ENOENTs.
  def test_integration_resolved_gh_spawns_from_path_when_no_sibling_ships
    Dir.mktmpdir do |path_dir|
      fake_gh = File.join(path_dir, "gh")
      File.write(fake_gh, "#!/bin/sh\necho fake-gh-ok\n")
      File.chmod(0o755, fake_gh)

      resolved = BinHelpers.bin_for(ENV_KEY, "gh")
      out, status = Open3.capture2({ "PATH" => path_dir }, resolved)

      assert status.success?, "resolved gh (#{resolved}) failed to spawn"
      assert_equal "fake-gh-ok", out.strip
    end
  end

  # ── [unit] safe_filename ─────────────────────────────────────────────────────

  def test_unit_safe_filename_collapses_and_trims
    assert_equal "a-b.c_d", BinHelpers.safe_filename("a/ b.c_d")
    assert_equal "slug", BinHelpers.safe_filename("--slug--")
    assert_equal "", BinHelpers.safe_filename(nil)
  end
end
