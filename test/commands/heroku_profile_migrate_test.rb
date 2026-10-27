# frozen_string_literal: true

# [unit] bin/heroku-profile-migrate against fixture profiles (never the real
# ~/.zprofile): literal HRKU- tokens come out, the managed block goes in, a
# second run changes nothing, a 0600 backup keeps the original, and no output
# line ever carries a token. Its preflight refuses to strand a lane.
#
# Run directly:  ruby -Itest test/commands/heroku_profile_migrate_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/fake_heroku_op"

class HerokuProfileMigrateTest < Minitest::Test
  BIN = File.expand_path("../../bin/heroku-profile-migrate", __dir__)
  STALE_AGENTS = "HRKU-stale-agents-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  STALE_ADMIN = "HRKU-stale-admin-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  STALE_APPS = "HRKU-stale-apps-cccccccccccccccccccccccccccccccccccccccccccccc"
  STRAY = "HRKU-stray-dddddddddddddddddddddddddddddddddddddddddddddddddddd"
  LIVE = "HRKU-live-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  SECRETS = [STALE_AGENTS, STALE_ADMIN, STALE_APPS, STRAY, LIVE, "ops_fixture_agent", "ops_fixture_admin"].freeze

  ZPROFILE = <<~SH
    export HEROKU_API_KEY=#{STALE_AGENTS}
    eval "$(/opt/homebrew/bin/brew shellenv)"
    # HEROKU_API_KEY is documented here; this comment survives
    export OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_agent
  SH

  ZPROFILE_ADMIN = <<~SH
    export OP_ADMIN_SERVICE_ACCOUNT_TOKEN=ops_fixture_admin
    export HEROKU_STUDIO_ADMIN_API_KEY="#{STALE_ADMIN}"
    HEROKU_STUDIO_AGENTS_API_KEY=#{STALE_AGENTS}
      export HEROKU_STUDIO_APPLICATIONS_API_KEY='#{STALE_APPS}'
    export SOME_OTHER_KEY=#{STRAY}
  SH

  def setup
    @dir = Dir.mktmpdir("heroku-profile-migrate")
    @home = File.join(@dir, "home")
    FileUtils.mkdir_p(@home)
    @zprofile = File.join(@home, ".zprofile")
    @admin = File.join(@home, ".zprofile.admin")
    File.write(@zprofile, ZPROFILE)
    File.write(@admin, ZPROFILE_ADMIN)
    [@zprofile, @admin].each { |p| File.chmod(0o600, p) }
    @shims = File.join(@dir, "shims")
    FileUtils.mkdir_p(@shims)
    File.write(File.join(@shims, "heroku"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(@shims, "heroku"))
    @op = FakeHerokuOp.install(File.join(@dir, "op"), "studio-agents/heroku.studio.agents" => LIVE,
                                                      "studio-agents-admin/heroku.studio.admin" => LIVE,
                                                      "studio-applications/heroku.studio.applications" => LIVE)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def run_bin(*args, env: {})
    base = FakeHerokuOp::SCRUB.merge(
      "HOME" => @home,
      "HEROKU_PROFILE_ZPROFILE" => @zprofile,
      "HEROKU_PROFILE_ZPROFILE_ADMIN" => @admin,
      "HEROKU_TOKEN_OP_BIN" => @op,
      "OP_SERVICE_ACCOUNT_TOKEN" => "ops_fixture_agent",
      "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "ops_fixture_admin",
      # A stale export in the migrator's own shell must not vouch for the item.
      "HEROKU_API_KEY" => STALE_AGENTS,
      "MCR_OP_READS_LOG" => File.join(@dir, "op-reads.log")
    )
    out, err, status = Open3.capture3(SessionEnv.neutralized(base.merge(env)), "ruby", BIN, "--shim-dir", @shims, *args)
    SECRETS.each do |secret|
      refute_includes out, secret, "stdout carried a secret"
      refute_includes err, secret, "stderr carried a secret"
    end
    [out, err, status]
  end

  def backups(path)
    Dir.glob("#{path}.bak-heroku-token-*")
  end

  def mode(path)
    File.stat(path).mode & 0o777
  end

  def test_literals_become_the_managed_block_with_a_private_backup
    out, err, status = run_bin

    assert status.success?, "#{out}\n#{err}"
    body = File.read(@zprofile)
    admin = File.read(@admin)
    [STALE_AGENTS, STALE_ADMIN, STALE_APPS].each do |token|
      refute_includes body + admin, token, "a literal Heroku token survived"
    end
    refute_match(/^\s*(export\s+)?HEROKU_[A-Z_]*=/, body + admin)
    assert_includes body, "# HEROKU_API_KEY is documented here; this comment survives"
    assert_includes body, "export OP_SERVICE_ACCOUNT_TOKEN=ops_fixture_agent"
    assert_includes admin, "export OP_ADMIN_SERVICE_ACCOUNT_TOKEN=ops_fixture_admin"
    assert_includes admin, "export SOME_OTHER_KEY=#{STRAY}", "a value under another name is never touched"
    assert body.end_with?("# <<< heroku-token <<<\n"), "the block is LAST, after any PATH prepend"
    assert_includes body, %(export PATH="#{File.expand_path(@shims)}${_ht_p:+:$_ht_p}")
    refute_includes admin, "export PATH", "the admin block changes no PATH"

    assert_equal 0o600, mode(@zprofile)
    assert_equal 0o600, mode(@admin)
    [[@zprofile, ZPROFILE], [@admin, ZPROFILE_ADMIN]].each do |path, original|
      saved = backups(path)
      assert_equal 1, saved.size
      assert_equal 0o600, mode(saved.first)
      backup = File.read(saved.first)
      SECRETS.grep(/\AHRKU-/).each do |token|
        refute_includes backup, token, "the backup must not keep a Heroku token"
      end
      refute_match(/HRKU-/, backup)
      assert_equal original.lines.size, backup.lines.size, "the backup keeps the file's shape, line for line"
      original.each_line.zip(backup.each_line).each do |was, kept|
        assert_equal was, kept, "a line holding no Heroku value is kept verbatim" unless was.match?(/HEROKU_|HRKU-/)
      end
    end
    assert_includes File.read(backups(@admin).first), "# HEROKU_STUDIO_ADMIN_API_KEY=[redacted"

    assert_includes out, "removed HEROKU_API_KEY (line 1)"
    assert_includes out, "HEROKU_STUDIO_APPLICATIONS_API_KEY (line 4)"
    assert_includes err, "line 5 holds a Heroku-shaped value under SOME_OTHER_KEY"
  end

  def test_the_block_puts_the_shim_first_on_path_in_a_real_shell
    _out, err, status = run_bin
    assert status.success?, err
    path, = Open3.capture2({ "PATH" => "/usr/bin:/bin" }, "sh", "-c", ". \"$1\" >/dev/null 2>&1; printf %s \"$PATH\"",
                           "sh", @zprofile)
    assert path.start_with?("#{File.expand_path(@shims)}:"), path
    twice, = Open3.capture2({ "PATH" => "/usr/bin:/bin" }, "sh", "-c", ". \"$1\"; . \"$1\"; printf %s \"$PATH\"", "sh", @zprofile)
    assert_equal 1, twice.split(":").count(File.expand_path(@shims)), "sourcing twice adds the shim once"
  end

  # A nested login shell: path_helper has already put the real CLI ahead of an
  # inherited shim entry. Sourcing the block must move the shim back to the front.
  def test_the_block_moves_an_inherited_shim_back_in_front_of_the_real_cli
    assert run_bin.last.success?
    shims = File.expand_path(@shims)
    path, = Open3.capture2({ "PATH" => "/opt/homebrew/bin:#{shims}:/usr/bin:/bin" }, "sh", "-c",
                           ". \"$1\" >/dev/null 2>&1; printf %s \"$PATH\"", "sh", @zprofile)
    assert_equal [shims], path.split(":").first(1) & [shims], path
    assert_equal 1, path.split(":").count(shims), "the inherited entry is moved, not duplicated"
  end

  def test_a_second_run_changes_nothing
    run_bin
    before = [File.read(@zprofile), File.read(@admin)]
    out, err, status = run_bin

    assert status.success?, "#{out}\n#{err}"
    assert_equal before, [File.read(@zprofile), File.read(@admin)]
    assert_equal 2, out.scan("already migrated, unchanged").size
    assert_equal 1, backups(@zprofile).size, "an unchanged file gets no new backup"
  end

  def test_dry_run_writes_nothing_and_reads_no_item
    out, err, status = run_bin("--dry-run")

    assert status.success?, "#{out}\n#{err}"
    assert_equal ZPROFILE, File.read(@zprofile)
    assert_equal ZPROFILE_ADMIN, File.read(@admin)
    assert_empty backups(@zprofile)
    assert_empty FakeHerokuOp.calls(File.join(@dir, "op"))
    assert_includes out, "would remove HEROKU_API_KEY (line 1)"
  end

  def test_the_preflight_reads_the_item_not_the_stale_export
    run_bin
    # Per file: the agent profile proves agents; the admin profile proves every
    # lane whose literal it holds (its agents mirror included).
    reads = FakeHerokuOp.calls(File.join(@dir, "op")).map { |c| c["argv"][1] }.uniq
    assert_equal %w[op://studio-agents/heroku.studio.agents/credential
                    op://studio-agents-admin/heroku.studio.admin/credential
                    op://studio-applications/heroku.studio.applications/credential], reads
  end

  def test_a_lane_that_does_not_resolve_leaves_its_file_unchanged
    out, err, status = run_bin(env: { "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => nil })

    assert_equal 1, status.exitstatus, "#{out}\n#{err}"
    assert_equal ZPROFILE_ADMIN, File.read(@admin), "the admin file must be untouched"
    assert_empty backups(@admin)
    assert_includes err, "NOTHING WAS WRITTEN to ~/.zprofile.admin"
    refute_includes File.read(@zprofile), STALE_AGENTS, "the agent file, whose lane resolved, still migrates"
  end

  def test_a_missing_shim_refuses_before_any_change
    FileUtils.rm_f(File.join(@shims, "heroku"))
    out, err, status = run_bin

    assert_equal 1, status.exitstatus, "#{out}\n#{err}"
    assert_includes err, "no executable heroku shim"
    assert_equal ZPROFILE, File.read(@zprofile)
    assert_equal ZPROFILE_ADMIN, File.read(@admin)
  end

  def test_an_absent_admin_profile_is_skipped
    FileUtils.rm_f(@admin)
    out, err, status = run_bin

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "~/.zprofile.admin: not present, skipped"
  end

  # A fresh Mac (bin/ecosystem-build): no ~/.zprofile yet, so it is created with
  # just the block, 0600, and no backup.
  def test_an_absent_agent_profile_is_created_with_the_block
    FileUtils.rm_f(@zprofile)
    out, err, status = run_bin("--agent-only")

    assert status.success?, "#{out}\n#{err}"
    assert_equal 0o600, mode(@zprofile)
    assert_includes File.read(@zprofile), %(export PATH="#{File.expand_path(@shims)}${_ht_p:+:$_ht_p}")
    assert_empty backups(@zprofile)
  end

  def test_agent_only_leaves_the_admin_profile_alone
    out, err, status = run_bin("--agent-only")

    assert status.success?, "#{out}\n#{err}"
    refute_includes File.read(@zprofile), STALE_AGENTS
    assert_equal ZPROFILE_ADMIN, File.read(@admin)
    refute_includes out, ".zprofile.admin"
  end
end
