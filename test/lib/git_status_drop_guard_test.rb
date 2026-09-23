# frozen_string_literal: true

require "test_helper"

# A TEST HELPER THAT SHELLS OUT TO git MAY NOT DROP THE EXIT STATUS.
#
# This defect has now been repaired FIVE times across FOUR files, in three separate
# passes, because each repair fixed a copy rather than the shape:
#
#   * PR 1505 (2026-09-21) repaired test/support/agent_worktree_fixture.rb#rev, after
#     `refute_empty rev(...)` was found passing on a ref that did not exist.
#   * Its G2 review found three more copies. /tasks/sweep-remaining-status-drops
#     repaired them: `head_branch` four lines above the first repair, and byte-identical
#     `rev` copies in test/commands/agent_worktree_port_isolation_test.rb and
#     test/commands/agent_worktree_registry_scope_test.rb.
#   * A fourth, unrecorded copy turned up in the same sweep — an endless-def
#     `IO.popen` form in test/lib/base_movement_audit_test.rb, which the card's "three
#     more copies" had not seen.
#
# WHY IT KEEPS COMING BACK. The dropping form is SHORTER and reads as correct, and a
# test that calls it with a ref that resolves can never tell the difference. So the
# copies are invisible until someone greps for them, which is what this file replaces.
#
# WHY IT IS DANGEROUS RATHER THAN MERELY SLOPPY. `git rev-parse <missing-ref>` prints
# the REF NAME to stdout and exits 128, and `git rev-parse --abbrev-ref HEAD` in a repo
# with no commits prints the literal "HEAD" and exits 128 (both measured 2026-09-22).
# A dropped status therefore returns a PLAUSIBLE STRING, never nil and never empty — so
# `refute_empty` cannot fail, and `rev(worktree, "HEAD")` fed to `update-ref` in the hub
# SUCCEEDS at exit 0 while pointing the ref at the wrong commit.
#
# ITS LIMIT, STATED PLAINLY: this reads NAMES, not behaviour. A copy called
# `resolve_ref` or `current_branch` is invisible here, and a body containing the word
# `raise` in a comment satisfies it. It is a ratchet on the two names this defect has
# actually used four times, not a proof about every git helper in the suite. The
# per-helper `[control]` tests beside each repair are what prove the helpers themselves
# bite; this only stops a fifth copy arriving unnoticed under the same names.
class GitStatusDropGuardTest < ActiveSupport::TestCase
  # The two names this defect has worn. Deliberately short: a name that has never
  # carried the defect is a guess, and a guard built on guesses flags innocent code.
  GUARDED_NAMES = %w[rev head_branch].freeze
  NAMES_RE = GUARDED_NAMES.join("|")

  # `def rev(dir, ref)` and the endless `def rev(dir, ref) = ...` alike.
  DEF_LINE = /\A(?<indent>\s*)def\s+(?<name>#{NAMES_RE})\b(?<rest>.*)\z/

  # THE ENDLESS FORM, matched on the `=` that follows the CLOSED parameter list —
  # not on a bare " =" anywhere in it. `def f(a, b = nil)` carries " =" inside the
  # parens and is an ordinary def; reading it as endless would take its body to be
  # the parameter list, which mentions no `raise` and would flag it.
  ENDLESS_TAIL = /\A\s*(?:\([^)]*\))?\s*=\s*\S/

  # A body that CHECKS the status: it raises, or it asserts on the status itself.
  STATUS_CHECKED = /\braise\b|\bassert[a-z_]*\b/

  # THE FLOOR. Five helpers exist today across four files. A pattern that rots — a
  # changed `def` spelling, a glob that stops matching — finds fewer and would
  # otherwise pass by finding nothing, which is the exact failure this suite keeps
  # being bitten by. Re-derive with:
  #   grep -rnE '^\s*def (rev|head_branch)\b' test/
  MINIMUM_HELPERS = 5

  def helpers
    @helpers ||= Rails.root.glob("test/**/*.rb").flat_map { |path| helpers_in(path) }
  end

  # THE RULE, extracted so the control below drives the REAL one. A copy of it in a
  # fixture would pass forever while the shipping rule rotted.
  def dropping_status?(body) = !body.match?(STATUS_CHECKED)

  # Every `def rev`/`def head_branch` in a file, with its body as one string. The body
  # runs to the matching `end` at the def's own indent; an endless def's body is the
  # remainder of its own line.
  def helpers_in(path)
    lines = path.read.lines
    lines.each_with_index.filter_map do |line, i|
      m = DEF_LINE.match(line.chomp)
      next unless m

      body =
        if m[:rest].match?(ENDLESS_TAIL)
          m[:rest]
        else
          closer = "#{m[:indent]}end"
          rest = lines[(i + 1)..] || []
          stop = rest.index { |l| l.chomp == closer }
          (stop ? rest[0...stop] : rest).join
        end

      { path: path.relative_path_from(Rails.root).to_s, line: i + 1, name: m[:name], body: body }
    end
  end

  test "[unit] the census still finds every git helper this defect has worn" do
    assert_operator helpers.size, :>=, MINIMUM_HELPERS,
                    "the census found #{helpers.size} `def rev`/`def head_branch` helpers under test/, " \
                    "fewer than the #{MINIMUM_HELPERS} that exist. A guard that finds nothing passes " \
                    "for free — re-derive the floor with " \
                    "`grep -rnE '^\\s*def (rev|head_branch)\\b' test/` before lowering it.\n" \
                    "found: #{helpers.map { |h| "#{h[:path]}:#{h[:line]}" }.join(', ')}"
  end

  test "[unit] no git helper under test/ drops the exit status" do
    dropping = helpers.select { |h| dropping_status?(h[:body]) }

    assert_empty dropping.map { |h| "#{h[:path]}:#{h[:line]} #{h[:name]}" }, <<~MSG
      A test helper that shells out to git is discarding the exit status.

      `git rev-parse` writes a PLAUSIBLE STRING to stdout when it fails — the ref NAME
      for a missing ref, the literal "HEAD" for an unborn one — and exits 128. So the
      dropping form never returns nil and never returns empty, `refute_empty` cannot
      fail on it, and the value it hands back can be fed to `update-ref` at exit 0 and
      land the ref on the wrong commit.

      Capture the status and RAISE, naming the ref, the directory and the exit code —
      returning nil is not the fix, because nil reaches git as `update-ref ""` and
      surfaces as `fatal: : not a valid SHA1`, which names neither. See
      test/support/agent_worktree_fixture.rb#rev, and pair the repair with a
      `[control]` test that drives the helper against a ref that does not resolve.
    MSG
  end

  # [control] THE RULE, DRIVEN AGAINST BOTH STATES. On a repaired tree the assertion
  # above passes whether the predicate works or not, so it proves nothing by itself.
  # These are the two bodies VERBATIM, before and after the repair.
  DROPPING_BODY = <<~RUBY
    out, = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", ref, chdir: dir)
    out.strip
  RUBY

  REPAIRED_BODY = <<~RUBY
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", ref, chdir: dir)
    unless status.success?
      raise "git rev-parse \#{ref.inspect} failed in \#{dir} (exit \#{status.exitstatus}): \#{err.strip}"
    end

    out.strip
  RUBY

  ENDLESS_DROPPING_BODY = ' = IO.popen(["git", "-C", dir, "rev-parse", ref], &:read).to_s.strip'

  test "[control] the rule flags the dropping form and clears the repaired one" do
    assert dropping_status?(DROPPING_BODY),
           "the predicate no longer sees the very body this guard was written for — every " \
           "assertion above now passes for free"
    assert dropping_status?(ENDLESS_DROPPING_BODY),
           "the endless-def copy in test/lib/base_movement_audit_test.rb was spelled this way; " \
           "a predicate blind to it would have missed the fourth copy too"
    assert ENDLESS_TAIL.match?(ENDLESS_DROPPING_BODY),
           "the endless-def tail must be READ as one, or its body is never extracted"
    refute ENDLESS_TAIL.match?("(where, text, path, first, last, target, anchor = nil)"),
           "an ordinary def with a DEFAULT ARGUMENT must not be read as endless — its body " \
           "would then be the parameter list, which raises nothing and would flag it"
    refute dropping_status?(REPAIRED_BODY),
           "the predicate flags the REPAIRED body, so it would red a clean tree"
  end

  # [control] THE PARSER, on the file that carries two helpers four lines apart —
  # which is how `head_branch` survived the first repair. A parser that found only
  # the first def per file would report a clean census forever.
  test "[control] the parser finds BOTH helpers in the file that carries two" do
    found = helpers_in(Rails.root.join("test/support/agent_worktree_fixture.rb"))

    assert_equal %w[head_branch rev], found.map { |h| h[:name] }.sort,
                 "the fixture defines both `head_branch` and `rev`; the parser saw " \
                 "#{found.map { |h| h[:name] }.inspect}"
    assert found.all? { |h| h[:body].include?("Open3.capture3") },
           "each helper's body must be the real one — an empty body would satisfy nothing " \
           "and clear the rule above by accident"
  end
end
