# frozen_string_literal: true

# [unit] AgentsBackup — which files the nightly agent-state backup copies, and
# how the runner drives rclone. Built against a temp tree that plants every kind
# of token or secret file .agents has held, so an exclusion that stops matching
# fails here, not in the bucket.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/agents_backup"

class AgentsBackupTest < Minitest::Test
  NOW = Time.utc(2026, 11, 7, 9, 41, 0)

  KEPT = %w[
    epics/plan.md
    handoffs/shots/locked-board-dark.png
    sessions/abc.json
    memory-notes/hub-entry-tokens.md
    memory-notes/secret-cache-design.md
  ].freeze

  SECRET = %w[
    atomic-capture/token.json
    harness-key.json
    github-tokens.json.lock
    deploy.token
    .env
    .env.local
    app.env
    handoffs/preship/keys.txt
    certs/server.pem
    certs/server.key
    gcp-credentials.json
    client_secret.json
    desk-ledger-queue.jsonl.lock
    .secret-cache/github-tokens.json
    tooling/abc123/bin/task
    bin.pre-tooling-20260925163609/gh-app-mint-token.rb
    locks/release.lock.json
    op-reads.log
    sessions/abc.admin-login
  ].freeze

  def setup
    @root = Dir.mktmpdir("agents-backup-test")
    (KEPT + SECRET).each do |rel|
      path = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "x")
    end
    # A symlink into the secret cache, as .agents/github-tokens.json is, and a
    # symlinked folder: neither is followed.
    File.symlink(File.join(@root, ".secret-cache/github-tokens.json"), File.join(@root, "github-tokens.json"))
    File.symlink(File.join(@root, "tooling"), File.join(@root, "bin"))
  end

  def teardown = FileUtils.rm_rf(@root)

  def test_plan_keeps_ordinary_files_and_notes_about_tokens
    assert_equal KEPT.sort, AgentsBackup.plan(@root)
  end

  def test_plan_excludes_every_token_and_secret_file
    planned = AgentsBackup.plan(@root)
    leaked = SECRET.select { |rel| planned.include?(rel) }
    assert_empty leaked, "token or secret files reached the backup plan"
    refute_includes planned, "github-tokens.json", "a symlink into .secret-cache is never followed"
    refute(planned.any? { |p| p.start_with?("bin/") }, "a symlinked folder is never entered")
  end

  def test_plan_of_a_missing_root_is_empty
    assert_equal [], AgentsBackup.plan(File.join(@root, "absent"))
  end

  def test_sources_take_the_defaults_and_an_env_override
    defaults = { "agents" => "/a", "memory" => "/m" }
    assert_equal defaults, AgentsBackup.sources(defaults, {})
    assert_equal "/tmp/x", AgentsBackup.sources(defaults, "AGENTS_BACKUP_MEMORY_DIR" => "/tmp/x")["memory"]
  end

  def test_expired_stamps_returns_only_old_stamp_shaped_names
    names = ["20261001T093700Z/\n", "20261020T093700Z/\n", "not-a-stamp/\n", "20261107T093700Z/\n"] # rclone lsf lines
    assert_equal ["20261001T093700Z"], AgentsBackup.expired_stamps(names, now: NOW, days: 30)
  end

  def test_rclone_env_encrypts_names_and_points_at_the_private_bucket
    env = AgentsBackup.rclone_env("endpoint" => "https://e", "access-key-id" => "i", "secret-access-key" => "s",
                                  "crypt-password-obscured" => "p", "crypt-salt-obscured" => "q")
    assert_equal "crypt", env["RCLONE_CONFIG_AB_CRYPT_TYPE"]
    assert_equal "ab_r2:mcritchie-agents-backup", env["RCLONE_CONFIG_AB_CRYPT_REMOTE"]
    assert_equal "standard", env["RCLONE_CONFIG_AB_CRYPT_FILENAME_ENCRYPTION"]
    assert_equal "true", env["RCLONE_CONFIG_AB_CRYPT_DIRECTORY_NAME_ENCRYPTION"]
  end

  # --- the runner, against a recording fake rclone ---------------------------------

  class FakeShell
    attr_reader :calls, :lists

    def initialize(lsf: "", copy_rc: 0)
      @calls = []
      @lists = []
      @lsf = lsf
      @copy_rc = copy_rc
    end

    def call(argv, _env)
      @calls << argv
      if argv[1] == "copy"
        @lists << File.read(argv[argv.index("--files-from-raw") + 1]).split("\n")
        return ["", @copy_rc]
      end
      return [@lsf, 0] if argv[1] == "lsf"

      ["", 0]
    end
  end

  def runner(shell) = AgentsBackup::Runner.new(env: {}, shell: shell, sources: { "agents" => @root })

  def test_run_copies_exactly_the_plan_through_the_crypt_remote_never_sync
    shell = FakeShell.new
    receipt = runner(shell).run(now: NOW)
    assert receipt["ok"]
    copy = shell.calls.find { |a| a[1] == "copy" }
    assert_equal "ab_crypt:current/agents", copy[3]
    assert_includes copy, "ab_crypt:archive/20261107T094100Z/agents"
    assert_equal KEPT.sort, shell.lists.first
    refute(shell.calls.any? { |a| a[1] == "sync" }, "a run never syncs: a wiped folder must not wipe its backup")
  end

  def test_run_collects_expired_archive_stamps_only_after_a_good_copy
    shell = FakeShell.new(lsf: "20261001T093700Z/\n20261101T093700Z/\n")
    receipt = runner(shell).run(now: NOW)
    assert_equal ["20261001T093700Z"], receipt["collected"]
    assert_includes shell.calls, ["rclone", "purge", "ab_crypt:archive/20261001T093700Z"]

    failed = FakeShell.new(lsf: "20261001T093700Z/\n", copy_rc: 1)
    receipt = runner(failed).run(now: NOW)
    refute receipt["ok"]
    refute(failed.calls.any? { |a| a[1] == "purge" }, "a failed run collects nothing")
  end

  def test_dry_run_passes_dry_run_and_purges_nothing
    shell = FakeShell.new(lsf: "20261001T093700Z/\n")
    runner(shell).run(now: NOW, dry_run: true)
    assert_includes shell.calls.find { |a| a[1] == "copy" }, "--dry-run"
    refute(shell.calls.any? { |a| a[1] == "purge" })
  end

  def test_an_empty_source_is_not_ok
    FileUtils.rm_rf(Dir.glob(File.join(@root, "*")) + Dir.glob(File.join(@root, ".[a-z]*")))
    refute runner(FakeShell.new).run(now: NOW)["ok"], "an empty plan is a broken source, not a good night"
  end

  def test_restore_copies_one_file_out_of_current_and_refuses_escapes
    shell = FakeShell.new
    target, rc = runner(shell).restore("agents", "epics/plan.md", File.join(@root, "out"))
    assert_equal 0, rc
    assert_equal File.join(@root, "out", "plan.md"), target
    assert_includes shell.calls, ["rclone", "copyto", "ab_crypt:current/agents/epics/plan.md", target]
    assert_raises(ArgumentError) { runner(shell).restore("agents", "../etc/passwd", @root) }
    assert_raises(ArgumentError) { runner(shell).restore("nope", "a", @root) }
  end
end
