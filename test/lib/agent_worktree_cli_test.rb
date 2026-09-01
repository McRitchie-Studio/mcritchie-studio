# frozen_string_literal: true

# [unit] AgentWorktreeCli — the argument dictionary bin/agent-worktree's guard reads.
#
# Pure and script-free: nothing here runs bin/agent-worktree, which is the point.
# The thing under test allocates a worktree, a port, a Redis DB and a Postgres
# database when probed, so its dictionary has to be checkable without it.
#
# WHAT THESE ASSERT THAT A HAND-WRITTEN LIST CANNOT. The dictionary's danger is not
# being wrong today — it is going stale. A dispatcher arm added later with no entry
# would be UNGUARDED and nothing would say so; a flag an arm reads but the dictionary
# omits would be REFUSED, wedging a real call on a lane like `bin/task begin`. So the
# arms and their flags are both DERIVED FROM bin/agent-worktree'S OWN SOURCE and
# reconciled against the dictionary, which makes both directions self-healing.
#
#   ruby -Itest test/lib/agent_worktree_cli_test.rb
require "minitest/autorun"
require_relative "../../bin/lib/agent_worktree_cli"

class AgentWorktreeCliTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/agent-worktree", __dir__)

  # The dispatcher body: everything from the main guard to the end of the file.
  def dispatcher
    @dispatcher ||= File.read(SCRIPT)[/^if \$PROGRAM_NAME == __FILE__$.*/m] ||
                    flunk("bin/agent-worktree no longer has a `if $PROGRAM_NAME == __FILE__` dispatcher")
  end

  # Each `when "cmd"` arm mapped to its own source text, so a flag can be attributed
  # to the arm that reads it rather than to the file as a whole.
  def arms
    @arms ||= begin
      names = dispatcher.scan(/^  when "([a-z-]+)"$/).flatten
      bodies = dispatcher.split(/^  when "[a-z-]+"$/).drop(1)
      names.zip(bodies).to_h
    end
  end

  def test_the_dictionary_covers_every_dispatcher_arm
    refute_empty arms, "no `when` arms were parsed — re-anchor this test on the dispatcher"

    missing = arms.keys - AgentWorktreeCli::COMMANDS.keys
    assert_empty missing,
                 "bin/agent-worktree dispatches #{missing.inspect} with NO dictionary entry, so " \
                 "guard_args returns nil for it and the arm runs UNGUARDED — every argument past " \
                 "the subcommand falls on the floor, which is the whole defect this closes"
  end

  def test_the_dictionary_names_no_arm_that_is_gone
    stale = AgentWorktreeCli::COMMANDS.keys - arms.keys
    assert_empty stale,
                 "the dictionary still lists #{stale.inspect}, which bin/agent-worktree no longer " \
                 "dispatches — a guard for a command that does not exist is a record nobody can check"
  end

  # THE DIRECTION THAT WEDGES A LANE. A flag an arm actually reads, but the dictionary
  # omits, is REFUSED by the guard — so `bin/task begin` (which shells `new` and
  # `bind-task`), the ship (`restore-primary`, `cleanup --reclaim --yes`) and
  # bin/qa-intake (`snapshot --write`) would break on a line that used to work.
  def test_every_flag_an_arm_reads_is_in_the_dictionary
    arms.each do |name, body|
      read = body.scan(/ARGV\.(?:delete|include\?)\("(--[a-z-]+)"\)/).flatten.uniq
      next if read.empty?

      declared = AgentWorktreeCli::COMMANDS.fetch(name).fetch(:bool)
      assert_empty read - declared,
                   "bin/agent-worktree #{name} READS #{(read - declared).inspect} but the dictionary " \
                   "does not list it, so the guard refuses a documented call"
    end
  end

  # …and the reverse, which is how a dictionary drifts into fiction: a flag listed for
  # an arm that does not read it advertises an option that silently does nothing.
  def test_the_dictionary_invents_no_flag
    AgentWorktreeCli::COMMANDS.each do |name, spec|
      body = arms.fetch(name)
      spec.fetch(:bool).each do |flag|
        assert_includes body, %("#{flag}"),
                        "the dictionary lists #{flag} for `#{name}`, but that arm never reads it — " \
                        "an accepted flag that does nothing is the silent no-op half of this defect"
      end
    end
  end

  # Every arm answers, and answers with the honest "it did not happen".
  def test_every_entry_carries_a_synopsis_and_a_consequence
    AgentWorktreeCli::COMMANDS.each do |name, spec|
      assert_match(/\Abin\/agent-worktree #{Regexp.escape(name)}\b/, spec[:synopsis],
                   "#{name}'s synopsis must lead with the command an operator types")
      refute_empty spec[:consequence].to_s.strip
      assert_match(/\bNO\b|\bNOT\b|\bnothing\b|\bno \b/, spec[:consequence],
                   "#{name}'s consequence must say plainly that the side effect did NOT happen — " \
                   "after a refusal the reader's question is whether the desk was created, and a " \
                   "vague answer is vague in the dangerous direction")
    end
  end

  # The load-bearing exit-code decision, pinned so it cannot drift back to the shared
  # guard's default. bin/task:1869 reads exit 0 from `new` as "THE WORKTREE WAS
  # CREATED" and `begin_step!` die!s on anything else; bin/qa-intake:56 reads it as
  # "the registry was refreshed"; bin/release.rb:6999/:7047 as "the primary was
  # restored" / "the reclaim ran". A help probe established none of those.
  def test_help_never_exits_zero
    refute_equal 0, AgentWorktreeCli::HELP_EXIT,
                 "exit 0 from bin/agent-worktree is read as a FACT by bin/task, bin/qa-intake and " \
                 "bin/release — a probe must not answer with the code that asserts them"
    assert_equal 1, AgentWorktreeCli::HELP_EXIT, "1 is what `usage` has always returned here"
  end

  def test_the_guard_args_ride_the_help_exit_and_the_consequence
    args = AgentWorktreeCli.guard_args("new")

    assert_equal 1, args[:help_exit]
    assert_equal "bin/agent-worktree new", args[:program]
    assert_includes args[:usage], "NOT RUN —",
                    "the consequence must ride the USAGE text too: the shared guard prints it only " \
                    "on a REFUSAL, and help is an answer rather than a refusal"
    assert_includes args[:usage], "NO worktree, branch, port"
  end

  # A token that is not a subcommand stays the dispatcher's `else` to answer, exactly
  # as it always did — the bare form was never the defect.
  def test_a_non_subcommand_is_not_the_guards_to_answer
    assert_nil AgentWorktreeCli.guard_args("--help")
    assert_nil AgentWorktreeCli.guard_args("not-a-subcommand")
    assert_nil AgentWorktreeCli.guard_args(nil)
  end

  # Exactly one arm forwards, and it is the one whose usage line declares a
  # pass-through. If a second ever appears, it must be a deliberate decision rather
  # than a copied keyword.
  def test_only_the_declared_forwarding_arm_passes_through
    passthrough = AgentWorktreeCli::COMMANDS.select { |_, spec| spec[:passthrough] }.keys

    assert_equal %w[test], passthrough,
                 "only `test` hands its tail to another tool (bin/rails test). A pass-through arm " \
                 "is exempt from the dictionary check, so adding one silently widens what the " \
                 "guard lets through"
    assert AgentWorktreeCli.passthrough?("test")
    refute AgentWorktreeCli.passthrough?("new")
    assert_includes AgentWorktreeCli::COMMANDS.fetch("test")[:synopsis], "-- rails-test-args",
                    "the forwarding arm's synopsis must show the `--` separator it forwards after"
  end

  # One copy of the usage text, shared by the dispatcher's fall-through and every
  # per-subcommand --help.
  def test_the_usage_text_lists_every_subcommand
    AgentWorktreeCli::COMMANDS.each_key do |name|
      assert_match(/^\s+#{Regexp.escape(name)}\b/, AgentWorktreeCli::USAGE,
                   "`#{name}` is dispatched and guarded but absent from the usage text")
    end
  end
end
