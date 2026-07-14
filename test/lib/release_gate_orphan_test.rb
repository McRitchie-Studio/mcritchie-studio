# frozen_string_literal: true

# The RELEASE GATE's orphan guard — bin/release.rb's G3/G4 suites must not outlive the
# conductor that spawned them.
#
# THE BUG (reproduced live before the fix, and again here). bin/release.rb#sh spawned
# with a bare `system(*argv, opts)`. That leaves the suite in the CONDUCTOR'S OWN
# process group with no handler, so a signal aimed at bin/release never reaches it:
#
#   $ kill -TERM <conductor>        # what a harness timeout / an operator ^C does
#   PID    PPID  PGID   COMMAND
#   13795  1     13380  /bin/sh -c psql ... begin; select pg_sleep(300);   ← PPID 1
#   pg_stat_activity: 13798 | active | psql                                ← holding the DB
#   $ psql -c 'DROP DATABASE mcr_orphan_repro_test'
#   ERROR:  database "..." is being accessed by other users
#
# WORSE HERE THAN IN THE CERT LANES, which is why it got its own change: the gate's test
# DB is FIXED per repo+role (`<repo>_gate_test`), not per worktree. One stranded suite
# therefore blocks EVERY later gate for that repo — its db:test:prepare cannot purge a
# DB somebody else holds — and on G4 that lands immediately before an irreversible prod
# deploy.
#
# TWO HALVES, and the second is not optional: a SIGKILL runs no handler, so PREVENTION
# (own process group, reap the group on TERM/INT/HUP) can never be complete. What it
# cannot prevent, the NEXT gate must DETECT and name.
#
# AND THE DIRECTION THAT CAN HURT PRODUCTION: a reaper that guesses is worse than no
# reaper. A pgid is a recyclable integer, so "something is alive under that number" is
# NOT proof it is ours — the cert's first cut graded on exactly that and killed an
# innocent bystander in a live reproduction. So the tests below put a REAL live
# bystander in front of the guard and assert it walks away. On the ship path a wrong
# kill is catastrophic, and no amount of reasoning substitutes for looking.
#
# Run directly:  ruby -Itest test/lib/release_gate_orphan_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../../bin/lib/cert_orphan_guard"

