# frozen_string_literal: true

# THE FIXTURE'S OWN PROOF — and the property the extraction exists to deliver.
#
# test/support/agent_worktree_fixture.rb was lifted out of
# test/commands/agent_worktree_test.rb, which had twice raised its own append ceiling in
# config/test_health.yml rather than split. The stated reason both times was not the
# tests: it was the STAGING. A `cleanup` question is only worth asking against a desk
# that is staged, aged, bound to a task and merged onto its base, and a new file could
# reach that only by re-staging `setup_repo + mark_worktree_merged_to_origin_main +
# abandon_desk! + bind_task_slug + removal_env + agent_worktree` from scratch — at which
# point the duplicated fixture, not the one variable the new test flips, is what a reader
# has to verify.
#
# So the claim this file exists to make is exactly one sentence: A SECOND FILE CAN STAGE
# THE DESK AND DRIVE THE REAL BINARY AGAINST IT WHILE COPYING NOTHING. This file is that
# second file. Its whole setup is the `include` below — delete that line and every test
# here dies on a NoMethodError rather than going quietly green, which is what makes them
# evidence for the claim and not merely compatible with it.
#
# WHAT THIS FILE IS NOT. It is not a second copy of the reclaim guard's coverage. The
# checks below drive the real sweep because a fixture that stages a desk nothing will
# accept has proven nothing — but they assert the FIXTURE's contribution (the desk
# reached the sweep, the aging took, the floor rode along), never the guard's copy. The
# guard's own cells live with the guard, in test/commands/agent_worktree_test.rb.
require "test_helper"
require_relative "../support/agent_worktree_fixture"

