# frozen_string_literal: true

# OutboundSeams — the NETWORK FLOOR for any test that spawns a bin/ command.
#
# SessionEnv (its sibling, required below) neutralizes the ambient agent-SESSION
# vars a child would inherit. This file closes the other half of the same hole:
# the child's ability to REACH THE OUTSIDE WORLD — the production task board, the
# `gh` CLI, 1Password, Heroku, and any git remote over ssh/https.
#
# WHY THIS EXISTS (measured 2026-08-14, not hypothesised):
#
#   * bin/task resolves `ENV.fetch("TASK_API_BASE", "https://mcritchie.studio")`.
#     PRODUCTION IS THE DEFAULT. Any spawned bin/ script that shells bin/task with
#     no pin therefore authenticates against — and writes to — the live board.
#     test/commands/agent_worktree_test.rb pinned nothing at all, and
#     bin/agent-worktree shells the hub's real bin/task on the mascot/bind paths.
#   * a leaked `gh` call on this machine does not fail quietly. The operator's gh
#     keyring token is invalid, so the refusal classifies as an AUTH failure, which
#     arms GhAuthRetry.mint (bin/lib/gh_auth_retry.rb) → bin/gh-token → `op read`
#     against LIVE 1Password → a POST to api.github.com that MINTS A REAL App
#     installation token. test/lib/ship_test.rb records that chain firing once
#     already. So an unsealed test run can mint production credentials, and neither
#     that nor the board write is a test FAILURE — both are silent successes.
#
# THE RULE THIS FILE ENCODES: containment is a property of the HARNESS, not a
# convention each test remembers. A seam that lives in six per-test helpers is one
# forgotten call site — or one fixture edit — away from re-opening, which is
# exactly how both leaks above survived review. So a harness that spawns bin/
# commands builds its child env through `OutboundSeams.env`, once, in its SHARED
# spawn helper.
#
#   def command_env(extra = {})
#     OutboundSeams.env({ "PROJECTS_DIR" => @projects_dir }.merge(extra))
#   end
#
# AND THE PINS ARE PROVEN, NEVER ASSUMED. A pin nobody exercised is advice: it
# looks present, it is never on the path, and the leak continues underneath it.
# So every stub here RECORDS the call it refused (`OutboundSeams.calls`), which
# lets each harness assert a POSITIVE RECEIPT — "the sealed binary is the one the
# child actually ran" — instead of the absence of a symptom. The precedent is
# test/lib/dor_check_browser_evidence_test.rb, which pins a loopback sink AND
# drives the dangerous shape through it to prove the sink received the request.
#
# TWO KINDS OF PIN, because there are two kinds of reach:
#
#   FAIL-CLOSED (the board)  — TASK_API_BASE/ATOMIC_CAPTURE_URL point at an
#     unroutable loopback port. Nothing listens, so a board call is refused
#     instantly and locally. Same fail-closed choice, and the same spelling, as
#     test/lib/release_cli_test.rb's UNROUTABLE_API_BASE, which was added after
#     that suite filed 39 real findings into the operator's live triage inbox.
#   SEALED BINARIES (gh, op, heroku, ssh) — a recording stub of each sits FIRST on
#     the child's PATH, and the named env seams (CI_STATUS_GH_BIN,
#     GH_AUTH_TOKEN_BIN, GIT_SSH_COMMAND) point at the same stubs so a call that
#     bypasses PATH is caught too. Each logs its argv and exits non-zero WITH NO
#     STDOUT — deliberately: an empty body is not auth-shaped, so it cannot arm
#     the GhAuthRetry mint chain described above. GH_AUTH_TOKEN_BIN is sealed as
#     well, so even a mint that IS somehow armed never reaches 1Password.
#
# A TEST MAY STILL OVERRIDE ANY OF IT. `env` merges the caller's hash last, so a
# test that plants its own fake `gh` on PATH, or points TASK_API_BASE at a stub
# server it owns, wins — as it should. What it can no longer do is reach the real
# thing by FORGETTING.
#
# Standalone by construction, exactly like SessionEnv: the test/lib/*.rb and
# test/commands/*.rb harnesses are bare `minitest/autorun` with no Rails and no
# test_helper, so this file must load with neither.
#
# LOAD ORDER, deliberately one-way: session_env.rb requires THIS file (the same
# way it already requires task_usage_sandbox.rb), because that is the one file
# every subprocess-spawning test already loads — which is what makes the arming
# below universal instead of opt-in. So this file must NOT require session_env
# back. `env` names SessionEnv at CALL time, by which point it is defined.
require "fileutils"
require "tmpdir"

