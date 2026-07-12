require "yaml"

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
  # worktree pinned at the exact SHA under test, plus its OWN test database. No
  # agent session, hand-run command, or other tool knows the tree exists, so it
  # cannot be flipped; and the primary NEVER leaves `main` — which also retires the
  # "a concurrent session's dirty primary aborted the ship" class of abort.
  #
  # TWO CAVEATS, both of which bit the first cut of this model — read them before
  # you trust the isolation:
  #
  #   1. The workspace is private to the CONDUCTOR, not to a PROCESS. Its path and
  #      DB name are FIXED, so another `bin/release` CAN reach them — and two
  #      concurrent conductors are a documented occurrence here. bin/release
  #      therefore holds a dedicated GATE-WORKSPACE lock (never the primary's)
  #      across pin → prepare → suite. Without it, conductor B resets this tree and
  #      purges this DB under conductor A's live suite: the same bugs, one directory
  #      over.
  #   2. The private DB is delivered by an ENV OVERLAY, and an env var only lands if
  #      the app's config/database.yml reads it. So it is ASSERTED, not assumed:
  #      bin/release boots the app and checks what it ACTUALLY connected to
  #      (private_db? below) before running — and refuses on a shared DB. See
  #      private_db? for the turf-monster case that made this necessary.
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

    # PURE. The DB URL the gate suite boots against. A local-socket URL (no
    # host/user) mirrors config/database.yml's default connection.
    def test_database_url(repo)
      "postgres:///#{test_database_name(repo)}"
    end

    # IO. The app's TEST adapter, read from its OWN config/database.yml (ERB
    # stripped — the file interpolates ENV). Derived from the app's truth rather
    # than a registry column, so a new app can't drift out of sync with a
    # convention nobody updated.
    def adapter(repo_path)
      file = File.join(repo_path.to_s, "config", "database.yml")
      return nil unless File.exist?(file)

      raw = File.read(file).gsub(/<%.*?%>/m, "")
      cfg = YAML.safe_load(raw, aliases: true)
      return nil unless cfg.is_a?(Hash)

      test = cfg["test"].is_a?(Hash) ? cfg["test"] : {}
      value = test["adapter"] || cfg.dig("default", "adapter")
      value.to_s.strip.empty? ? nil : value.to_s.strip
    rescue StandardError
      nil
    end

    # IO. The gate DB URL to overlay for THIS app, or nil when it needs none.
    #
    # nil for a FILE-BACKED test DB (SQLite — rolio's `storage/test.sqlite3`):
    # that file lives INSIDE the gate worktree, so it is already private by
    # construction, and handing a SQLite app a `postgres:///…` URL would be a live
    # trap the moment it took effect. Postgres apps (hub, turf-monster) get the
    # private gate DB.
    def database_url_for(repo, repo_path)
      name = adapter(repo_path).to_s
      return nil if name.empty? || name.start_with?("sqlite")

      test_database_url(repo)
    end

    # PURE. Is `resolved` — the database the app ACTUALLY connected to, read back
    # from a booted Rails — private to this gate run? Two ways to qualify:
    #   * it IS the gate's own DB (postgres), or
    #   * it is a FILE inside the gate workspace (SQLite), which no other process
    #     can reach because no other process knows the workspace exists.
    # Anything else — most importantly a bare `<app>_test`, the SHARED primary
    # test DB — is NOT private, and the caller aborts rather than run (and
    # `db:test:prepare`-PURGE) a suite against a database someone else is using.
    #
    # This is what turns the private-DB claim from a convention into a checked
    # invariant: `TEST_DATABASE_URL` is a hand-rolled seam that turf-monster's
    # database.yml silently ignores, so asserting the DB NAME STRING (as the first
    # cut of this model did) proved nothing about what the app actually connects to.
    def private_db?(resolved:, repo:, workspace:)
      db = resolved.to_s.strip
      return false if db.empty?
      return true if db == test_database_name(repo)
      return false unless file_backed?(db)

      root = File.absolute_path(workspace.to_s)
      File.absolute_path(db, root).start_with?(root + File::SEPARATOR)
    rescue StandardError
      false
    end

    # PURE. A file-backed (SQLite) database name is a PATH; a postgres one is a
    # bare identifier. Without this, `File.absolute_path("turf_monster_test",
    # workspace)` would resolve INSIDE the workspace and wave a shared DB through.
    def file_backed?(db)
      name = db.to_s
      name.include?(File::SEPARATOR) || name.end_with?(".sqlite3")
    end
  end
end
