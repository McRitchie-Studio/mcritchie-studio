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
require "rbconfig"
require_relative "../support/session_env"

class InstallAgentSkillsTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  SCRIPT   = File.join(ROOT, "bin", "install-agent-docs")
  RUNTIME  = File.join(ROOT, "bin", "agent-runtime")
  WRAP_SRC = File.join(ROOT, "docs", "agents", "skills", "wrap", "SKILL.md")
  QA_RELEASE_SRC = File.join(ROOT, "docs", "agents", "skills", "qa-release", "SKILL.md")
  INSIGHTS_BIN = File.join(ROOT, "bin", "session-insights")

  def setup
    @sandbox  = Dir.mktmpdir("install-agent-skills")
    @home     = File.join(@sandbox, "home")
    @projects = File.join(@sandbox, "projects")
    FileUtils.mkdir_p(@home)
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
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # Run bin/install-agent-docs with HOME + PROJECTS_DIR pinned into the sandbox
  # (and the ambient agent-session vars unset — see test/support/session_env.rb).
  def run_installer(mode, env = {})
    Open3.capture3(
      SessionEnv.neutralized(default_env.merge(env)),
      SCRIPT, mode
    )
  end

  def default_env
    {
      "HOME" => @home,
      "PROJECTS_DIR" => @projects,
      "CODEX_REQUIREMENTS_PATH" => installed_codex_requirements,
      "AGENT_RUNTIME_RUBY_PATH_PREFIX" => File.dirname(RbConfig.ruby),
      "AGENT_RUNTIME_ZSH" => @fake_zsh
    }
  end

  def run_runtime(*args, env: {})
    Open3.capture3(
      SessionEnv.neutralized(default_env.merge(env)),
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

  def installed_qa_release_dirs
    [
      File.join(@home, ".claude", "skills", "qa-release"),
      File.join(@home, ".codex", "skills", "qa-release")
    ]
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

  def installed_zprofile
    File.join(@home, ".zprofile")
  end

  def jq_available?
    system(SessionEnv.neutralized, "command -v jq >/dev/null 2>&1")
  end

  def with_fake_runtime_ruby
    ruby_dir = File.join(@sandbox, "fake-runtime-ruby", "bin")
    FileUtils.mkdir_p(ruby_dir)
    fake_ruby = File.join(ruby_dir, "ruby")
    File.write(fake_ruby, <<~SH)
      #!/bin/sh
      if [ "$1" = "-e" ] && printf '%s' "$2" | grep -q 'RUBY_VERSION'; then
        printf '3.3.11'
        exit 0
      fi
      exec #{RbConfig.ruby} "$@"
    SH
    FileUtils.chmod("+x", fake_ruby)
    yield ruby_dir
  end

  def runtime_doctor_env(ruby_dir)
    {
      "AGENT_RUNTIME_RUBY_PATH_PREFIX" => ruby_dir,
      "AGENT_RUNTIME_ZPROFILE" => installed_zprofile,
      "AGENT_RUNTIME_BUNDLER_CHECK_CMD" => "true",
      "AGENT_RUNTIME_RAILS_BOOT_CMD" => "true",
      "PATH" => ENV.fetch("PATH", "")
    }
  end

  def capture_login_shell(command, env)
    shell_env = SessionEnv.neutralized(default_env.merge(env))
    Open3.capture3(shell_env, shell_env.fetch("AGENT_RUNTIME_ZSH"), "-lc", command)
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

  def test_unit_qa_release_skill_is_retired_from_canonical_source
    refute File.exist?(QA_RELEASE_SRC),
      "qa-release must be a plain launcher phrase routed by AGENTS/docs, not an installed skill"
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

  # bin/session-insights is invoked by the SessionStart hook as a BARE PATH, so it
  # MUST be tracked executable (100755) or the hook fails "Permission denied" on a
  # fresh clone — the OPSD feed-forward would silently never fire. The git index
  # mode (not the local fs mode) is the durable, machine-independent contract.
  def test_unit_session_insights_bin_is_tracked_executable
    mode, _err, status = Open3.capture3(SessionEnv.neutralized, "git", "-C", ROOT, "ls-files", "-s", "bin/session-insights")
    assert status.success?, "git ls-files failed for bin/session-insights"
    refute_empty mode, "bin/session-insights must be tracked in git"
    assert_match(/\A100755\s/, mode,
      "bin/session-insights must be tracked executable (100755) so the SessionStart " \
      "hook can run it as a bare path; got: #{mode.inspect}")
    assert File.executable?(INSIGHTS_BIN), "bin/session-insights must be executable on disk"
  end

  # The installer SOURCE must wire the feed-forward hook: reference the bin, target
  # the prod board via ATOMIC_CAPTURE_URL, and register it under SessionStart.
  def test_unit_installer_source_wires_session_insights_feed_forward
    src = File.read(SCRIPT)
    assert_includes src, "bin/session-insights",
      "installer must wire the session-insights feed-forward hook"
    assert_includes src, "bin/atomic-capture-hook",
      "installer must wire the shared action capture hook"
    assert_includes src, "bin/agent-activity close-open",
      "installer must wire the activity teardown hook"
    assert_match(/AGENT_INSIGHTS_BOARD_URL:-https:\/\/mcritchie\.studio/, src,
      "installer must default the insights board to prod (overridable via AGENT_INSIGHTS_BOARD_URL)")
    assert_includes src, "ATOMIC_CAPTURE_URL=$INSIGHTS_BOARD_URL",
      "the Claude hook command must bake the prod board URL like the capture hook"
    assert_match(/hooks\.SessionStart/, src,
      "the insights hook must be registered under SessionStart")
  end

  # The installer SOURCE must wire the PreToolUse capture hook — the SAME
  # atomic-capture-hook command as PostToolUse, registered under PreToolUse, so the
  # turn-driven span lifecycle opens a span BEFORE each tool runs (reason live).
  def test_unit_installer_source_wires_pretooluse_capture_hook
    src = File.read(SCRIPT)
    assert_match(/hooks\.PreToolUse\s*=/, src,
      "installer must register the capture hook under PreToolUse")
    assert_includes src, "added PreToolUse hook",
      "installer must announce the added PreToolUse hook"
    assert_includes src, "removed old PreToolUse capture hooks",
      "installer must prune stale PreToolUse capture hooks before adding (idempotent)"
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

  def test_integration_install_wires_the_pretooluse_capture_hook
    skip "jq required" unless jq_available?

    _out, err, status = run_installer("install")
    assert status.success?, "install failed: #{err}"

    cmds = pretooluse_capture_commands
    assert(cmds.any? { |c| c.include?("/bin/atomic-capture-hook") },
      "install must wire a PreToolUse hook running bin/atomic-capture-hook; got #{cmds.inspect}")

    # idempotent — a second install must keep exactly ONE PreToolUse capture hook
    _out2, err2, status2 = run_installer("install")
    assert status2.success?, "second install failed: #{err2}"
    assert_equal 1, pretooluse_capture_commands.length,
      "re-running install must keep exactly ONE PreToolUse capture hook, not duplicate it"
  end

  # The PreToolUse hook commands in the sandbox settings.json running our capture hook.
  def pretooluse_capture_commands
    settings = JSON.parse(File.read(installed_settings))
    (settings.dig("hooks", "PreToolUse") || [])
      .flat_map { |block| (block["hooks"] || []).map { |h| h["command"] } }
      .compact
      .select { |c| c.include?("/bin/atomic-capture-hook") }
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

  # ---------------------------------------------------------------------------
  # Drift guidance — task preflight-invites-wrong-fix.
  #
  # THE BUG (measured 2026-09-07): three separate agents in one night read this
  # script's entry-doc drift FAIL as a chore they personally owed, and two
  # proposed acting on it — one wrote it up as "a post-merge global install owed
  # from the primary checkout". They were not careless. The message SAID that:
  # from a worktree it read "install from the PRIMARY checkout ($RUNTIME_ROOT)",
  # and from a primary it handed over a runnable "Run: cd <root> && bin/install-agent-docs".
  # Editing a primary checkout is the thing the operating model forbids most flatly.
  #
  # WHAT IS ACTUALLY TRUE. Installed entry docs/skills are published by exactly one
  # OWNED step: bin/release.rb's `sync_agent_docs`, which `bin/release ship` calls
  # after every production ship (Steffon, G4 Ship). It installs from the hub's SHIP
  # WORKSPACE — the tree pinned at the SHA that just shipped — runs unconditionally,
  # is idempotent, is non-fatal by construction, and HEALS PRIOR DRIFT. So drift
  # between a docs merge and the next ship is an EXPECTED state that closes itself.
  #
  # A hand-run is wrong from either tree AND cannot even close what the reader sees:
  # the check compares the installed roots against THIS $ROOT's sources, so installing
  # from a primary republishes a `main` that can be a release behind and leaves a
  # worktree's drift exactly where it was.
  #
  # BOUNDARY (checked, not missed): two hand-runs stay legitimate and are NOT
  # drift reports — `bin/agent-runtime install` during fresh-machine bringup
  # (house-burn-down step 5b, install mode, never this branch), and bin/release.rb's
  # own warn line when the ship's `sync_agent_docs` step fails, which is Steffon
  # standing at the ship.
  #
  # Worktree-ness is ROOT != RUNTIME_ROOT ($AGENT_DOCS_RUNTIME_ROOT overrides).

  # Every drift report must name the OWNER and the MOMENT that closes it.
  OWNED_CLOSER_PATTERNS = {
    "the shipping command" => %r{bin/release ship}i,
    "the owned pipeline step" => /sync_agent_docs/i,
    "the step's owner" => /steffon/i,
    "that the drift is expected, not owed" => /expected/i
  }.freeze

  # No drift report may invite a hand-run install, from a worktree or a primary.
  HAND_RUN_INVITATIONS = {
    "a runnable install command" => %r{(run|cd)[^\n]{0,80}bin/install-agent-docs(?![^\n]{0,20}check)}i,
    "an install-from-the-primary instruction" => %r{install[^\n]{0,40}from the[^\n]{0,40}primary}i
  }.freeze

  def assert_drift_guidance(err, where)
    OWNED_CLOSER_PATTERNS.each do |what, pattern|
      assert_match pattern, err,
        "#{where}: drift guidance must name #{what}, got:\n#{err}"
    end
    HAND_RUN_INVITATIONS.each do |what, pattern|
      refute_match pattern, err,
        "#{where}: drift guidance must not offer #{what}, got:\n#{err}"
    end
  end

  # [integration] From a WORKTREE the guidance names the owned closer and offers
  # no hand-run. The ERROR assertion is the FLOOR: it proves drift really fired and
  # the guidance branch really ran, so the refutations cannot pass vacuously.
  def test_integration_drift_guidance_from_a_worktree_names_the_owned_closer
    run_installer("install")
    File.write(installed_claude_wrap, "#{File.read(installed_claude_wrap)}\nlocal drift\n")

    _out, err, status = run_installer("check", "AGENT_DOCS_RUNTIME_ROOT" => "/some/primary-checkout")

    refute status.success?, "drift must fail the check"
    assert_match(/^ERROR: .*is out of date with /, err,
      "FLOOR: the check must have reported real drift, got:\n#{err}")
    assert_drift_guidance(err, "worktree")
  end

  # [integration] The other half. From the PRIMARY (ROOT == RUNTIME_ROOT) the old
  # code printed "Run: cd <root> && bin/install-agent-docs" — the exact hand-run
  # this task exists to delete. The primary gets the SAME owned-closer explanation.
  def test_integration_drift_guidance_from_the_primary_names_the_owned_closer
    run_installer("install")
    File.write(installed_claude_wrap, "#{File.read(installed_claude_wrap)}\nlocal drift\n")

    _out, err, status = run_installer("check", "AGENT_DOCS_RUNTIME_ROOT" => ROOT)

    refute status.success?, "drift must fail the check"
    assert_match(/^ERROR: .*is out of date with /, err,
      "FLOOR: the check must have reported real drift, got:\n#{err}")
    assert_drift_guidance(err, "primary")
    refute_match(%r{Run: cd \S+ && bin/install-agent-docs}, err,
      "the primary must never be handed a runnable install, got:\n#{err}")
  end

  # [unit] Sweep every site that REPORTS entry-doc drift to a reader. A half-corrected
  # explanation is worse than the current one, because it reads as authoritative.
  #
  # Exit-blind guard: a glob that matched nothing would make the loop body never run
  # and this test would pass having proved nothing. So the sweep is an explicit,
  # named list, every entry is asserted to exist and to be non-empty, and the number
  # of files actually READ is asserted against a floor.
  DRIFT_REPORT_SITES = [
    "bin/install-agent-docs",
    "bin/session-preflight",
    "bin/agent-runtime",
    "docs/agents/modules/docs-maintenance.md",
    "docs/agents/agents/alex/role.md"
  ].freeze

  def test_unit_no_drift_report_site_invites_a_hand_run_install_from_a_primary
    read = 0

    DRIFT_REPORT_SITES.each do |rel|
      path = File.join(ROOT, rel)
      assert File.file?(path), "drift-report site #{rel} is missing — fix the sweep list"
      body = File.read(path)
      refute body.empty?, "drift-report site #{rel} is empty — the sweep would prove nothing"
      read += 1

      refute_match(%r{install[^\n]{0,40}from the[^\n]{0,40}primary}i, body,
        "#{rel} tells a reader to install from a primary checkout — the forbidden hand-run")
      refute_match(%r{Run: cd \S+ && bin/install-agent-docs}, body,
        "#{rel} hands over a runnable entry-docs install")
    end

    assert_equal DRIFT_REPORT_SITES.size, read,
      "FLOOR: the sweep must have read every listed site, not short-circuited"
    assert_operator read, :>=, 5, "FLOOR: the sweep must cover every known drift-report site"
  end

  # [unit] The positive half: deleting the invitation is not enough — the prose a
  # reader lands on must NAME the owned closer, or the drift is simply unexplained
  # and the next session invents an owner again. These two are the docs a drift
  # report and a docs reviewer actually reach for.
  OWNER_NAMING_DOCS = [
    "docs/agents/modules/docs-maintenance.md",
    "docs/agents/agents/alex/role.md"
  ].freeze

  def test_unit_entry_doc_drift_prose_names_the_owned_closer
    checked = 0

    OWNER_NAMING_DOCS.each do |rel|
      path = File.join(ROOT, rel)
      assert File.file?(path), "#{rel} is missing — fix the list"
      body = File.read(path)
      refute body.empty?, "#{rel} is empty — this assertion would prove nothing"
      checked += 1

      assert_match(%r{bin/release ship}, body,
        "#{rel} must name the command that closes entry-doc drift")
      assert_match(/sync_agent_docs/, body,
        "#{rel} must name the owned step that closes entry-doc drift")
    end

    assert_equal OWNER_NAMING_DOCS.size, checked,
      "FLOOR: every listed doc must have been read"
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

  def test_integration_install_prunes_retired_qa_release_skill
    installed_qa_release_dirs.each do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "stale qa-release skill")
    end

    out, err, status = run_installer("install")

    assert status.success?, "install failed: #{err}"
    installed_qa_release_dirs.each do |dir|
      refute File.exist?(dir), "install must remove retired managed skill #{dir}"
      assert_includes out, "removed retired skill #{dir}"
    end
  end

  def test_integration_check_fails_when_retired_qa_release_skill_is_installed
    installed_qa_release_dirs.each do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "stale qa-release skill")
    end

    _out, err, status = run_installer("check")

    refute status.success?, "check must fail while retired qa-release is still installed"
    installed_qa_release_dirs.each do |dir|
      assert_includes err, "ERROR: retired managed skill still installed: #{dir}"
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
    assert_includes out, "ok: Codex update guard executable"
    assert_includes out, "ok: runtime installer executable"
    assert_includes out, "ok: installed agent docs and skills match tracked sources"
    assert_includes out, "ok: Codex config includes thread-title status item"
    assert_match(/ok: Codex (managed requirements|user hooks) include McRitchie .*hook/, out)
    assert_match(/ok: Codex (managed requirements|user hooks) include action capture/, out)
    assert_match(/ok: Codex (managed requirements|user hooks) include activity close-open/, out)
  end

  def test_integration_migrates_legacy_managed_codex_status_line
    FileUtils.mkdir_p(File.dirname(installed_codex_config))
    File.write(installed_codex_config, <<~TOML)
      [tui]
      status_line = ["model-with-reasoning", "current-dir", "thread-title"]
    TOML

    _out, err, status = run_installer("install")

    assert status.success?, "install failed: #{err}"
    assert_match(
      /^status_line = \["thread-title", "model-with-reasoning", "context-remaining"\]$/,
      File.read(installed_codex_config)
    )
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
    # The feed-forward insights hook is wired alongside the mascot, pointed at the
    # runtime root (survives worktree cleanup) and the prod board by default.
    assert_includes commands, "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/session-insights"
    refute commands.any? { |command| command.include?("/.worktrees/") }

    # The insights hook carries a bounded timeout + status message so a fresh
    # session start never hangs on the network fetch.
    insights_hook = settings.fetch("hooks").fetch("SessionStart")
      .flat_map { |entry| entry.fetch("hooks") }
      .find { |hook| hook.fetch("command").include?("/bin/session-insights") }
    assert insights_hook, "session-insights must be registered as a SessionStart hook"
    assert_equal 15, insights_hook["timeout"]
    assert_equal "Loading insights…", insights_hook["statusMessage"]

    post_tool_commands = settings.fetch("hooks").fetch("PostToolUse")
      .flat_map { |entry| entry.fetch("hooks").map { |hook| hook.fetch("command") } }
    assert_includes post_tool_commands,
      "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/atomic-capture-hook"
    session_end_commands = settings.fetch("hooks").fetch("SessionEnd")
      .flat_map { |entry| entry.fetch("hooks").map { |hook| hook.fetch("command") } }
    assert_includes session_end_commands,
      "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/agent-activity close-open"

    codex_requirements = File.read(installed_codex_requirements)
    assert_includes codex_requirements,
      %(command = "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/session-insights")
    assert_includes codex_requirements,
      %(command = "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/atomic-capture-hook")
    assert_includes codex_requirements,
      %(command = "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/agent-activity close-open")
    assert_includes codex_requirements, 'statusMessage = "Loading insights…"'

    config = File.read(installed_codex_config)
    assert_match(/^check_for_update_on_startup = false$/, config)
    assert_match(
      /^status_line = \["thread-title", "model-with-reasoning", "context-remaining"\]$/,
      config
    )
    assert_match(/terminal_title = \[[^\n]*"thread-title"/, config)
    refute_includes config, "shell_environment_policy.set",
      "installer must not replace Codex PATH and break normal Bash tool lookup"
    assert_includes File.read(installed_zprofile), "# BEGIN McRitchie agent Ruby PATH"

    refute File.exist?(installed_codex_hooks),
      "Codex mascot startup must be managed, not a user hook that requires /hooks review"

    requirements = File.read(installed_codex_requirements)
    assert_includes requirements, "# BEGIN McRitchie Codex telemetry managed hook"
    assert_includes requirements, %(managed_dir = "#{runtime_root}")
    assert_includes requirements, "[[hooks.SessionStart]]"
    assert_includes requirements, 'matcher = "startup|resume"'
    assert_includes requirements, "[[hooks.PostToolUse]]"
    assert_includes requirements, "[[hooks.Stop]]"
    assert_includes requirements, 'matcher = "Bash"'
    assert_includes requirements, %(command = "#{runtime_root}/bin/codex-session-title")
    assert_includes requirements, 'statusMessage = "Setting session mascot"'
    assert_includes requirements, 'statusMessage = "Capturing action"'
  end

  def test_integration_install_allows_runtime_ruby_path_override
    ruby_path = "/tmp/homebrew-ruby/bin:/tmp/homebrew-gems/bin"
    _out, err, status = run_installer("install", "AGENT_RUNTIME_RUBY_PATH_PREFIX" => ruby_path)

    assert status.success?, "install failed: #{err}"
    zprofile = File.read(installed_zprofile)
    assert_includes zprofile, "# BEGIN McRitchie agent Ruby PATH"
    assert_includes zprofile, "mcritchie_ruby_path_prefix=#{ruby_path}"
  end

  def test_integration_agent_runtime_doctor_checks_login_shell_ruby
    with_fake_runtime_ruby do |ruby_dir|
      env = runtime_doctor_env(ruby_dir)
      run_runtime("install", env: env)
      out, err, status = run_runtime("doctor", env: env)

      assert status.success?, "agent-runtime doctor failed:\nSTDOUT:\n#{out}\nSTDERR:\n#{err}"
      assert_includes out, "ok: agent zsh login startup prepends required Ruby path"
      assert_includes out, "ok: login shell Ruby path: #{ruby_dir}/ruby (3.3.11)"
      assert_includes out, "ok: Bundler available under login-shell Ruby"
      assert_includes out, "ok: Rails boots under login-shell Ruby"
    end
  end

  def test_integration_agent_runtime_doctor_flags_ruby_path_drift
    with_fake_runtime_ruby do |ruby_dir|
      env = runtime_doctor_env(ruby_dir)
      run_runtime("install", env: env)
      File.write(installed_zprofile, File.read(installed_zprofile).gsub(ruby_dir, "/wrong/ruby"))

      _out, err, status = run_runtime("doctor", env: env)

      refute status.success?, "doctor must fail when zsh login startup loses the Ruby path"
      assert_includes err, "agent shell login startup missing required Ruby path"
      assert_includes err, "login shell Ruby path drift"
    end
  end

  def test_integration_agent_zprofile_preserves_normal_path_lookup
    with_fake_runtime_ruby do |ruby_dir|
      env = runtime_doctor_env(ruby_dir)
      _out, err, status = run_installer("install", env)
      assert status.success?, "install failed: #{err}"

      shell_env = env.merge("PATH" => "/usr/bin:#{ruby_dir}:#{ENV.fetch('PATH', '')}")
      out, shell_err, shell_status = capture_login_shell(<<~'ZSH', shell_env)
        printf "ruby=%s\n" "$(command -v ruby)"
        printf "version="
        ruby -e 'print RUBY_VERSION'
        printf "\nenv=%s\n" "$(command -v env)"
      ZSH

      assert shell_status.success?, "login shell failed:\n#{shell_err}"
      assert_includes out, "ruby=#{ruby_dir}/ruby"
      assert_includes out, "version=3.3.11"
      assert_match(/^env=.+env$/, out, "managed Ruby path must preserve normal command lookup")
    end
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
    assert_includes requirements, "[[hooks.Stop]]"
    assert_includes requirements, %(command = "#{runtime_root}/bin/codex-session-title")
    assert_includes requirements, "/bin/atomic-capture-hook"
    assert_includes requirements, "/bin/agent-activity close-open"
  end

  def test_integration_install_prunes_legacy_claude_session_mascot_wrapper
    skip "jq is required for settings hook install" unless jq_available?

    runtime_root = "/stable/mcritchie-studio"
    legacy_cmd = [
      %(id="${CLAUDE_CODE_SESSION_ID:-$(jq -r '.session_id // empty')}";),
      %(CLAUDE_CODE_SESSION_ID="$id" #{runtime_root}/bin/task session-mascot >/dev/null 2>&1 || true)
    ].join(" ")
    current_cmd = "#{runtime_root}/bin/task session-mascot"

    FileUtils.mkdir_p(File.dirname(installed_settings))
    File.write(installed_settings, JSON.pretty_generate(
      "hooks" => {
        "SessionStart" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => legacy_cmd
              }
            ]
          },
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => current_cmd
              }
            ]
          }
        ]
      }
    ))

    _out, err, status = run_installer("install", "AGENT_DOCS_RUNTIME_ROOT" => runtime_root)

    assert status.success?, "install failed: #{err}"
    commands = JSON.parse(File.read(installed_settings)).fetch("hooks").fetch("SessionStart").flat_map do |entry|
      entry.fetch("hooks").map { |hook| hook.fetch("command") }
    end
    assert_equal 1, commands.count { |command| command == current_cmd }
    refute commands.any? { |command| command != current_cmd && command.include?("/bin/task session-mascot") },
      "legacy shell-wrapped mascot hooks must be pruned"
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
    assert_includes out, "admin install required for organic Codex telemetry"
    assert_includes out, "installed user-level Codex SessionStart/PostToolUse/Stop fallback"
    assert_includes out, "Staged managed requirements:"
    refute_includes out, "Review once inside Codex with /hooks"

    assert_includes out, "/bin/session-insights",
      "the fallback echo should report the wired insights command"
    assert_includes out, "/bin/atomic-capture-hook",
      "the fallback echo should report the wired action capture command"
    assert_includes out, "/bin/agent-activity close-open",
      "the fallback echo should report the wired close-open command"

    staged = File.join(@home, ".codex", "mcritchie-requirements.toml")
    assert File.file?(staged), "installer should stage the managed requirements for admin install"
    staged_requirements = File.read(staged)
    assert_includes staged_requirements, "/bin/codex-session-title"
    assert_includes staged_requirements, "/bin/session-insights"
    assert_includes staged_requirements, "/bin/atomic-capture-hook"
    assert_includes staged_requirements, "/bin/agent-activity close-open"
    assert_includes staged_requirements, "[[hooks.SessionStart]]"
    assert_includes staged_requirements, "[[hooks.PostToolUse]]"
    assert_includes staged_requirements, "[[hooks.Stop]]"

    codex_hooks = JSON.parse(File.read(installed_codex_hooks))
    runtime_root = ROOT.sub(%r{/\.worktrees/.*\z}, "")
    session_commands = (codex_hooks.dig("hooks", "SessionStart") || []).flat_map do |entry|
      entry.fetch("hooks", []).map { |hook| hook["command"] }
    end
    post_tool_commands = (codex_hooks.dig("hooks", "PostToolUse") || []).flat_map do |entry|
      entry.fetch("hooks", []).map { |hook| hook["command"] }
    end
    stop_commands = (codex_hooks.dig("hooks", "Stop") || []).flat_map do |entry|
      entry.fetch("hooks", []).map { |hook| hook["command"] }
    end

    # The fallback wires BOTH the mascot and the feed-forward insights hook under
    # SessionStart (insights as its own entry so each stays independently prunable),
    # then captures every tool call and closes open activities on Stop.
    assert_equal [
      "#{runtime_root}/bin/codex-session-title",
      "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/session-insights"
    ], session_commands
    assert_equal [
      "#{runtime_root}/bin/codex-session-title",
      "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/atomic-capture-hook"
    ], post_tool_commands
    assert_equal ["ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/agent-activity close-open"], stop_commands
  end

  # ── integration: the feed-forward insights SessionStart hook ────────────────

  def test_integration_wires_session_insights_hook_idempotently
    skip "jq is required for settings hook install" unless jq_available?

    runtime_root = "/stable/mcritchie-studio"
    board = "https://board.example"
    env = { "AGENT_DOCS_RUNTIME_ROOT" => runtime_root, "AGENT_INSIGHTS_BOARD_URL" => board }

    2.times do # idempotent: re-running must not duplicate the hook
      _out, err, status = run_installer("install", env)
      assert status.success?, "install failed: #{err}"
    end

    settings = JSON.parse(File.read(installed_settings))
    insights = settings.fetch("hooks").fetch("SessionStart")
      .flat_map { |entry| entry.fetch("hooks") }
      .select { |hook| hook.fetch("command").include?("/bin/session-insights") }
    assert_equal 1, insights.length, "exactly one insights hook after two installs"
    assert_equal "ATOMIC_CAPTURE_URL=#{board} #{runtime_root}/bin/session-insights",
      insights.first.fetch("command"),
      "the board URL override must flow into the wired command"
  end

  def test_integration_prunes_stale_worktree_session_insights_hook
    skip "jq is required for settings hook install" unless jq_available?

    FileUtils.mkdir_p(File.dirname(installed_settings))
    File.write(installed_settings, JSON.pretty_generate(
      "hooks" => {
        "SessionStart" => [
          {
            "hooks" => [
              {
                "type" => "command",
                "command" => "/repo/.worktrees/old-slug/bin/session-insights",
                "timeout" => 15
              }
            ]
          }
        ]
      }
    ))

    runtime_root = "/stable/mcritchie-studio"
    _out, err, status = run_installer("install", "AGENT_DOCS_RUNTIME_ROOT" => runtime_root)
    assert status.success?, "install failed: #{err}"

    commands = JSON.parse(File.read(installed_settings)).fetch("hooks").fetch("SessionStart")
      .flat_map { |entry| entry.fetch("hooks").map { |hook| hook.fetch("command") } }
    refute commands.any? { |command| command.include?("/.worktrees/") },
      "the stale worktree insights hook must be pruned"
    assert_equal 1, commands.count { |command| command.include?("/bin/session-insights") },
      "the pruned worktree hook must be replaced by exactly one runtime-root hook"
    assert_includes commands, "ATOMIC_CAPTURE_URL=https://mcritchie.studio #{runtime_root}/bin/session-insights"
  end
end