class ReleaseGateOrphanTest < Minitest::Test
  RELEASE = File.expand_path("../../bin/release.rb", __dir__)
  RUBY = RbConfig.ruby

  # The DB backstop is a separate concern from the reaper, and it must not go poking at
  # this box's real databases while we are testing process identity. No psql → no
  # backends → the runlock is the only thing under test.
  NO_DB = { "CERT_GUARD_PSQL" => "/nonexistent/psql" }.freeze

  def setup
    @root = Dir.mktmpdir("release-gate-orphan")
    @spawned = []
  end

  def teardown
    @spawned.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    FileUtils.rm_rf(@root)
  end

  # --- harness -----------------------------------------------------------------------

  # The child env for every subprocess here: the agent-session vars neutralized (see
  # SessionEnv), and the release's lock dir redirected into our tmpdir so a test can
  # never read — or write — the operator's real .agents/locks.
  def child_env(extra = {})
    SessionEnv.neutralized({ "MCR_PRIMARY_LOCK_DIR" => File.join(@root, "locks") }.merge(extra))
  end

  # A stand-in CONDUCTOR. It `require`s bin/release.rb — which is guarded by
  # `__FILE__ == $PROGRAM_NAME`, so requiring it dispatches no CLI — and then calls
  # release.rb's OWN sh(), the exact seam the G3/G4 gate suites run through. Nothing is
  # re-implemented here: if sh() regresses, this regresses.
  # `Process.detach` is load-bearing, not tidiness: the conductor is OUR child, so once we
  # kill it it becomes a ZOMBIE — and a zombie answers signal 0 for as long as nobody
  # reaps it, so `alive?` would report a killed conductor as alive forever. Detaching
  # hands the reaping to a Ruby thread, so a dead conductor really does vanish. (The guard
  # is not fooled by this: it reads the process table and skips state Z — which is exactly
  # why liveness is a poor definition of alive, the moral of this whole file.)
  def spawn_conductor(body)
    path = File.join(@root, "conductor.rb")
    File.write(path, <<~RUBY)
      $PROGRAM_NAME = "gate-conductor-under-test"
      require #{RELEASE.dump}
      #{body}
    RUBY
    pid = Process.spawn(child_env, RUBY, path, out: File::NULL, err: File::NULL)
    @spawned << pid
    Process.detach(pid)
    pid
  end

  # Evaluate an expression inside a loaded bin/release.rb and hand back the value. Lets
  # the unit tests below assert on release.rb's REAL helpers rather than on a copy of
  # their logic — a copy would keep passing after the real one drifted.
  def release_eval(expr, argv: [])
    script = <<~RUBY
      $PROGRAM_NAME = "release-eval"
      ARGV.replace(#{argv.inspect})
      require #{RELEASE.dump}
      require "json"
      $stdout.puts("__VALUE__" + JSON.generate(v: (#{expr})))
    RUBY
    out = IO.popen(child_env, [RUBY, "-e", script], err: File::NULL, &:read).to_s
    line = out.lines.find { |l| l.start_with?("__VALUE__") }
    raise "release.rb eval produced no value for `#{expr}`:\n#{out}" unless line

    JSON.parse(line.sub("__VALUE__", ""))["v"]
  end

  # A REAL process in a group of its very own — exactly what CertProcess spawns, and so
  # exactly what a recycled pgid lands on. Detached, because a killed child of ours
  # becomes a ZOMBIE, and a zombie answers signal 0 forever: `alive?` would then report
  # a successfully-reaped orphan as alive and red this suite against a guard that did
  # its job. (The guard itself is not fooled — it reads the process table and skips
  # state Z. That asymmetry is the whole moral of the file.)
  def spawn_bystander(command = "sleep 45")
    pid = Process.spawn(command, pgroup: true, out: File::NULL, err: File::NULL)
    @spawned << pid
    Process.detach(pid)
    pid
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::EPERM
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout: 8.0)
    deadline = Time.now + timeout
    sleep 0.1 while !yield && Time.now < deadline
    yield
  end

  def read_pid_file(path)
    assert wait_until { File.exist?(path) && !File.read(path).strip.empty? },
           "the gate suite never started (no pid file at #{path})"
    File.read(path).strip.to_i
  end

  # Ask the GUARD where its lock lives — never hardcode `<root>/tmp/cert-run.json`. #539
  # resolves the path through `git rev-parse --absolute-git-dir`, so a root inside a repo
  # puts the lock in that repo's git dir instead. A test that hardcodes the old path is a
  # test that silently stops looking at the file the code actually writes.
  def lock_path = CertOrphanGuard.lock_path(@root)
  def read_lock = JSON.parse(File.read(lock_path))

  # CertProcess writes the runlock AFTER it spawns (it has to: the lock names the group it
  # just created, and it reads the OS start time for two pids first). So the child can be
  # up — and its pid file written — a beat BEFORE the lock exists. Killing the conductor in
  # that window leaves no lock to find, which under a parallel full suite is a real flake
  # and not a hypothetical one: it errored exactly here, once, in 3946 runs. Wait for the
  # artifact the assertion depends on, not for a proxy that merely usually precedes it.
  def wait_for_runlock
    assert wait_until { File.exist?(lock_path) },
           "the conductor never wrote its runlock (#{lock_path}) — nothing for the next gate to read"
  end

  def pgid_of(pid)
    Process.getpgid(pid)
  rescue Errno::ESRCH
    nil
  end

  # --- [unit] the voice: a gate abort must never read as a red suite ------------------

  # The load-bearing sentence. An abort on the G3/G4 path that does NOT say this reads
  # as a red suite, and a red suite gets a task EJECTED from the release — so a leftover
  # process would evict good code. That is the exact disease the isolated gate was built
  # to cure, and the reaper meant to help must not reintroduce it.
  def test_gate_voice_says_an_env_abort_is_not_a_release_regression
    line = CertOrphanGuard::GATE.env_line

    assert_includes line, "NOT a release regression"
    assert_includes line, "nothing to eject or revert"
  end

  # The cert keeps its own words — one mechanism, two callers, and neither inherits the
  # other's wrong advice ("nothing to eject" is meaningless to a builder certifying a diff).
  def test_cert_voice_is_unchanged_and_is_the_default
    assert_includes CertOrphanGuard::CERT.env_line, "NOT a regression in your diff"
    assert_equal "cert", CertOrphanGuard::CERT.actor

    refuse = CertOrphanGuard.foreign_backend_message(db: "hub_test", backends: [{ pid: 1, application_name: "x" }])

    assert_includes refuse, "NOT a regression in your diff", "the default voice must stay the cert's"
  end

  # Every refusal a GATE can emit carries the release convention. Asserted over the whole
  # set rather than one sampled message: a new refusal path that forgot the line would
  # otherwise ship silently, and the one that forgot it is the one that ejects a task.
  def test_every_gate_refusal_carries_the_release_convention
    found = { pid: 4242, command: "sleep 60", started_at: "Tue Jul 14 11:05:12 2026" }
    gate = CertOrphanGuard::GATE
    messages = {
      concurrent: CertOrphanGuard.concurrent_message(cert_pid: 42, db: "hub_gate_test", voice: gate),
      unverifiable: CertOrphanGuard.unverifiable_message(pgid: 4242, found: found, db: "hub_gate_test",
                                                         root: "/tmp/x", voice: gate),
      # The three refusal paths PR #539 added in review. They are here because THIS is the
      # test that has to fail when someone adds a fourth and forgets the line — a set that
      # only covers the messages that existed when it was written is a set that quietly
      # stops asserting anything.
      unsafe_pgid: CertOrphanGuard.unverifiable_message(pgid: 1, subject: :unsafe_pgid, root: "/tmp/x",
                                                        db: "hub_gate_test", voice: gate),
      malformed: CertOrphanGuard.malformed_message(root: "/tmp/x", db: "hub_gate_test", voice: gate),
      reap_failed: CertOrphanGuard.reap_failed_message(pgid: 4242, lane: "gate:hub", db: "hub_gate_test",
                                                       voice: gate),
      foreign_backend: CertOrphanGuard.foreign_backend_message(db: "hub_gate_test",
                                                               backends: [{ pid: 7, application_name: "rails" }],
                                                               voice: gate),
      orphan: CertOrphanGuard.orphan_message(pgid: 4242, db: "hub_gate_test", voice: gate)
    }

    messages.each do |name, message|
      assert_includes message, "nothing to eject or revert",
                      "the gate's #{name} message must not read as a release regression"
      refute_includes message, "your diff", "the gate is not certifying a diff — that is the cert's voice"
    end
  end

  # The set above is only as good as its coverage, so PROVE it covers every message the
  # guard can actually emit. A new refusal path added tomorrow shows up here as a red test
  # rather than as a gate that silently ejects a good task over a leftover process.
  def test_the_voice_covers_every_message_the_guard_can_emit
    emitters = CertOrphanGuard.methods.grep(/_message\z/).sort

    emitters.each do |name|
      params = CertOrphanGuard.method(name).parameters

      assert_includes params, %i[key voice],
                      "CertOrphanGuard.#{name} does not take a voice: — a gate emitting it would " \
                      "speak the cert's words and read as a red suite"
    end
    assert_operator emitters.size, :>=, 7, "expected every refusal/notice builder to be discovered"
  end

  # --- [unit] the runlock outlives the workspace it guards ----------------------------

  # THE DESIGN, not a detail. CertProcess writes its runlock under the root it is handed.
  # For a cert that root is the agent worktree, which persists. A GATE workspace does
  # NOT: gate_workspace! `git worktree remove --force`s and rebuilds it whenever
  # `git reset --hard` fails — and a tree half-written by a conductor killed mid-suite is
  # EXACTLY when that happens. A runlock kept inside the workspace would be destroyed by
  # the next run, on the one path where an orphan is most likely: the detect half would
  # be silently dead precisely when it was needed.
  def test_the_gate_runlock_lives_outside_the_workspace_it_guards
    runlock_root = release_eval(%(gate_runlock_root("mcritchie-studio")))
    workspace = release_eval(%(Release::GateWorkspace.path(repo_path("mcritchie-studio"))))

    refute runlock_root.start_with?(workspace),
           "a runlock inside the gate workspace dies with it — `git worktree remove --force` " \
           "rebuilds that tree exactly when a conductor was killed mid-suite"
    assert Dir.exist?(runlock_root), "the runlock root must exist by the time a suite can be spawned"
  end

  # Keyed by repo AND role, so two repos' gates — or a repo's gate and ship roles — can
  # never read each other's lock and reason about a process group that was never theirs.
  # A shared lock here would make the guard confidently wrong, which is the failure mode
  # that matters.
  # Asserted on the LOCK FILE, not on the directory — because those are not the same claim.
  # CertOrphanGuard.lock_path resolves through `git rev-parse --absolute-git-dir`, so four
  # distinct roots INSIDE a git repo all resolve to ONE lock in that repo's git dir. Testing
  # that the roots differ would pass while the locks silently collapsed.
  def test_each_repo_and_role_gets_its_own_runlock_FILE
    locks = [
      %(gate_runlock_root("mcritchie-studio")),
      %(gate_runlock_root("turf-monster")),
      %(gate_runlock_root("mcritchie-studio", role: "ship")),
      %(gate_runlock_root("turf-monster", role: "ship"))
    ].map { |expr| CertOrphanGuard.lock_path(release_eval(expr)) }

    assert_equal 4, locks.uniq.size,
                 "a shared runlock file lets one repo's gate reason about another's process group " \
                 "— and reap it"
  end

  # The collapse, driven rather than argued: point the lock dir INSIDE a git repo and the
  # gate must refuse to build a runlock root at all, instead of quietly writing every repo's
  # lock to one file in that repo's git dir.
  def test_a_lock_dir_inside_a_git_repo_is_refused_not_silently_collapsed
    repo_lock_dir = File.join(@root, "inside-a-repo")
    FileUtils.mkdir_p(repo_lock_dir)
    system("git", "-C", repo_lock_dir, "init", "--quiet", out: File::NULL, err: File::NULL)

    script = <<~RUBY
      $PROGRAM_NAME = "release-eval"
      require #{RELEASE.dump}
      begin
        puts "ROOT:" + gate_runlock_root("mcritchie-studio")
      rescue SystemExit
        puts "ABORTED"
      end
    RUBY
    out = IO.popen(SessionEnv.neutralized("MCR_PRIMARY_LOCK_DIR" => repo_lock_dir),
                   [RUBY, "-e", script], err: %i[child out], &:read).to_s

    assert_includes out, "ABORTED",
                    "a lock dir inside a git repo collapses every gate's runlock onto one file — refuse it"
    assert_includes out, "nothing to eject or revert", "and refuse in the ENV class, never as a red suite"
  end

  # The guard is handed what it needs to NAME an orphan — the lane and the database — so
  # the next gate reports "gate:mcritchie-studio bin/rails test, holding hub_gate_test"
  # instead of a bare pgid the operator has to go identify by hand. Naming the cause is
  # the entire point of the 2026-07-12 gate program.
  def test_the_suite_guard_names_its_lane_and_its_database
    guard = release_eval(%(gate_suite_guard("mcritchie-studio", "bin/rails test")))

    assert_equal release_eval(%(gate_runlock_root("mcritchie-studio"))), guard["root"]
    assert_includes guard["lane"], "mcritchie-studio"
    assert_includes guard["lane"], "bin/rails test"
  end

  # --- [unit] the blast radius stays small --------------------------------------------

  # A --dry-run PLANS the gate; it must never spawn a suite. The guard sits behind the
  # dry-run short-circuit, so a preview cannot touch a process or a database.
  def test_a_dry_run_plans_the_gate_suite_and_never_spawns_it
    marker = File.join(@root, "spawned")
    ok = release_eval(
      %(sh("/bin/sh", "-c", "touch #{marker}", guard: { root: #{@root.dump}, lane: "x", db: nil }).last),
      argv: ["--dry-run"]
    )

    assert ok, "a dry-run reports success without running anything"
    refute File.exist?(marker), "a --dry-run must PLAN the gate suite, never spawn it"
  end

  # OPT-IN, and deliberately so: `pgroup: true` moves a child OUT of the terminal's
  # foreground process group, so a child that reads the TTY (an interactive `gem push`
  # OTP prompt) would take SIGTTIN and STOP. Only the long-running, non-interactive,
  # DB-holding gate suites opt in; every other sh() call on the ship path keeps the
  # spawn it always had. This pins that — a blanket change here would hang a deploy.
  def test_an_unguarded_sh_is_untouched_and_writes_no_runlock
    assert release_eval(%(sh("/bin/sh", "-c", "exit 0").last)), "an unguarded sh still runs its command"
    refute release_eval(%(sh("/bin/sh", "-c", "exit 3").last)), "an unguarded sh still reports failure"
    refute File.exist?(lock_path), "only a guarded gate suite writes a runlock"
  end

  # --- [integration] the wiring: the guard actually runs, and runs FIRST ---------------

  # ORDER IS THE FIX. `db:test:prepare` is the exact command that dies with
  # PG::ObjectInUse — it PURGES the gate DB — so a guard that runs after it has already
  # lost. This drives the REAL prepare_gate_workspace! with its collaborators recorded,
  # and asserts the orphan guard lands before the purge.
  #
  # Asserted, not declared. A comment claiming "the guard runs first" is exactly the kind
  # of thing that stays true in the file and false in the process after one refactor.
  def test_prepare_gate_workspace_runs_the_orphan_guard_before_it_purges_the_db
    order = release_eval(<<~EXPR.strip)
      begin
        $order = []
        def ensure_suite_bundle!(*, **) = $order << "bundle"
        def gate_orphan_guard!(*, **) = $order << "orphan_guard"
        def assert_private_gate_db!(*, **) = $order << "assert_private_db"
        def sh(*cmd, **) = ($order << cmd.join(" "); ["", true])
        prepare_gate_workspace!("mcritchie-studio", #{@root.dump})
        $order
      end
    EXPR

    assert_includes order, "orphan_guard", "prepare_gate_workspace! must run the orphan guard at all"
    purge = order.index { |step| step.include?("db:test:prepare") }

    refute_nil purge, "prepare_gate_workspace! must still run db:test:prepare"
    assert_operator order.index("orphan_guard"), :<, purge,
                    "the orphan guard must run BEFORE db:test:prepare — that is the command " \
                    "that dies with PG::ObjectInUse, so guarding after it is guarding nothing"
  end

  # --- [integration] PREVENT: the suite is reaped with the conductor -------------------

  # THE REGRESSION. Before the fix this test's suite survived the conductor and kept the
  # gate's test DB — reproduced live: PPID 1, and the next DROP DATABASE refused with
  # "is being accessed by other users".
  def test_a_terminated_conductor_reaps_its_gate_suite_instead_of_orphaning_it
    marker = File.join(@root, "suite.pid")
    conductor = spawn_conductor(<<~RUBY)
      sh("/bin/sh", "-c", "echo $$ > #{marker.dump[1..-2]}; sleep 60",
         guard: { root: #{@root.dump}, lane: "gate:mcritchie-studio bin/rails test", db: nil })
    RUBY
    suite = read_pid_file(marker)
    # The signal handlers go up immediately AFTER the runlock is written, so the lock
    # appearing is our proof the conductor is armed. TERM it before that and we would be
    # testing the default handler, not the fix — a flake that fails the guard for doing
    # its job.
    wait_for_runlock

    # The structural half of the fix: the suite leads a group of its OWN. Under the old
    # `system` spawn it sat in the conductor's group — which on a real run is the
    # SHELL's group, so there was not even a group the conductor could safely signal.
    assert_equal suite, pgid_of(suite), "the gate suite must lead its own process group"
    refute_equal pgid_of(conductor), pgid_of(suite), "the suite must not share the conductor's group"

    Process.kill("TERM", conductor)

    assert wait_until { !alive?(suite) },
           "the gate suite outlived the conductor — this is the orphan that wedges the NEXT gate " \
           "on <repo>_gate_test with PG::ObjectInUse"
  end

  # --- [integration] DETECT: a SIGKILLed conductor runs no handler ---------------------

  # Prevention can never be complete, so the next gate has to finish the job. The runlock
  # is what makes that possible — and what makes it SAFE, because it carries identity.
  def test_the_next_gate_reaps_the_orphan_a_sigkilled_conductor_left_behind
    marker = File.join(@root, "suite.pid")
    conductor = spawn_conductor(<<~RUBY)
      sh("/bin/sh", "-c", "echo $$ > #{marker.dump[1..-2]}; sleep 60",
         guard: { root: #{@root.dump}, lane: "gate:mcritchie-studio bin/rails test", db: nil })
    RUBY
    suite = read_pid_file(marker)
    wait_for_runlock # the lock is written just after the spawn — do not race it

    # SIGKILL: no trap runs, nothing is reaped. Exactly the case prevention cannot cover.
    Process.kill("KILL", conductor)

    assert wait_until { !alive?(conductor) }, "the conductor must be gone"
    assert alive?(suite), "a SIGKILLed conductor cannot reap anything — that is the premise"

    lock = read_lock

    assert_equal suite, lock["pgid"], "the runlock must NAME the group it stranded"
    refute_nil lock["pgid_started_at"], "a lock without identity can prove nothing and must never authorize a kill"

    # The next gate, arriving at the same workspace.
    verdict, notices = CertOrphanGuard.preflight(root: @root, env: NO_DB, voice: CertOrphanGuard::GATE)

    assert_equal :ok, verdict
    assert wait_until { !alive?(suite) }, "the next gate must reap the orphan it can prove is its own"
    assert_includes notices.join, "ORPHAN REAPED"
    assert_includes notices.join, "nothing to eject or revert", "reaping an orphan is an ENV event, not a red suite"
    refute File.exist?(lock_path), "a reaped orphan's runlock is a corpse — clear it"
  end

  # --- [integration] SAFETY: the direction that can hurt production --------------------

  # THE ONE THAT MATTERS ON THE SHIP PATH. A pgid is a recyclable integer and this runlock
  # is durable — it outlives reboots — so "the pgid in this lock now belongs to somebody
  # else" is an ORDINARY state, not an exotic one. Grading it on liveness ("some process
  # with this pgid is alive") is what made the cert's first cut TERM/KILL an unrelated
  # process and report "ORPHAN REAPED".
  #
  # So: a real live bystander, a lock that names its pgid, and a recorded start time that
  # does NOT match it. The guard must prove the process is not ours and walk away.
  def test_a_recycled_pgid_is_proven_innocent_and_never_killed
    bystander = spawn_bystander

    CertOrphanGuard.write_lock(@root, cert_pid: 999_998, pgid: bystander,
                               cert_started_at: "Mon Jan 1 00:00:00 2020",
                               pgid_started_at: "Mon Jan 1 00:00:00 2020", # NOT when it really started
                               lane: "gate:mcritchie-studio bin/rails test", db: "hub_gate_test")

    verdict, notices = CertOrphanGuard.preflight(root: @root, env: NO_DB, voice: CertOrphanGuard::GATE)

    assert_equal :ok, verdict, "a recycled pgid is a stale lock, not a blocker"
    assert alive?(bystander), "THE GUARD KILLED AN INNOCENT PROCESS — a reaper that guesses is worse than none"
    assert_includes notices.join, "STALE RUNLOCK"
    assert_includes notices.join, "NOT killing it"
    refute File.exist?(lock_path), "the stale lock is discarded so the gate proceeds"
  end

  # The same bystander, but now the lock carries NO identity at all (a lock written before
  # the guard recorded start times — or a truncated one). We cannot prove the group is
  # ours, and we cannot prove it isn't. The rule is absolute: kill only what you can PROVE
  # is yours. So the gate REFUSES, names the process, and lets a human decide — and it
  # says, in the same breath, that this is not grounds to eject anything from the release.
  def test_an_unprovable_group_is_refused_and_named_never_killed
    bystander = spawn_bystander

    CertOrphanGuard.write_lock(@root, cert_pid: 999_998, pgid: bystander,
                               cert_started_at: nil, pgid_started_at: nil,
                               lane: "gate:mcritchie-studio bin/rails test", db: "hub_gate_test")

    verdict, message = CertOrphanGuard.preflight(root: @root, env: NO_DB, voice: CertOrphanGuard::GATE)

    assert_equal :refuse, verdict
    assert alive?(bystander), "an unprovable process must never be killed"
    assert_includes message, "REFUSING"
    assert_includes message, bystander.to_s, "a refusal must NAME the process — that is the whole point"
    assert_includes message, "nothing to eject or revert"
  end

  # A group we must never address. `kill(sig, -1)` is not "process group 1" — POSIX
  # defines it as EVERY process the caller may signal, so one truncated lock file is all
  # that stands between a wedged gate and `kill -TERM -1` on the operator's whole session.
  # Structural refusal, asserted at the trigger.
  def test_the_reaper_refuses_to_address_a_group_it_must_never_signal
    refute CertOrphanGuard.reap_group(1, started_at: "Tue Jul 14 11:05:12 2026"),
           "pgid 1 addresses every process we own — never signal it"
    refute CertOrphanGuard.reap_group(0, started_at: "Tue Jul 14 11:05:12 2026"),
           "pgid 0 is our own group"
    refute CertOrphanGuard.reap_group(Process.getpgrp, started_at: "Tue Jul 14 11:05:12 2026"),
           "the gate must never reap the group it is itself running in"
  end
end
