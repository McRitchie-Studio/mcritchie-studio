class Release
  # The PRIVATE checkout a local test gate (G3 pre-QA / G4 ship) runs its suite in.
  #
  # ROOT CAUSE it closes (verified 2026-07-12, from the rel-20260711-7f2913
  # false-negatives): the gates ran a MULTI-MINUTE suite on the SHARED PRIMARY
  # checkout, against a working tree and a test DB that other processes mutate.
  # Two properties make that unsound:
  #
  #   * TEST-ENV AUTOLOADING IS LAZY. config/environments/test.rb sets
  #     `config.eager_load = ENV["CI"].present?` — so CI loads the whole app at
  #     boot (ONE coherent snapshot), while the LOCAL gate leaves Zeitwerk to read
  #     each file off disk the first time it's referenced, spread across the
  #     minutes the suite runs. Views are lazier still (compiled on first render).
  #     Flip the tree mid-run and the process ends up with a TORN snapshot: test
  #     files already loaded from `release`, models autoloaded afterwards from
  #     `main`. That is precisely the reported `NoMethodError: undefined method
  #     'count' for an instance of Task` — main's `rework_rounds(events)` meeting
  #     release's `rework_rounds(task)` test in one process.
  #   * THE PRIMARY IS SHARED. `with_primary_checkout`'s flock is ADVISORY: it
  #     excludes other `bin/release` invocations and nothing else. A concurrent
  #     agent session, a hand-run `git checkout`, or any other tool can flip HEAD
  #     mid-suite, and the shared test DB takes writes from any concurrent suite.
  #
  # (Bootsnap was the prime suspect and is INNOCENT — its compile cache keys on
  # mtime+size, and `git checkout` bumps mtime, so it recompiles from the new
  # source. Verified by experiment: prime the cache on an old method signature,
  # checkout the new one, and the app loads the NEW code. Clearing it would have
  # been a placebo that left the real cause live. Do not "fix" it here.)
  #
  # THE FIX: give the gate a working tree nobody else touches. A detached-HEAD git
  # worktree pinned at the exact SHA under test, plus its OWN test database. The
  # tree cannot be flipped (no other process knows it exists), the DB cannot be
  # polluted (no other process connects to it), and the primary NEVER leaves
  # `main` — which also retires the "a concurrent session's dirty primary aborted
  # the ship" class of abort.
  #
  # A worktree, not a clone: it shares the primary's object store, so it costs a
  # checkout rather than a fetch. It PERSISTS between runs (reset --hard to the
  # new SHA each time) so the bundle and the test DB stay warm — a throwaway clone
  # would re-pay bundle install on every gate.
  #
  # IO-light by design (like Release::GateRuby): pure path/name helpers the caller
  # unit-tests; bin/release owns the git/DB side-effects.
  module GateWorkspace
    module_function

    # Under the repo's own .worktrees/ — the same parent the agent worktrees use,
    # so the suite runs from the layout it is already known-green in (a clean
    # agent worktree was the ground truth that proved the release tip green), and
    # it inherits that dir's .gitignore entry so the primary's `git status` stays
    # clean (a dirty primary aborts the ship preflight).
    #
    # It is NOT an agent worktree and must never be mistaken for one:
    # bin/agent-worktree enumerates `.worktrees/*/<stack env file>`, and the gate
    # workspace carries no stack env (no port, no Redis DB, no server) — so it is
    # invisible to `list` / `doctor` / `cleanup` by construction. The leading
    # underscore keeps it clear of task-slug names too.
    DIRNAME = "_gate".freeze

    # PURE. The gate checkout for a repo, given that repo's PRIMARY path.
    def path(repo_path)
      File.join(repo_path.to_s, ".worktrees", DIRNAME)
    end

    # PURE. The gate's PRIVATE test database — never the primary's
    # `<app>_test`, so a concurrent suite (agent worktree, hand-run `bin/rails
    # test`) can neither pollute the gate's DB nor be polluted by it. Seed/order
    # -dependent cross-talk between two suites on one DB was the third mechanism
    # behind the false-negatives (failure counts varied 0 → 8 → 16 across seeds
    # on the SAME SHA).
    def test_database_name(repo)
      "#{repo.to_s.tr('-', '_')}_gate_test"
    end

    # PURE. The TEST_DATABASE_URL the gate suite boots against. A local-socket
    # URL (no host/user) mirrors config/database.yml's default connection.
    def test_database_url(repo)
      "postgres:///#{test_database_name(repo)}"
    end
  end
end
