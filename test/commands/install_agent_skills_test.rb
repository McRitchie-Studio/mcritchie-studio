# frozen_string_literal: true

# Standalone test for bin/install-agent-docs' user-global skills install/check
# (no Rails needed — the script is pure bash, so we shell out to it). Run directly:
#   ruby -Itest test/commands/install_agent_skills_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# CRITICAL: every run sandboxes HOME and PROJECTS_DIR into a throwaway tmp dir, so
# the installer copies into the sandbox and NEVER touches the operator's real
# ~/.claude/skills or projects-root AGENTS.md/CLAUDE.md.
#
# Tier split (backend shape → unit + integration):
#   test_unit_*        — isolated source/CLI-contract assertions (no install round trip)
#   test_integration_* — the install↔check round trip across the filesystem boundary

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class InstallAgentSkillsTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  SCRIPT   = File.join(ROOT, "bin", "install-agent-docs")
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
  def run_installer(mode)
    Open3.capture3(
      { "HOME" => @home, "PROJECTS_DIR" => @projects },
      SCRIPT, mode
    )
  end

  def installed_wrap = File.join(@home, ".claude", "skills", "wrap", "SKILL.md")

  # ── unit ──────────────────────────────────────────────────────────────────

  def test_unit_wrap_skill_present_in_canonical_source
    assert File.file?(WRAP_SRC),
      "the /wrap skill must live in the tracked canonical source dir " \
      "(docs/agents/skills/wrap/SKILL.md) so it survives a wiped machine"
    body = File.read(WRAP_SRC)
    assert_match(/^name:\s*wrap\s*$/, body, "canonical /wrap must carry its skill frontmatter")
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

  # ── integration ───────────────────────────────────────────────────────────

  def test_integration_install_lands_skill_in_home_claude_skills
    _out, err, status = run_installer("install")
    assert status.success?, "install failed: #{err}"
    assert File.file?(installed_wrap),
      "install must place the /wrap skill at ~/.claude/skills/wrap/SKILL.md"
    assert_equal File.read(WRAP_SRC), File.read(installed_wrap),
      "the installed skill must be a byte-for-byte copy of the canonical source"
  end

  def test_integration_does_not_install_top_level_readme
    # Only files inside a <name>/ skill dir are skills; a top-level README in the
    # canonical source documents the tree and must NOT land in ~/.claude/skills.
    run_installer("install")
    refute File.exist?(File.join(@home, ".claude", "skills", "README.md")),
      "a top-level docs/agents/skills/README.md must not be mirrored as a skill"
  end

  def test_integration_install_is_idempotent
    run_installer("install")
    first = File.read(installed_wrap)
    _out, err, status = run_installer("install")
    assert status.success?, "second install failed: #{err}"
    assert_equal first, File.read(installed_wrap),
      "re-running install must be a no-op on an already-current skill"
  end

  def test_integration_check_passes_after_install
    run_installer("install")
    out, _err, status = run_installer("check")
    assert status.success?, "check should pass immediately after a clean install"
    assert_match(%r{OK:.*skills/wrap/SKILL\.md}, out,
      "check should report the installed skill as matching")
  end

  def test_integration_check_fails_when_local_skill_modified
    run_installer("install")
    File.write(installed_wrap, "#{File.read(installed_wrap)}\nlocal drift\n")
    _out, err, status = run_installer("check")
    refute status.success?, "check must fail when a local skill drifts from the source"
    assert_match(%r{ERROR:.*skills/wrap/SKILL\.md}, err)
  end

  def test_integration_check_fails_when_local_skill_missing
    run_installer("install")
    FileUtils.rm_rf(File.join(@home, ".claude", "skills", "wrap"))
    _out, err, status = run_installer("check")
    refute status.success?, "check must fail when a tracked skill is missing locally"
    assert_match(%r{ERROR:.*skills/wrap/SKILL\.md}, err)
  end
end
