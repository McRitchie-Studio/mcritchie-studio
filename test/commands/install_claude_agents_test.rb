# frozen_string_literal: true

# bin/install-claude-agents and its library, bin/lib/claude_agent_definitions.rb.
# Run directly: ruby -Itest test/commands/install_claude_agents_test.rb
#
# CRITICAL: every write goes to a throwaway tmp dir (--dest, or a sandboxed HOME for
# the bin/install-agent-docs wiring). Nothing here touches the real ~/.claude/agents.
#
#   test_unit_*        — the library against fixture source trees
#   test_integration_* — the CLI and bin/install-agent-docs round trip on disk

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../../bin/lib/claude_agent_definitions"

class InstallClaudeAgentsTest < Minitest::Test
  ROOT   = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "install-claude-agents")
  DOCS   = File.join(ROOT, "bin", "install-agent-docs")
  CAD    = ClaudeAgentDefinitions

  def setup
    @tmp = Dir.mktmpdir("install-claude-agents")
    @dest = File.join(@tmp, "agents")
    @backups = File.join(@tmp, "agents-backup")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def fixture_root(defs)
    root = File.join(@tmp, "repo")
    defs.each do |soul, body|
      path = File.join(root, "docs/agents/agents/#{soul}/claude-agent.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    root
  end

  def defn(name, body = "You are #{name}.\n") = "---\nname: #{name}\ndescription: d\n---\n\n#{body}"

  # ── unit ──────────────────────────────────────────────────────────────────

  def test_unit_sources_are_one_per_soul_folder_sorted
    root = fixture_root("zed" => defn("zed"), "amy" => defn("amy"))
    assert_equal %w[amy zed], CAD.sources(root).map(&:name)
    assert_equal "docs/agents/agents/amy/claude-agent.md", CAD.sources(root).first.rel
  end

  def test_unit_a_frontmatter_name_that_is_not_the_folder_refuses
    root = fixture_root("amy" => defn("bob"))
    err = assert_raises(CAD::SourceError) { CAD.sources(root) }
    assert_match(/expected "amy"/, err.message)
  end

  def test_unit_install_creates_then_reports_unchanged
    srcs = CAD.sources(fixture_root("amy" => defn("amy")))
    assert_equal [:created], CAD.install!(srcs, @dest, backup_root: @backups).map(&:status)
    assert_equal [:unchanged], CAD.install!(srcs, @dest, backup_root: @backups).map(&:status)
    refute Dir.exist?(@backups), "nothing differed, so nothing is backed up"
  end

  def test_unit_install_backs_up_a_differing_copy_outside_the_agents_folder
    FileUtils.mkdir_p(@dest)
    File.write(File.join(@dest, "amy.md"), "hand edited\n")
    srcs = CAD.sources(fixture_root("amy" => defn("amy")))
    res = CAD.install!(srcs, @dest, backup_root: @backups, now: Time.utc(2026, 11, 6, 12))
    assert_equal :updated, res.first.status
    assert_equal File.join(@backups, "20261106T120000Z", "amy.md"), res.first.backup
    assert_equal "hand edited\n", File.read(res.first.backup)
    assert_equal defn("amy"), File.read(File.join(@dest, "amy.md"))
    assert_equal ["amy.md"], Dir.children(@dest), "no temp file or backup is left in the agents folder"
  end

  def test_unit_the_default_backup_root_is_beside_the_agents_folder
    assert_equal "/h/.claude/agents-backup", CAD.default_backup_root("/h/.claude/agents")
  end

  def test_unit_compare_reports_missing_same_and_differs
    root = fixture_root("amy" => defn("amy"), "bob" => defn("bob"), "cat" => defn("cat"))
    FileUtils.mkdir_p(@dest)
    File.write(File.join(@dest, "amy.md"), defn("amy"))
    File.write(File.join(@dest, "bob.md"), defn("bob", "drifted\n"))
    assert_equal %i[same differs create], CAD.compare(CAD.sources(root), @dest).map(&:status)
  end

  def test_unit_files_with_no_source_are_unmanaged_and_left_alone
    FileUtils.mkdir_p(@dest)
    File.write(File.join(@dest, "handmade.md"), "x")
    File.write(File.join(@dest, "amy.md.bak-20260924"), "old")
    srcs = CAD.sources(fixture_root("amy" => defn("amy")))
    CAD.install!(srcs, @dest, backup_root: @backups)
    assert_equal ["handmade"], CAD.unmanaged(srcs, @dest)
    assert_equal "x", File.read(File.join(@dest, "handmade.md"))
    assert_equal "old", File.read(File.join(@dest, "amy.md.bak-20260924"))
  end

  def test_unit_sources_read_from_a_commit
    root = fixture_root("amy" => defn("amy"))
    git = ->(*a) { Open3.capture2e("git", "-C", root, *a).last.success? || flunk("git #{a.join(' ')}") }
    git.call("init", "-q")
    git.call("add", ".")
    git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one")
    File.write(File.join(root, "docs/agents/agents/amy/claude-agent.md"), defn("amy", "later\n"))
    assert_equal defn("amy"), CAD.sources(root, rev: "HEAD").first.content
    assert_equal defn("amy", "later\n"), CAD.sources(root).first.content
  end

  # Every soul the repo ships a definition for, read from the real tree: this is the
  # set the ship writes into ~/.claude/agents.
  def test_unit_the_repo_carries_every_soul_definition_with_a_matching_name
    names = CAD.sources(ROOT).map(&:name)
    assert_equal %w[alex avi carl jasper mack mason pokemon shannon steffon], names
  end

  # The fixed broken references: none of these paths may come back.
  def test_unit_no_definition_cites_a_file_that_was_removed
    text = CAD.sources(ROOT).map(&:content).join("\n")
    refute_includes text, "about-alex.md"
    refute_includes text, "docs/agents/system/email-delivery.md"
    refute_includes text, "turf-vault/CLAUDE.md"
  end

  # Repo-relative paths each definition cites must exist, so a rename cannot leave a
  # definition pointing at nothing again.
  def test_unit_every_repo_path_a_definition_cites_exists
    CAD.sources(ROOT).each do |src|
      # Bare docs/ paths only: a bare bin/ path can name an app repo's script
      # (steffon's turf-monster `bin/deploy`).
      src.content.scan(%r{`(docs/[A-Za-z0-9_./-]+)`}).flatten.uniq.each do |rel|
        assert File.exist?(File.join(ROOT, rel)), "#{src.rel} cites #{rel}, which does not exist"
      end
      src.content.scan(%r{`mcritchie-studio/((?:docs|bin)/[A-Za-z0-9_./-]+)`}).flatten.uniq.each do |rel|
        assert File.exist?(File.join(ROOT, rel)), "#{src.rel} cites mcritchie-studio/#{rel}, which does not exist"
      end
    end
  end

  # ── integration: the CLI ──────────────────────────────────────────────────

  def run_cli(*args, env: {})
    Open3.capture3(SessionEnv.neutralized(env), RbConfig.ruby, SCRIPT, *args)
  end

  def test_integration_install_into_a_temp_dir_matches_the_sources_and_check_passes
    _out, err, st = run_cli("install", "--dest", @dest, "--backup-dir", @backups)
    assert st.success?, err
    CAD.sources(ROOT).each do |src|
      assert_equal src.content, File.binread(File.join(@dest, "#{src.name}.md")), src.name
    end
    out, err, st = run_cli("check", "--dest", @dest)
    assert st.success?, err
    assert_match(/OK: .*pokemon\.md matches/, out)
  end

  def test_integration_check_fails_when_an_installed_definition_differs_or_is_missing
    run_cli("install", "--dest", @dest, "--backup-dir", @backups)
    File.write(File.join(@dest, "carl.md"), "drifted\n")
    File.delete(File.join(@dest, "avi.md"))
    _out, err, st = run_cli("check", "--dest", @dest)
    refute st.success?
    assert_match(/carl\.md differs/, err)
    assert_match(/avi\.md is missing/, err)
  end

  def test_integration_install_backs_up_the_drifted_copy_and_heals_it
    run_cli("install", "--dest", @dest, "--backup-dir", @backups)
    File.write(File.join(@dest, "carl.md"), "drifted\n")
    out, err, st = run_cli("install", "--dest", @dest, "--backup-dir", @backups)
    assert st.success?, err
    assert_match(/carl\.md updated \(previous copy backed up to/, out)
    assert_equal ["drifted\n"], Dir.glob(File.join(@backups, "*", "carl.md")).map { |p| File.read(p) }
    assert run_cli("check", "--dest", @dest)[2].success?
  end

  def test_integration_manifest_writes_nothing
    out, _err, st = run_cli("manifest", "--dest", @dest)
    assert st.success?
    assert_includes out, "WRITE\t#{File.join(@dest, 'steffon.md')}"
    refute Dir.exist?(@dest)
  end

  def test_integration_help_and_unknown_arguments_write_nothing
    _o, _e, st = run_cli("install", "--dest", @dest, "--help")
    assert_equal 1, st.exitstatus
    _o, _e, st = run_cli("install", "extra", "--dest", @dest)
    assert_equal 2, st.exitstatus
    refute Dir.exist?(@dest)
  end

  # A copy of the installer stood up inside a fake desk. The "real" folder is pointed
  # at the sandbox, so even a regressed refusal could not write to ~/.claude/agents.
  def test_integration_a_desk_refuses_to_install_into_the_real_agents_folder
    desk = File.join(@tmp, "hub", ".worktrees", "some-desk")
    %w[bin/install-claude-agents bin/lib/claude_agent_definitions.rb
       docs/agents/agents/pokemon/claude-agent.md].each do |rel|
      FileUtils.mkdir_p(File.dirname(File.join(desk, rel)))
      FileUtils.cp(File.join(ROOT, rel), File.join(desk, rel))
    end
    real = File.join(@tmp, "real-agents")
    env = { "INSTALL_CLAUDE_AGENTS_REAL_DEST" => real }
    _o, err, st = Open3.capture3(SessionEnv.neutralized(env), RbConfig.ruby,
                                 File.join(desk, "bin", "install-claude-agents"), "install", "--dest", real)
    assert_equal 2, st.exitstatus
    assert_match(/refusing to install from the desk/, err)
    refute Dir.exist?(real), "the refusal writes nothing"

    _o, err, st = Open3.capture3(SessionEnv.neutralized(env), RbConfig.ruby,
                                 File.join(desk, "bin", "install-claude-agents"), "install", "--dest", @dest)
    assert st.success?, "a desk may install into any other folder: #{err}"
  end

  # ── integration: bin/install-agent-docs runs it (the ship's sync step) ────

  def docs_env(home, projects)
    {
      "HOME" => home,
      "PROJECTS_DIR" => projects,
      "CODEX_REQUIREMENTS_PATH" => File.join(home, "codex-requirements.toml"),
      "AGENT_RUNTIME_RUBY_PATH_PREFIX" => File.dirname(RbConfig.ruby),
      "AGENT_RUNTIME_ZPROFILE" => File.join(home, ".zprofile"),
      "CLAUDE_AGENTS_DIR" => File.join(home, ".claude", "agents"),
      "PATH" => "#{File.dirname(RbConfig.ruby)}:#{ENV.fetch('PATH')}"
    }
  end

  def test_integration_install_agent_docs_writes_and_checks_the_definitions
    home = File.join(@tmp, "home")
    projects = File.join(@tmp, "projects")
    FileUtils.mkdir_p(home)
    env = SessionEnv.neutralized(docs_env(home, projects))
    agents = File.join(home, ".claude", "agents")

    out, _err, _st = Open3.capture3(env, DOCS, "manifest")
    assert_includes out, "WRITE\t#{File.join(agents, 'avi.md')}"
    refute Dir.exist?(agents), "manifest writes nothing"

    _out, err, st = Open3.capture3(env, DOCS, "install")
    assert st.success?, err
    assert_equal CAD.sources(ROOT).map { |s| "#{s.name}.md" }, Dir.children(agents).sort

    File.write(File.join(agents, "mason.md"), "drifted\n")
    _out, err, st = Open3.capture3(env, DOCS, "check")
    refute st.success?, "check must fail on a drifted definition"
    assert_match(/mason\.md differs/, err)
  end
end
