# frozen_string_literal: true

# Tests for bin/lib/session_markers.rb — the ONE owner of the per-session
# narration-marker store: the READS bin/atomic-event and bin/atomic-capture-hook
# share (formerly byte-identical private copies), and the WRITES/DELETES that now
# go through its fail-closed choke point.
#
#   ruby -Itest test/lib/session_markers_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# Best-effort contract on the reads and on genuine IO failures: degrade to nil,
# never raise — narration must never block an agent's real work.
#
# THE GUARD UNDER TEST. Six writers (four copies in bin/atomic-event, one in
# bin/devops-shift, one in bin/statusline) each resolved the marker path by the
# same fallback — CLAUDE_PROJECTS_DIR else the real projects root — and none
# failed closed when a spawned test ran unpinned. Same family as the task-usage
# cost store (PR #525), and it leaked here for real. So with TASK_USAGE_SANDBOX
# armed, a MUTATION of this store must be (1) PINNED by CLAUDE_PROJECTS_DIR — the
# fallback is forbidden, not merely discouraged — and (2) OUTSIDE the operator's
# real <projects>/.agents, whatever pointed it there.
#
# NOTHING HERE TOUCHES THE REAL STORE. write_path is pure: it resolves and guards,
# and aborts BEFORE any IO. So the violation cases can be asserted against the
# real state dir without ever attempting the write they forbid. Allowed writes go
# to a tmpdir.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../support/session_env"

require File.expand_path("../../bin/lib/session_markers", __dir__)

