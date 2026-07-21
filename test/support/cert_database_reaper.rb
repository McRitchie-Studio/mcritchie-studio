# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require "uri"

require_relative "test_database_purge"

# CertDatabaseReaper — drop the per-run cert test databases a hard-killed run stranded.
#
# THE LEAK THIS EXISTS TO KILL (follow-up to PR #603, isolate-cert-shared-state).
# One test provisions a REAL Postgres database to exercise db provisioning end to
# end (the worktree DB-name overflow probe in test/commands/agent_worktree_test.rb).
# It used to reclaim a FIXED name via `dropdb --if-exists`, so a hard kill left ONE
# database the next run reclaimed — the mess was self-limiting. That probe now mints
# a UNIQUE per-run name (mcritchie_studio_test_<slug>_<8hex>) so concurrent runs do
# not corrupt each other, and its `ensure` drops that unique name. But an `ensure`
# does not run under SIGKILL — and parallel certs in this ecosystem HAVE hit
# SIGKILL/SIGSEGV — so every hard kill now strands a DISTINCT database and nothing
# reclaims it. Slow, but unbounded.
#
# WHY A NAME PATTERN CANNOT BE THE ANSWER (the doctrine trap).
# The stranded name `<base>_<slug>_<8hex>` is INDISTINGUISHABLE BY SHAPE from a
# legitimate long-slug worktree's test DB: bounded_db_slug (bin/agent-worktree)
# truncates any over-long worktree slug and suffixes it with the same 8-hex digest,
# so a real, live, long-named worktree owns a database of exactly this shape. A
# reaper that dropped "everything matching the per-run pattern" would eventually
# drop a live worktree's test database. So a pattern is not an identity.
#
# THE IDENTITY IS A LEASE. The mint site writes a lease naming the database and the
# PID that owns it; a clean `ensure` drops the database and clears the lease; a hard
# kill leaves both. This reaper acts ONLY on databases named in a lease WE wrote —
# a worktree DB is never leased, so it is never a candidate. That is the closed set.
#
# WHY BARE PID-LIVENESS IS SAFE HERE (it is NOT safe in CertOrphanGuard, on purpose).
# CertOrphanGuard KILLS processes, so a recycled PID would kill a bystander — it must
# prove (pid, start-time) identity. This reaper DROPS a per-run-UNIQUE database. A PID
# is only ever reused AFTER its original owner exits, so `Process.kill(0, pid)`:
#   * succeeds  -> SOME process holds the pid: either our still-running mint (correct
#                  skip) or a stranger who inherited it (the mint is dead, but we still
#                  skip). Either way we do not drop. A false-ALIVE only ever LEAKS.
#   * raises ESRCH -> NO process holds the pid: the mint is PROVABLY gone, and because
#                  the database is unique to that one run, it is PROVABLY orphaned.
# A false-DEAD (dropping a database a live run still needs) is therefore impossible.
# Every uncertain answer resolves toward "alive" — absence of signal is never a drop.
#
# THE GUARD (assert_test_database!'s doctrine, reused). Even acting only on leased
# names, the reaper re-proves each name is a per-run TEST database before it drops:
# it must sit in the app's test namespace (`<base>_`, separator REQUIRED) and carry
# the per-run digest suffix. This is a positive structural invariant, not a blacklist
# of forbidden spellings — so a corrupt or hostile lease naming `mcritchie_studio_
# development` (the database test_database_purge.rb exists to spare, and whose first
# cut once bricked every release) is REFUSED, not dropped. The base is read the same
# env-independent way the purge guard reads it (the `database:` literal in
# config/database.yml's test env), never guessed from a name.
module CertDatabaseReaper
  # The per-run digest suffix every ephemeral cert DB carries: `_` + 8 lowercase hex
  # (DB_SLUG_HASH_LEN in bin/agent-worktree; SecureRandom.hex(4) in the probe). This
  # is the per-run PROPERTY, asserted positively — never a list of names to exclude.
  RUN_SUFFIX = /_[0-9a-f]{8}\z/

  LEASE_DIR_REL = File.join("tmp", "cert_db_leases")

  class << self
    # --- lease lifecycle (called by the mint site) --------------------------

    # Record intent to own `db_name`: a lease file naming the database and this
    # process. Written BEFORE db:test:prepare so a failure mid-provision is still
    # covered. A clean run calls release; a hard kill leaves this for the next reap.
    def register(db_name, dir: lease_dir, pid: Process.pid, now: Time.now)
      db_name = db_name.to_s
      return if db_name.empty?

      FileUtils.mkdir_p(dir)
      File.write(lease_path(dir, db_name),
                 JSON.generate("db" => db_name, "pid" => pid, "at" => now.utc.iso8601))
      db_name
    end

    # Clean teardown: drop the database, then forget the lease. `drop` is injected
    # so the mint site can reuse its own credentialed pg env.
    def release(db_name, dir: lease_dir, drop: method(:drop_database))
      db_name = db_name.to_s
      return if db_name.empty?

      drop.call(db_name)
      forget(db_name, dir: dir)
    end

    def forget(db_name, dir: lease_dir)
      File.delete(lease_path(dir, db_name.to_s))
    rescue Errno::ENOENT
      nil
    end

    # --- the reaper ---------------------------------------------------------

    # Drop every leased database whose owning run is provably gone AND whose name
    # proves out as a per-run test database. Returns {reaped:, skipped:, refused:}
    # — factual, so a caller reports what happened, never what it hoped happened.
    #
    #   skipped : a live run owns it (PID alive, or its liveness is unknowable).
    #   refused : the lease is malformed, or its name is not an admissible per-run
    #             test DB — NAME it, never guess it away and never drop it.
    #   reaped  : owner gone + name admissible -> dropped and forgotten.
    def reap!(dir: lease_dir, base: default_base,
              alive: method(:process_alive?), drop: method(:drop_database))
      result = { reaped: [], skipped: [], refused: [] }

      leases(dir).each do |lease|
        db = lease["db"].to_s
        pid = coerce_pid(lease["pid"])

        if pid.nil?
          result[:refused] << db                 # malformed lease: cannot prove the owner is gone
        elsif alive.call(pid)
          result[:skipped] << db                 # AC2: a live run owns it
        elsif !admissible?(db, base: base)
          result[:refused] << db                 # AC3: the closed-set floor
        else
          drop.call(db)                           # AC1: owner gone + name proven -> drop
          delete_file(lease["_path"])
          result[:reaped] << db
        end
      end

      result
    end

    # AC3 guard: is `name` one of THIS app's per-run test databases? A positive
    # invariant (test namespace + per-run digest), so everything else — above all
    # mcritchie_studio_development — falls outside it and is refused.
    def admissible?(name, base: default_base)
      name = name.to_s
      base = base.to_s
      return false if name.empty? || base.empty?
      return false unless name.start_with?("#{base}_") # in the test namespace; the `_` separator is required
      return false unless name.match?(RUN_SUFFIX)      # carries the per-run digest suffix

      true
    end

    def default_base
      TestDatabasePurge.declared_test_database
    end

    # --- liveness -----------------------------------------------------------

    # PROVABLY dead (ESRCH) -> false. Anything else — alive, alive-but-not-ours
    # (EPERM), or any surprise — resolves to true: an uncertain owner is never a
    # drop. See the module header for why a false-alive is the safe direction here.
    def process_alive?(pid)
      pid = coerce_pid(pid)
      return true if pid.nil?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue StandardError
      true
    end

    # --- drop (the only side effect on Postgres) ----------------------------

    def drop_database(name, env: pg_conn_env, dropdb: "dropdb")
      system(env, dropdb, "--if-exists", name.to_s, out: File::NULL, err: File::NULL)
    end

    # Subprocess env for `dropdb`, derived from the run's own connection URL so it
    # authenticates the same way the suite does (a PATH-only env -> fe_sendauth on
    # CI). Neutralizes the agent session marker when that helper is loaded so the
    # sweep never attributes to a session.
    def pg_conn_env
      env = { "PATH" => ENV.fetch("PATH", "") }
      env = SessionEnv.neutralized(env) if defined?(SessionEnv)

      url = ENV["DATABASE_URL"].to_s
      url = ENV["TEST_DATABASE_URL"].to_s if url.strip.empty?
      return env if url.strip.empty?

      uri = URI.parse(url)
      env["PGHOST"] = uri.host if uri.host && !uri.host.empty?
      env["PGPORT"] = uri.port.to_s if uri.port
      env["PGUSER"] = uri.user if uri.user && !uri.user.empty?
      env["PGPASSWORD"] = uri.password if uri.password && !uri.password.empty?
      env
    rescue URI::InvalidURIError
      env
    end

    # --- lease store --------------------------------------------------------

    def lease_dir
      File.join(repo_root, LEASE_DIR_REL)
    end

    def lease_path(dir, db_name)
      File.join(dir, "#{db_name}.json")
    end

    private

    def leases(dir)
      Dir.glob(File.join(dir, "*.json")).filter_map do |path|
        data = JSON.parse(File.read(path))
        data["_path"] = path
        data
      rescue JSON::ParserError, Errno::ENOENT
        nil # an unreadable lease must not crash a periodic sweep; skip it (a leak, the safe way)
      end
    end

    def coerce_pid(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def delete_file(path)
      File.delete(path) if path
    rescue Errno::ENOENT
      nil
    end

    def repo_root
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s
      else
        Dir.pwd
      end
    end
  end
end
