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

  # --- positional_slugs: the one-or-more task slugs `merge` accepts ---

  test "positional_slugs returns a single slug (backward-compatible)" do
    assert_equal %w[my-task], Release::Cli.positional_slugs(%w[my-task])
  end

  test "positional_slugs returns every non-flag token in order" do
    assert_equal %w[task-a task-b task-c],
                 Release::Cli.positional_slugs(%w[task-a task-b task-c])
  end

  test "positional_slugs excludes any flag-shaped token" do
    # By the time merge reads ARGV, load-time flags are gone — but a stray flag
    # must never be mistaken for a slug.
    assert_equal %w[task-a task-b],
                 Release::Cli.positional_slugs(%w[task-a --dry-run task-b])
  end

  test "positional_slugs is NON-mutating (leaves args intact)" do
    args = %w[task-a task-b]
    Release::Cli.positional_slugs(args)
    assert_equal %w[task-a task-b], args, "merge reads nothing else from args, so it doesn't consume them"
  end

  test "positional_slugs returns [] for no positional tokens" do
    assert_equal [], Release::Cli.positional_slugs([])
    assert_equal [], Release::Cli.positional_slugs(%w[--dry-run])
  end

  # --- the `=` spelling: the two parsers must agree ------------------------
  #
  # The shared argument guard's `classify` accepts `--flag=value` for every
  # declared value flag. Before this, opt_value/opt_values understood ONLY
  # `--flag value` — so `--slug=rel-x` would have passed the guard (accounted
  # for!) and then been dropped here, and prepare would have promoted under a
  # slug it invented. A guard blessing a spelling the parser discards is the same
  # silent-substitution defect one seam over, so both spellings resolve here.

  test "[unit] opt_value reads the --flag=value spelling the shared guard accepts" do
    args = ["prepare", "--slug=rel-2026-08-31-x", "--expedite"]
    assert_equal "rel-2026-08-31-x", Release::Cli.opt_value(args, "--slug")
    assert_equal ["prepare", "--expedite"], args, "the whole --flag=value token is consumed"
  end

  test "[unit] opt_value keeps an = inside the VALUE" do
    args = ["--feedback=rebase=needed"]
    assert_equal "rebase=needed", Release::Cli.opt_value(args, "--feedback")
  end

  test "[unit] opt_value takes whichever spelling comes FIRST" do
    args = ["--slug", "spaced", "--slug=equals"]
    assert_equal "spaced", Release::Cli.opt_value(args, "--slug")
    assert_equal ["--slug=equals"], args
  end

  test "[unit] opt_value does not match a flag that merely starts the same" do
    args = ["--slug-hint", "x"]
    assert_nil Release::Cli.opt_value(args, "--slug")
    assert_equal ["--slug-hint", "x"], args
  end

  test "[unit] opt_values collects both spellings, in order" do
    args = ["prepare", "--task=t-a", "--task", "t-b", "--slug", "rel-x"]
    assert_equal %w[t-a t-b], Release::Cli.opt_values(args, "--task")
    assert_equal ["prepare", "--slug", "rel-x"], args
  end

  test "[unit] opt_values accepts an EMPTY value on the = spelling without hanging" do
    args = ["--task="]
    assert_equal [""], Release::Cli.opt_values(args, "--task")
    assert_empty args, "the token is consumed, so the loop terminates"
  end

  # --- COMMANDS: the dictionary the guard is built from ---------------------

  # Every subcommand bin/release dispatches must be in the dictionary. A `when`
  # arm with no entry is a subcommand the guard cannot describe — so guard_args
  # returns nil for it, the guard does not run, and it is back in the defect
  # class this table exists to close.
  test "[unit] COMMANDS names every subcommand bin/release dispatches" do
    # Scoped to the DISPATCH BLOCK, not the whole file: a `when "…"` anywhere else
    # in 7,500 lines is a different case statement, and scanning globally would
    # make this test fail on an unrelated edit.
    src = File.read(Rails.root.join("bin", "release.rb"))
    block = src[/^  case ARGV\.shift$.*?^  else$/m]
    assert block, "bin/release.rb no longer dispatches with `case ARGV.shift` — re-anchor this test"
    dispatched = block.scan(/^  when "([a-z-]+)"/).flatten.sort

    assert_equal dispatched, Release::Cli::COMMANDS.keys.sort,
                 "the dispatcher and the argument dictionary disagree — a subcommand in one and " \
                 "not the other is either an unguarded mutation or a guard for a command that " \
                 "no longer exists"
  end

  test "[unit] every COMMANDS entry is fully specified" do
    Release::Cli::COMMANDS.each do |name, spec|
      assert_equal %i[synopsis consequence bool value allow_positional].sort, spec.keys.sort,
                   "bin/release #{name}: the entry is missing a key the guard reads"
      assert spec[:synopsis].start_with?("bin/release #{name}"),
             "bin/release #{name}: the synopsis must lead with the command it describes"
      assert_includes [true, false], spec[:allow_positional]
      (spec[:bool] + spec[:value]).each do |flag|
        assert flag.start_with?("--"), "bin/release #{name}: #{flag.inspect} is not a long flag"
      end
      assert_empty spec[:bool] & spec[:value],
                   "bin/release #{name}: a flag cannot be both boolean and value-taking"
    end
  end

  # The refusal sentence is what the operator reads after a typo. Its ONLY job is
  # to answer "did the mutation happen?" — so a generic reassurance would be vague
  # in the dangerous direction.
  test "[unit] every refusal consequence states plainly that nothing happened" do
    Release::Cli::COMMANDS.each do |name, spec|
      assert_match(/\b(no|nothing|not)\b/i, spec[:consequence],
                   "bin/release #{name}: the refusal must say what did NOT happen")
    end
  end

  # `bin/release status --clean-only` exits 0 to ASSERT a clean ladder, and
  # `deploy-with-task` gates an expedite on that exit code. A `--help` or a
  # refusal that exited 0 would hand that act a verdict nobody computed.
  test "[unit] help and refusal never exit 0 — 0 is a clean-ladder verdict on this CLI" do
    refute_equal 0, Release::Cli::HELP_EXIT
    assert_equal 1, Release::Cli.guard_args("status")[:help_exit]
    assert_match(/NOT a clean-ladder verdict/, Release::Cli::COMMANDS["status"][:consequence])
  end

  # --- guard_args: the one call bin/release and its tests both make ---------

  test "[unit] guard_args returns the complete keyword set CliArgGuard.guard! reads" do
    args = Release::Cli.guard_args("prepare")

    assert_equal "bin/release prepare", args[:program]
    assert_equal ["--expedite"], args[:bool]
    assert_equal ["--task", "--slug"], args[:value]
    assert_equal false, args[:allow_positional]
    assert_equal 1, args[:help_exit]
    assert_includes args[:usage], "bin/release prepare [--task SLUG ...]"
    assert_includes args[:usage], Release::Cli::GLOBAL_FLAGS,
                    "the globals are stripped before the guard sees them, so help must still name them"
    assert_includes args[:usage], Release::Cli::USAGE, "…and still show the whole-CLI usage"
  end

  # nil, not a raise and not a default spec: a token that is not a subcommand
  # (a bare `--help`, a typo) falls through to the dispatcher's own `else`, which
  # prints usage and exits 1 — the behaviour this CLI has always had.
  test "[unit] guard_args returns nil for anything that is not a subcommand" do
    assert_nil Release::Cli.guard_args("--help")
    assert_nil Release::Cli.guard_args("prepar")
    assert_nil Release::Cli.guard_args(nil)
    assert_nil Release::Cli.guard_args("")
  end
end
