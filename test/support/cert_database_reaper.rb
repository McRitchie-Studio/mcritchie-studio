# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require "tmpdir"
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
# A candidate pid must FIRST be a positive integer: a non-positive or unparseable value is a
# malformed lease (and a negative pid would make Process.kill(0, -N) probe a process GROUP,
# whose absence reads as ESRCH=dead and would fail OPEN), so it is REFUSED, never liveness-probed.
#
# THE GUARD (assert_test_database!'s doctrine, reused). Even acting only on leased
# names, the reaper re-proves each name is a per-run TEST database before it drops:
# it must sit in the app's test namespace (`<base>_`, separator REQUIRED) and carry
# the per-run digest suffix. This is a positive structural invariant, not a blacklist
# of forbidden spellings — so a corrupt or hostile lease naming `mcritchie_studio_
# development` (the database test_database_purge.rb exists to spare, and whose first
# cut once bricked every release) is REFUSED, not dropped. It also refuses any name past
# Postgres's 63-byte identifier limit — `dropdb` would TRUNCATE a longer name and could act on
# a DIFFERENT 63-byte database; a minted name is already bounded to fit, so a longer one never
# named a DB we minted. The base is read the same env-independent way the purge guard reads it
# (the `database:` literal in config/database.yml's test env), never guessed from a name.
module CertDatabaseReaper
  # Durable, shared per-user, and outside any repo/worktree — see lease_dir for why.
  LEASE_DIR = File.join(Dir.home, ".mcritchie", "cert-db-leases")

  # Postgres NAMEDATALEN-1: identifiers longer than this are TRUNCATED. `dropdb` on an
  # over-long name would act on the truncated head and could drop a DIFFERENT 63-byte
  # database, so a name past this bound is refused — a minted name is already bounded to fit.
  MAX_IDENTIFIER_BYTES = 63

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

    # Clean teardown: drop the database, then forget the lease — but ONLY when the drop
    # succeeded. A failed drop KEEPS the lease so a later reap retries it, never leaving a
    # live database with no record of who owns it. `drop` is injected so the mint site can
    # reuse its own credentialed pg env.
    def release(db_name, dir: lease_dir, drop: method(:drop_database))
      db_name = db_name.to_s
      return if db_name.empty?

      forget(db_name, dir: dir) if drop.call(db_name)
    end

    def forget(db_name, dir: lease_dir)
      File.delete(lease_path(dir, db_name.to_s))
    rescue Errno::ENOENT
      nil
    end

    # --- the reaper ---------------------------------------------------------

    # Drop every leased database whose owning run is provably gone AND whose name
    # proves out as a per-run test database. Returns {reaped:, skipped:, refused:, failed:}
    # — factual, so a caller reports what happened, never what it hoped happened.
    #
    #   skipped : a live run owns it (PID alive, or its liveness is unknowable).
    #   refused : the lease is malformed, or its name is not an admissible per-run
    #             test DB — NAME it, never guess it away and never drop it.
    #   failed  : owner gone + name proven, but the DROP failed (permission/connection —
    #             dropdb --if-exists exits 0 for a merely-absent DB). The lease is KEPT so
    #             a later sweep retries; a failed drop is NEVER reported reaped.
    #   reaped  : owner gone + name admissible + drop SUCCEEDED -> dropped and forgotten.
    def reap!(dir: lease_dir, base: default_base,
              alive: method(:process_alive?), drop: method(:drop_database))
      result = { reaped: [], skipped: [], refused: [], failed: [] }

      leases(dir).each do |lease|
        db = lease["db"].to_s
        pid = coerce_pid(lease["pid"])

        if pid.nil?
          result[:refused] << db                 # malformed lease: cannot prove the owner is gone
        elsif alive.call(pid)
          result[:skipped] << db                 # AC2: a live run owns it
        elsif !admissible?(db, base: base)
          result[:refused] << db                 # AC3: the closed-set floor
        elsif drop.call(db)                       # AC1: owner gone + name proven + drop OK
          delete_file(lease["_path"])
          result[:reaped] << db
        else
          result[:failed] << db                  # drop failed: KEEP the lease so a later sweep retries
        end
      end

      result
    end

    # AC3 guard: is `name` one of THIS app's per-run test databases? A positive
    # invariant asserting the full ephemeral SHAPE a run could actually MINT —
    # `<base>_<slug>_<8hex>` where the slug is the MINTABLE charset only. A Postgres DB
    # name minted here is lowercase `[a-z0-9_]` (bounded_db_slug tr's `-`->`_` and clips a
    # SHA-hex digest), so the slug segment is `[a-z0-9_]+` and the digest is `[0-9a-f]{8}`.
    # Anything else falls outside and is refused: mcritchie_studio_development, the base,
    # its parallel clones, the release workspaces, a no-slug `<base>_<8hex>` look-alike, and
    # a non-mintable look-alike (uppercase, hyphen, or any char no mint could have produced).
    def admissible?(name, base: default_base)
      name = name.to_s
      base = base.to_s
      return false if name.empty? || base.empty?
      return false if name.bytesize > MAX_IDENTIFIER_BYTES # dropdb would TRUNCATE and could hit another DB

      name.match?(/\A#{Regexp.escape(base)}_[a-z0-9_]+_[0-9a-f]{8}\z/)
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

    # DURABLE, SHARED per-user, and OUTSIDE any repo/worktree. The lease is the ONLY identity
    # record for a database that lives in the shared Postgres cluster, so it must outlive
    # everything shorter-lived than that cluster. A lease under a worktree's own `tmp/` VANISHES
    # on worktree cleanup; a lease under Dir.tmpdir (`/var/folders/.../T`, `/tmp`) is pruned by
    # the OS temp-cleaner — either way the database it named is stranded as PERMANENTLY unreapable
    # (its only identity gone, its name inadmissible to a blind pattern drop). A per-user home dir
    # survives worktree cleanup, temp sweeps, and reboots, and is still shared across every run on
    # the host, so each boot sweep sees every other run's leases.
    def lease_dir
      LEASE_DIR
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

    # A provable owner PID is a POSITIVE integer. A non-positive value is malformed — and a
    # NEGATIVE pid handed to Process.kill(0, -N) probes a process GROUP, whose absence reads as
    # ESRCH=dead and would fail OPEN into a drop. Coerce those to nil so reap! REFUSES the lease.
    def coerce_pid(value)
      pid = Integer(value)
      pid.positive? ? pid : nil
    rescue ArgumentError, TypeError
      nil
    end

    def delete_file(path)
      File.delete(path) if path
    rescue Errno::ENOENT
      nil
    end
  end
end
