# frozen_string_literal: true

# Tests for bin/lib/bin_helpers.rb — bin_for (helper-binary resolution shared by
# bin/conductor, bin/pr-review) and safe_filename (shared by bin/pr-review,
# bin/devops-cycle). Only exact-match duplicates were folded here.
#   ruby -Itest test/lib/bin_helpers_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

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

  # ── [unit] safe_filename ─────────────────────────────────────────────────────

  def test_unit_safe_filename_collapses_and_trims
    assert_equal "a-b.c_d", BinHelpers.safe_filename("a/ b.c_d")
    assert_equal "slug", BinHelpers.safe_filename("--slug--")
    assert_equal "", BinHelpers.safe_filename(nil)
  end
end
