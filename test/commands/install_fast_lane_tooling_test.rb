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
    %w[submit submit-wait ship ship-wait task fast-check dor-check release agent-worktree agent-activity gh-auth-refresh].each do |script|
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

  # The session-start hook runs from the installed tree, so the bank it reads ships in it.
  def test_integration_the_installed_tree_carries_the_dream_bank
    install!

    out, err, status = Open3.capture3(SessionEnv.neutralized({}), RbConfig.ruby, File.join(link, "dream"), "platform")

    assert status.success?, err
    assert_includes out, "## Dreams", "the installed loader finds no dreams"
    assert_includes out, "### Helper agents"
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

  # A rollback reinstalls a SHA already on disk. It must be freshened, or the tree the
  # link now names could rank oldest and be pruned out from under it.
  def test_integration_a_reinstalled_old_sha_is_freshened_before_pruning
    install!
    tree = File.join(tooling_root, @sha)
    File.utime(Time.now - 86_400, Time.now - 86_400, tree)
    (1..3).each { |i| FileUtils.mkdir_p(File.join(tooling_root, i.to_s * 40)) }

    install!

    assert Dir.exist?(tree), "the reinstalled SHA survives its own prune"
    assert_operator File.mtime(tree), :>, Time.now - 60
  end

  # ── SCRIPTS THAT BOOT RAILS ───────────────────────────────────────────────────
  #
  # The install copies ALL of bin/, and a few of those scripts boot the Rails
  # APPLICATION. The tooling tree is bin/ + lib/ + config/ + pure app/models — no
  # Gemfile, no app/assets, no db/ — so a direct copy died on FIRST BOOT:
  #
  #   $ /Users/alex/projects/.agents/bin/reviewer-select --help
  #   bundler/definition.rb:38:in 'build': .../tooling/<sha>/Gemfile not found
  #     (Bundler::GemfileNotFound)
  #
  # Measured 2026-09-27 and true of EVERY tooling tree since the fixed path was born
  # (45c83556, 2026-09-25) — not a regression at one ship. Five scripts: rails, rake,
  # jobs, reviewer-select, reap-cert-databases. A reviewer following CLAUDE.md, which
  # names the fixed path FIRST, read it as a broken Ruby install and fell back by hand.
  #
  # WHY THE OLD TESTS PASSED THROUGH IT. The install test asserted PRESENCE and
  # EXECUTABILITY of nine named scripts and booted exactly one, `submit-wait`, a script
  # that needs no Rails, asserting only `refute_match(/cannot load such file/)`. Nothing
  # in the suite ever BOOTED a Rails-booting script from the installed tree, so the
  # install could ship five scripts that cannot run and stay green. These tests close
  # that: the set is DERIVED from bin/ so a NEW Rails-booting script is covered the day
  # it is written, and one of them is really executed.
  # ...or loads app/services, which the tooling tree does not carry either
  # (bin/x-post, the first such script, died on its first require there).
  RAILS_BOOT_RE = %r{require_relative\s+"\.\./(?:config/(?:boot|environment)|app/services/)}

  # Derived, never enumerated: an enumerated list goes stale silently.
  def rails_booting_scripts(dir)
    Dir.children(dir).select do |name|
      path = File.join(dir, name)
      File.file?(path) && File.read(path).match?(RAILS_BOOT_RE)
    rescue ArgumentError # a binary in bin/ is not a Ruby script
      false
    end.sort
  end

  def test_integration_rails_booting_scripts_install_as_hub_shims_not_copies
    expected = rails_booting_scripts(File.join(ROOT, "bin"))
    refute_empty expected, "nothing in bin/ boots Rails — this test would assert nothing"
    # The measured instance. If reviewer-select ever stops booting Rails, revisit this
    # deliberately rather than letting the guard quietly cover an empty set.
    assert_includes expected, "reviewer-select"
    assert_includes expected, "x-post", "a script that loads app/services must delegate to the hub too"

    install!

    assert_empty rails_booting_scripts(link),
                 "a Rails-booting COPY at the fixed path dies on Bundler::GemfileNotFound"
    expected.each do |name|
      body = File.read(File.join(link, name))
      assert_match(/\A#!\/bin\/sh/, body, "#{name} must be installed as a shim, not copied")
      # The shim bakes the hub ROOT and its own NAME and composes the target at run
      # time, so assert those two, not a joined literal that never appears.
      assert_match(/^hub=(?:'#{Regexp.escape(@runtime)}'|#{Regexp.escape(@runtime)})$/, body,
                   "#{name}'s shim must bake the hub root it delegates to")
      assert_match(/^name=#{Regexp.escape(name)}$/, body, "#{name}'s shim must name itself")
      assert_includes body, 'exec "$target" "$@"', "#{name}'s shim must exec the hub copy"
      assert File.executable?(File.join(link, name)), "#{name} must stay executable"
    end
  end

  # The real boot. The hub copy is a SYMLINK to this checkout's own script: Ruby
  # resolves require_relative against a file's REAL path, so the script loads the
  # hub's config/boot and the hub's Gemfile, exactly as it would in production.
  # Read-only — `--help` exits before any board or Rails work.
  def test_integration_a_shimmed_script_boots_from_the_fixed_path
    install!
    FileUtils.mkdir_p(File.join(@runtime, "bin"))
    File.symlink(File.join(ROOT, "bin", "reviewer-select"), File.join(@runtime, "bin", "reviewer-select"))

    out, err, status = Open3.capture3(SessionEnv.neutralized({ "HOME" => @home }),
                                      File.join(link, "reviewer-select"), "--help")
    text = out + err
    refute_match(/GemfileNotFound/, text, "the fixed-path script still dies in Bundler")
    refute_match(/cannot load such file/, text)
    assert_match(/Usage: .*reviewer-select/, text, "the shim must reach the real script")
    assert status.success?, text
  end

  # An install that CANNOT run must say so in one line naming the path, not hand the
  # operator a Bundler stack trace that reads like a broken Ruby install.
  def test_integration_a_shim_without_its_hub_copy_diagnoses_the_missing_delegate
    install!

    out, err, status = Open3.capture3(SessionEnv.neutralized({ "HOME" => @home }),
                                      File.join(link, "reviewer-select"), "--help")
    text = out + err
    assert_equal 127, status.exitstatus, text
    refute_match(/GemfileNotFound/, text)
    assert_includes text, "needs the Rails app"
    assert_includes text, File.join(@runtime, "bin", "reviewer-select"),
                    "the diagnosis must name the delegate it could not find"
  end

  # `check` said OK about the broken tree for two days, because it only asked whether
  # `ship` was executable. Presence is not runnability.
  def test_unit_check_names_an_install_that_cannot_run
    install!
    out, = run_installer("check")
    refute_match(/^WARN:/, out, "a shimmed install is not a warning")

    # The pre-fix state: the Rails-booting script back as a plain copy.
    FileUtils.cp(File.join(ROOT, "bin", "reviewer-select"), File.join(link, "reviewer-select"))
    out, _err, status = run_installer("check")

    assert_match(/^WARN: .*Rails-booting COPIES.*reviewer-select/, out,
                 "check must name the scripts that cannot run")
    # It WARNS without failing: every tree already on disk is a copy install and only
    # the next production ship replaces it, so failing here would block every desk's
    # preflight over a condition no builder can fix. CI is the gate that blocks.
    assert status.success?, "check reports; it does not fail the caller's preflight"
  end

  def test_unit_check_reports_the_install_without_calling_it_drift
    out, = run_installer("check")
    assert_includes out, "NOTE: #{link} is not installed yet"

    install!
    out, = run_installer("check")
    assert_includes out, "OK: #{link} -> tooling/#{@sha}/bin"
  end

  # [integration] the installed submit-wait runs from a desk it does not live in, and
  # acts on THAT desk: its state dir is the cwd's tree, not the tooling dir.
  def test_integration_installed_scripts_act_on_the_cwd_desk
    install!
    desk = File.join(@sandbox, "desk")
    FileUtils.mkdir_p(desk)
    system("git", "-C", desk, "init", "-q", exception: true)

    out, err, status = Open3.capture3(SessionEnv.neutralized({ "HOME" => @home }),
                                      File.join(link, "submit-wait"), "some-task", "--timeout", "1", chdir: desk)
    text = out + err
    refute_match(/cannot load such file/, text)
    refute status.success?, "no ship log exists, so the wait cannot succeed"
    assert_includes text, File.join(File.realpath(desk), "tmp", "ship-wait"),
                    "the installed script roots at the cwd's desk"
  end

  # LAYER 3 receipt for the bash writer (test/lib/state_store_containment_test.rb):
  # armed and UNPINNED, the install refuses before it writes. Run from a COPY whose
  # default projects root is inside the sandbox, so even a broken guard could only
  # write there, never to the operator's real .agents.
  def test_integration_an_armed_unpinned_install_refuses_the_tooling_write
    fake_projects = File.join(@sandbox, "fake-projects")
    copy_root = File.join(fake_projects, "mcritchie-studio")
    FileUtils.mkdir_p(File.join(copy_root, "bin", "lib"))
    FileUtils.cp(SCRIPT, File.join(copy_root, "bin", "install-agent-docs"))
    # The installer resolves its default projects root through this sibling.
    FileUtils.cp(File.join(ROOT, "bin", "lib", "projects_root.rb"), File.join(copy_root, "bin", "lib"))
    FileUtils.cp_r(File.join(ROOT, "docs"), copy_root)
    system("git", "-C", copy_root, "init", "-q", exception: true)
    system("git", "-C", copy_root, "-c", "user.email=t@t", "-c", "user.name=t", "add", "bin", exception: true)
    system("git", "-C", copy_root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "seed",
           exception: true)

    env = SessionEnv.neutralized({
      "HOME" => @home, "TASK_USAGE_SANDBOX" => "1", "AGENT_DOCS_RUNTIME_ROOT" => @runtime,
      "CODEX_REQUIREMENTS_PATH" => File.join(@sandbox, "codex-requirements.toml"),
      "AGENT_RUNTIME_ZPROFILE" => File.join(@home, ".zprofile")
    }).merge("PROJECTS_DIR" => nil)
    _out, err, status = Open3.capture3(env, File.join(copy_root, "bin", "install-agent-docs"), "install")

    assert_equal 3, status.exitstatus, err
    assert_includes err, "refusing to install fast-lane tooling"
    refute File.exist?(File.join(fake_projects, ".agents", "tooling")), "nothing was written"
  end
end
