require "test_helper"

# Unit coverage for the pure ARGV-parsing helpers extracted from bin/release.
# These mutate the args array in place (consuming the flags they parse), exactly
# as the old top-level `ARGV.delete` / `opt_value` / `opt_values` did — so the
# shell can route every flag through one tested place.
class Release::CliTest < ActiveSupport::TestCase
  # --- take_flag ---

  test "take_flag returns true and deletes the flag when present" do
    args = ["prepare", "--dry-run", "--local"]
    assert Release::Cli.take_flag(args, "--dry-run")
    assert_equal ["prepare", "--local"], args, "the consumed flag is removed"
  end

  test "take_flag returns false and leaves args untouched when absent" do
    args = ["prepare", "--local"]
    refute Release::Cli.take_flag(args, "--dry-run")
    assert_equal ["prepare", "--local"], args
  end

  test "take_flag deletes a flag even when it is the only token" do
    args = ["--yes"]
    assert Release::Cli.take_flag(args, "--yes")
    assert_empty args
  end

  # --- opt_value ---

  test "opt_value returns the token after the flag and consumes both" do
    args = ["ship", "--by", "carl", "--dry-run"]
    assert_equal "carl", Release::Cli.opt_value(args, "--by")
    assert_equal ["ship", "--dry-run"], args, "flag + value both removed"
  end

  test "opt_value returns nil and leaves args untouched when the flag is absent" do
    args = ["ship", "--dry-run"]
    assert_nil Release::Cli.opt_value(args, "--by")
    assert_equal ["ship", "--dry-run"], args
  end

  test "opt_value consumes only the FIRST occurrence" do
    args = ["--slug", "rel-a", "--slug", "rel-b"]
    assert_equal "rel-a", Release::Cli.opt_value(args, "--slug")
    assert_equal ["--slug", "rel-b"], args
  end

  # --- opt_values ---

  test "opt_values collects every flag + value pair and consumes them all" do
    args = ["prepare", "--task", "t-a", "--task", "t-b", "--slug", "rel-x"]
    assert_equal %w[t-a t-b], Release::Cli.opt_values(args, "--task")
    assert_equal ["prepare", "--slug", "rel-x"], args, "only --task pairs consumed"
  end

  test "opt_values returns [] and leaves args untouched when the flag is absent" do
    args = ["prepare", "--slug", "rel-x"]
    assert_equal [], Release::Cli.opt_values(args, "--task")
    assert_equal ["prepare", "--slug", "rel-x"], args
  end

  test "opt_values compacts a trailing flag with no value" do
    # A dangling flag (no following token) yields a nil value, which is compacted
    # out — matching the old opt_values' `.compact`.
    args = ["prepare", "--task"]
    assert_equal [], Release::Cli.opt_values(args, "--task")
  end
end
