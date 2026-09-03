# frozen_string_literal: true

require "open3"
# gate_workspace.rb opens `class Release` with no superclass so bin scripts can
# load it without Rails. Inside a booted Rails process that same line PLANTS a
# plain Release if the autoloader has not defined the real AR model yet —
# Zeitwerk cannot replace a taken constant, and every Task#release reflection
# after that raises "not an ActiveRecord::Base subclass" (load-order dependent:
# it bit whenever desk_guard_test loaded before anything touching the model).
# Referencing ::Release first makes the path-load below a harmless reopen.
::Release if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
require_relative "../../app/models/release/gate_workspace"

# DeskGuard — refuse a CERT lane in a worktree DESK whose test database is not its own.
#
# A desk (an agent worktree at <repo>/.worktrees/<slug>) is supposed to get its OWN test
# database at bringup. When it does not, RAILS_ENV=test does not fail — it QUIETLY JOINS
# the SHARED `<app>_test` that the primary checkout, CI, and the release gate workspaces
# use. Cross-suite pollution, PG::ObjectInUse on purge, order-dependent phantom failures
# — and a cert lane's FIRST act is `db:test:purge`, so the desk does not merely read that
# database, it DESTROYS it, mid-suite, under every concurrent run. Nothing about the
# directory announces any of this.
#
# ═══ WHY THIS ASKS THE BOOTED APP, AND WHY THE FIRST CUT WAS WORSE THAN NOTHING ═══
#
# The first cut allowed on the PRESENCE OF A STRING: a non-empty TEST_DATABASE_URL in
# .env.test.local or the env, and the desk walked. That is a DECLARATION, and a
# declaration is not the property. `TEST_DATABASE_URL` is a HAND-ROLLED seam — it lands
# only if the app's config/database.yml actually reads it:
#
#   * mcritchie-studio renders `url: <%= ENV["TEST_DATABASE_URL"] %>` — it lands.
#   * turf-monster (before this) did NOT — bare `database: turf_monster_test`. The pin was
#     INERT. Every turf desk declared an isolated-LOOKING URL, resolved to the SHARED
#     `turf_monster_test`, and this guard said ALLOW — while the next lane purged it, with
#     two turf desks live. A guard that REPORTS an isolation it has not PROVEN launders a
#     live hazard into a claimed-closed one: worse than no guard at all.
#   * rolio is SQLite and has no TEST_DATABASE_URL BY DESIGN — its test DB is a FILE inside
#     the desk, private by construction. Demanding the string there refuses a perfectly
#     isolated tree.
#
# One root cause, wrong in BOTH directions on BOTH satellites: the model was
# POSTGRES-SHAPED and DECLARATION-TRUSTING. So the verdict is RESOLVED, not trusted — boot
# the app in the desk, under the env the LANE will boot with, and read back the database it
# ACTUALLY connects to (`connection_db_config`; it does not open a connection). This is the
# doctrine bin/release.rb's assert_private_gate_db! already used for the gate workspaces.
# The desks now share its primitive (Release::GateWorkspace) rather than keep a second,
# drifting copy.
#
# ═══ THE INVARIANT ═══
#
# POSITIVE and adapter-agnostic: THIS DESK'S TEST DATABASE IS NOT THE REPO'S SHARED ONE.
#
#   * file-backed (SQLite): the database is a PATH — private iff it resolves INSIDE the
#     desk, where no other process can reach it. Proven by CONTAINMENT, never by a name.
#   * identifier (Postgres): private iff it is not the repo's shared `test.database`.
#
# The shared name is computed EXTERNALLY — Release::GateWorkspace.declared_test_database
# reads config/database.yml with the ERB STRIPPED, so no env var can rewrite the thing we
# compare against. Comparing a resolved database against a config the caller's own env has
# already rewritten is a placebo: it proves `x == x`.
#
# FAIL CLOSED. Refuse when it is provably shared; allow when it is provably not; and when
# it can prove NEITHER — the app would not boot, config/database.yml is unreadable — REFUSE
# AND SAY SO. An unprovable isolation claim is the exact failure this guard exists to end.
#
# RESIDUAL, stated rather than hidden: for Postgres this proves "not the SHARED database",
# not "not ANY other desk's database". Two desks whose slugs truncate to the same bounded
# identifier (bin/agent-worktree's bounded_db_slug, under the 63-byte PG limit) would
# collide, and this guard would allow both. That is a NAMING bug in bringup, not a hole in
# the comparison — but it is not closed here, so it is written down here.
#
# RESIDUAL 2, same shape, also stated rather than hidden: `refusal` defaults to `env: ENV`,
# so a TEST_DATABASE_URL INHERITED from another desk's shell resolves to a database that is
# private — but private to SOMEBODY ELSE — and is admitted, because it is not the shared one.
# full-suite-check's `db:test:purge` would then destroy that OTHER desk's database. Bringup
# scrubs both DB vars for exactly this reason (desk_probe_env); the cert lanes deliberately
# do not, because they must prove THE RUN THEY ARE ABOUT TO DO, inherited env and all. Not
# closed here.
#
# ═══ WHERE IT APPLIES ═══
#
# It guards AGENT DESKS IN RAILS REPOS only, and the two exclusions are different in kind:
#
#   * `.worktrees/` also holds the release gate/ship workspaces (`_gate`, `_ship`), whose
#     leading underscore is a namespace Release::GateWorkspace reserves precisely so they are
#     "NOT an agent worktree and must never be mistaken for one". They are not exempt from
#     the rule so much as covered by their own, stricter one: assert_private_gate_db! proves
#     their DB is private BEFORE db:test:purge destroys it.
#   * a desk in a repo that is NOT A RAILS APP (studio-engine, solana-studio, turf-vault) has
#     no test database, so this guard has no job there and ADMITS WITHOUT BOOTING. That is
#     INAPPLICABILITY, not a soft pass — and it is emphatically not "the boot failed, so
#     allow". See rails_repo?, which is where that line is drawn and defended.
module DeskGuard
  module_function

  WORKTREES_DIR = ".worktrees"
  TEST_ENV_LOCAL = ".env.test.local"
  # Release::GateWorkspace::DIRNAME — `_gate` / `_ship`, and any future sibling.
  RESERVED_PREFIX = "_"
  # The two things a Rails app must have for this guard to have a job: something to BOOT,
  # and a declared test database to boot INTO. A repo with neither has no test DB at all.
  RAILS_ENTRYPOINT = File.join("bin", "rails")
  DATABASE_CONFIG = File.join("config", "database.yml")

  # Read back the database the app ACTUALLY connects to in the test env. Reading
  # `connection_db_config` does NOT open a connection, so the probe is safe against a desk
  # whose database does not exist yet — and it never touches the database it is protecting.
  PROBE = 'print "DESKDB=#{ActiveRecord::Base.connection_db_config.database}\n"'

  # nil when `root` may run a test lane; otherwise the refusal message.
  #
  # A non-desk root (the primary checkout, CI, a bare clone) is never refused — the shared
  # `<app>_test` IS the correct database there — and is never even booted, so the probe's
  # cost lands only where the hazard does.
  #
  # `env:` is the env the LANE will run under (bin/fast-check and bin/full-suite-check both
  # `system(cmd, chdir: root)`, so the lane inherits the ambient ENV) — the probe therefore
  # boots what the lane boots, including a DATABASE_URL the caller happens to export. Prove
  # the run you are about to do, not a tidier one. `resolver:` is the seam the unit tests
  # drive instead of a real Rails boot.
  def refusal(root, env: ENV, resolver: nil)
    return nil unless desk?(root)

    desk = File.expand_path(root.to_s)
    repo = repo_root(desk)
    # INAPPLICABLE — not a Rails repo, so there is no test database for a cert lane to
    # purge and nothing this guard can prove. ADMIT, and do not pay for a boot that would
    # only fail. This is NOT "boot failed, so allow" — see rails_repo? for why that
    # distinction is the whole ballgame.
    return nil unless rails_repo?(repo)

    shared = Release::GateWorkspace.declared_test_database(repo).to_s.strip
    resolved, output, booted = (resolver || method(:resolve)).call(desk, env: env)
    resolved = resolved.to_s.strip

    return unresolved_refusal(desk, output) if !booted || resolved.empty?
    return unreadable_config_refusal(desk, repo, resolved) if shared.empty?
    return nil if private_db?(resolved: resolved, desk: desk, shared: shared)

    shared_refusal(desk, repo, resolved, shared, env: env)
  end

  # A tree is an agent desk when it sits directly under a repo's .worktrees/ and is not one
  # of the reserved `_`-prefixed release workspaces. Checked on the PATH, not on the stack
  # env: a half-built desk is missing exactly those files, so keying the check on them would
  # let the broken case walk straight through.
  def desk?(root)
    path = File.expand_path(root.to_s)
    return false unless File.basename(File.dirname(path)) == WORKTREES_DIR

    !File.basename(path).start_with?(RESERVED_PREFIX)
  end

  # The primary checkout a desk hangs off: <repo>/.worktrees/<slug> -> <repo>.
  def repo_root(desk)
    File.dirname(File.dirname(File.expand_path(desk.to_s)))
  end

  # Does this REPO have a Rails test database at all — i.e. does this guard have a JOB here?
  #
  # ═══ INAPPLICABLE IS NOT "UNPROVEN". COLLAPSING THEM BRICKS ONE HALF OR THE OTHER ═══
  #
  # This guard can fail in two directions and each one bricks a different half of the
  # ecosystem. They must stay apart:
  #
  #   INAPPLICABLE -> ADMIT, without booting.
  #     The repo is not a Rails app at all — studio-engine, solana-studio, turf-vault carry
  #     no bin/rails and no config/database.yml. There is no shared `<app>_test`, no
  #     `db:test:purge` lane, NOTHING TO PROTECT and nothing this guard could prove. (Even
  #     studio-engine's dummy app is `database: ":memory:"` — private to the process by
  #     construction.) Refusing here is not caution, it is a BRICK: the first cut asked only
  #     "is this path under .worktrees/?", booted anyway, hit Errno::ENOENT on the missing
  #     bin/rails, and fail-closed straight into refusing the cert lane for every gem and
  #     Anchor desk — the `library` shape could not pass G1 AT ALL. A guard that refuses a
  #     desk it has no business judging is not safe; it is broken.
  #
  #   UNPROVEN -> REFUSE.
  #     The repo IS a Rails app, so the hazard is real and live, and we could not resolve
  #     the desk's database — the app would not boot, config/database.yml is unreadable.
  #     This is the guard's entire purpose and it does not soften by one inch.
  #
  # THE LINE IS DRAWN ON FILES IN THE REPO, NEVER ON A BOOT OUTCOME. "The app failed to
  # boot" must never be allowed to mean "there was no app": that is the exact fail-open hole
  # this task exists to close, and it would hand a free pass to every turf desk (whose boot
  # DOES work, and resolves to the SHARED turf_monster_test) the moment its boot broke for
  # any unrelated reason.
  #
  # Read on the REPO, not on the desk — the repo is the seam OUTSIDE the desk's control, the
  # same reason declared_test_database is computed there. A desk cannot delete its way out of
  # being guarded.
  #
  # EITHER file, not both: any trace of a Rails app and we prove-or-refuse. Only a repo with
  # NEITHER is inapplicable. Today the three managed Rails apps carry both files and the three
  # non-Rails repos carry neither, so nothing sits in between — and if something ever does (a
  # malformed app, a half-deleted config), it takes the STRICT path. That is the safe way to
  # be wrong.
  def rails_repo?(repo)
    root = File.expand_path(repo.to_s)
    File.exist?(File.join(root, RAILS_ENTRYPOINT)) || File.exist?(File.join(root, DATABASE_CONFIG))
  end

  # IO. Boot the app in `root` at RAILS_ENV=test and read back the database it connects to.
  # -> [resolved, combined_output, booted?]
  def resolve(root, env: ENV)
    probe_env = env.to_h.transform_values { |v| v.nil? ? nil : v.to_s }.merge("RAILS_ENV" => "test")
    # capture2e merges stderr (bundler/rubygems chatter), so pluck the token rather than
    # trust the whole stream — the same reason assert_private_gate_db! plucks GATEDB=.
    out, status = Open3.capture2e(probe_env, "bin/rails", "runner", PROBE, chdir: root.to_s)
    [out[/DESKDB=(.*)$/, 1].to_s.strip, out, status.success?]
  rescue StandardError => e
    ["", "#{e.class}: #{e.message}", false]
  end

  # PURE. Is `resolved` — the database the app ACTUALLY connected to — private to THIS desk?
  # Two ways to qualify, and they are the two adapter shapes:
  #   * a FILE inside the desk (SQLite): unreachable by any other process, private by
  #     construction. Containment, not naming — an absolute path at the PRIMARY's
  #     storage/test.sqlite3 is shared, and fails here, as it must.
  #   * an identifier that is NOT the repo's shared `<app>_test` (Postgres).
  # Anything else — most importantly the bare shared name — is NOT private.
  def private_db?(resolved:, desk:, shared:)
    db = resolved.to_s.strip
    return false if db.empty?

    if Release::GateWorkspace.file_backed?(db)
      root = File.absolute_path(desk.to_s)
      return File.absolute_path(db, root).start_with?(root + File::SEPARATOR)
    end

    name = shared.to_s.strip
    # Nothing trustworthy to compare against: we cannot prove isolation, so we don't claim it.
    return false if name.empty?

    db != name
  end

  # TEST_DATABASE_URL as the desk DECLARES it — the env first, then .env.test.local.
  #
  # DIAGNOSIS ONLY. It never decides the verdict — that is the whole lesson of this file. It
  # picks WHICH refusal to print, because "you pinned an isolated DB and your app ignored
  # it" and "you pinned nothing, bringup died half-way" are different problems with
  # different fixes, and handing an operator the wrong one costs an afternoon.
  def declared_test_database_url(root, env: {})
    from_env = env.to_h["TEST_DATABASE_URL"].to_s.strip
    return from_env unless from_env.empty?

    path = File.join(File.expand_path(root.to_s), TEST_ENV_LOCAL)
    return nil unless File.exist?(path)

    File.readlines(path).each do |line|
      key, _, value = line.strip.partition("=")
      return value.strip if key.strip == "TEST_DATABASE_URL"
    end
    nil
  rescue SystemCallError
    nil
  end

  # --- refusals ------------------------------------------------------------------------

  # Could not resolve at all. Honest about BOTH causes: a boot-breaking diff lands here too,
  # so it must not be pinned on the env alone.
  def unresolved_refusal(desk, output)
    <<~MSG.strip
      could not resolve this desk's test database — `bin/rails runner` did not boot.

        desk: #{desk}

      Refusing: this guard exists to PROVE the desk owns the database the next lane is about
      to PURGE, and it could not prove it. It does not guess. Two things land here — a broken
      ENV (bundle, Postgres, a missing gem) or a boot-time error in your own diff — and the
      output below is what tells them apart. Either way, the cert could not have run.

      #{indent(output)}
    MSG
  end

  # Resolved fine, but there is nothing trustworthy to compare it against.
  def unreadable_config_refusal(desk, repo, resolved)
    <<~MSG.strip
      could not read the SHARED test database name from #{repo}/config/database.yml, so this
      desk's isolation cannot be proven.

        desk:     #{desk}
        resolved: #{resolved}

      Refusing rather than assuming: an unprovable isolation claim is exactly the failure this
      guard exists to end. This is an ENV/config issue, NOT a regression in your diff.
    MSG
  end

  # Proven shared. Two very different causes, two very different fixes.
  def shared_refusal(desk, repo, resolved, shared, env: {})
    declared = declared_test_database_url(desk, env: env).to_s.strip
    app = File.basename(repo)
    slug = File.basename(desk)

    detail =
      if declared.empty?
        <<~MSG
            missing:  #{TEST_ENV_LOCAL} (TEST_DATABASE_URL=…), and none is exported in the env

          This desk has no isolated test DB — its bringup did not complete. RAILS_ENV=test falls
          back to the SHARED base test database, so every `bin/rails test` here pollutes, and is
          polluted by, every concurrent suite — and this cert's next lane (`db:test:purge`) would
          DESTROY it. A cert against a shared database certifies nothing.

          This is an ENV issue with the DESK, not a regression in your diff. Re-provision it
          (bringup is idempotent and repairs the missing pieces):

            bin/agent-worktree new #{app} #{slug}
        MSG
      else
        <<~MSG
            declared: TEST_DATABASE_URL=#{declared}

          The desk DECLARES an isolated test DB and the app IGNORES it: #{app}'s
          config/database.yml never reads TEST_DATABASE_URL in its `test:` block, so the pin is
          INERT and the suite silently joins the SHARED database. This cert's next lane
          (`db:test:purge`) would DESTROY it, mid-suite, under every concurrent run.

          Fix the REPO, not the desk — in #{app}/config/database.yml, `test:` block:

            url: <%= ENV["TEST_DATABASE_URL"] %>

          If the repo already carries that line, this desk predates it — rebase onto
          origin/release and the pin takes effect.

          This is an ENV/config issue, NOT a regression in your diff.
        MSG
      end

    <<~MSG.strip
      this desk's test lane would run against the SHARED test database.

        desk:     #{desk}
        resolved: #{resolved}   <- what the BOOTED app connects to at RAILS_ENV=test
        shared:   #{shared}   <- config/database.yml's test database: the primary checkout's, CI's
      #{detail}
    MSG
  end

  # The tail of the probe's output, indented so it reads as evidence under a refusal rather
  # than as more prose. Mirrors bin/release.rb's indent_output.
  def indent(output, lines: 20)
    text = output.to_s.strip
    return "  (no output captured)" if text.empty?

    kept = text.lines.last(lines).map { |l| "  #{l.rstrip}" }.join("\n")
    text.lines.size > lines ? "  … (#{text.lines.size - lines} earlier lines omitted)\n#{kept}" : kept
  end
end
