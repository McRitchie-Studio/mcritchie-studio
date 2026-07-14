# frozen_string_literal: true

require_relative "../bin/lib/projects_root"

# TaskUsageSandbox — the fail-closed guard on EVERY state store the bin/ stack
# writes OUTSIDE its repo, under the operator's real projects root:
#
#   <projects>/.agents/task-usage/<session>.json     the usage/cost baselines
#   <projects>/.agents/sessions/<session>.*          the narration markers
#   <projects>/.agents/atomic-capture/token.json     the agent-API token cache
#   <projects>/.agents/locks/*.lock                  the conductor's flocks
#   <projects>/.agents/worktree-registry.json        the worktree registry
#   <projects>/.agents/agent-worktree.lock           the DB-allocation flock
#   <projects>/.agents/redis-capacity.json           the elastic Redis band
#
# ONE FAMILY, not five bugs. Every one of these is resolved by the SAME fallback
# shape — an env var, ELSE a path under the operator's real <projects>/.agents —
# so every one of them hands a spawned, unpinned test the operator's live state.
# The cost store leaked first (PR #525), the narration store second (PR #549);
# the remaining three were found by the review that caught the second, and are
# closed here rather than left in a PR body. A PR body is not a backlog.
#
# The store names below are the WHOLE family, and test/lib/state_store_containment_test.rb
# re-derives that family FROM THE SOURCE on every run: a sixth store added later
# without a guard fails the suite. The list cannot rot into a lie quietly.
#
# WHY THIS EXISTS (a live production leak, not a hypothetical). Both stores are
# resolved by FALLBACK — TASK_USAGE_DIR else <projects>/.agents/task-usage;
# CLAUDE_PROJECTS_DIR else <projects>/.agents/sessions — and test/lib/task_cli_test.rb
# pinned NEITHER. Its SESSION constant is a REAL past session id (copied from a
# live run), whose 30MB transcript still sits in the operator's ~/.claude, and
# HOME was not pinned either. So `bin/task create` under the test suite globbed
# that transcript and wrote its ~1.9-BILLION-token cumulative totals into the
# operator's LIVE cost store, keyed by the stub's slug ("demo-task"). Measured
# $cost is not decoration: Task#actual_size buckets on it and reviewer-select
# baselines read it, so one fixture row silently skews the sizing intelligence.
#
# THE RULE. When the sandbox is ACTIVE (TASK_USAGE_SANDBOX set — test/support/
# task_usage_sandbox.rb sets it process-wide, so every subprocess a test spawns
# inherits it), a write to either store must satisfy BOTH:
#
#   1. PINNED  — the env var that locates the store is explicitly set. The
#      fallback to the real projects root is FORBIDDEN, not merely discouraged.
#   2. OUTSIDE — the resolved path does not live under the real
#      <projects>/.agents, whatever env var pointed it there.
#
# Rule 1 closes the actual bug. Rule 2 makes the guarantee a property of the
# PATH rather than of the configuration: a fixed-path "private" dir is not
# private from your own tooling, and a pin that happens to point back inside the
# real state dir is not a sandbox. Neither is a boot-time env check that nothing
# re-verifies at the moment of the write — so this is checked AT the write seam,
# on every write, and there is no way to reach the store around it.
#
# FAIL CLOSED, AND WHY IT MUST `abort`. Every caller of this state is
# best-effort: bin/task's autofill_move_usage, seed_usage_baseline and
# write_feature_marker all `rescue StandardError => nil` so a usage hiccup can
# never abort a stage transition, and TaskUsageBaseline swallows IO errors for
# the same reason. A violation raised as a StandardError would therefore be
# SWALLOWED — the guard would report nothing and the write would simply be
# skipped in tests and silently proceed everywhere else. So a violation exits
# via `abort` (SystemExit), which is NOT a StandardError and so escapes those
# rescues by design — the same isolation lever bin/task's board_mascot documents.
# Loud, unmissable, and impossible to degrade into a no-op.
#
# Plain Ruby (no Rails): the standalone CLIs (bin/task, bin/release,
# bin/reviewer-select) require it directly.
module TaskUsageSandbox
  # Set (to anything but a falsey string) by any process that must not be able to
  # touch the operator's real state — i.e. every test process.
  ENV_KEY = "TASK_USAGE_SANDBOX"

  FALSEY = %w[0 false no off].freeze

  # The stores this guard covers, and the env var that pins each. The key is what
  # a caller passes as `store:`. Adding a store here is not enough — the guard
  # must be CALLED at that store's write seam, and the containment test proves it
  # is (it fails on a path into <projects>/.agents that reaches IO unguarded).
  # Each store maps to the env vars that can LOCATE it. A store is PINNED when ANY
  # of them is set — because any one of them is enough to steer the path away from
  # the operator's real root, which is the only thing rule 1 is defending against.
  #
  # Why a LIST and not one var. bin/agent-worktree resolves its three stores from
  # PROJECTS_DIR (the root) with an optional per-file override, so a test that pins
  # only the root is ALREADY safe — its path cannot reach the real store. Demanding
  # the specific var there would abort a legitimate caller: a guard that fails closed
  # on the HAPPY path, which is worse than the leak it closes. Accepting either is
  # safe because rule 2 is the backstop — a pin aimed back INSIDE the real .agents is
  # refused whatever var pointed it there.
  STORES = {
    "task-usage" => %w[TASK_USAGE_DIR],            # lib/task_usage_baseline.rb, bin/task, bin/release.rb, bin/reviewer-select
    "session-marker" => %w[CLAUDE_PROJECTS_DIR],   # bin/lib/session_markers.rb (the choke point), bin/task
    "agent-token" => %w[CLAUDE_PROJECTS_DIR],      # bin/lib/agent_api.rb — the token cache
    "agent-locks" => %w[MCR_PRIMARY_LOCK_DIR],     # bin/release.rb — the conductor flocks
    "worktree-registry" => %w[AGENT_WORKTREE_REGISTRY PROJECTS_DIR], # bin/agent-worktree — the registry snapshot
    "worktree-lock" => %w[AGENT_WORKTREE_LOCK PROJECTS_DIR],         # bin/agent-worktree — the DB-allocation flock
    "redis-capacity" => %w[AGENT_REDIS_CAPACITY_FILE PROJECTS_DIR]   # bin/agent-worktree — the elastic Redis band
  }.freeze

  module_function

  # The env a guard is evaluated against, for the callers that carry an INJECTABLE
  # env (AgentApi#env, and the CLIs built on it) rather than reading ENV directly.
  # Deliberately assembled from TWO sources, because the guard's two rules answer
  # to different scopes:
  #
  #   THE PIN (CLAUDE_PROJECTS_DIR, …) comes from the CALLER'S env, because that is
  #     what resolved the path. A test that constructs a client with a tmpdir pin IS
  #     correctly pinned, and reading the process ENV instead would abort it — a
  #     guard that fails closed on the HAPPY path is worse than the leak it closes.
  #   THE ARMING (TASK_USAGE_SANDBOX) comes from the PROCESS ENV whenever the
  #     caller's env is silent about it. Arming is a property of the PROCESS — a test
  #     arms it for itself and every child it spawns — so an injected env that simply
  #     OMITS it must not be able to disarm the guard. Otherwise `AgentApi.new(env: {})`
  #     resolves the real projects root with the sandbox reading as OFF and writes the
  #     operator's store: the very hole this exists to close. An env that names it
  #     explicitly still wins.
  def guard_env(env)
    env = env.to_h
    return env if env.key?(ENV_KEY)

    env.merge(ENV_KEY => ENV[ENV_KEY]).compact
  end

  # The operator's real cross-repo state dir — <projects>/.agents. Resolved from
  # the repo's own location (ProjectsRoot climbs out of .worktrees), NOT from an
  # env var, so a sandboxed process cannot spoof its way past rule 2.
  def real_state_dir
    File.join(ProjectsRoot.default_projects_dir, ".agents")
  end

  def active?(env = ENV)
    value = env[ENV_KEY].to_s.strip
    !value.empty? && !FALSEY.include?(value.downcase)
  end

  # The violation message for a write of +path+ to +store+, or nil when the write
  # is allowed. Pure — `state_dir` is injectable so the rules can be tested
  # against a stand-in root, because proving them against the REAL one would mean
  # attempting the very write this guard exists to prevent.
  def violation(path, store:, env: ENV, state_dir: real_state_dir)
    return nil unless active?(env)

    pins = STORES.fetch(store)
    if pins.none? { |pin| !env[pin].to_s.strip.empty? }
      named = pins.join(" or ")
      return "#{ENV_KEY} is on and #{named} #{pins.one? ? "is" : "are all"} unset — refusing to fall back to " \
             "the operator's real #{store} store under #{state_dir}. Pin #{named} at a tmpdir " \
             "(test/support/task_usage_sandbox.rb)."
    end

    return nil unless inside?(path, state_dir)

    "#{ENV_KEY} is on and the resolved #{store} path (#{path}) is inside the operator's real state dir " \
      "(#{state_dir}). A sandboxed run may never write there."
  end

  # Enforce the rule at a write seam and return +path+ so callers can inline it:
  #
  #   dir = TaskUsageSandbox.enforce!(dir, store: "task-usage")
  #
  # A violation aborts the process (see FAIL CLOSED above); a no-sandbox process
  # (an agent's real `bin/task move`) is untouched.
  def enforce!(path, store:, env: ENV, state_dir: real_state_dir)
    message = violation(path, store: store, env: env, state_dir: state_dir)
    return path unless message

    abort("task-usage sandbox: #{message}")
  end

  # Is +path+ at or under +root+? Compares expanded paths on a separator boundary,
  # so ".../.agents-scratch" is not read as being inside ".../.agents".
  def inside?(path, root)
    path = File.expand_path(path.to_s)
    root = File.expand_path(root.to_s)
    path == root || path.start_with?("#{root}#{File::SEPARATOR}")
  end
end
