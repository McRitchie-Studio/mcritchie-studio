# frozen_string_literal: true

# Standalone coverage for bin/gh-app-git-credential. Both external legs are
# injected through the script's declared test seams — GH_APP_OP_BIN (a fake
# `op`) and GH_APP_MINT_CMD (a fake minter) — so no test here touches
# 1Password, GitHub, or the real minter.

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../support/session_env"

class GhAppGitCredentialTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "gh-app-git-credential")

  FAKE_PEM = "-----BEGIN FAKE KEY-----\nline-one\nline-two\n-----END FAKE KEY-----"

  def setup
    @sandbox = Dir.mktmpdir("gh-app-credential")
    write_op_fixtures
    @fake_op = write_script("fake-op", <<~RUBY)
      #!/usr/bin/env ruby
      dir = __dir__
      File.open(File.join(dir, "op.log"), "a") { |f| f.puts ARGV.join(" ") }
      case ARGV[0]
      when "item" then puts File.read(File.join(dir, "item.json"))
      when "read"
        ref = ARGV[1].to_s
        if ref.end_with?("/app-id")
          puts File.read(File.join(dir, "app-id.txt")).strip
        else
          print File.read(File.join(dir, "pem.txt"))
        end
      else
        abort "fake-op: unexpected \#{ARGV.inspect}"
      end
    RUBY
    @fake_mint = write_script("fake-mint", <<~RUBY)
      #!/usr/bin/env ruby
      File.write(File.join(__dir__, "mint-env.txt"), "id=\#{ENV["GH_APP_ID"]}\\npem=\#{ENV["GH_APP_PEM"]}\\n")
      puts "minted-token-\#{ENV["GH_APP_ID"]}"
    RUBY
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  def test_non_get_actions_are_silent_no_ops
    %w[store erase].each do |action|
      out, err, status = run_credential(action)

      assert status.success?, "#{action}: #{err}"
      assert_empty out
      assert_empty err
    end
  end

  def test_get_emits_the_credential_pair_from_the_minted_token
    out, err, status = run_credential("get")

    assert status.success?, err
    assert_equal ["username=x-access-token", "password=minted-token-424242"], out.lines(chomp: true)
  end

  def test_get_defaults_to_the_agent_identity
    _out, _err, status = run_credential("get")

    assert status.success?
    log = File.read(File.join(@sandbox, "op.log"))
    assert_includes log, "item get github.mcritchie-agent --vault agents --format json"
    assert_includes log, "read op://agents/github.mcritchie-agent/app-id"
  end

  def test_gh_app_item_selects_the_deployer_identity
    _out, _err, status = run_credential("get", env: { "GH_APP_ITEM" => "github.mcritchie-deployer" })

    assert status.success?
    log = File.read(File.join(@sandbox, "op.log"))
    assert_includes log, "item get github.mcritchie-deployer --vault agents --format json"
    assert_includes log, "read op://agents/github.mcritchie-deployer/app-id"
  end

  # The key is the .pem FILE attachment — the helper must pick it over other
  # attachments and hand its CONTENT (multi-line PEM intact) to the minter,
  # alongside the app id. This is the whole 1Password → mint seam in one pass.
  def test_pem_file_attachment_is_selected_and_fed_to_the_minter
    _out, _err, status = run_credential("get")

    assert status.success?
    log = File.read(File.join(@sandbox, "op.log"))
    assert_includes log, "read op://agents/github.mcritchie-agent/mcritchie-agent.2026-07-29.private-key.pem"
    refute_includes log, "note.txt"
    assert_equal "id=424242\npem=#{FAKE_PEM}\n", File.read(File.join(@sandbox, "mint-env.txt"))
  end

  def test_item_without_file_attachment_fails_loudly
    File.write(File.join(@sandbox, "item.json"), JSON.generate({ "files" => [] }))

    out, err, status = run_credential("get")

    refute status.success?
    refute_includes out, "password="
    assert_includes err, ".pem file attachment"
  end

  def test_op_failure_fails_loudly_naming_the_item
    broken_op = write_script("broken-op", "#!/bin/bash\nexit 1\n")

    out, err, status = run_credential("get", env: { "GH_APP_OP_BIN" => broken_op })

    refute status.success?
    refute_includes out, "password="
    assert_includes err, "1Password read failed for item 'github.mcritchie-agent'"
  end

  def test_mint_failure_fails_loudly_and_emits_no_credentials
    broken_mint = write_script("broken-mint", "#!/usr/bin/env ruby\nabort \"mint exploded\"\n")

    out, err, status = run_credential("get", env: { "GH_APP_MINT_CMD" => broken_mint })

    refute status.success?
    refute_includes out, "password="
    assert_includes err, "token mint failed"
  end

  private

  def run_credential(*args, env: {})
    base = {
      "GH_APP_OP_BIN" => @fake_op,
      "GH_APP_MINT_CMD" => @fake_mint,
      "GH_APP_ITEM" => nil
    }
    Open3.capture3(SessionEnv.neutralized(base.merge(env)), SCRIPT, *args)
  end

  def write_op_fixtures
    File.write(File.join(@sandbox, "item.json"), JSON.generate(
      { "files" => [{ "name" => "note.txt" }, { "name" => "mcritchie-agent.2026-07-29.private-key.pem" }] }
    ))
    File.write(File.join(@sandbox, "app-id.txt"), "424242\n")
    File.write(File.join(@sandbox, "pem.txt"), FAKE_PEM)
  end

  def write_script(name, body)
    path = File.join(@sandbox, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end
end
