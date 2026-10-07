# frozen_string_literal: true

# A feature desk cannot publish the agent docs.
#
# bin/install-agent-docs writes global, shared targets (the projects-root entry docs,
# the user-global skills, the hooks), so an `install` from a feature desk pushes
# unshipped text to every session on the machine. The installer refuses that run
# itself, before it writes anything, which is why no doc needs a guard against
# prescribing it. The ship's own workspace (`.worktrees/_ship`) and a sandboxed run
# (PROJECTS_DIR pinned) still install; `check` still runs from any desk, because
# bin/session-preflight calls it there.
#
# Each case copies the script into a throwaway tree shaped like a desk, with HOME
# and the Codex requirements path pinned into that tree, so a refusal that failed
# to fire would still write nothing outside the sandbox.
#
# Standalone: ruby -Itest test/commands/install_agent_docs_desk_refusal_test.rb
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

class InstallAgentDocsDeskRefusalTest < Minitest::Test
  REPO = File.expand_path("../..", __dir__)

  def setup
    @tmp = Dir.mktmpdir("install-desk-refusal")
    @home = File.join(@tmp, "home")
    FileUtils.mkdir_p(@home)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # A copy of the installer at <tmp>/projects/repo/.worktrees/<desk>/bin.
  def desk(name)
    root = File.join(@tmp, "projects", "repo", ".worktrees", name)
    FileUtils.mkdir_p(File.join(root, "bin", "lib"))
    FileUtils.cp(File.join(REPO, "bin", "install-agent-docs"), File.join(root, "bin"))
    FileUtils.cp(File.join(REPO, "bin", "lib", "projects_root.rb"), File.join(root, "bin", "lib"))
    root
  end

  def run_installer(root, *args, env: {})
    base = { "HOME" => @home, "CODEX_REQUIREMENTS_PATH" => File.join(@home, "requirements.toml"),
             "PATH" => ENV.fetch("PATH") }
    Open3.capture3(base.merge(env), "bash", File.join(root, "bin", "install-agent-docs"), *args,
                   chdir: @tmp, unsetenv_others: true)
  end

  def written_under_home
    Dir.glob(File.join(@home, "**", "*"), File::FNM_DOTMATCH).reject { |p| File.directory?(p) }
  end

  # [unit] install from a feature desk refuses with exit 2 and writes nothing
  def test_install_from_a_feature_desk_is_refused_before_any_write
    _out, err, status = run_installer(desk("feat"), "install")

    assert_equal 2, status.exitstatus, err
    assert_includes err, "refusing to publish from the desk"
    assert_includes err, "sync_agent_docs"
    assert_empty written_under_home
  end

  # [unit] the bare invocation defaults to install, so it is refused too
  def test_the_bare_invocation_is_refused_from_a_feature_desk
    _out, err, status = run_installer(desk("feat"))

    assert_equal 2, status.exitstatus, err
    assert_includes err, "refusing to publish from the desk"
  end

  # [unit] the ship's workspace is not refused (it fails later, on the missing sources)
  def test_the_ship_workspace_is_not_refused
    _out, err, status = run_installer(desk("_ship"), "install")

    refute_includes err, "refusing to publish from the desk"
    refute_equal 2, status.exitstatus, err
  end

  # [unit] a sandboxed run (PROJECTS_DIR pinned) from a desk is not refused
  def test_a_pinned_sandbox_run_from_a_desk_is_not_refused
    projects = File.join(@tmp, "sandbox-projects")
    FileUtils.mkdir_p(projects)
    _out, err, _status = run_installer(desk("feat"), "install", env: { "PROJECTS_DIR" => projects })

    refute_includes err, "refusing to publish from the desk"
  end

  # [unit] check still runs from a desk, where session-preflight calls it
  def test_check_from_a_feature_desk_is_not_refused
    _out, err, _status = run_installer(desk("feat"), "check")

    refute_includes err, "refusing to publish from the desk"
  end
end
