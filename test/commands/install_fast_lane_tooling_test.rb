# frozen_string_literal: true

# bin/install-agent-docs installs the fast-lane tooling at a FIXED PATH outside any
# checkout: <projects>/.agents/tooling/<sha>/ behind an atomically swapped symlink,
# <projects>/.agents/bin. Run directly:
#   ruby -Itest test/commands/install_fast_lane_tooling_test.rb
#
# THE CAUSE IT REMOVES. The scripts ran only from the hub PRIMARY, which other
# sessions move with `git checkout`; a command starting in that window died with
# `cannot load such file`. A directory nothing checks out cannot move under you.
#
# CRITICAL: every run pins HOME, PROJECTS_DIR and the runtime root into a throwaway
# tmp dir. Nothing here touches the operator's real /Users/alex/projects/.agents.
#
#   test_unit_*        — manifest / check contract, no install round trip
#   test_integration_* — a real install, then the installed scripts run from a desk
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"

class InstallFastLaneToolingTest < Minitest::Test
  ROOT   = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "install-agent-docs")

  def setup
    @sandbox  = Dir.mktmpdir("install-fast-lane-tooling")
    @home     = File.join(@sandbox, "home")
    @projects = File.join(@sandbox, "projects")
    @runtime  = File.join(@sandbox, "runtime")
    FileUtils.mkdir_p([@home, @runtime])
    File.write(File.join(@runtime, ".env"), "SANDBOX=1\n")
    @sha = Open3.capture2("git", "-C", ROOT, "rev-parse", "HEAD").first.strip
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  def run_installer(mode, env = {})
    Open3.capture3(
      SessionEnv.neutralized({
        "HOME" => @home,
        "PROJECTS_DIR" => @projects,
        "AGENT_DOCS_RUNTIME_ROOT" => @runtime,
        "CODEX_REQUIREMENTS_PATH" => File.join(@sandbox, "codex-requirements.toml"),
        "AGENT_RUNTIME_ZPROFILE" => File.join(@home, ".zprofile"),
        "AGENT_RUNTIME_RUBY_PATH_PREFIX" => File.dirname(RbConfig.ruby)
      }.merge(env)),
      SCRIPT, mode
    )
  end

  def link = File.join(@projects, ".agents", "bin")
  def tooling_root = File.join(@projects, ".agents", "tooling")

  def install!
    out, err, status = run_installer("install")
    assert status.success?, "install failed:\n#{out}\n#{err}"
    out
  end

  def test_unit_manifest_names_the_tooling_writes_and_writes_nothing
    out, err, status = run_installer("manifest")
    assert status.success?, err
    writes = out.lines.grep(/\AWRITE\t/).map { |line| line.split("\t", 2).last.strip }
    assert_includes writes, File.join(tooling_root, @sha)
    assert_includes writes, link
    refute File.exist?(File.join(@projects, ".agents")), "manifest is a dry run"
  end

  def test_integration_install_lays_down_the_tree_behind_a_relative_symlink
    out = install!

    assert File.symlink?(link), ".agents/bin must be a symlink"
    assert_equal "tooling/#{@sha}/bin", File.readlink(link), "relative, so the projects root can move"
    %w[ship ship-wait task fast-check dor-check release agent-worktree agent-activity gh-auth-refresh].each do |script|
      assert File.executable?(File.join(link, script)), "#{script} must be installed executable"
    end
    tree = File.join(tooling_root, @sha)
    assert File.exist?(File.join(tree, "bin", "lib", "repo_root.rb")), "bin/lib/** comes along"
    # Globbed, not named: naming a config file here would map this test onto it.
    refute_empty Dir.glob(File.join(tree, "config", "*.yml")), "the config the gates read comes along"
    assert File.exist?(File.join(tree, "app", "models", "release", "ship_sequence.rb")),
           "the pure app/models/release the scripts require_relative comes along"
    assert_equal File.join(@runtime, ".env"), File.readlink(File.join(tree, ".env")),
                 "the board secret is the runtime hub's own .env, linked — never copied"
    assert_equal @sha, File.read(File.join(tree, ".complete")).strip
    assert_includes out, "#{link} -> tooling/#{@sha}/bin"
    assert_empty Dir.glob(File.join(tooling_root, ".staging-*")), "no staging dir survives a good install"
  end

  # The swap replaces the symlink ITSELF. A naive `mv new .agents/bin` onto a symlink to
  # a directory moves the new link INSIDE the old tree and leaves the old one live.
  def test_integration_the_swap_replaces_an_older_link_in_place
    old = File.join(tooling_root, "0" * 40)
    FileUtils.mkdir_p(File.join(old, "bin"))
    File.write(File.join(old, ".complete"), "old\n")
    FileUtils.mkdir_p(File.dirname(link))
    File.symlink("tooling/#{"0" * 40}/bin", link)

    install!

    assert_equal "tooling/#{@sha}/bin", File.readlink(link)
    assert_empty Dir.children(File.join(old, "bin")), "nothing was moved inside the old tree"
    assert Dir.exist?(old), "the previous SHA is kept for a command still loading from it"
  end

  def test_integration_a_second_install_is_idempotent
    install!
    marker = File.join(tooling_root, @sha, "bin", "sentinel")
    File.write(marker, "x")
    install!
    assert File.exist?(marker), "a complete tree for this SHA is reused, not rebuilt"
    assert_equal "tooling/#{@sha}/bin", File.readlink(link)
  end

  def test_integration_a_real_directory_at_the_link_is_moved_aside_not_deleted
    FileUtils.mkdir_p(link)
    File.write(File.join(link, "hand-made"), "keep me")

    out = install!

    assert File.symlink?(link)
    aside = Dir.glob("#{link}.pre-tooling-*")
    assert_equal 1, aside.size, "the old directory is parked beside the link"
    assert_equal "keep me", File.read(File.join(aside.first, "hand-made"))
    assert_includes out, "moved the existing directory"
  end

  def test_integration_old_trees_are_pruned_to_the_newest_three
    olds = (1..4).map do |i|
      dir = File.join(tooling_root, i.to_s * 40)
      FileUtils.mkdir_p(dir)
      File.utime(Time.now - (i * 60), Time.now - (i * 60), dir)
      dir
    end

    install!

    kept = Dir.children(tooling_root).reject { |name| name.start_with?(".") }.sort
    assert_equal [@sha, "1" * 40, "2" * 40].sort, kept,
                 "the current SHA plus the two newest others survive; older trees go"
    refute Dir.exist?(olds.last)
  end

  def test_unit_check_reports_the_install_without_calling_it_drift
    out, = run_installer("check")
    assert_includes out, "NOTE: #{link} is not installed yet"

    install!
    out, = run_installer("check")
    assert_includes out, "OK: #{link} -> tooling/#{@sha}/bin"
  end

  # [integration] the installed ship-wait runs from a desk it does not live in, and
  # acts on THAT desk: its state dir is the cwd's tree, not the tooling dir.
  def test_integration_installed_scripts_act_on_the_cwd_desk
    install!
    desk = File.join(@sandbox, "desk")
    FileUtils.mkdir_p(desk)
    system("git", "-C", desk, "init", "-q", exception: true)

    out, err, status = Open3.capture3(SessionEnv.neutralized({ "HOME" => @home }),
                                      File.join(link, "ship-wait"), "some-task", "--timeout", "1", chdir: desk)
    text = out + err
    refute_match(/cannot load such file/, text)
    refute status.success?, "no ship log exists, so the wait cannot succeed"
    assert_includes text, File.join(File.realpath(desk), "tmp", "ship-wait"),
                    "the installed script roots at the cwd's desk"
  end
end
