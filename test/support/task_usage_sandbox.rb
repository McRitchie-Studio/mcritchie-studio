# frozen_string_literal: true

require "fileutils"

# TaskUsageSandboxEnv — the test-side half of the fail-closed sandbox on the two
# state stores the bin/ stack writes under the operator's REAL projects root:
#
#   <projects>/.agents/task-usage/<session>.json   usage/cost baselines
#   <projects>/.agents/sessions/<session>.json     the active-feature marker
#
# WHAT WENT WRONG (this is not hypothetical — it reached production data).
# Both stores fall back to the real projects root when their env var is unset,
# and test/lib/task_cli_test.rb pinned NEITHER. Its SESSION constant is a REAL
# past session id whose 30MB transcript still lives in the operator's ~/.claude,
# and HOME was not pinned either — so `bin/task create` under the suite globbed
# that transcript and wrote its ~1.9-BILLION-token cumulative totals into the
# operator's LIVE cost store, keyed by the stub's slug ("demo-task"). Measured
# $cost feeds Task#actual_size (which buckets on it) and the reviewer-select
# baselines, so one fixture row quietly skews the sizing intelligence.
#
# TWO HALVES, AND WHY BOTH.
#
#   CONFIGURED  `child_env` pins TASK_USAGE_DIR + CLAUDE_PROJECTS_DIR + HOME into
#               a tmpdir, so a test child reads no real transcript and writes no
#               real store.
#   ASSERTED    the ENV line below turns the sandbox ON for the whole test
#               PROCESS. Ruby's spawn semantics hand the parent's env to every
#               child, so EVERY subprocess a test starts — today's, and the one
#               written next year by someone who never read this file — inherits
#               TASK_USAGE_SANDBOX and is refused by TaskUsageSandbox the moment
#               it resolves an unpinned store. A pin you have to REMEMBER is the
#               bug we are fixing; this is the half that cannot be forgotten.
#
# Loud by design: an unpinned child ABORTS with a message naming the missing var,
# rather than silently writing the operator's store and passing green.
#
# Loaded from test/support/session_env.rb — the one file every subprocess-spawning
# test already goes through (bare `minitest/autorun` files require it directly;
# test_helper requires it for the Rails side). Both worlds are covered, and
# neither needs Rails.
module TaskUsageSandboxEnv
  # The whole point: set for THIS process, inherited by every child it spawns.
  # `||=` so an operator can still run a deliberate un-sandboxed spawn by exporting
  # TASK_USAGE_SANDBOX=0 (the guard treats 0/false/no/off as off).
  ENV["TASK_USAGE_SANDBOX"] ||= "1"

  module_function

  # The child env pinning both write roots (and HOME) inside +root+ — a tmpdir the
  # caller owns. Merge it into a spawn env:
  #
  #   env = SessionEnv.neutralized(TaskUsageSandboxEnv.child_env(tmp).merge("FOO" => "1"))
  #
  # HOME is pinned too: it is the READ half of the leak. The store the child writes
  # is only ever as clean as the transcript it read, and an unpinned HOME lets a
  # test glob whatever real session transcript happens to match its fixture id.
  def child_env(root)
    usage = File.join(root, "task-usage")
    projects = File.join(root, "projects")
    home = File.join(root, "home")
    FileUtils.mkdir_p([usage, File.join(projects, ".agents"), home])

    { "TASK_USAGE_DIR" => usage, "CLAUDE_PROJECTS_DIR" => projects, "HOME" => home }
  end
end