class AgentWorktreeFixtureTest < ActiveSupport::TestCase
  include AgentWorktreeFixture

  test "[integration] the include alone stages a hub and a real git worktree under it" do
    assert_path_exists @hub_dir, "the fixture must stage a primary checkout"
    assert_path_exists @worktree_dir, "the fixture must cut a real worktree off it"

    assert_equal "main", head_branch(@hub_dir), "the primary sits on main, as a real one does"
    assert_equal "feat/terminal-context", head_branch(@worktree_dir), "the desk sits on its feature branch"

    # BOTH trees read CLEAN, and both halves are load-bearing: a dirty desk is disqualified
    # from reclaim on its own, so a fixture that staged a dirty one would make every
    # withhold check pass for the wrong reason.
    refute git_dirty?(@hub_dir), "the primary must read clean with a worktree provisioned under it"
    refute git_dirty?(@worktree_dir), "the staged desk must read clean"

    # THE POSITIVE CONTROL. Every `git_dirty?` site in this suite is a `refute`, so a
    # predicate that had quietly stopped detecting anything would satisfy all of them.
    # Dirty the desk on purpose, prove it is SEEN, and put it back.
    scratch = File.join(@worktree_dir, "dirty-probe.txt")
    File.write(scratch, "x")
    assert git_dirty?(@worktree_dir),
           "git_dirty? did not see an untracked file — every refute above passes for free"
    File.delete(scratch)
    refute git_dirty?(@worktree_dir), "the probe must leave the desk as it found it"

    # A SHA, not merely "not empty". `git rev-parse` on a missing ref prints the ref
    # NAME and exits 128, so `refute_empty` could not fail here — the helper now raises,
    # and this pins the shape it returns.
    assert_match(/\A[0-9a-f]{40}\z/, rev(@hub_dir, "refs/remotes/origin/main"),
                 "base resolution needs a local origin/main ref resolving to a SHA, with no network")
  end

  # [control] THE ASSERTION THAT COULD NOT FAIL, now pinned from the other side.
  #
  # `git rev-parse <missing-ref>` prints the REF NAME on stdout and exits 128 —
  # measured. So the old helper, which dropped the status, returned a non-empty
  # string for a ref that does not exist, and `refute_empty rev(...)` passed on
  # precisely the case it was written to catch. This test is what makes the
  # repair falsifiable: revert the helper to `out, = Open3.capture3(...)` and it
  # goes red, because nothing raises and the name comes back instead.
  test "[control] rev RAISES on a ref that does not resolve, rather than echoing its name" do
    error = assert_raises(RuntimeError) { rev(@hub_dir, "refs/heads/no-such-ref") }

    assert_includes error.message, "no-such-ref", "the failure must name the ref that did not resolve"
    assert_includes error.message, "128", "and the exit status, so a reader can tell it apart from a crash"

    # The other half: a ref that DOES resolve still comes back as a bare SHA, so the
    # repair did not simply turn the helper into something that always raises.
    assert_match(/\A[0-9a-f]{40}\z/, rev(@hub_dir, "HEAD"))
  end

  # [control] THE SAME DEFECT, FOUR LINES UP. `head_branch` dropped its status too,
  # and its silent case is an UNBORN HEAD rather than a missing ref: in a repo with
  # no commits `git rev-parse --abbrev-ref HEAD` prints the literal "HEAD" on stdout
  # and exits 128 (measured 2026-09-22, and reproduced by this test's own premise
  # below). So the dropping form answered "this repo is on branch HEAD" for a repo
  # that is on no branch at all.
  #
  # IT WAS HARMLESS BY LUCK, WHICH IS NOT A MECHANISM. Every asserting call site is
  # an `assert_equal` against a named branch, so "HEAD" fails loudly at each of them
  # — a property of those assertions, not of the helper. Revert it to
  # `out, = Open3.capture3(...)` and this test goes red while all six stay green.
  test "[control] head_branch RAISES on an unborn HEAD, rather than answering \"HEAD\"" do
    unborn = File.join(@projects_dir, "unborn-repo")
    FileUtils.mkdir_p(unborn)
    _out, _err, status = Open3.capture3(SessionEnv.neutralized, "git", "init", "-q", chdir: unborn)
    assert status.success?, "premise: the probe repo must actually be a git repo"

    # THE PREMISE, MEASURED RATHER THAN ASSUMED: git really does print "HEAD" here
    # and really does exit non-zero. Without this the control could pass because the
    # probe failed some other way, and a repaired helper raising on the WRONG reason
    # is indistinguishable from one raising on this one.
    raw, _raw_err, raw_status = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse",
                                               "--abbrev-ref", "HEAD", chdir: unborn)
    refute raw_status.success?, "premise: an unborn HEAD must exit non-zero"
    assert_equal "HEAD", raw.strip,
                 "premise: git prints the literal \"HEAD\" on stdout — this is what a dropped " \
                 "status hands back as a branch name"

    error = assert_raises(RuntimeError) { head_branch(unborn) }

    assert_includes error.message, unborn, "the failure must name the directory it asked about"
    assert_includes error.message, "128", "and the exit status, so a reader can tell it apart from a crash"

    # The other half: a repo that DOES have a branch still comes back as its name, so
    # the repair did not simply turn the helper into something that always raises.
    assert_equal "main", head_branch(@hub_dir)
  end

  test "[integration] the staged desk starts FRESH — abandon_desk! is what ages it" do
    marker = File.join(@worktree_dir, ".git")

    assert_operator Time.now - File.mtime(marker), :<, ClaimLease::DESK_IDLE_SECONDS,
                    "premise: a newly staged desk must read as LIVE, or a test that needs a live " \
                    "desk would be passing on the fixture's leftovers rather than on its own setup"

    abandon_desk!

    assert_operator Time.now - File.mtime(marker), :>, ClaimLease::DESK_IDLE_SECONDS,
                    "abandon_desk! must move the desk's birthday past the idle window"
  end

  test "[integration] a second file stages a reclaim premise and the real sweep accepts it" do
    mark_worktree_merged_to_origin_main
    abandon_desk! # LAST — anything written after this re-ages the desk

    out, err, status = agent_worktree("cleanup", "mcritchie-studio")

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "cleanup candidates:",
                    "the desk this file staged must reach the real sweep as a candidate — if it does " \
                    "not, the fixture is not staging the premise it claims to"
    assert_includes out, "mcritchie-studio/terminal-context"
  end

  test "[integration] a second file's board stand-in reaches the real stage channel" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("second-file-task")
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio",
                                      env: { "AGENT_WORKTREE_TASK_JSON" => board_record_at("reviewed") })

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "withheld mcritchie-studio/terminal-context",
                    "board_record_at + bind_task_slug must compose into a payload the real sweep reads " \
                    "as a bound, mid-release task — the fixture's board stand-ins are useless otherwise"

    # AND WITHHELD FOR THE RIGHT REASON. The sweep prints `withheld <desk>` for every
    # hold it takes — fresh, dirty, claimed, unreadable — so the line alone cannot tell
    # a board-stage hold from any other, and this test's whole claim is about the BOARD
    # payload. Assert the stage the sweep read back.
    assert_includes out, "board stage `reviewed`",
                    "the desk was withheld, but the line does not say the BOARD STAGE held it — so this " \
                    "test cannot tell a stage hold from a freshness or dirtiness hold, which is the only " \
                    "thing it exists to prove"
  end

  test "[integration] the network floor rides along — this file's spawn cannot reach the real board" do
    # THE PROPERTY WORTH MOST IN THE EXTRACTION. The harness this fixture came from grew its
    # floor because per-test env hashes leaked: ~11 spawn sites authenticated against and read
    # the PRODUCTION board on every `bin/rails test`, because a seam spelled per test covers
    # only the tests that remember it. A fixture that handed a second file the desk but not the
    # floor would re-open exactly that hole, one new file at a time — and it would do it
    # SILENTLY, because a leak here is a successful read, not a failure.
    OutboundSeams.reset!

    agent_worktree!("bind-task", "mcritchie-studio", @task, "fixture-proof-task")

    reads = OutboundSeams.calls_to("task-cli")
    refute_empty reads,
                 "this file passed NO env of its own, so every pin it got came from the fixture's " \
                 "command_env. Nothing was recorded, which means the mascot read went to the real " \
                 "#{Rails.root.join("bin/task")} — the board's production default."
    assert(reads.any? { |line| line.include?("field fixture-proof-task mascot") },
           "expected the mascot field read through the seam, got #{reads.inspect}")
  end
end