class SessionMarkersTest < Minitest::Test
  SESSION = "e7c1a930-0000-4000-8000-abcdefabcdef"
  REAL = ProjectsRoot.default_projects_dir              # the operator's real projects root
  ON = { "TASK_USAGE_SANDBOX" => "1" }.freeze
  SUFFIXES = %w[.json .acting-agent .open-activity .open-span .activity-usage.json .devops-shift].freeze

  # ── [unit] read_context_marker ───────────────────────────────────────────────

  def test_unit_context_marker_reads_from_the_cwd
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate("task" => "t-1"))
      assert_equal({ "task" => "t-1" }, SessionMarkers.read_context_marker(dir))
    end
  end

  def test_unit_context_marker_walks_up_to_the_nearest_marker
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate("task" => "root"))
      nested = File.join(dir, "app", "models")
      FileUtils.mkdir_p(nested)
      assert_equal({ "task" => "root" }, SessionMarkers.read_context_marker(nested),
                   "a tool running in a subdir still resolves the worktree's marker")
    end
  end

  def test_unit_context_marker_is_nil_when_absent_or_blank_cwd
    Dir.mktmpdir { |dir| assert_nil SessionMarkers.read_context_marker(dir) }
    assert_nil SessionMarkers.read_context_marker(nil)
    assert_nil SessionMarkers.read_context_marker("   ")
  end

  def test_unit_context_marker_is_nil_on_invalid_json
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), "{nope")
      assert_nil SessionMarkers.read_context_marker(dir), "telemetry must never raise on a corrupt marker"
    end
  end

  # ── [unit] read_session_marker ───────────────────────────────────────────────

  def test_unit_session_marker_reads_the_per_session_file
    Dir.mktmpdir do |proj|
      write_session_marker(proj, "sess-1", "feature" => "f-1")
      assert_equal({ "feature" => "f-1" }, SessionMarkers.read_session_marker("sess-1", proj))
    end
  end

  def test_unit_session_marker_sanitizes_the_session_id
    Dir.mktmpdir do |proj|
      write_session_marker(proj, "abc123", "x" => 1)
      assert_equal({ "x" => 1 }, SessionMarkers.read_session_marker("abc/123", proj),
                   "path separators are stripped, never traversed")
    end
  end

  def test_unit_session_marker_is_nil_for_blank_id_or_missing_file
    Dir.mktmpdir do |proj|
      assert_nil SessionMarkers.read_session_marker("", proj)
      assert_nil SessionMarkers.read_session_marker(nil, proj)
      assert_nil SessionMarkers.read_session_marker("no-such", proj)
    end
  end

  # ── [unit] marker_path — ONE builder, so reads and writes cannot disagree ────
  #
  # `send`, because the builder is PRIVATE. An unguarded path builder sitting beside
  # a guarded write API is an attractive nuisance — bin/atomic-event reached for it
  # and raw-File.deleted the operator's live store with it (PR #549 review). Only
  # this module may name a marker now; the exported mutations (write/delete) enforce.
  # A test reaching in is a deliberate, greppable act, not an accident.

  def test_unit_marker_path_is_private_so_no_caller_can_hand_roll_a_raw_write
    refute_includes SessionMarkers.singleton_methods, :marker_path,
                    "marker_path must not be publicly callable — the footgun a caller cannot pick up " \
                    "beats the test that scolds them for picking it up"
    assert_raises(NoMethodError) { SessionMarkers.marker_path(SESSION, "/tmp/p", ".json") }
  end

  def test_unit_marker_path_is_pure_and_lives_under_the_sessions_dir
    assert_equal "/tmp/p/.agents/sessions/#{SESSION}.open-activity",
                 SessionMarkers.send(:marker_path, SESSION, "/tmp/p", ".open-activity")
  end

  # The session id is interpolated straight INTO a path. A traversing id must not
  # be able to steer a WRITE out of the sessions dir (the read side pins this too).
  def test_unit_a_traversing_session_id_cannot_escape_the_sessions_dir
    path = SessionMarkers.send(:marker_path, "../../../../etc/passwd", "/tmp/p", ".json")
    assert_equal "/tmp/p/.agents/sessions", File.dirname(path), "a traversing id stays in the sessions dir"
    refute_includes path, "/etc/", "path separators are stripped from the id, never traversed"
  end

  # ── [unit] rule 1: PINNED — the fallback that actually leaked ────────────────

  def test_unit_every_marker_write_aborts_when_the_store_is_unpinned
    SUFFIXES.each do |suffix|
      err = assert_aborts("#{suffix} must refuse to fall back to the real store") do
        SessionMarkers.write_path(SESSION, REAL, suffix, env: ON)
      end
      assert_includes err, "CLAUDE_PROJECTS_DIR is unset", "the abort must name the var to pin"
    end
  end

  # ── [unit] rule 2: OUTSIDE the real state dir, whatever pointed it there ─────

  def test_unit_a_pin_aimed_back_into_the_real_state_dir_still_aborts
    err = assert_aborts("a pin is not a sandbox if it points back at the real store") do
      SessionMarkers.write_path(SESSION, REAL, ".open-activity", env: ON.merge("CLAUDE_PROJECTS_DIR" => REAL))
    end
    assert_includes err, "real state dir", "the abort must say the destination IS the real store"
  end

  # A fixed-path "private" dir INSIDE the real .agents is not private from our own
  # tooling — rule 2 is a property of the PATH, not of the configuration.
  def test_unit_a_scratch_dir_nested_inside_the_real_agents_dir_aborts
    nested = File.join(REAL, ".agents", "scratch")
    assert_aborts("a scratch dir under the real .agents is still the real store") do
      SessionMarkers.write_path(SESSION, nested, ".devops-shift", env: ON.merge("CLAUDE_PROJECTS_DIR" => nested))
    end
  end

  # The separator-boundary trap: "<real>-scratch" is a SIBLING of the real root,
  # not inside it, and must NOT be refused. A naive prefix match false-positives.
  def test_unit_a_sibling_of_the_real_root_is_not_inside_it
    sibling = "#{REAL}-scratch"
    path = SessionMarkers.write_path(SESSION, sibling, ".json", env: ON.merge("CLAUDE_PROJECTS_DIR" => sibling))
    assert_includes path, "-scratch", "a sibling path is allowed — the guard compares on a separator boundary"
  end

  # ── [unit] the happy paths — a guard that fails these is worse than the bug ──

  # Sandbox OFF (a real agent session): the guard is a STRICT no-op, not a softer
  # check. Narration keeps exactly the contract it had — every marker it has always
  # written still resolves to the same path, and nothing aborts.
  #
  # A real session has NO TASK_USAGE_SANDBOX in its env; `=> nil` says exactly that
  # (the key is present and empty, so guard_env does not reach for the suite's own
  # armed process ENV — see guard_env's two-scope rule).
  OFF = { "TASK_USAGE_SANDBOX" => nil }.freeze

  def test_unit_a_real_agent_session_is_untouched_by_the_guard
    SUFFIXES.each do |suffix|
      assert_equal SessionMarkers.send(:marker_path, SESSION, REAL, suffix),
                   SessionMarkers.write_path(SESSION, REAL, suffix, env: OFF),
                   "an unsandboxed agent's #{suffix} write must be a strict no-op for the guard"
    end
  end

  def test_unit_an_explicitly_disarmed_sandbox_is_off
    %w[0 false no off].each do |off|
      assert SessionMarkers.write_path(SESSION, REAL, ".json", env: { "TASK_USAGE_SANDBOX" => off }),
             "#{off.inspect} must read as disarmed"
    end
  end

  def test_unit_a_sandboxed_run_pinned_at_a_tmpdir_writes_reads_and_deletes_normally
    Dir.mktmpdir do |dir|
      env = ON.merge("CLAUDE_PROJECTS_DIR" => dir)

      path = SessionMarkers.write(SESSION, dir, ".open-activity", "1720\n", env: env)
      assert_equal File.join(dir, ".agents", "sessions", "#{SESSION}.open-activity"), path
      assert_equal "1720\n", File.read(path), "a sandboxed-but-PINNED write must land normally"
      assert_equal "1720\n", SessionMarkers.read(SESSION, dir, ".open-activity")

      SessionMarkers.delete(SESSION, dir, ".open-activity", env: env)
      refute_path_exists path, "delete must remove the marker"
      assert_nil SessionMarkers.read(SESSION, dir, ".open-activity"), "a deleted marker reads as nil"
    end
  end

  # ── [unit] the load-bearing property: the guard is RESCUE-PROOF ──────────────

  # write and delete both `rescue StandardError => nil`, because narration is
  # non-fatal by contract. A guard that RAISED would be swallowed right there —
  # the write silently skipped, the guard reporting nothing, the leak carrying on
  # GREEN. That is the whole reason TaskUsageSandbox exits via `abort`: SystemExit
  # is not a StandardError, so it escapes those rescues by design.
  #
  # These two are the ONLY guard cases that reach real IO if the guard regresses,
  # so they aim at an INJECTED stand-in state dir (the tmpdir is "the real store"
  # as far as the guard is concerned). A broken fix then writes a tmpdir, not the
  # operator's narration store — the same reason TaskUsageSandbox's own rule-2
  # tests inject a root instead of firing at ~/projects.
  def test_unit_the_abort_is_not_swallowed_by_the_writers_own_rescue
    Dir.mktmpdir do |stand_in|
      env = ON.merge("CLAUDE_PROJECTS_DIR" => stand_in)

      assert_aborts("write's rescue must NOT swallow the sandbox abort") do
        SessionMarkers.write(SESSION, stand_in, ".acting-agent", "carl\n", env: env, state_dir: stand_in)
      end
      assert_aborts("delete's rescue must NOT swallow the sandbox abort") do
        SessionMarkers.delete(SESSION, stand_in, ".open-activity", env: env, state_dir: stand_in)
      end

      assert_empty Dir.glob(File.join(stand_in, ".agents", "sessions", "*")),
                   "the abort must land BEFORE any IO — a refused write creates nothing"
    end
  end

  # A genuine IO failure is a DIFFERENT thing and must still degrade to nil — the
  # best-effort contract narration depends on. (Sandbox off; .agents is a FILE, so
  # mkdir_p raises.) The guard must not have turned every hiccup into a crash.
  def test_unit_a_real_io_failure_still_degrades_to_nil
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agents"), "not a directory")
      assert_nil SessionMarkers.write(SESSION, dir, ".json", "{}", env: OFF),
                 "an IO error still degrades to nil — narration never blocks the agent"
    end
  end

  # ── [unit] guard_env — the two rules answer to DIFFERENT scopes ──────────────

  # THE PIN comes from the CALLER'S env. bin/atomic-event and bin/devops-shift take
  # an injectable env (AgentApi#env) and resolve projects_dir from it; a test that
  # constructs one with a tmpdir pin IS correctly pinned. Reading the process ENV
  # instead would abort it — a guard that fails closed on the happy path, which is
  # worse than the leak. (This regression was real: it aborted the whole
  # atomic_event_cli_test process on the first cut of this change.)
  def test_unit_the_pin_is_read_from_the_callers_env_not_the_process_env
    Dir.mktmpdir do |pinned|
      # Process ENV here has the sandbox ARMED and NO pin (the suite's own state).
      assert TaskUsageSandbox.active?, "the suite must run with the sandbox armed"

      path = SessionMarkers.write_path(SESSION, pinned, ".open-activity",
                                       env: { "CLAUDE_PROJECTS_DIR" => pinned })
      assert_includes path, pinned,
                      "an injected env that pins the store is correctly pinned — the guard must not " \
                      "re-read the process ENV and abort a legitimately sandboxed caller"
    end
  end

  # THE ARMING comes from the PROCESS ENV when the caller's env is silent about it.
  # Otherwise `AgentActivityCli.new(env: {})` resolves the REAL projects root with
  # the sandbox reading as OFF — and writes the operator's store. That is the very
  # hole this guard exists to close, so an env that merely OMITS the flag must not
  # be able to disarm it.
  def test_unit_an_injected_env_that_omits_the_flag_cannot_disarm_the_guard
    assert TaskUsageSandbox.active?, "the suite must run with the sandbox armed"

    assert_aborts("an env that omits TASK_USAGE_SANDBOX must inherit the PROCESS arming") do
      SessionMarkers.write_path(SESSION, REAL, ".acting-agent", env: {})
    end
  end

  # …but an env that names it EXPLICITLY still wins — that is the documented
  # opt-out (TASK_USAGE_SANDBOX=0 for a deliberate un-sandboxed run).
  def test_unit_an_env_that_names_the_flag_explicitly_wins
    assert SessionMarkers.write_path(SESSION, REAL, ".json", env: { "TASK_USAGE_SANDBOX" => "0" }),
           "an explicit off-switch in the caller's env disarms the guard"
  end

  # ── [unit] reads stay unguarded on purpose — a read cannot pollute ───────────

  def test_unit_reads_of_the_real_store_are_never_aborted
    assert_nil SessionMarkers.read_session_marker("no-such-session-#{SESSION}", REAL),
               "a read of an absent marker is nil, never an abort — reads cannot pollute"
  end

  private

  # `abort` raises SystemExit — NOT a StandardError — which is precisely why the
  # guard survives the callers' rescue. Assert on it, and capture the message so a
  # green run stays quiet. Returns stderr so the caller can assert on the REASON.
  #
  # $stderr is swapped by hand rather than via capture_io/capture_subprocess_io:
  # abort raises SystemExit straight out of the block, so those helpers never
  # reach their return value and hand back an empty string.
  def assert_aborts(message)
    original = $stderr
    $stderr = StringIO.new
    ex = assert_raises(SystemExit, message) { yield }
    refute_predicate ex.status, :zero?, "an aborted marker write must exit non-zero"
    $stderr.string
  ensure
    $stderr = original
  end

  def write_session_marker(projects_dir, session_id, attrs)
    dir = File.join(projects_dir, ".agents", "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{session_id}.json"), JSON.generate(attrs))
  end
end
