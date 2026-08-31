# frozen_string_literal: true

# THE BOOBY-TRAPPED `op` — proof that 1Password read ATTRIBUTION cannot cost the
# ecosystem its 1Password FALLBACKS.
#
#   bin/rails test test/commands/op_meter_fallback_test.rb
#
# WHY THIS LANE EXISTS AND THE UNIT TESTS ARE NOT ENOUGH. bin/lib/op-meter.sh is
# shell. No Ruby source scan can read it, no mocked method can prove a process
# was not spawned, and its failure mode is not an exception — it is a script that
# quietly stops working, or worse, one that works until the day `op` is down.
# Every consumer wired to the meter has a working fallback for a rate-limited or
# absent `op` today; the ecosystem ran a FULL DAY of 1Password outage on those
# fallbacks. Metering may observe that path. It may not alter it.
#
# So the technique is the crude one, and the crude one is right: put an `op` on
# PATH that EXITS 127 and never answers, then run the real scripts and read what
# they say. A trap that is first on PATH also catches a bare `op` the wiring
# missed — which a stubbed constant never could.
#
# THE SECOND AXIS is the shim's own absence. `op_metered` is defined by a sourced
# file, and a sourced file can be missing (a partial checkout, a bad rsync, an
# older worktree on a shared PATH). Every consumer therefore declares a fallback
# definition, and the tests below DELETE the shim to prove that fallback runs the
# binary rather than dying on "command not found".

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "securerandom"
require "digest"
require_relative "../support/session_env"
require_relative "../../lib/task_usage_sandbox"

class OpMeterFallbackTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "op-reads.log")
    @trap_calls = File.join(@dir, "trap-calls.log")
    @bindir = File.join(@dir, "bin")
    FileUtils.mkdir_p(@bindir)

    # THE TRAP. Records that it ran, answers nothing, exits 127 — the shell's
    # "command not found", i.e. the shape of an `op` that is not there.
    write(File.join(@bindir, "op"), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{@trap_calls}
      exit 127
    SH

    # A WORKING op, for the shim-deleted lane below. Proving a fallback works
    # needs an observable SUCCESS: an absent `op_metered` and an absent `op`
    # produce the SAME refusal from every consumer, so a test that only reads the
    # error message cannot tell a working fallback from a missing one.
    write(File.join(@bindir, "op-ok"), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{@trap_calls}
      printf '%s' 'THE-VALUE'
    SH
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def write(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  # PATH with the trap FIRST, so a bare `op` anywhere in a consumer hits it.
  def trapped_env(overrides = {})
    SessionEnv.neutralized({
      "PATH" => "#{@bindir}:#{ENV.fetch('PATH', '/usr/bin:/bin')}",
      "MCR_OP_READS_LOG" => @log,
      # bin/secret pins its binary and so ignores PATH — the trap must be handed
      # to it explicitly, or the test talks to the operator's LIVE vault and
      # spends real quota to assert a fallback.
      "SECRET_OP_BIN" => File.join(@bindir, "op"),
      "HOME" => @dir
    }.merge(overrides))
  end

  def rows
    return [] unless File.exist?(@log)

    File.readlines(@log).map { |l| l.chomp.split("\t") }
  end

  # Run a repo script from a COPY of bin/ so a test may delete the shim without
  # touching the working tree.
  def isolated_bin
    root = File.join(@dir, "repo")
    FileUtils.mkdir_p(root)
    FileUtils.cp_r(File.join(ROOT, "bin"), root)
    FileUtils.mkdir_p(File.join(root, "lib"))
    FileUtils.cp(File.join(ROOT, "lib", "task_usage_sandbox.rb"), File.join(root, "lib"))
    File.join(root, "bin")
  end

  # ── the trap: every consumer still behaves ───────────────────────────────────

  # bin/secret must fail with ITS OWN diagnostic — the one that tells an operator
  # what to do — not with a shell error from inside the metering wrapper.
  def test_integration_secret_still_fails_loudly_when_op_is_absent
    _out, err, status = Open3.capture3(
      trapped_env, File.join(ROOT, "bin", "secret"), "agents-studio", "agent.heroku", "api key"
    )

    refute status.success?, "an absent op must still be a failure"
    assert_includes err, "secret:", "the script's own diagnostic must survive the wrapper"
    refute_includes err, "op_metered", "the metering wrapper must never appear in a user-facing error"
    refute_includes err, "command not found"
  end

  # The whole point of the trap being FIRST ON PATH: bin/secret pins its own
  # binary at /opt/homebrew/bin/op, so on a machine without one it exits at its
  # own `[ -x "$OP" ]` guard. Either way the contract is the same — its own
  # message, and no crash from the meter.
  def test_integration_secret_reports_its_own_guard_not_a_wrapper_error
    _out, err, status = Open3.capture3(
      trapped_env, File.join(ROOT, "bin", "secret"), "agents-studio", "agent.heroku"
    )

    refute status.success?
    assert_match(/1Password CLI not found|not authenticated|could not read/, err,
                 "the failure must be one of bin/secret's OWN three, not a shell error: #{err}")
  end

  # bin/gh-app-git-credential is the hot path — it runs on every push and fetch.
  # An absent op must produce its documented refusal and, above all, NO CREDENTIAL
  # ON STDOUT. git reads stdout; a wrapper that leaked a partial line there would
  # be a credential bug, not a metering bug.
  def test_integration_git_credential_helper_refuses_cleanly_with_op_absent
    out, err, status = Open3.capture3(
      trapped_env("GH_APP_OP_BIN" => File.join(@bindir, "op")),
      File.join(ROOT, "bin", "gh-app-git-credential"), "get", stdin_data: "protocol=https\nhost=github.com\n"
    )

    refute status.success?
    refute_includes out, "password=", "no credential may reach stdout when the read failed"
    assert_includes err, "1Password read failed", "the helper's own diagnostic must survive"
  end

  # And the attempt is ATTRIBUTED. This is the feature: a burst of failing reads
  # during an outage is exactly the thing nobody could account for on 2026-08-31.
  def test_integration_a_failed_attempt_is_still_attributed_to_the_caller
    Open3.capture3(
      trapped_env("GH_APP_OP_BIN" => File.join(@bindir, "op")),
      File.join(ROOT, "bin", "gh-app-git-credential"), "get", stdin_data: "protocol=https\nhost=github.com\n"
    )

    refute_empty rows, "an op invocation that failed is still an op invocation"
    caller, action, outcome = rows.first.values_at(1, 2, 3)
    assert_equal "gh-app-git-credential", caller,
                 "attribution must name the COMMAND — the entire point of this log"
    assert_equal "item get", action
    assert_equal "fail:127", outcome
  end

  # ── the shim's own absence ───────────────────────────────────────────────────

  # Delete bin/lib/op-meter.sh and the consumers must still run. The fallback
  # definition in each script is what makes metering OPTIONAL rather than a new
  # hard dependency on the credential path.
  # MEASURED, and it is why this test looks the way it does. Asserting on the
  # error message here was VACUOUS: bin/secret runs its op calls with stderr
  # redirected to /dev/null, so deleting the fallback definition produced the
  # SAME "op is not authenticated" refusal — a lie that reads exactly like the
  # truth. The mutant survived. The honest assertion is that `op` was actually
  # REACHED, so this drives the SUCCESS path with a working stub: no fallback
  # definition, no execution, no value.
  def test_integration_secret_still_reaches_op_with_the_shim_deleted
    bindir = isolated_bin
    FileUtils.rm_f(File.join(bindir, "lib", "op-meter.sh"))

    out, err, status = Open3.capture3(
      trapped_env("SECRET_OP_BIN" => File.join(@bindir, "op-ok")),
      File.join(bindir, "secret"), "agents-studio", "agent.heroku"
    )

    assert status.success?, "with the shim gone, bin/secret must still reach op and answer: #{err}"
    assert_equal "THE-VALUE", out, "the fallback definition must run the binary, not swallow the call"
    refute_includes err, "op_metered: command not found"
  end

  def test_integration_git_credential_helper_runs_with_the_shim_deleted
    bindir = isolated_bin
    FileUtils.rm_f(File.join(bindir, "lib", "op-meter.sh"))

    out, err, status = Open3.capture3(
      trapped_env("GH_APP_OP_BIN" => File.join(@bindir, "op")),
      File.join(bindir, "gh-app-git-credential"), "get", stdin_data: "protocol=https\nhost=github.com\n"
    )

    refute status.success?
    refute_includes out, "password="
    refute_includes err, "op_metered: command not found"

    # THE LOAD-BEARING ASSERTION. "1Password read failed" is what the helper says
    # BOTH when op refused and when op was never run at all, so it cannot tell a
    # working fallback from a missing one. The trap counts EXECUTIONS; without
    # the fallback definition there are none.
    assert_equal 1, File.readlines(@trap_calls).length,
                 "with no shim at all, the helper must still EXECUTE op directly — a fallback that " \
                 "silently skips the call produces this same error message"
  end

  # ── the meter costs no reads ─────────────────────────────────────────────────

  # The shell half of constraint 1, observed rather than argued. The trap counts
  # EVERY execution of `op`; the helper makes exactly one before it gives up, so
  # any extra execution is the meter's, and there must be none.
  def test_integration_the_shim_executes_op_exactly_once_per_metered_call
    Open3.capture3(
      trapped_env("GH_APP_OP_BIN" => File.join(@bindir, "op")),
      File.join(ROOT, "bin", "gh-app-git-credential"), "get", stdin_data: "protocol=https\nhost=github.com\n"
    )

    calls = File.exist?(@trap_calls) ? File.readlines(@trap_calls) : []
    assert_equal 1, calls.length,
                 "the helper's first read failed and it gave up, so exactly ONE op execution is correct. " \
                 "More means the meter spawned its own — an instrument consuming what it measures."
    assert_equal 1, rows.length, "and exactly one row recorded it"
  end

  # ── caller attribution in BOTH shells ────────────────────────────────────────

  # THE BUG THIS PINS. zsh's FUNCTION_ARGZERO rebinds $0 to the FUNCTION NAME
  # inside a function body, so reading `${0##*/}` in the recorder logged
  # `op_meter_record` for every zsh caller. bin/setup-1pass-token is #!/bin/zsh —
  # so the single attribution this whole feature exists to produce was the one it
  # silently got wrong. Both shells are asserted because fixing one is easy and
  # fixing one is what happened the first time.
  # NO `skip` HERE, DELIBERATELY. The obvious shape for this is one test per
  # shell, skipped when the shell is missing — and that is what it was, until it
  # crossed two ratchets at once (config/test_health.yml's skip-call-site count
  # and config/rails_lane.yml's skipped-test ceiling). Both were RIGHT to fire: a
  # skip is a test switched off while keeping its name, and CI runners have no
  # zsh, so the zsh lane — the ONLY lane that covers the bug this pins — was
  # switched off on exactly the machine that matters. Raising the ceilings would
  # have bought a green ratchet and kept the hole.
  #
  # So the coverage is split by what each half can honestly promise:
  #   * bash runs EVERYWHERE, so it is asserted unconditionally here.
  #   * zsh is asserted too WHEN PRESENT — an extra assertion inside this test,
  #     never a separate skippable one.
  #   * the STATIC test below pins the mechanism on every platform, zsh or not.
  def test_integration_the_calling_script_is_attributed_in_every_shell
    shells = ["bash"] + (system("command -v zsh >/dev/null 2>&1") ? ["zsh"] : [])

    shells.each do |shell|
      FileUtils.rm_f(@log)
      script = File.join(@dir, "pretend-consumer")
      write(script, <<~SH)
        #!/bin/#{shell}
        . "#{File.join(ROOT, 'bin', 'lib', 'op-meter.sh')}"
        op_metered "#{File.join(@bindir, 'op')}" read "op://$V/$I/f" >/dev/null 2>&1 || true
      SH

      Open3.capture3(trapped_env, script)

      assert_equal "pretend-consumer", rows.first[1],
                   "#{shell} must attribute the read to the SCRIPT, not to a function or the shim"
    end
  end

  # THE BUG, PINNED STATICALLY — and this is the half that runs on CI.
  #
  # zsh's FUNCTION_ARGZERO (on by default) rebinds $0 to the FUNCTION NAME inside
  # a function body. bin/setup-1pass-token is #!/bin/zsh, so reading `${0##*/}`
  # in the recorder logged `op_meter_record` as the caller for every zsh consumer
  # — the single attribution this whole feature exists to produce was the one it
  # silently got wrong, and a log full of confident useless rows is worse than no
  # log. The fix is to capture the caller ONCE at source time, at top level,
  # where bash and zsh disagree about nothing.
  #
  # Asserted on the SOURCE because the runtime proof needs a zsh that CI does not
  # have. The rule is exact and mechanical: $0 may be read at top level (that is
  # the capture), never inside a function body.
  def test_unit_the_shim_never_reads_dollar_zero_inside_a_function
    path = File.join(ROOT, "bin", "lib", "op-meter.sh")
    lines = File.readlines(path)
    first_fn = lines.index { |l| l =~ /^\s*[a-z_]\w*\(\)\s*\{/ }

    refute_nil first_fn, "the shim must define functions for this rule to mean anything"

    offenders = lines[first_fn..].each_with_index.filter_map do |line, i|
      next if line.strip.start_with?("#")
      next unless line =~ /\$\{?0/

      "bin/lib/op-meter.sh:#{first_fn + i + 1}: #{line.strip}"
    end

    assert_empty offenders,
                 "$0 is read inside a function body. Under zsh that is the FUNCTION NAME, not the calling " \
                 "script, so every zsh consumer (bin/setup-1pass-token) is misattributed. Capture the " \
                 "caller at top level instead:\n  " + offenders.join("\n  ")
  end

  # The other half of the same claim: the top-level capture must actually handle
  # zsh. Without this, deleting the ZSH_ARGZERO branch would leave the rule above
  # satisfied (no $0 in a function) while silently attributing every zsh caller
  # to the SHIM's own path, because a sourced file's $0 is the file in zsh.
  def test_unit_the_caller_capture_handles_zsh_argzero
    src = File.read(File.join(ROOT, "bin", "lib", "op-meter.sh"))
    code = src.lines.reject { |l| l.strip.start_with?("#") }.join

    assert_includes code, "ZSH_ARGZERO",
                    "the top-level capture must use ZSH_ARGZERO — in zsh a SOURCED file's $0 is the file " \
                    "itself, so plain $0 would attribute every zsh read to op-meter.sh"
    assert_includes code, "OP_METER_CALLER",
                    "the explicit override must survive — git spawns the credential helper by absolute path"
  end

  # ── LAYER 3 containment: the shim may not touch the operator's real store ────

  # bin/lib/op-meter.sh is bash, so its containment is OBSERVED, not scanned —
  # the same lane state_store_containment_test.rb runs for bin/statusline, and
  # for the same reason: a shell-out, a subprocess and a bash write can all hide
  # from a Ruby source scan, but none of them can hide from the bytes not
  # changing.
  #
  # SAFE AND NON-VACUOUS. "Unpinned" does not mean it writes the operator's real
  # store from here: with HOME pinned at a tmpdir, an unguarded shim lands in
  # <tmp>/projects/.agents. That is what contains the blast — and it is also why
  # the assertion is made THERE, on seeded decoys and a per-file fingerprint,
  # rather than on the real store the child could never reach anyway. A test that
  # cannot fail is not evidence.
  def test_integration_the_shim_cannot_touch_the_store_when_armed_and_unpinned
    id = "op-meter-containment-#{SecureRandom.uuid}"
    home = File.join(@dir, "home")
    root = File.join(home, "projects", ".agents") # where an UNPINNED shim falls back to
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "op-reads.log"), "decoy\n")
    File.write(File.join(root, "#{id}.decoy"), "decoy")

    before = fingerprint(root)

    script = File.join(@dir, "unpinned-consumer")
    write(script, <<~SH)
      #!/bin/bash
      . "#{File.join(ROOT, 'bin', 'lib', 'op-meter.sh')}"
      op_metered "#{File.join(@bindir, 'op')}" read "op://v/i/f" >/dev/null 2>&1 || true
      echo RAN
    SH

    out, _err, _status = Open3.capture3(
      SessionEnv.neutralized(
        "PATH" => "#{@bindir}:#{ENV.fetch('PATH', '/usr/bin:/bin')}",
        "TASK_USAGE_SANDBOX" => "1", # armed
        "CLAUDE_PROJECTS_DIR" => nil, # UNPINNED — the exact leak this family closes
        "MCR_OP_READS_LOG" => nil,
        "HOME" => home
      ), script
    )

    assert_includes out, "RAN",
                    "the consumer must still RUN when the meter refuses — a refusal that also breaks the " \
                    "caller would just get the guard reverted"
    assert_equal before, fingerprint(root),
                 "bin/lib/op-meter.sh MUTATED the store while sandboxed and unpinned"

    assert_empty Dir.glob(File.join(TaskUsageSandbox.real_state_dir, "**", "*#{id}*"), File::FNM_DOTMATCH),
                 "the child reached the operator's real state dir"
  end

  def test_integration_the_shim_records_normally_when_armed_but_pinned
    script = File.join(@dir, "pinned-consumer")
    write(script, <<~SH)
      #!/bin/bash
      . "#{File.join(ROOT, 'bin', 'lib', 'op-meter.sh')}"
      op_metered "#{File.join(@bindir, 'op')}" read "op://v/i/f" >/dev/null 2>&1 || true
    SH

    Open3.capture3(trapped_env("TASK_USAGE_SANDBOX" => "1"), script)

    assert_equal 1, rows.length,
                 "a PINNED destination is provable, so recording must continue — failing closed on the " \
                 "happy path would be worse than the leak it closes"
  end

  def fingerprint(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .select { |f| File.file?(f) }
       .to_h { |f| [f, Digest::SHA256.file(f).hexdigest] }
  end
end
