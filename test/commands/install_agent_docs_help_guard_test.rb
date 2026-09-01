# frozen_string_literal: true

# [integration] The ARGUMENT GUARD on bin/install-agent-docs and bin/agent-runtime,
# proven BY RECEIPT — a pinned sandbox that stays EMPTY, and a spy that never runs.
#
# THE DEFECT (/tasks/docs-installer-help-publishes). bin/install-agent-docs read its
# mode as `MODE="${1:-install}"` and dispatched on $1 ALONE. There was no `$#` check
# anywhere in the file, so every token past the first was discarded. The `-h|--help`
# arm therefore fired only for the BARE probe — and the bare probe was the one that
# was already safe. One position over:
#
#     bin/install-agent-docs install --help
#
# PUBLISHED FOR REAL. `--help` sat in $2, was dropped on the floor, and MODE stayed
# `install`: it copied AGENTS.md and CLAUDE.md into the projects root, mirrored every
# tracked skill into ~/.claude/skills and ~/.codex/skills, `rm -rf`'d the retired
# ones, rewrote the hooks in ~/.claude/settings.json, and appended the Ruby PATH
# block to ~/.zprofile — the operator's live login profile and editor settings, from
# a command whose entire purpose is to be the safe thing you type when you do not
# know what a command does.
#
# bin/agent-runtime was the same defect with a longer fuse: its install/repair/check
# arms `shift` and then `exec "$INSTALLER" <mode> "$@"`, handing `--help` straight
# down to the script above. `bin/agent-runtime install --help` published exactly the
# same set. Only ONE of its six arms — `doctor` — ever counted its arguments.
#
# WHY THAT IS WORSE THAN A LOCAL FILE WRITE. These targets are GLOBAL and shared:
# the installer's own header (bin/install-agent-docs:169-177) records that publishing
# from a worktree flips every concurrent session to "installed docs drift". So one
# agent probing a command it did not recognize reddens the preflight for every other
# agent on the machine, and there is no reflog behind ~/.zprofile.
#
# HOW THIS FILE PROVES THE FIX WITHOUT PUBLISHING ANYTHING. Every probe below runs
# with HOME and PROJECTS_DIR pinned into a throwaway tmp dir (and the ambient
# agent-session vars neutralized), exactly like test/commands/install_agent_skills_test.rb,
# which has run the REAL installer inside that sandbox for many releases. So the
# worst case — the guard having regressed — is a publish into a directory that is
# deleted in teardown. config/test_health.yml records what the un-sandboxed version
# of this mistake costs: two under-stubbed tests once ran bin/clean-artifacts and
# bin/archive-docs FOR REAL against a developer's machine.
#
# The verdict is a RECEIPT, in the shape test/integration/qa_server_argv_guard_test.rb
# established, because "it printed usage" is not evidence that it did not also act:
#
#   1. A PINNED SPY THAT STAYS SILENT. bin/agent-runtime's whole mutation is
#      `exec "$INSTALLER"`, so AGENT_RUNTIME_INSTALLER is pointed at a stub that
#      appends its argv to a log. A guarded probe leaves NO LOG FILE AT ALL.
#   2. A PINNED SANDBOX THAT STAYS EMPTY. For the installer itself the spy is the
#      filesystem: every path under HOME and PROJECTS_DIR is listed before and
#      after, and a guarded probe leaves that list byte-identical.
#   3. A CONTROL DRIVING A REAL CALL THROUGH THE SAME SPIES. Both receipts above are
#      satisfied by a script that is simply broken, so each is paired with an
#      unguarded command line that MUST light the same spy up. Without the control,
#      "the log is empty" and "the logger is unwired" are the same observation —
#      which is exactly how a green manifest once certified a fully unguarded
#      script (finding-e429a953ff23).
#
#   ruby -Itest test/commands/install_agent_docs_help_guard_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class InstallAgentDocsHelpGuardTest < Minitest::Test
  ROOT      = File.expand_path("../..", __dir__)
  INSTALLER = File.join(ROOT, "bin", "install-agent-docs")
  RUNTIME   = File.join(ROOT, "bin", "agent-runtime")

  # The exact probes the task record measured as mutating, kept as data so the
  # names in the failure output are the command lines an operator would type.
  PUBLISHING_PROBES = [
    %w[install --help],
    %w[install -h]
  ].freeze

  def setup
    @sandbox  = Dir.mktmpdir("install-agent-docs-help-guard")
    @home     = File.join(@sandbox, "home")
    @projects = File.join(@sandbox, "projects")
    FileUtils.mkdir_p(@home)

    # A login shell that sources the SANDBOX profile, never the operator's.
    @fake_zsh = File.join(@sandbox, "fake-zsh")
    File.write(@fake_zsh, <<~SH)
      #!/bin/sh
      if [ "$1" = "-lc" ]; then
        shift
        [ -f "$HOME/.zprofile" ] && . "$HOME/.zprofile"
        exec /bin/sh -c "$1"
      fi
      exec /bin/sh "$@"
    SH
    FileUtils.chmod("+x", @fake_zsh)

    @spy_log = File.join(@sandbox, "installer-spy.log")
    @spy     = write_spy(File.join(@sandbox, "spy-installer"), @spy_log)

    @codex_update_log = File.join(@sandbox, "codex-update-spy.log")
    @codex_update_spy = write_spy(File.join(@sandbox, "spy-codex-update"), @codex_update_log)
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # A stand-in that records the argv it was called with. Its ABSENCE is the
  # assertion: a guarded probe must never reach the exec, so the log is never
  # created at all (rather than created-and-empty, which a truncating bug fakes).
  def write_spy(path, log)
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{log}"
      exit 0
    SH
    FileUtils.chmod("+x", path)
    path
  end

  def sandbox_env(extra = {})
    SessionEnv.neutralized(
      {
        "HOME" => @home,
        "PROJECTS_DIR" => @projects,
        # Default is /etc/codex/requirements.toml — a REAL path outside the sandbox.
        "CODEX_REQUIREMENTS_PATH" => File.join(@sandbox, "etc", "codex", "requirements.toml"),
        "AGENT_RUNTIME_ZPROFILE" => File.join(@home, ".zprofile"),
        "AGENT_RUNTIME_ZSH" => @fake_zsh
      }.merge(extra)
    )
  end

  def run_installer(*argv, env: {})
    Open3.capture3(sandbox_env(env), INSTALLER, *argv)
  end

  # bin/agent-runtime with BOTH of its exec targets replaced by recording spies, so
  # no probe here can reach the real installer even if every guard in the file is gone.
  def run_runtime(*argv, env: {})
    Open3.capture3(
      sandbox_env({
        "AGENT_RUNTIME_INSTALLER" => @spy,
        "AGENT_RUNTIME_CODEX_UPDATE" => @codex_update_spy
      }.merge(env)),
      RUNTIME, *argv
    )
  end

  # Every path the installer could have published, as one sorted list. This is the
  # spy for bin/install-agent-docs: the sandbox IS the operator's home and projects
  # root, so "the list did not change" is the whole no-publish claim.
  def published_paths
    [@home, @projects].flat_map { |dir| Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH) }
                      .reject { |path| File.basename(path) == "." || File.basename(path) == ".." }
                      .sort
  end

  # ── the publish receipt: the guard is proven by an EMPTY sandbox ────────────

  # THE REGRESSION TEST. Before the fix, each of these left the sandbox holding
  # AGENTS.md, CLAUDE.md, both skills trees and a rewritten .zprofile.
  def test_integration_help_after_a_mode_publishes_nothing
    PUBLISHING_PROBES.each do |argv|
      before = published_paths

      out, err, status = run_installer(*argv)

      assert_equal before, published_paths,
                   "`bin/install-agent-docs #{argv.join(' ')}` PUBLISHED to the sandbox home/projects " \
                   "root. A help probe must copy no doc, mirror no skill, and rewrite no profile.\n" \
                   "new paths: #{(published_paths - before).join(', ')}"
      refute status.success?,
             "`#{argv.join(' ')}` exited 0. bin/release.rb:7030 reads this script's exit status as " \
             "\"the installed agent docs were synced\" and bin/session-preflight:478 reads `check`'s " \
             "as \"no docs drift\" — a probe that establishes neither must not answer with success"
      assert_equal 1, status.exitstatus, "help exits 1 on this script (see the exit-code note in bin/install-agent-docs)"
      assert_match(/Usage: bin\/install-agent-docs/, err + out, "a help probe must still print the usage it asked for")
    end
  end

  # A trailing token this script cannot account for is refused BEFORE anything is
  # published — the task's own acceptance line.
  def test_integration_unaccounted_for_argument_refuses_without_publishing
    before = published_paths

    _out, err, status = run_installer("install", "--dry-run")

    assert_equal before, published_paths, "a refused command line must publish nothing"
    assert_equal 2, status.exitstatus, "an unaccounted-for argument exits 2"
    assert_match(/unrecognized argument/, err,
                 "the refusal must name itself the way the other guarded shell scripts do")
    assert_match(/--dry-run/, err, "…and quote the token it could not account for")
    assert_match(/PUBLISHES NOTHING|published nothing|NOTHING was published/i, err,
                 "the refusal must say plainly that it did not act")
  end

  # THE CONTROL. Everything above is also true of a script that is simply broken, so
  # this drives a real publish through the SAME observation and proves it fires.
  def test_integration_control_a_real_install_lights_up_the_sandbox
    before = published_paths

    out, err, status = run_installer("install")

    assert status.success?, "the control install must still succeed:\n#{err}\n#{out}"
    published = published_paths - before
    refute_empty published, "the sandbox observation sees nothing even for a REAL install — it is " \
                            "reading the wrong directories, and every no-publish assertion above is vacuous"

    assert_includes published, File.join(@projects, "AGENTS.md")
    assert_includes published, File.join(@projects, "CLAUDE.md")
    assert published.any? { |p| p.include?(File.join(".claude", "skills")) },
           "a real install mirrors the user-global Claude skills — the probes above prove that did NOT happen"
  end

  # The read-only modes are guarded too, and they are the ones safe to probe even if
  # the guard has regressed — `manifest` is a declared dry run and `check` only cmp's.
  # This is the execution that proves the SCRIPT is guarded rather than merely
  # carrying a guard somewhere in its text.
  def test_integration_read_only_modes_answer_help_without_running
    { %w[manifest --help] => /WRITE\t/, %w[check --help] => /^OK: |out of date/ }.each do |argv, ran_marker|
      out, err, status = run_installer(*argv)

      assert_equal 1, status.exitstatus, "`#{argv.join(' ')}` must answer help, not run the mode"
      refute_match ran_marker, out,
                   "`#{argv.join(' ')}` RAN #{argv.first} instead of answering the help flag — the " \
                   "argument was dropped exactly the way `install --help` used to drop it"
      assert_match(/Usage: bin\/install-agent-docs/, err + out)
    end
  end

  # The bare forms keep working. A guard that refuses the real command lines would
  # pass every assertion above and break the fresh-machine bringup.
  def test_integration_bare_modes_still_work
    assert_equal 0, run_installer("manifest").last.exitstatus, "manifest is a dry run and must still run"
    assert_equal 1, run_installer("help").last.exitstatus, "the `help` mode word still answers help"
    assert_equal 64, run_installer("bogus").last.exitstatus,
                 "an unknown MODE keeps its established 64 (EX_USAGE) — pinned by " \
                 "test/commands/install_agent_skills_test.rb"
  end

  # ── the exec receipt: bin/agent-runtime never reaches the installer ─────────

  def test_integration_runtime_help_never_execs_the_installer
    [%w[install --help], %w[repair --help], %w[check --help], %w[install -h]].each do |argv|
      _out, err, status = run_runtime(*argv)

      refute File.exist?(@spy_log),
             "`bin/agent-runtime #{argv.join(' ')}` EXEC'd the installer — the flag was handed " \
             "straight down and the docs/skills/profile were published"
      assert_equal 1, status.exitstatus, "help exits 1: bin/ecosystem-build:488 reads 0 from this script as \"installed\""
      assert_match(/Usage:/, err, "a help probe must print usage on stderr, since its exit is non-zero")
    end
  end

  def test_integration_runtime_refuses_an_unaccounted_for_argument
    _out, err, status = run_runtime("install", "--dry-run")

    refute File.exist?(@spy_log), "a refused command line must not reach the installer"
    assert_equal 2, status.exitstatus
    assert_match(/unrecognized argument/, err)
    assert_match(/--dry-run/, err)
  end

  # THE CONTROL for the spy. Proves the log would have appeared.
  def test_integration_control_a_real_runtime_install_execs_the_installer
    _out, err, status = run_runtime("install")

    assert status.success?, "the control must still exec the installer:\n#{err}"
    assert File.exist?(@spy_log),
           "the installer spy never fired even for a REAL `agent-runtime install` — it is unwired, " \
           "and every \"never exec'd\" assertion above is vacuous"
    assert_match(/install/, File.read(@spy_log), "the spy records the mode it was handed")
  end

  # The BARE form, which `command="${1:-install}"` exists to support — and which was
  # DEAD. Every arm opened with an unconditional `shift`; `shift` returns non-zero
  # when there are no positional parameters, and the script runs under `set -e`, so
  # `bin/agent-runtime` with no arguments exited 1 having installed nothing and said
  # nothing. It went unnoticed because every documented caller (bin/ecosystem-build,
  # README, house-burn-down) passes an explicit subcommand.
  def test_integration_bare_runtime_still_means_install
    _out, err, status = run_runtime

    assert status.success?, "bare `bin/agent-runtime` must mean `install`, not exit 1 silently:\n#{err}"
    assert File.exist?(@spy_log), "…and must actually reach the installer"
  end

  # The ONE arm that is a declared pass-through stays one. `codex-update [args...]`
  # forwards to bin/codex-update, which owns its own --help; swallowing that flag
  # here would be a blanket guard wearing a per-arm guard's clothes.
  def test_integration_codex_update_still_forwards_its_arguments
    _out, err, status = run_runtime("codex-update", "--help")

    assert status.success?, "codex-update is a pass-through and must keep forwarding:\n#{err}"
    assert File.exist?(@codex_update_log), "the codex-update arm must still exec its target"
    assert_match(/--help/, File.read(@codex_update_log),
                 "the forwarded argv must arrive intact — bin/codex-update owns its own help")
  end

  # doctor was the ONE arm that already counted its arguments. It keeps refusing, and
  # now answers a help probe as help rather than as a usage error.
  def test_integration_doctor_answers_help_without_inspecting
    _out, err, status = run_runtime("doctor", "--help")

    assert_equal 1, status.exitstatus
    assert_match(/Usage:/, err)
    refute_match(/^ok: |^fail: /, err, "doctor must not run its inspection for a help probe")
  end
end
