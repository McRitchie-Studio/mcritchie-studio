# frozen_string_literal: true

# Guard catalog row 4.1 (worked example A): a desk measures nothing it cannot fix.
#
# `bin/install-agent-docs check` compares the installed entry docs and skills with the
# tree the last ship PUBLISHED — the SHA the fixed-path tooling link names — not with
# the caller's own tree. So a docs merge after the ship changes the desk's sources and
# leaves the answer alone: the check that failed every desk cut after a docs merge can
# no longer fail that way. A real mismatch with the published tree still fails, which
# is the control that proves the comparison bites.
#
# Each test builds a throwaway repo holding a copy of the installer and the docs it
# publishes, stands up a fake fixed path at the "shipped" commit, and runs `check`.
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/session_env"

class InstallAgentDocsShippedTreeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @sandbox = Dir.mktmpdir("install-agent-docs-shipped")
    @repo = File.join(@sandbox, "repo")
    @home = File.join(@sandbox, "home")
    @projects = File.join(@sandbox, "projects")
    FileUtils.mkdir_p([@home, @projects])

    copy("bin/install-agent-docs")
    copy("bin/lib/projects_root.rb")
    write("docs/agents/index.md", "# Entry map, shipped\n")
    write("docs/agents/claude.md", "# Adapter, shipped\n")
    write("docs/agents/skills/wrap/SKILL.md", "wrap skill, shipped\n")
    git("init", "-q")
    git("config", "user.email", "tester@example.com")
    git("config", "user.name", "Tester")
    git("add", "-A")
    git("commit", "-q", "-m", "shipped")
    @shipped = git("rev-parse", "HEAD").strip

    publish_from_shipped_tree
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # [integration] The construction: a docs merge after the ship leaves the check green.
  def test_a_docs_merge_after_the_ship_does_not_fail_the_check
    write("docs/agents/index.md", "# Entry map, merged after the ship\n")
    write("docs/agents/skills/wrap/SKILL.md", "wrap skill, merged after the ship\n")
    git("commit", "-qam", "docs merge")

    out, err, status = check

    assert status.success?, "a docs merge since the ship must not fail check:\n#{out}\n#{err}"
    assert_includes out, "the tree the last ship published (#{@shipped[0, 12]})"
    assert_includes out, "#{File.join(@projects, "AGENTS.md")} matches docs/agents/index.md at #{@shipped[0, 12]}"
    refute_match(/^ERROR:/, err)
  end

  # [integration] The control: an installed copy that differs from the PUBLISHED tree
  # still fails, and the guidance names the owner. Without it the green above could be
  # a check that compares nothing.
  def test_a_copy_that_differs_from_the_published_tree_fails_and_names_the_owner
    File.write(File.join(@projects, "AGENTS.md"), "# hand-installed text\n")

    _out, err, status = check

    refute status.success?, "a mismatch with the published tree must fail check"
    assert_includes err, "ERROR: #{File.join(@projects, "AGENTS.md")} is out of date with docs/agents/index.md " \
                         "at the shipped tree #{@shipped[0, 12]}"
    assert_match(/sync_agent_docs/, err)
    assert_match(/expected to heal/, err)
  end

  # [unit] Without a fixed path (a fresh machine) there is no published tree to name,
  # so the check measures the installer's own tree, as bringup needs.
  def test_without_a_fixed_path_the_check_measures_its_own_tree
    FileUtils.rm_f(File.join(@projects, ".agents", "bin"))
    write("docs/agents/index.md", "# Entry map, edited\n")

    _out, err, status = check

    refute status.success?
    assert_includes err, "ERROR: #{File.join(@projects, "AGENTS.md")} is out of date with " \
                         "#{File.join(@repo, "docs/agents/index.md")}"
    assert_match(/No published tree is installed/, err)
  end

  private

  def check
    Open3.capture3(
      SessionEnv.neutralized("HOME" => @home, "PROJECTS_DIR" => @projects),
      File.join(@repo, "bin", "install-agent-docs"), "check"
    )
  end

  # What the ship's sync_agent_docs leaves behind: the docs copied from the shipped
  # tree and the fixed path naming that tree's SHA.
  def publish_from_shipped_tree
    FileUtils.cp(File.join(@repo, "docs/agents/index.md"), File.join(@projects, "AGENTS.md"))
    FileUtils.cp(File.join(@repo, "docs/agents/claude.md"), File.join(@projects, "CLAUDE.md"))
    %w[.claude .codex].each do |runtime|
      dest = File.join(@home, runtime, "skills", "wrap", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(File.join(@repo, "docs/agents/skills/wrap/SKILL.md"), dest)
    end
    tree = File.join(@projects, ".agents", "tooling", @shipped)
    FileUtils.mkdir_p(File.join(tree, "bin"))
    File.write(File.join(tree, "bin", "submit"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(tree, "bin", "submit"))
    File.write(File.join(tree, ".complete"), "#{@shipped}\n")
    File.symlink("tooling/#{@shipped}/bin", File.join(@projects, ".agents", "bin"))
  end

  def copy(rel)
    dest = File.join(@repo, rel)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(File.join(ROOT, rel), dest)
  end

  def write(rel, body)
    path = File.join(@repo, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", @repo, *args)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out
  end
end