module OutboundSeams
  # An unroutable loopback base. Port 1 is reserved and nothing binds it, so a
  # board call fails with ECONNREFUSED in microseconds rather than hanging or —
  # the case this exists to prevent — succeeding against production.
  UNROUTABLE = "http://127.0.0.1:1"

  # The executables a test child must never resolve to the real binary. `ssh` and
  # `git-askpass` are here for git's two reach paths (a remote over ssh, and an
  # https remote prompting for a credential); the rest are the outbound CLIs the
  # bin/ scripts shell directly.
  # `task-cli` is not a PATH lookup: it is the stub a harness points a named
  # task-binary seam at (AGENT_WORKTREE_TASK_BIN), so a board read through the
  # hub's CLI is refused AND recorded rather than merely misrouted.
  SEALED_COMMANDS = %w[gh gh-token op heroku ssh git-askpass task-cli].freeze

  module_function

  # The stub directory, built once per test process. Not a Dir.mktmpdir BLOCK: the
  # stubs must outlive the call that created them (every subprocess for the rest of
  # the run reads them), so it is cleaned at exit instead.
  def bin_dir
    @bin_dir ||= build_bin_dir
  end

  # Where the stubs record what they refused. PID-scoped so a forked parallel test
  # worker reads its OWN receipts and never another worker's.
  def log_path
    File.join(bin_dir, "outbound-calls-#{Process.pid}.log")
  end

  # Every outbound call the stubs intercepted, newest last, as "<command> <argv>".
  def calls
    File.exist?(log_path) ? File.readlines(log_path, chomp: true) : []
  end

  # The intercepted calls naming `command` — the receipt a harness asserts on.
  def calls_to(command)
    calls.select { |line| line.split(" ", 2).first == command.to_s }
  end

  # Forget the receipts. Call before the run whose calls you are about to assert.
  def reset!
    File.delete(log_path) if File.exist?(log_path)
  end

  def stub(name)
    File.join(bin_dir, name.to_s)
  end

  # PATH with the sealed stubs in FRONT of the ambient one, so `gh` resolves here
  # and not in /opt/homebrew/bin.
  def sealed_path
    [bin_dir, ENV.fetch("PATH", "")].reject { |part| part.to_s.empty? }.join(File::PATH_SEPARATOR)
  end

  # The floor itself. Kept separate from `env` so a harness that builds its child
  # env some other way can still read (and assert on) the exact pins.
  def defaults
    {
      "PATH" => sealed_path,
      "TASK_API_BASE" => UNROUTABLE,
      "ATOMIC_CAPTURE_URL" => UNROUTABLE,
      "CI_STATUS_GH_BIN" => stub("gh"),
      "GH_AUTH_TOKEN_BIN" => stub("gh-token"),
      "GIT_SSH_COMMAND" => stub("ssh"),
      "GIT_ASKPASS" => stub("git-askpass"),
      "GIT_TERMINAL_PROMPT" => "0",
      "OUTBOUND_SEAM_LOG" => log_path,
      # THE SESSION-MARKER STORE, pinned for every child built from this env.
      #
      # Several bin/ entry points now publish a presence claim through SessionMarkers
      # (bin/lib/presence_claim.rb, and bin/lib/release_presence.rb for the release
      # conductors). That store is FAIL-CLOSED: test/support/task_usage_sandbox.rb arms
      # TASK_USAGE_SANDBOX for this whole PROCESS, every child inherits it, and a child
      # that then resolves an UNPINNED CLAUDE_PROJECTS_DIR does not degrade — it ABORTS,
      # naming the var. That guard is right and must stay loud: it exists because an
      # unpinned store once wrote ~1.9 BILLION tokens into the operator's live cost data.
      #
      # So the pin belongs on the harness, never in the writer — a presence writer taught
      # to shrug off a sandbox violation is the leak wearing a rescue. And it belongs HERE
      # rather than in each harness, for this file's own stated reason: every leak it
      # exists to close was in a file whose author believed it was already sealed. A
      # caller that wants its own store still wins via `overrides`.
      "CLAUDE_PROJECTS_DIR" => marker_store
    }
  end

  # One throwaway marker store per test process, cleaned up with the rest.
  def marker_store
    @marker_store ||= begin
      dir = Dir.mktmpdir("outbound-seams-markers")
      register_cleanup(dir)
      dir
    end
  end

  # The child env: the session scrub, the network floor, then the caller's
  # overrides ON TOP (a test that pins its own fake or sink still wins).
  def env(overrides = {})
    SessionEnv.neutralized(defaults.merge(overrides.to_h { |key, value| [key.to_s, value] }))
  end

  # ARM THE FLOOR FOR THIS PROCESS, so it is enforcement rather than documentation.
  #
  # `OutboundSeams.env` covers the harnesses that adopt it. The harnesses that do
  # NOT adopt it are the whole problem — every leak this file exists to close was in
  # a file whose author believed it was already sealed. So requiring this file also
  # pins the two board URLs and the token broker in the TEST PROCESS, which every
  # child inherits (Process.spawn semantics) whether its harness ever heard of this
  # module or not. Same idea as TaskUsageSandboxEnv one file over.
  #
  # BUT NOT THE SAME OPERATOR. The sandbox arms with `||=`, which keeps whatever
  # the shell already exported. That is wrong here, and measurably so: an AGENT
  # SHELL EXPORTS `ATOMIC_CAPTURE_URL=https://mcritchie.studio` for its own
  # narration, so `||=` would have preserved production as the value and armed
  # nothing at all — the ambient value IS the leak. Hence a plain assignment, plus
  # an EXPLICIT opt-out (OUTBOUND_SEAMS=off) for the rare deliberate live run.
  # A test that wants a different destination still wins: this runs once at require
  # time, long before any test body sets ENV or builds a child env hash.
  #
  # WHY THESE THREE AND NOT THE REST: a var is armable here only if it is inert
  # in-process and harmless to inherit. These are — nothing under app/ or lib/ reads
  # either board URL, and no test asserts GhAuthRetry's default broker against
  # ambient ENV (it passes an explicit env). PATH is deliberately NOT armed: sealing
  # `gh` process-wide would reach in-process helpers and the test runner's own
  # tooling, so it stays a per-harness pin via `env` above, where a test that wants
  # the real thing can say so.
  #
  # (The assignments live at the very bottom of this module: they CALL the helpers
  # below, so they cannot run before those are defined.)
  OPT_OUT = %w[0 false no off].freeze

  def armed?
    !OPT_OUT.include?(ENV.fetch("OUTBOUND_SEAMS", "").to_s.strip.downcase)
  end

  def build_bin_dir
    dir = Dir.mktmpdir("outbound-seams")
    register_cleanup(dir)
    SEALED_COMMANDS.each do |name|
      path = File.join(dir, name)
      File.write(path, stub_body(name))
      FileUtils.chmod(0o755, path)
    end
    dir
  end

  # Delete the stub directory when the RUN is over — which is not the same moment as
  # "when this process exits", and getting that wrong deletes the stubs before a
  # single test uses them.
  #
  # `minitest/autorun` runs the whole suite from inside an at_exit hook it registers
  # at require time. at_exit handlers run LIFO, so an at_exit registered LATER — as
  # this file's would be, since a harness requires minitest first — fires BEFORE the
  # suite does. The first version of this file did exactly that, and every stub was
  # gone by the time a test spawned one (ENOENT, caught by
  # OutboundSeamsTest#test_unit_a_sealed_command_records_its_argv_and_refuses).
  # Minitest.after_run runs inside that same hook, AFTER the suite, which is the
  # moment actually wanted. at_exit remains the fallback for a non-minitest loader.
  def register_cleanup(dir)
    remover = -> { FileUtils.remove_entry(dir, true) }
    if defined?(Minitest) && Minitest.respond_to?(:after_run)
      Minitest.after_run(&remover)
    else
      at_exit(&remover)
    end
  end

  # A recording refusal. /bin/sh so it costs nothing to spawn, and so it works as
  # GIT_SSH_COMMAND (which git execs through a shell).
  #
  # NO STDOUT, ON PURPOSE. CiStatus classifies a gh failure by its OUTPUT, and an
  # auth-shaped one triggers the token mint. An empty body is not auth-shaped, so
  # the stub refuses without arming anything.
  def stub_body(name)
    <<~SH
      #!/bin/sh
      # Recording refusal planted by test/support/outbound_seams.rb.
      # This is a TEST child: reaching the real #{name} would mean reaching production.
      if [ -n "${OUTBOUND_SEAM_LOG:-}" ]; then
        printf '%s %s\\n' "#{name}" "$*" >> "$OUTBOUND_SEAM_LOG"
      fi
      exit 1
    SH
  end

  # THE ARMING (see the block comment above build_bin_dir). Last in the module so
  # every helper it calls is already defined.
  if armed?
    # THREE spellings of "the board", not one. bin/task and bin/dor-check read
    # TASK_API_BASE; the narration clients (bin/agent-activity, bin/atomic-event,
    # bin/lib/agent_api.rb) read ATOMIC_CAPTURE_URL; bin/devops-cycle and
    # bin/review-autopilot read TASK_BOARD_URL. All three default to
    # https://mcritchie.studio, so pinning one and calling the board contained is
    # the mistake this list exists to prevent.
    ENV["TASK_API_BASE"] = UNROUTABLE
    ENV["ATOMIC_CAPTURE_URL"] = UNROUTABLE
    ENV["TASK_BOARD_URL"] = UNROUTABLE
    ENV["GH_AUTH_TOKEN_BIN"] = stub("gh-token")

    # RubyGems' COMPACT INDEX — a fourth outbound surface, added 2026-08-15.
    #
    # bin/release.rb waits for a just-published gem to appear on
    # index.rubygems.org before committing the consumer lock bump (the publish→CI
    # race: bundler exits 7 installing a version the index does not carry yet).
    # That wait reaches the network and POLLS, so an un-seamed test does not merely
    # touch the internet — it BLOCKS. Measured before this line existed: the
    # release CLI suite went from ~4.5 minutes to over an hour, because every test
    # driving the non-dry bump with a stub gem name got a 404 and then waited out
    # the full RELEASE_GEM_POLL_TIMEOUT.
    #
    # "yes" rather than an unroutable host on purpose: the seam answers the
    # QUESTION ("is it indexed?"), so the default must be the non-blocking answer.
    # Pointing it at an unroutable host would reproduce the hang it exists to
    # prevent. A test that wants the waiting or refusing path sets it to "no"
    # explicitly, which is exactly what test/lib/release_cli_gem_await_test.rb does.
    ENV["RELEASE_GEM_INDEXED"] = "yes"
  end
end
