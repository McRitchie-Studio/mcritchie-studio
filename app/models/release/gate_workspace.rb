require "yaml"

class Release
  # The PRIVATE checkout a release step works in, instead of the SHARED primary.
  #
  # TWO ROLES, one primitive (`role:` selects the directory + the test DB):
  #   * "gate" — <repo>/.worktrees/_gate, DB <app>_gate_test. The tree a local
  #     test gate (G3 pre-QA / G4 ship) runs its SUITE in.
  #   * "ship" — <repo>/.worktrees/_ship, DB <app>_ship_test. The tree
  #     `bin/release ship` DEPLOYS from: the re-pin commit, and any `repo_script`
  #     app whose own bin/deploy needs a real working tree (it runs that repo's
  #     suite). Pinned at the QA-FROZEN SHA, so the deploy builds from exactly the
  #     commit QA certified — and from a tree no other process can touch.
  # Separate directories and separate LOCKS: a ship must never queue behind a
  # concurrent conductor's G3 suite, nor reset the tree under it.
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
  # THE FIX: give the step a working tree nobody else touches. A detached-HEAD git
  # worktree pinned at the exact SHA under test, plus its OWN test database. No
  # agent session, hand-run command, or other tool knows the tree exists, so it
  # cannot be flipped; and the primary NEVER leaves `main`.
  #
  # THE SHIP ROLE closes the SECOND half of the same story (2026-07-12). The gate
  # moved off the primary but `bin/release ship` did not: it fast-forwarded the
  # primary's `main`, re-pinned Gemfiles there, and ran the satellites' bin/deploy
  # there — so its preflight REFUSED a dirty primary, and a concurrent feature
  # session with staged work ABORTED a production ship after the gems had already
  # published. Discarding that work was never an option (it is a live session's),
  # so the recovery was a delicate stash-to-a-labeled-branch rescue at the worst
  # possible moment. Now the ship owns a checkout too, and what the deploy needs a
  # WORKING TREE for shrank to almost nothing: advancing `main` and pushing to
  # Heroku are pure REF PUSHES against the shared object store
  # (`git push <remote> <frozen-sha>:refs/heads/main` — fast-forward-checked, so
  # it still fails closed), which read no working tree at all and cannot be
  # perturbed by a dirty primary. Only the re-pin commit and the repo_script
  # satellites genuinely need a tree; they get this one.
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
    # bin/agent-worktree enumerates `.worktrees/*/<stack env file>`, and these
    # workspaces carry no stack env (no port, no Redis DB, no server) — so they are
    # invisible to `list` / `doctor` / `cleanup` by construction. The leading
    # underscore keeps them clear of task-slug names too.
    DIRNAME = "_gate".freeze

    # The roles this primitive serves — see the class doc. A typo'd role would
    # otherwise silently mint a THIRD workspace (its own dir, its own DB) that
    # nothing locks, so the lookup fails loudly instead.
    ROLES = %w[gate ship].freeze

    def role!(role)
      name = role.to_s
      return name if ROLES.include?(name)

      raise ArgumentError, "unknown workspace role: #{role.inspect} (known: #{ROLES.join(', ')})"
    end

    # PURE. The workspace DIRECTORY name for a role: `_gate` / `_ship`.
    def dirname(role = "gate")
      "_#{role!(role)}"
    end

    # PURE. The workspace checkout for a repo, given that repo's PRIMARY path.
    def path(repo_path, role: "gate")
      File.join(repo_path.to_s, ".worktrees", dirname(role))
    end

    # PURE. The workspace's PRIVATE test database — never the primary's
    # `<app>_test`, so a concurrent suite (agent worktree, hand-run `bin/rails
    # test`) can neither pollute it nor be polluted by it. Seed/order
    # -dependent cross-talk between two suites on one DB was the third mechanism
    # behind the false-negatives (failure counts varied 0 → 8 → 16 across seeds
    # on the SAME SHA). Per ROLE, so the ship's repo_script deploy (turf's
    # bin/deploy runs its own suite) can never purge the DB a concurrent gate is
    # mid-suite against: <app>_gate_test vs <app>_ship_test.
    def test_database_name(repo, role: "gate")
      "#{repo.to_s.tr('-', '_')}_#{role!(role)}_test"
    end

    # PURE. The DB URL a suite in this workspace boots against. A local-socket URL
    # (no host/user) mirrors config/database.yml's default connection.
    def test_database_url(repo, role: "gate")
      "postgres:///#{test_database_name(repo, role: role)}"
    end

    # IO. The app's TEST adapter, read from its OWN config/database.yml (ERB
    # stripped — the file interpolates ENV). Derived from the app's truth rather
    # than a registry column, so a new app can't drift out of sync with a
    # convention nobody updated.
    def adapter(repo_path)
      test_config(repo_path)["adapter"]
    end

    # IO. The app's DECLARED test database — `test.database` from its OWN
    # config/database.yml, ERB STRIPPED. This is the SHARED one: the database the
    # primary checkout, CI, and every un-overlaid boot land on.
    #
    # ERB-stripped is the WHOLE POINT, and it is the difference between a guard and a
    # placebo. The question a caller asks is "did the overlay actually move me OFF the
    # shared DB?" — so the shared DB must be computed EXTERNALLY, from a source the
    # overlay cannot reach. Render the ERB and `url: <%= ENV["TEST_DATABASE_URL"] %>`
    # resolves to whatever the env just set, the comparison becomes `x == x`, and it
    # waves through exactly the case it exists to catch. Compare a RESOLVED database
    # against a config the env has already rewritten and you have proven nothing.
    def declared_test_database(repo_path)
      test_config(repo_path)["database"]
    end

    # IO. The app's `test:` block, ERB stripped and merged over `default:`, with blank
    # values dropped (`url:` renders EMPTY when its env var is unset). Values are
    # strings or absent — never nil-but-present, so callers can `.to_s.empty?` on a
    # miss without distinguishing "declared blank" from "not declared".
    def test_config(repo_path)
      file = File.join(repo_path.to_s, "config", "database.yml")
      return {} unless File.exist?(file)

      raw = File.read(file).gsub(/<%.*?%>/m, "")
      cfg = YAML.safe_load(raw, aliases: true)
      return {} unless cfg.is_a?(Hash)

      default = cfg["default"].is_a?(Hash) ? cfg["default"] : {}
      test = cfg["test"].is_a?(Hash) ? cfg["test"] : {}
      default.merge(test).transform_values { |v| v.to_s.strip }.reject { |_, v| v.empty? }
    rescue StandardError
      {}
    end

    # IO. The workspace DB URL to overlay for THIS app, or nil when it needs none.
    #
    # nil for a FILE-BACKED test DB (SQLite — rolio's `storage/test.sqlite3`):
    # that file lives INSIDE the worktree, so it is already private by
    # construction, and handing a SQLite app a `postgres:///…` URL would be a live
    # trap the moment it took effect. Postgres apps (hub, turf-monster) get the
    # private DB.
    def database_url_for(repo, repo_path, role: "gate")
      name = adapter(repo_path).to_s
      return nil if name.empty? || name.start_with?("sqlite")

      test_database_url(repo, role: role)
    end

    # PURE. Is `resolved` — the database the app ACTUALLY connected to, read back
    # from a booted Rails — private to this run? Two ways to qualify:
    #   * it IS this workspace's own DB (postgres), or
    #   * it is a FILE inside the workspace (SQLite), which no other process
    #     can reach because no other process knows the workspace exists.
    # Anything else — most importantly a bare `<app>_test`, the SHARED primary
    # test DB — is NOT private, and the caller aborts rather than run (and
    # `db:test:prepare`-PURGE) a suite against a database someone else is using.
    # The role matters: the ship's deploy must not qualify on the GATE's DB either
    # (a concurrent conductor may be mid-suite against it).
    #
    # This is what turns the private-DB claim from a convention into a checked
    # invariant: `TEST_DATABASE_URL` is a hand-rolled seam that turf-monster's
    # database.yml silently ignores, so asserting the DB NAME STRING (as the first
    # cut of this model did) proved nothing about what the app actually connects to.
    def private_db?(resolved:, repo:, workspace:, role: "gate")
      db = resolved.to_s.strip
      return false if db.empty?
      return true if db == test_database_name(repo, role: role)
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
