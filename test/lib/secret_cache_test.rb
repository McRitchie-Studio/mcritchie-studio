# frozen_string_literal: true

# [unit] bin/lib/secret_cache.rb — the shared cache for expiring credentials.
#
# Every case runs against a tmpdir folder (MCR_SECRET_CACHE_DIR / CLAUDE_PROJECTS_DIR);
# nothing here reads 1Password, mints a token, or touches the operator's real
# <projects>/.secret-cache.
#
#   ruby -Itest test/lib/secret_cache_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "time"
require "securerandom"
require "stringio"
require_relative "../../bin/lib/secret_cache"
require_relative "../../bin/lib/secret_cache_cli"
# The narration hook, loaded for its pure redaction predicate (main is guarded).
load File.expand_path("../../bin/atomic-capture-hook", __dir__) unless defined?(AtomicCaptureHook)

class SecretCacheTest < Minitest::Test
  TOKEN = "ghs_UNITSECRETVALUE0123456789"

  def with_home
    Dir.mktmpdir("secret-cache-unit") do |root|
      env = { "CLAUDE_PROJECTS_DIR" => root, "TASK_USAGE_SANDBOX" => "1" }
      yield root, env, File.join(root, ".secret-cache")
    end
  end

  def seed_github(env, created_at)
    SecretCache.write_json(SecretCache::GITHUB_FILE,
                           { "agent" => { "active" => "a",
                                          "a" => { "token" => TOKEN, "created_at" => created_at.utc.iso8601 } } },
                           env: env)
  end

  # ── where ──────────────────────────────────────────────────────────────────

  def test_unit_the_folder_is_top_level_under_projects_not_inside_dot_agents
    assert_equal "/p/.secret-cache", SecretCache.dir("CLAUDE_PROJECTS_DIR" => "/p")
    assert_equal "/elsewhere", SecretCache.dir("CLAUDE_PROJECTS_DIR" => "/p", "MCR_SECRET_CACHE_DIR" => "/elsewhere")
    unarmed = { "TASK_USAGE_SANDBOX" => "0" }
    assert_equal File.join(File.expand_path("~/projects"), ".secret-cache"), SecretCache.dir(unarmed)
    refute_includes SecretCache.dir(unarmed), "/.agents/"
  end

  # An armed run READS nothing from the real folder, quietly; it never aborts a read.
  def test_unit_an_armed_unpinned_read_answers_nothing
    armed = { "TASK_USAGE_SANDBOX" => "1" }
    assert_nil SecretCache.readable_dir(armed)
    assert_nil SecretCache.read_json(SecretCache::GITHUB_FILE, env: armed)
    assert_equal "", SecretCache.session_block(env: armed)
  end

  # ── the folder's shape ─────────────────────────────────────────────────────

  def test_unit_ensure_home_makes_a_0700_folder_with_a_readme_and_a_value_free_manifest
    with_home do |_root, env, home|
      SecretCache.ensure_home!(env)

      assert_equal 0o700, File.stat(home).mode & 0o777
      %w[README.md manifest.json].each do |file|
        assert_equal 0o600, File.stat(File.join(home, file)).mode & 0o777, file
      end
      entries = JSON.parse(File.read(File.join(home, "manifest.json")))["entries"]
      assert_equal %w[github.agent github.deployer harness-key], entries.keys.sort
      %w[lifetime refresh_window source owner readers on_expired contingency].each do |field|
        refute_nil entries["github.agent"][field], "github.agent lacks #{field}"
      end
      assert_equal 600, entries["github.agent"]["refresh_window_seconds"], "GitHub's window is the last 10 minutes"
      assert_equal 4, entries["github.agent"]["contingency"].size
      assert_includes entries["github.agent"]["contingency"][2], "quit and reopen the 1Password app"
      assert_equal false, entries["github.deployer"]["persist"], "the deployer token is never on disk"
      readme = File.read(File.join(home, "README.md"))
      assert_includes readme, "secret-cache.md"
      assert_includes readme, "Production dynos cannot read this folder"
    end
  end

  def test_unit_operator_edits_to_the_manifest_survive_and_new_defaults_are_added
    with_home do |_root, env, home|
      FileUtils.mkdir_p(home, mode: 0o700)
      File.write(File.join(home, "manifest.json"),
                 JSON.generate("entries" => { "github.agent" => { "owner" => "alex" },
                                              "agent.heroku" => { "kind" => "op-item" } }), perm: 0o600)
      SecretCache.ensure_home!(env)
      entries = JSON.parse(File.read(File.join(home, "manifest.json")))["entries"]

      assert_equal "alex", entries["github.agent"]["owner"], "an operator edit is kept"
      assert_equal "op-item", entries["agent.heroku"]["kind"], "an operator-named entry is kept"
      assert entries.key?("harness-key"), "a missing default is added"
    end
  end

  # ── guards: perms must not widen, the folder may not sit in a repo ───────────

  def test_unit_a_widened_folder_fails_loudly_on_read_and_write
    with_home do |_root, env, home|
      SecretCache.ensure_home!(env)
      File.chmod(0o755, home)

      error = assert_raises(SecretCache::Unsafe) { SecretCache.read_json(SecretCache::GITHUB_FILE, env: env) }
      assert_includes error.message, "chmod 700"
      assert_raises(SecretCache::Unsafe) { SecretCache.write_json("x.json", {}, env: env) }
      assert_includes SecretCache.session_block(env: env), "UNSAFE", "session start says so too"
    end
  end

  def test_unit_a_widened_file_fails_loudly
    with_home do |_root, env, home|
      seed_github(env, Time.now)
      File.chmod(0o644, File.join(home, SecretCache::GITHUB_FILE))

      error = assert_raises(SecretCache::Unsafe) { SecretCache.read_json(SecretCache::GITHUB_FILE, env: env) }
      assert_includes error.message, "chmod 600"
      refute_includes error.message, TOKEN
    end
  end

  def test_unit_a_folder_inside_a_git_repository_is_refused
    with_home do |root, env, _home|
      FileUtils.mkdir_p(File.join(root, ".git"))
      File.write(File.join(root, ".git", "HEAD"), "ref: refs/heads/main\n")

      error = assert_raises(SecretCache::Unsafe) { SecretCache.ensure_home!(env) }
      assert_includes error.message, "inside the git repository"
      refute File.exist?(File.join(root, ".secret-cache")), "nothing was created inside the repo"
    end
  end

  # A stray `.git` folder with no HEAD is not a repository (~/.git on this Mac).
  def test_unit_a_stray_dot_git_folder_without_head_is_not_a_repository
    with_home do |root, env, home|
      FileUtils.mkdir_p(File.join(root, ".git", "info"))
      SecretCache.ensure_home!(env)
      assert File.directory?(home)
    end
  end

  # Control for the guard above: the same tree without `.git` is accepted.
  def test_unit_the_git_guard_passes_outside_a_repository
    with_home do |_root, env, home|
      SecretCache.ensure_home!(env)
      assert File.directory?(home)
    end
  end

  def test_unit_an_armed_sandbox_with_no_pin_refuses_the_real_folder
    pid = fork do
      $stderr.reopen(File::NULL)
      SecretCache.ensure_home!("TASK_USAGE_SANDBOX" => "1")
      exit!(0)
    end
    Process.wait(pid)
    refute $?.success?, "an unpinned sandboxed write must abort, never reach the operator's folder"
  end

  # Regression (CI 2026-10-27, credential_remedy_reaches_the_operator_test): a failed
  # deployer mint in an armed, unpinned run aborted on its BOOKKEEPING, hiding the
  # remedy the operator needed. Recording a mint or a failure never aborts.
  def test_unit_bookkeeping_in_an_armed_unpinned_run_records_nothing_and_never_aborts
    armed = { "TASK_USAGE_SANDBOX" => "1" }
    assert_equal false, SecretCache.record_failure!("github.deployer", env: armed)
    assert_equal false, SecretCache.record_mint!("github.agent", Time.now, env: armed)
  end

  # ── time left, in words ────────────────────────────────────────────────────

  def test_unit_states_read_in_plain_words
    now = Time.utc(2026, 10, 27, 12, 0, 0)
    fresh = SecretCache.timed_state(now + 42 * 60, 600, now)
    window = SecretCache.timed_state(now + 6 * 60, 600, now)
    expired = SecretCache.timed_state(now - 3 * 60, 600, now)

    assert_equal [:fresh, "expires in 42 min"], [fresh[:state], fresh[:words]]
    assert_equal :window, window[:state]
    assert_includes window[:words], "the next read refreshes"
    assert_equal :expired, expired[:state]
    assert_equal "expired 3 min ago — refreshes on next read", expired[:words]
    assert_equal "1 h 5 min", SecretCache.duration_words(65 * 60)
    assert_equal "under a minute", SecretCache.duration_words(20)
  end

  def test_unit_status_reports_time_left_and_never_the_value
    with_home do |_root, env, _home|
      seed_github(env, Time.now - 18 * 60)
      lines = SecretCache.status_lines(env: env).join("\n")

      assert_match(/github\.agent: expires in 4[12] min/, lines)
      assert_includes lines, "github.deployer: not cached by design"
      refute_includes lines, TOKEN
      refute_match(/ghs_/, lines)
    end
  end

  def test_unit_expires_at_prefers_the_recorded_stamp_then_created_plus_an_hour
    created = Time.utc(2026, 10, 27, 12, 0, 0)
    assert_equal created + 3600, SecretCache.slot_expires_at("token" => "t", "created_at" => created.iso8601)
    stamp = created + 1800
    assert_equal stamp, SecretCache.slot_expires_at("token" => "t", "created_at" => created.iso8601,
                                                    "expires_at" => stamp.iso8601)
    assert_nil SecretCache.slot_expires_at("created_at" => created.iso8601), "no token, no expiry"
  end

  # ── session start ──────────────────────────────────────────────────────────

  def test_unit_session_block_is_silent_without_a_folder
    with_home { |_root, env, _home| assert_equal "", SecretCache.session_block(env: env) }
  end

  def test_unit_session_block_names_an_entry_expiring_within_the_hour_and_a_failed_refresh
    with_home do |_root, env, _home|
      seed_github(env, Time.now - 55 * 60)
      block = SecretCache.session_block(env: env)
      assert_includes block, "github.agent: expires in"
      assert_includes block, "refreshes itself on read"

      SecretCache.record_failure!("github.agent", env: env)
      assert_includes SecretCache.session_block(env: env), "LAST REFRESH FAILED"
      refute_includes SecretCache.session_block(env: env), TOKEN
    end
  end

  def test_unit_session_block_skips_an_entry_with_more_than_an_hour_left
    with_home do |_root, env, _home|
      seed_github(env, Time.now)
      assert_equal "", SecretCache.session_block(env: env, horizon: 30 * 60)
    end
  end

  # ── mint bookkeeping and the contingency ──────────────────────────────────

  def test_unit_a_mint_stamps_expires_at_and_clears_a_recorded_failure
    with_home do |_root, env, home|
      SecretCache.record_failure!("github.agent", env: env)
      expires = Time.utc(2026, 10, 27, 13, 0, 0)
      SecretCache.record_mint!("github.agent", expires, env: env)
      entry = JSON.parse(File.read(File.join(home, "manifest.json")))["entries"]["github.agent"]

      assert_equal expires.iso8601, entry["expires_at"]
      assert_nil entry["last_refresh_failed_at"]
    end
  end

  def test_unit_the_contingency_is_ordered_and_names_the_other_identity
    with_home do |_root, env, _home|
      seed_github(env, Time.now - 10 * 60)
      deployer = SecretCache.contingency_lines("github.deployer", env: env)
      agent = SecretCache.contingency_lines("github.agent", env: env)

      assert_equal 5, deployer.size, "a header and four steps"
      assert_match(/Now: github\.agent is expires in 49|Now: github\.agent is expires in 50/, deployer[1])
      assert_includes deployer[2], "token-session"
      assert_includes deployer[3], "quit and reopen the 1Password app"
      assert_includes deployer[4], "blocker"
      assert_includes agent[1], "github.deployer is not cached by design"
      refute_includes (deployer + agent).join, TOKEN
    end
  end

  # ── legacy adoption ────────────────────────────────────────────────────────

  def test_unit_a_legacy_file_moves_in_and_leaves_a_symlink_that_still_reads
    with_home do |root, env, home|
      legacy = File.join(root, ".agents", "harness-key.json")
      FileUtils.mkdir_p(File.dirname(legacy))
      File.write(legacy, JSON.generate("token" => "KEY"), perm: 0o600)

      SecretCache.adopt_legacy!(legacy, "harness-key.json", env: env)

      assert File.symlink?(legacy), "the old path is now a link"
      assert_equal File.join(home, "harness-key.json"), File.readlink(legacy)
      assert_equal "KEY", JSON.parse(File.read(legacy))["token"], "an old reader still finds the key"
      assert_equal 0o600, File.stat(File.join(home, "harness-key.json")).mode & 0o777

      SecretCache.adopt_legacy!(legacy, "harness-key.json", env: env)
      assert File.symlink?(legacy), "idempotent"
    end
  end

  def test_unit_a_legacy_file_an_older_writer_rewrote_is_relinked_only_on_request
    with_home do |root, env, home|
      SecretCache.write_json("github-tokens.json", { "agent" => {} }, env: env)
      legacy = File.join(root, ".agents", "github-tokens.json")
      FileUtils.mkdir_p(File.dirname(legacy))
      File.write(legacy, "{}")

      SecretCache.adopt_legacy!(legacy, "github-tokens.json", env: env)
      refute File.symlink?(legacy), "without relink the older writer's file is left for the read-through"

      SecretCache.adopt_legacy!(legacy, "github-tokens.json", env: env, relink: true)
      assert_equal File.join(home, "github-tokens.json"), File.readlink(legacy)
    end
  end

  # ── op-item values (none by default) ──────────────────────────────────────

  def test_unit_an_op_item_value_is_served_until_its_refresh_window
    with_home do |_root, env, home|
      SecretCache.ensure_home!(env)
      manifest = JSON.parse(File.read(File.join(home, "manifest.json")))
      manifest["entries"]["agent.heroku"] = { "kind" => "op-item", "vault" => "v", "item" => "agent.heroku",
                                              "lifetime_seconds" => 3600, "refresh_window_seconds" => 600 }
      File.write(File.join(home, "manifest.json"), JSON.generate(manifest))
      now = Time.now
      SecretCache.store_item("agent.heroku", "VALUE", env: env, now: now)

      assert_equal "VALUE", SecretCache.cached_item("agent.heroku", env: env, now: now + 60)
      assert_nil SecretCache.cached_item("agent.heroku", env: env, now: now + 3100), "inside the window: refetch"
      assert_equal "agent.heroku", SecretCache.item_entry("v", "agent.heroku", "password", env).first
      assert_nil SecretCache.item_entry("v", "other", "password", env)
    end
  end
  # ── hardening (secret-cache-hardening) ────────────────────────────────────

  # A stand-in bin/gh-token: --expires-at prints the expiry in +state+; --force
  # either mints (moves the expiry an hour out) or, with +fallback+, prints the
  # real script's fallback warning and leaves the expiry where it was.
  def stub_gh_token(dir, fallback:)
    state = File.join(dir, "expires_at")
    File.write(state, (Time.now.utc + 26 * 60).iso8601)
    bin = File.join(dir, "gh-token-stub")
    mint = fallback ? "echo 'gh-token: refresh failed (1Password unreadable); serving the cached agent token that is still valid' >&2" : "echo #{(Time.now.utc + 3600).iso8601} > #{state}"
    File.write(bin, <<~SH)
      #!/bin/sh
      case "$*" in
        *--expires-at*) cat #{state} ;;
        *--force*) #{mint}; echo ghs_STUBTOKEN ;;
      esac
    SH
    File.chmod(0o755, bin)
    bin
  end

  # SecureRandom.hex answers +value+ inside the block (minitest 6 has no stub).
  def with_fixed_hex(value)
    original = SecureRandom.method(:hex)
    SecureRandom.define_singleton_method(:hex) { |*_args| value }
    yield
  ensure
    SecureRandom.define_singleton_method(:hex, original)
  end

  def cli(argv, env)
    out = StringIO.new
    err = StringIO.new
    code = SecretCacheCli.run(argv, env: env, out: out, err: err)
    [code, out.string, err.string]
  end

  # Item 1. The 2026-10-27 report: "refreshed — expires in 26 min" right after
  # "refresh failed (1Password unreadable); serving the cached agent token".
  def test_unit_refresh_and_prewarm_say_served_cached_fallback_when_1password_failed
    with_home do |root, env, _home|
      env = env.merge("SECRET_GH_TOKEN_BIN" => stub_gh_token(root, fallback: true),
                      "SECRET_PREWARM_IN_SANDBOX" => "1")

      code, out, = cli(%w[refresh github.agent], env)
      assert_equal 1, code, "a refresh that did not refresh is not a success"
      assert_includes out, "github.agent: served cached fallback"
      refute_includes out, "refreshed"
      refute_includes out, "ghs_STUBTOKEN"

      code, out, = cli(%w[prewarm], env)
      assert_equal 0, code, "prewarm is never fatal"
      assert_includes out, "github.agent: served cached fallback"
      refute_includes out, "refreshed"
    end
  end

  # The control: a real mint still says refreshed.
  def test_unit_refresh_says_refreshed_when_the_mint_succeeded
    with_home do |root, env, _home|
      env = env.merge("SECRET_GH_TOKEN_BIN" => stub_gh_token(root, fallback: false))

      code, out, = cli(%w[refresh github.agent], env)
      assert_equal 0, code
      assert_includes out, "github.agent: refreshed — expires in"
      refute_includes out, "fallback"
    end
  end

  # The expiry that did not move is caught even when the warning wording changes.
  def test_unit_an_expiry_that_did_not_advance_is_a_fallback
    at = Time.now
    assert SecretCacheCli.served_fallback?("", at, at)
    assert SecretCacheCli.served_fallback?("", at, nil)
    refute SecretCacheCli.served_fallback?("", at, at + 3600)
    refute SecretCacheCli.served_fallback?("", nil, at + 3600)
  end

  # Item 2.
  def test_unit_atomic_write_opens_its_temp_file_o_excl_and_o_nofollow
    flags = SecretCache.atomic_write_flags
    assert_equal File::EXCL, flags & File::EXCL
    assert_equal File::NOFOLLOW, flags & File::NOFOLLOW

    with_home do |root, env, home|
      SecretCache.ensure_home!(env)
      target = File.join(home, "x.json")
      outside = File.join(root, "outside.txt")
      File.write(outside, "untouched")
      with_fixed_hex("fixedfixedfixed0") do
        tmp = "#{target}.#{Process.pid}.fixedfixedfixed0.tmp"
        File.symlink(outside, tmp)
        assert_raises(Errno::EEXIST) { SecretCache.atomic_write(target, TOKEN) }
        assert_equal "untouched", File.read(outside), "a planted symlink never receives the secret"
        assert File.symlink?(tmp), "a temp name this call did not create is not deleted"
        File.delete(tmp)

        File.write(tmp, "planted")
        assert_raises(Errno::EEXIST) { SecretCache.atomic_write(target, TOKEN) }
        assert_equal "planted", File.read(tmp)
        File.delete(tmp)
      end
      refute File.exist?(target)
      SecretCache.atomic_write(target, "{}")
      assert_equal 0o600, File.stat(target).mode & 0o777
      assert_empty Dir.glob("#{target}.*.tmp"), "no temp file is left behind"
    end
  end

  # Item 3.
  def test_unit_check_file_refuses_a_symlink_and_a_file_another_user_owns
    with_home do |root, env, home|
      seed_github(env, Time.now)
      path = File.join(home, SecretCache::GITHUB_FILE)

      error = assert_raises(SecretCache::Unsafe) { SecretCache.check_file!(path, uid: Process.euid + 1) }
      assert_includes error.message, "owned by uid #{Process.euid}"
      assert_equal path, SecretCache.check_file!(path), "the owner's 0600 file passes"

      elsewhere = File.join(root, "planted.json")
      File.write(elsewhere, JSON.generate("agent" => {}), perm: 0o600)
      File.delete(path)
      File.symlink(elsewhere, path)
      error = assert_raises(SecretCache::Unsafe) { SecretCache.read_json(SecretCache::GITHUB_FILE, env: env) }
      assert_includes error.message, "symlink"
      File.delete(path)
      File.symlink(File.join(root, "missing.json"), path)
      assert_raises(SecretCache::Unsafe) { SecretCache.check_file!(path) }
    end
  end

  # Item 4.
  def test_unit_an_admin_vault_item_is_never_written_to_disk
    with_home do |_root, env, home|
      SecretCache.ensure_home!(env)
      manifest = JSON.parse(File.read(File.join(home, "manifest.json")))
      manifest["entries"]["deploy.key"] = { "kind" => "op-item", "vault" => "studio-agents-admin",
                                            "item" => "deploy.key", "lifetime_seconds" => 3600 }
      File.write(File.join(home, "manifest.json"), JSON.generate(manifest))

      error = assert_raises(SecretCache::AdminVaultRefused) { SecretCache.store_item("deploy.key", "VALUE", env: env) }
      assert_includes error.message, "deploy.key"
      refute File.exist?(File.join(home, SecretCache.value_file("deploy.key")))
      File.write(File.join(home, SecretCache.value_file("deploy.key")),
                 JSON.generate("value" => "PLANTED", "expires_at" => (Time.now + 3600).utc.iso8601), perm: 0o600)
      assert_raises(SecretCache::AdminVaultRefused) { SecretCache.cached_item("deploy.key", env: env) }

      deployer = { "deployer" => { "active" => "a", "a" => { "token" => TOKEN } } }
      error = assert_raises(SecretCache::AdminVaultRefused) do
        SecretCache.write_json(SecretCache::GITHUB_FILE, deployer, env: env)
      end
      assert_includes error.message, "github.deployer"
      refute_includes error.message, TOKEN
      refute File.exist?(File.join(home, SecretCache::GITHUB_FILE))

      renamed = env.merge("MCR_OP_VAULT_ADMIN" => "ops-admin")
      assert SecretCache.admin_entry?({ "vault" => "ops-admin" }, renamed), "a renamed admin vault is refused too"
      refute SecretCache.admin_entry?({ "vault" => "studio-agents" }, env)
      SecretCache.write_json(SecretCache::GITHUB_FILE, { "agent" => {} }, env: env)
      assert File.exist?(File.join(home, SecretCache::GITHUB_FILE)), "the agent identity still persists"
    end
  end

  # Item 5. Pinned by MCR_SECRET_CACHE_DIR alone (no CLAUDE_PROJECTS_DIR), the
  # forget used to abort on the legacy path and leave the folder's key in place.
  def test_unit_forget_harness_key_removes_the_file_under_mcr_secret_cache_dir
    Dir.mktmpdir("secret-cache-forget") do |root|
      home = File.join(root, "pinned-cache")
      env = { "MCR_SECRET_CACHE_DIR" => home, "TASK_USAGE_SANDBOX" => "1" }
      SecretCache.write_json(SecretCache::HARNESS_FILE, { "token" => "HARNESSVALUE" }, env: env)
      assert File.exist?(File.join(home, SecretCache::HARNESS_FILE))

      code, out, err = cli(%w[forget harness-key], env)
      assert_equal 0, code, err
      assert_includes out, "harness-key: forgotten"
      refute File.exist?(File.join(home, SecretCache::HARNESS_FILE))
    end
  end

  # Item 6. The narration hook blanked every `bin/secret` line; the metadata
  # subcommands print no value and must stay legible. Readers stay suppressed.
  def test_unit_the_narration_hook_keeps_bin_secret_metadata_output
    hook = AtomicCaptureHook.new(env: { "CLAUDE_PROJECTS_DIR" => "/nonexistent-secret-cache" })
    bash = ->(command) { { "tool_name" => "Bash", "tool_input" => { "command" => command } } }

    ["bin/secret status", "/Users/alex/projects/.agents/bin/secret refresh github.agent --if-under 45",
     "bin/secret prewarm 2>&1 | tail -3", "bin/secret forget harness-key", "bin/secret contingency github.agent"].each do |cmd|
      refute hook.reads_secret_material?(bash.call(cmd)), cmd
    end
    ["bin/secret get github.agent", "bin/secret agents agent.heroku 'api key'",
     "bin/secret status; bin/secret get github.agent"].each do |cmd|
      assert hook.reads_secret_material?(bash.call(cmd)), cmd
    end
  end
end
