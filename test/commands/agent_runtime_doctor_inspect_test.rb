# frozen_string_literal: true

# Standalone test for the ONE doctor check that can see an unmanaged Codex install:
# `bin/agent-runtime doctor` delegating to `bin/codex-update inspect`. Run directly:
#   ruby -Itest test/commands/agent_runtime_doctor_inspect_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# THE DEFECT THIS GUARDS (verified against origin/accepted before the fix):
# doctor's only live-repaint signal was `[ -f ]` on a ZERO-BYTE SENTINEL touch-file
# (~/.codex/mcritchie-live-thread-title.enabled). `bin/codex-update inspect` — which
# reads the binary's SessionStart wire-struct arity and exits 2 when live-repaint
# support is missing — existed, was correct, and was called by NOTHING. So a raw
# `curl … install.sh` swapped the patched runtime for a stock one, the identity bar
# reverted to a thread UUID, and doctor still reported fine: the sentinel survives any
# reinstall, and stock and patched BOTH self-report the same `codex-cli` version, so
# neither the touch-file nor the version line can tell them apart.
#
# CRITICAL: every run sandboxes HOME, PATH and the installer so doctor never reads the
# operator's real ~/.codex, and never shells out to the real runtime installer.
#
# Tier split (backend shape → unit + integration):
#   test_unit_*        — doctor's contract with a STUBBED inspect (exit code → verdict)
#   test_integration_* — doctor over the REAL bin/codex-update, inspecting a real file

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"

