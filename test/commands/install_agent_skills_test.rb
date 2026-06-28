# frozen_string_literal: true

# Standalone test for bin/install-agent-docs' user-global skills install/check
# (no Rails needed — the script is pure bash, so we shell out to it). Run directly:
#   ruby -Itest test/commands/install_agent_skills_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# CRITICAL: every run sandboxes HOME and PROJECTS_DIR into a throwaway tmp dir, so
# the installer copies into the sandbox and NEVER touches the operator's real
# ~/.claude/skills, ~/.codex/skills, or projects-root AGENTS.md/CLAUDE.md.
#
# Tier split (backend shape → unit + integration):
#   test_unit_*        — isolated source/CLI-contract assertions (no install round trip)
#   test_integration_* — the install↔check round trip across the filesystem boundary

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

class InstallAgentSkillsTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  SCRIPT   = File.join(ROOT, "bin", "install-agent-docs")
  RUNTIME  = File.join(ROOT, "bin", "agent-runtime")
  WRAP_SRC = File.join(ROOT, "docs", "agents", "skills", "wrap", "SKILL.md")

  def setup
    @sandbox  = Dir.mktmpdir("install-agent-skills")
    @home     = File.join(@sandbox, "home")
    @projects = File.join(@sandbox, "projects")
    FileUtils.mkdir_p(@home)
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # Run bin/install-agent-docs with HOME + PROJECTS_DIR pinned into the sandbox.
  def run_installer(mode, env = {})
    Open3.capture3(
      default_env.merge(env),
      SCRIPT, mode
    )
  end

  def default_env
    {
      "HOME" => @home,
      "PROJECTS_DIR" => @projects,
      "CODEX_REQUIREMENTS_PATH" => installed_codex_requirements
    }
  end

  def run_runtime(*args, env: {})
    Open3.capture3(
      default_env.merge(env),
      RUNTIME, *args
    )
  end

  def installed_claude_wrap
    File.join(@home, ".claude", "skills", "wrap", "SKILL.md")
  end

  def installed_codex_wrap
    File.join(@home, ".codex", "skills", "wrap", "SKILL.md")
  end

  def installed_wraps
    [installed_claude_wrap, installed_codex_wrap]
  end

  def installed_settings
    File.join(@home, ".claude", "settings.json")
  end

  def installed_codex_config
    File.join(@home, ".codex", "config.toml")
  end

  def installed_codex_hooks
    File.join(@home, ".codex", "hooks.json")
  end

  def installed_codex_requirements
    File.join(@sandbox, "etc", "codex", "requirements.toml")
  end

  def jq_available?
    system("command -v jq >/dev/null 2>&1")
  end

  # ── unit ──────────────────────────────────────────────────────────────────

  def test_unit_wrap_skill_present_in_canonical_source
    assert File.file?(WRAP_SRC),
      "the /wrap skill must live in the tracked canonical source dir " \
      "(docs/agents/skills/wrap/SKILL.md) so it survives a wiped machine"
    body = File.read(WRAP_SRC)
    assert_match(/^name:\s*wrap\s*$/, body, "canonical /wrap must carry its skill frontmatter")
  end

  def test_unit_wrap_skill_is_shared_between_claude_and_codex
    body = File.read(WRAP_SRC)
    assert_match(/Claude/, body, "the shared wrap skill should still support Claude")
    assert_match(/Codex/, body, "the shared wrap skill should explicitly support Codex")
    assert_match(/AGENTS\.md/, body, "active-doc routing should point at the shared agent entry")
    refute_match(/per `CLAUDE\.md`/, body,
      "the shared wrap skill must not route active-doc work solely through CLAUDE.md")
  end

  def test_unit_wrap_degrades_gracefully_without_personal_trimmer
    body = File.read(WRAP_SRC)
    # The personal trimmer is NOT platform-owned, so /wrap must guard on its
    # presence (an `[ -x ... ]` test) rather than invoke it unconditionally.
    assert_includes body, "trim-index",
      "step 2 should still reference the trim-index action"
    assert_match(/\[\s*-x\s+"?[^"]*trim-index"?\s*\]/, body,
      "step 2 must guard the trimmer behind a presence check so it never hard-fails when absent")
  end

  def test_unit_unknown_mode_is_rejected
    _out, err, status = run_installer("bogus")
    refute status.success?, "an unknown mode must be a non-zero failure"
    assert_equal 64, status.exitstatus, "unknown mode should exit 64 (usage error)"
    assert_match(/unknown mode/i, err)
  end

  def test_unit_agent_runtime_unknown_command_is_rejected
    _out, err, status = run_runtime("bogus")
    refute status.success?, "an unknown runtime command must fail"
    assert_equal 64, status.exitstatus
    assert_match(/unknown command/i, err)
  end

  # ── integration ───────────────────────────────────────────────────────────

  def test_integration_install_lands_skill_in_home_agent_skills
    _out, err, status = run_installer("install")
    assert status.success?, "install failed: #{err}"
    installed_wraps.each do |path|
      assert File.file?(path),
        "install must place the /wrap skill at #{path}"
      assert_equal File.read(WRAP_SRC), File.read(path),
        "the installed skill must be a byte-for-byte copy of the canonical source"
    end
  end

  def test_integration_does_not_install_top_level_readme
    # Only files inside a <name>/ skill dir are skills; a top-level README in the
    # canonical source documents the tree and must NOT land in an agent skills dir.
    run_installer("install")
    [".claude", ".codex"].each do |runtime_dir|
      refute File.exist?(File.join(@home, runtime_dir, "skills", "README.md")),
        "a top-level docs/agents/skills/README.md must not be mirrored as a skill"
    end
  end

  def test_integration_install_is_idempotent
    run_installer("install")
    first = installed_wraps.to_h { |path| [path, File.read(path)] }
    _out, err, status = run_installer("install")
    assert status.success?, "second install failed: #{err}"
    first.each do |path, body|
      assert_equal body, File.read(path),
        "re-running install must be a no-op on an already-current skill"
    end
  end

  def test_integration_check_passes_after_install
    run_installer("install")
    out, _err, status = run_installer("check")
    assert status.success?, "check should pass immediately after a clean install"
    assert_match(%r{OK:.*\.claude/skills/wrap/SKILL\.md}, out,
      "check should report the Claude skill as matching")
    assert_match(%r{OK:.*\.codex/skills/wrap/SKILL\.md}, out,
      "check should report the Codex skill as matching")
  end

  def test_integration_check_fails_when_any_local_skill_modified
    installed_wraps.each do |path|
      run_installer("install")
      File.write(path, "#{File.read(path)}\nlocal drift\n")
      _out, err, status = run_installer("check")
      refute status.success?, "check must fail when a local skill drifts from the source"
      assert_includes err, "ERROR: #{path} is out of date with #{WRAP_SRC}"
    end
  end

  def test_integration_check_fails_when_any_local_skill_missing
    [
      File.join(@home, ".claude", "skills", "wrap"),
      File.join(@home, ".codex", "skills", "wrap")
    ].each do |path|
      run_installer("install")
      FileUtils.rm_rf(path)
      _out, err, status = run_installer("check")
      refute status.success?, "check must fail when a tracked skill is missing locally"
      assert_match(%r{ERROR:.*skills/wrap/SKILL\.md}, err)
    end
  end

  def test_integration_agent_runtime_install_delegates_to_installer
    out, err, status = run_runtime("install")

    assert status.success?, "agent-runtime install failed: #{err}"
    assert_includes out, "Installed:"
    assert File.file?(installed_claude_wrap)
    assert File.file?(installed_codex_wrap)
  end

  def test_integration_agent_runtime_doctor_passes_after_install
    run_runtime("install")
    out, err, status = run_runtime("doctor")

    assert status.success?, "agent-runtime doctor failed:\nSTDOUT:\n#{out}\nSTDERR:\n#{err}"
    assert_includes out, "ok: marker provider executable"
    assert_includes out, "ok: runtime installer executable"
    assert_includes out, "ok: installed agent docs and skills match tracked sources"
    assert_includes out, "ok: Codex config includes thread-title status item"
    assert_match(/ok: Codex (managed requirements|user hooks) include McRitchie .*hook/, out)
  end

  def test_integration_global_hooks_use_runtime_root_override
    skip "jq is required for settings hook install" unless jq_available?

    runtime_root = "/stable/mcritchie-studio"
    _out, err, status = run_installer("install", "AGENT_DOCS_RUNTIME_ROOT" => runtime_root)

    assert status.success?, "install failed: #{err}"
    settings = JSON.parse(File.read(installed_settings))
    assert_equal "#{runtime_root}/bin/statusline", settings.dig("statusLine", "command")
    commands = settings.fetch("hooks").fetch("SessionStart").flat_map { |entry| entry.fetch("hooks").map { |hook| hook.fetch("command") } }
    assert_includes commands, "#{runtime_root}/bin/task session-mascot"
    refute commands.any? { |command| command.include?("/.worktrees/") }

    config = File.read(installed_codex_config)
    assert_match(/status_line = \[[^\n]*"thread-title"/, config)
    assert_match(/terminal_title = \[[^\n]*"thread-title"/, config)

    refute File.exist?(installed_codex_hooks),
      "Codex mascot startup must be managed, not a user hook that requires /hooks review"

    requirements = File.read(installed_codex_requirements)
    assert_includes requirements, "# BEGIN McRitchie Codex mascot managed hook"
    assert_includes requirements, %(managed_dir = "#{runtime_root}")
    assert_includes requirements, "[[hooks.SessionStart]]"
    assert_includes requirements, 'matcher = "startup|resume"'
    assert_includes requirements, "[[hooks.PostToolUse]]"
    assert_includes requirements, 'matcher = "Bash"'
    assert_includes requirements, %(command = "#{runtime_root}/bin/codex-session-title")
    assert_includes requirements, 'statusMessage = "Setting session mascot"'
  end

  def test_integration_install_prunes_stale_worktree_session_hooks
    skip "jq is required for settings hook install" unless jq_available?

    FileUtils.mkdir_p(File.dirname(installed_settings))
    File.write(installed_settings, JSON.pretty_generate(
      "hooks" => {
        "SessionStart" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => "/repo/.worktrees/docs-gate-cleanup/bin/task session-mascot"
              }
            ]
          }
        ]
      }
    ))
    FileUtils.mkdir_p(File.dirname(installed_codex_hooks))
    File.write(installed_codex_hooks, JSON.pretty_generate(
      "hooks" => {
        "SessionStart" => [
          {
            "matcher" => "startup|resume",
            "hooks" => [
              {
                "type" => "command",
                "command" => "/repo/.worktrees/docs-gate-cleanup/bin/codex-session-title"
              }
            ]
          }
        ],
        "PostToolUse" => [
          {
            "matcher" => "Bash",
            "hooks" => [
              {
                "type" => "command",
                "command" => "/repo/.worktrees/docs-gate-cleanup/bin/codex-session-title"
              }
            ]
          }
        ]
      }
    ))

    runtime_root = "/stable/mcritchie-studio"
    _out, err, status = run_installer("install", "AGENT_DOCS_RUNTIME_ROOT" => runtime_root)

    assert status.success?, "install failed: #{err}"
    commands = JSON.parse(File.read(installed_settings)).fetch("hooks").fetch("SessionStart").flat_map do |entry|
      entry.fetch("hooks").map { |hook| hook.fetch("command") }
    end
    refute commands.any? { |command| command.include?("/.worktrees/") }
    assert_includes commands, "#{runtime_root}/bin/task session-mascot"

    codex_hooks = JSON.parse(File.read(installed_codex_hooks))
    codex_commands = %w[SessionStart PostToolUse].flat_map do |event|
      (codex_hooks.dig("hooks", event) || []).flat_map do |entry|
        entry.fetch("hooks", []).map { |hook| hook["command"] }
      end
    end
    refute codex_commands.any? { |command| command.include?("/bin/codex-session-title") }

    requirements = File.read(installed_codex_requirements)
    assert_includes requirements, "[[hooks.SessionStart]]"
    assert_includes requirements, "[[hooks.PostToolUse]]"
    assert_includes requirements, %(command = "#{runtime_root}/bin/codex-session-title")
  end

  def test_integration_stages_admin_requirements_when_etc_unwritable
    skip "jq is required for settings hook install" unless jq_available?

    blocked_parent = File.join(@sandbox, "not-a-directory")
    File.write(blocked_parent, "nope")

    FileUtils.mkdir_p(File.dirname(installed_codex_hooks))
    File.write(installed_codex_hooks, JSON.pretty_generate(
      "hooks" => {
        "SessionStart" => [
          {
            "matcher" => "startup|resume",
            "hooks" => [
              {
                "type" => "command",
                "command" => "/stable/mcritchie-studio/bin/codex-session-title"
              }
            ]
          }
        ]
      }
    ))

    out, err, status = run_installer("install",
      "CODEX_REQUIREMENTS_PATH" => File.join(blocked_parent, "requirements.toml"))

    assert status.success?, "install should not fail when admin requirements need root: #{err}"
    assert_includes out, "admin install required for organic Codex mascot"
    assert_includes out, "installed user-level Codex SessionStart/PostToolUse fallback"
    assert_includes out, "Staged managed requirements:"
    refute_includes out, "Review once inside Codex with /hooks"

    staged = File.join(@home, ".codex", "mcritchie-requirements.toml")
    assert File.file?(staged), "installer should stage the managed requirements for admin install"
    staged_requirements = File.read(staged)
    assert_includes staged_requirements, "/bin/codex-session-title"
    assert_includes staged_requirements, "[[hooks.SessionStart]]"
    assert_includes staged_requirements, "[[hooks.PostToolUse]]"

    codex_hooks = JSON.parse(File.read(installed_codex_hooks))
    runtime_root = ROOT.sub(%r{/\.worktrees/.*\z}, "")
    session_commands = (codex_hooks.dig("hooks", "SessionStart") || []).flat_map do |entry|
      entry.fetch("hooks", []).map { |hook| hook["command"] }
    end
    post_tool_commands = (codex_hooks.dig("hooks", "PostToolUse") || []).flat_map do |entry|
      entry.fetch("hooks", []).map { |hook| hook["command"] }
    end

    assert_equal ["#{runtime_root}/bin/codex-session-title"], session_commands
    assert_equal ["#{runtime_root}/bin/codex-session-title"], post_tool_commands
  end
end