class AgentRuntimeDoctorInspectTest < Minitest::Test
  ROOT         = File.expand_path("../..", __dir__)
  RUNTIME      = File.join(ROOT, "bin", "agent-runtime")
  CODEX_UPDATE = File.join(ROOT, "bin", "codex-update")

  # The exact byte patterns bin/codex-update's inspect_binary keys on. A patched
  # runtime carries the McRitchie marker; a stock one carries the 2-element wire
  # struct and no marker. Both report the same version — that is the whole problem.
  PATCHED_BYTES = "McRitchie session marker: threadName " \
                  "SessionStartHookSpecificOutputWire with 3 elements\n"
  STOCK_BYTES   = "SessionStartHookSpecificOutputWire with 2 elements\n"

  def setup
    @sandbox = Dir.mktmpdir("agent-runtime-doctor-inspect")
    @home    = File.join(@sandbox, "home")
    @stubbin = File.join(@sandbox, "stubbin")
    @codex_home = File.join(@home, ".codex")
    FileUtils.mkdir_p([@codex_home, @stubbin])

    @inspect_calls = File.join(@sandbox, "inspect-calls.log")
    @sentinel      = File.join(@codex_home, "mcritchie-live-thread-title.enabled")

    seed_clean_doctor_environment
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # ── fixture ───────────────────────────────────────────────────────────────
  #
  # Everything doctor checks BESIDES the runtime inspection is seeded green, so the
  # process exit code is attributable to the inspection alone.

  def seed_clean_doctor_environment
    # A Codex config carrying the thread-title status item.
    File.write(File.join(@codex_home, "config.toml"), <<~TOML)
      [tui]
      status_line = ["thread-title", "model-with-reasoning", "context-remaining"]
    TOML

    # User-level hooks referencing all three McRitchie hook entry points.
    File.write(File.join(@codex_home, "hooks.json"), <<~JSON)
      {
        "sessionStart": "#{ROOT}/bin/codex-session-title",
        "postToolUse": "#{ROOT}/bin/atomic-capture-hook",
        "stop": "#{ROOT}/bin/agent-activity close-open"
      }
    JSON

    # A fake ruby that satisfies both the path check and the version requirement.
    @ruby_dir = File.join(@sandbox, "rubybin")
    FileUtils.mkdir_p(@ruby_dir)
    write_exec(File.join(@ruby_dir, "ruby"), <<~SH)
      #!/bin/sh
      if [ "$1" = "-e" ] && [ "$2" = "print RUBY_VERSION" ]; then printf '3.3.11'; exit 0; fi
      exec #{RbConfig.ruby} "$@"
    SH

    # A login shell that resolves that ruby and nothing else.
    @fake_zsh = File.join(@sandbox, "fake-zsh")
    write_exec(@fake_zsh, <<~SH)
      #!/bin/sh
      if [ "$1" = "-lc" ]; then
        case "$2" in
          "command -v ruby") printf '#{File.join(@ruby_dir, "ruby")}\\n'; exit 0 ;;
        esac
        PATH="#{@ruby_dir}:$PATH" exec /bin/sh -c "$2"
      fi
      exec /bin/sh "$@"
    SH

    # A zprofile that prepends the required ruby path.
    @zprofile = File.join(@home, ".zprofile")
    File.write(@zprofile, "export PATH=\"#{@ruby_dir}:$PATH\"\n")

    # A runtime installer stub: `check` is green, so doctor's docs check never runs
    # the real installer against the operator's projects root.
    @installer = File.join(@sandbox, "installer-stub")
    write_exec(@installer, "#!/bin/sh\nexit 0\n")

    # A codex binary on PATH. Its --version is deliberately the SAME string a patched
    # runtime prints — the version line must never be what decides this.
    write_exec(File.join(@stubbin, "codex"), <<~SH)
      #!/bin/sh
      [ "$1" = "--version" ] && { printf 'codex-cli 0.144.3\\n'; exit 0; }
      exit 0
    SH
  end

  def write_exec(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end

  # A stand-in for bin/codex-update that records its argv and exits on demand.
  def stub_codex_update(exit_status)
    write_exec(File.join(@sandbox, "codex-update-stub"), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{@inspect_calls}
      printf 'binary: /fake/codex\\nhook:   stubbed\\n'
      exit #{exit_status}
    SH
  end

  def doctor_env(overrides = {})
    SessionEnv.neutralized({
      "HOME" => @home,
      "CODEX_HOME" => @codex_home,
      "PATH" => "#{@stubbin}:#{@ruby_dir}:#{ENV.fetch("PATH", "")}",
      "AGENT_RUNTIME_INSTALLER" => @installer,
      "AGENT_RUNTIME_ZSH" => @fake_zsh,
      "AGENT_RUNTIME_ZPROFILE" => @zprofile,
      "AGENT_RUNTIME_RUBY_PATH_PREFIX" => @ruby_dir,
      "AGENT_RUNTIME_BUNDLER_CHECK_CMD" => "true",
      "AGENT_RUNTIME_RAILS_BOOT_CMD" => "true",
      "BUNDLE_BIN_PATH" => nil,
      "BUNDLE_GEMFILE" => nil,
      "RUBYLIB" => nil,
      "RUBYOPT" => nil
    }.merge(overrides))
  end

  def run_doctor(overrides = {})
    Open3.capture3(doctor_env(overrides), RUNTIME, "doctor")
  end

  # ── unit ──────────────────────────────────────────────────────────────────

  def test_unit_doctor_actually_invokes_codex_update_inspect
    run_doctor("AGENT_RUNTIME_CODEX_UPDATE" => stub_codex_update(0))

    assert File.file?(@inspect_calls),
      "doctor never ran the Codex update guard at all — the detector being present " \
      "but UNCALLED is the whole defect this file guards"
    assert_equal ["inspect"], File.read(@inspect_calls).split("\n"),
      "doctor must ask the guard for `inspect` exactly once"
  end

  def test_unit_doctor_fails_when_inspect_reports_missing_support
    out, err, status = run_doctor("AGENT_RUNTIME_CODEX_UPDATE" => stub_codex_update(2))

    refute status.success?,
      "inspect exit 2 means the runtime cannot repaint the footer; doctor must FAIL\n" \
      "STDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_match(/^fail: Codex runtime lacks live thread-title repaint support/, err)
    assert_includes err, "bin/agent-runtime codex-update run",
      "the failure must name the command that restores the patched runtime"
  end

  def test_unit_doctor_passes_when_inspect_reports_support
    out, err, status = run_doctor("AGENT_RUNTIME_CODEX_UPDATE" => stub_codex_update(0))

    assert status.success?,
      "every other doctor check is seeded green, so a supported runtime must pass\n" \
      "STDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_match(/^ok: Codex runtime supports live thread-title repaint/, out)
    refute_includes err, "lacks live thread-title repaint support"
  end

  def test_unit_sentinel_alone_does_not_certify_repaint_support
    FileUtils.touch(@sentinel)
    out, err, status = run_doctor("AGENT_RUNTIME_CODEX_UPDATE" => stub_codex_update(2))

    assert_includes out, "ok: live Codex thread-title repaint sentinel enabled",
      "the sentinel is still reported — it records the operator's OPT-IN"
    refute status.success?,
      "THE REGRESSION: a present zero-byte sentinel used to be doctor's whole " \
      "live-repaint check, so an unmanaged install that reverted the binary read as " \
      "healthy. The sentinel must no longer be able to certify a stock runtime.\n" \
      "STDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_match(/^fail: Codex runtime lacks live thread-title repaint support/, err)
  end

  def test_unit_inspect_crash_warns_rather_than_failing
    out, err, status = run_doctor("AGENT_RUNTIME_CODEX_UPDATE" => stub_codex_update(1))

    assert status.success?,
      "only exit 2 means `support is missing`; any other non-zero exit is the guard " \
      "itself failing, which must warn rather than assert a revert\n" \
      "STDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_match(/^warn: Codex runtime inspection did not complete \(exit 1\)/, out)
    refute_includes err, "lacks live thread-title repaint support"
  end

  def test_unit_missing_codex_binary_does_not_fail_doctor
    FileUtils.rm_f(File.join(@stubbin, "codex"))
    # A PATH with NO codex anywhere — the operator's own PATH carries a real one, and
    # inheriting it would make this assertion pass for the wrong reason.
    codex_free_path = "#{@ruby_dir}:/usr/bin:/bin"
    assert_nil codex_free_path.split(":").find { |dir| File.executable?(File.join(dir, "codex")) },
      "fixture must not leak a codex binary onto PATH"

    out, err, status = run_doctor(
      "AGENT_RUNTIME_CODEX_UPDATE" => stub_codex_update(2),
      "PATH" => codex_free_path
    )

    assert status.success?,
      "a machine with no Codex installed (every CI runner) has nothing to revert; " \
      "doctor must warn, not fail\nSTDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_includes out, "warn: codex binary not found on PATH"
    refute File.file?(@inspect_calls),
      "with no codex on PATH there is no binary to inspect, so the guard must not run"
  end

  # ── integration ───────────────────────────────────────────────────────────
  #
  # doctor over the REAL bin/codex-update, reading a REAL file off disk. This is the
  # pairing the defect broke: the detector was correct in isolation the whole time.

  def fake_runtime(bytes)
    path = File.join(@sandbox, "codex-runtime-#{bytes.hash.abs}")
    write_exec(path, "#!/bin/sh\nexit 0\n# #{bytes}")
  end

  def test_integration_real_guard_fails_doctor_on_a_stock_runtime
    out, err, status = run_doctor(
      "AGENT_RUNTIME_CODEX_UPDATE" => CODEX_UPDATE,
      "CODEX_UPDATE_ACTIVE_BINARY" => fake_runtime(STOCK_BYTES)
    )

    refute status.success?,
      "the real guard inspects the real bytes: a 2-element wire struct with no " \
      "marker is a stock runtime and doctor must fail\nSTDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_match(/^fail: Codex runtime lacks live thread-title repaint support/, err)
  end

  def test_integration_real_guard_passes_doctor_on_a_patched_runtime
    out, err, status = run_doctor(
      "AGENT_RUNTIME_CODEX_UPDATE" => CODEX_UPDATE,
      "CODEX_UPDATE_ACTIVE_BINARY" => fake_runtime(PATCHED_BYTES)
    )

    assert status.success?,
      "a runtime carrying the McRitchie marker supports live repaint\n" \
      "STDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_match(/^ok: Codex runtime supports live thread-title repaint/, out)
  end

  def test_integration_guard_reads_the_binary_not_the_version_string
    stock   = fake_runtime(STOCK_BYTES)
    patched = fake_runtime(PATCHED_BYTES)

    stock_out,   = Open3.capture3(doctor_env("CODEX_UPDATE_ACTIVE_BINARY" => stock),
                                  CODEX_UPDATE, "inspect")
    patched_out, = Open3.capture3(doctor_env("CODEX_UPDATE_ACTIVE_BINARY" => patched),
                                  CODEX_UPDATE, "inspect")

    assert_includes stock_out,   "hook:   missing"
    assert_includes patched_out, "hook:   supported"

    stock_version   = `#{stock} --version 2>/dev/null`
    patched_version = `#{patched} --version 2>/dev/null`
    assert_equal stock_version, patched_version,
      "if the version line could tell these apart, doctor would not need to read the " \
      "binary — it cannot, which is why the sentinel check was undetectably wrong"
  end
end
