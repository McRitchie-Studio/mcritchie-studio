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
    assert_includes log, "item get github.mcritchie-agent --vault agents-studio --format json"
    assert_includes log, "read op://agents-studio/github.mcritchie-agent/app-id"
  end

  def test_gh_app_item_selects_the_deployer_identity
    _out, _err, status = run_credential("get", env: { "GH_APP_ITEM" => "github.mcritchie-deployer" })

    assert status.success?
    log = File.read(File.join(@sandbox, "op.log"))
    # THE ISOLATION, asserted rather than assumed: the deployer resolves to a
    # DIFFERENT vault than the agent. agents-studio carries the agent App item and
    # NOT the deployer's, so collapsing these two onto one vault turns the build
    # lane green while breaking production deploys silently. See bin/lib/op_vaults.rb.
    assert_includes log, "item get github.mcritchie-deployer --vault agents-admin --format json"
    refute_includes log, "--vault agents-studio",
                    "the deployer must never read from the agent vault"
    assert_includes log, "read op://agents-admin/github.mcritchie-deployer/app-id"
  end

  # The key is the .pem FILE attachment — the helper must pick it over other
  # attachments and hand its CONTENT (multi-line PEM intact) to the minter,
  # alongside the app id. This is the whole 1Password → mint seam in one pass.
  def test_pem_file_attachment_is_selected_and_fed_to_the_minter
    _out, _err, status = run_credential("get")

    assert status.success?
    log = File.read(File.join(@sandbox, "op.log"))
    assert_includes log, "read op://agents-studio/github.mcritchie-agent/mcritchie-agent.2026-07-29.private-key.pem"
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


  # ── THE REFUSAL MUST NAME THE DOOR ──────────────────────────────────────────
  #
  # MEASURED 2026-08-30. This message used to end "...needs
  # OP_ADMIN_SERVICE_ACCOUNT_TOKEN, which an ordinary agent shell does not carry,
  # by design." Every word true, and it reads as a WALL. An agent hit that line,
  # concluded the ship lane was not self-service, and put a hand-mint chore on the
  # operator while a production deploy waited — the token had been installed for
  # two days, and one `source` fixed it.
  #
  # As with the Ruby side, THE ASSERTION THAT MATTERS IS THE DIFFERENCE: a
  # single-branch message satisfies any test that just greps for the token name.
  def test_a_provisioned_ship_lane_is_told_which_line_to_run
    Dir.mktmpdir do |home|
      File.write(File.join(home, ".zprofile.admin"), "# token\n")
      err = deployer_failure(home)

      assert_includes err, "source ~/.zprofile.admin", "name the command, not the obstacle"
      refute_includes err, "setup-1pass-token", "installing is the wrong errand here"
    end
  end

  def test_an_unprovisioned_ship_lane_is_told_to_install_once
    Dir.mktmpdir do |home|
      err = deployer_failure(home)

      assert_includes err, "setup-1pass-token --admin", "with no file this IS the operator's step"
      refute_includes err, "source ~/.zprofile.admin", "sourcing a missing file is a dead end"
    end
  end

  # The AGENT lane must not be handed admin advice — its token is ambient, and a
  # failure there is a different problem with a different fix.
  def test_the_agent_lane_gets_no_admin_remedy
    Dir.mktmpdir do |home|
      refute_includes agent_failure(home), "zprofile.admin"
    end
  end


  # ── THE HEADER MUST DESCRIBE THE CODE UNDERNEATH IT ────────────────────────
  #
  # The header said "Only the `get` action is answered; store/erase are silent
  # no-ops" — three lines above `case "$ACTION" in get|erase)`, and after `erase`
  # had become the ONLY way a rejected token is ever retired. A reader who trusted
  # it would conclude the 401 path self-heals by magic.
  #
  # ASSERTED AGAINST THE CODE, not against a fixed string. Pinning the sentence
  # would just move the staleness into this file the next time an action is added;
  # the property is that the two agree.
  def test_the_header_names_exactly_the_actions_the_script_answers
    source = File.read(SCRIPT)
    header = source.lines.take_while { |l| l.start_with?("#") || l.strip.empty? }.join
    answered = source[/^case "\$ACTION" in\n\s*([a-z|]+)\)/, 1].to_s.split("|")

    assert_equal %w[get erase], answered, "guard the guard: the dispatch shape changed"

    answered.each do |action|
      assert_match(/`#{action}`/, header,
                   "the header must name `#{action}` — it is answered, and a reader who " \
                   "believes otherwise misreads the whole 401 retirement path")
    end
    refute_match(/store\/erase are silent no-ops|only the `get` action is answered/i, header,
                 "erase is answered; saying otherwise is the stale claim this pins")
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

  def deployer_failure(home) = credential_failure(home, "github.mcritchie-deployer")
  def agent_failure(home) = credential_failure(home, "github.mcritchie-agent")

  # Drive the failure path with an `op` that always fails, so the message under
  # test is reached deterministically and no real 1Password call is made.
  #
  # PIN EVERY DECLARED SEAM, including GH_APP_TOKEN_CMD. This helper used to build
  # its env by hand and leave that one unset, so the script invoked the REAL
  # bin/gh-token for its shared-session read. These assertions passed only because
  # TASK_USAGE_SANDBOX=1 (test/support/task_usage_sandbox.rb) aborts it — an
  # INCIDENTAL seal, off in any shell without that variable, and one that would
  # have let a cached token satisfy the read and skip the message under test
  # entirely. Its sibling `run_credential` already routes through the seams; so
  # does this now.
  def credential_failure(home, item)
    Dir.mktmpdir do |dir|
      op = File.join(dir, "op")
      File.write(op, "#!/bin/sh\nexit 1\n")
      FileUtils.chmod(0o755, op)
      # No cached session and no minter: both legs must fail so the run reaches
      # the credential-refusal message these tests read.
      no_token = File.join(dir, "gh-token")
      File.write(no_token, "#!/bin/sh\nexit 1\n")
      FileUtils.chmod(0o755, no_token)
      env = { "HOME" => home, "GH_APP_ITEM" => item, "GH_APP_OP_BIN" => op,
              "GH_APP_TOKEN_CMD" => no_token, "GH_APP_MINT_CMD" => no_token,
              "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => nil }
      _out, err, _status = Open3.capture3(SessionEnv.neutralized(env), SCRIPT, "get",
                                          stdin_data: "protocol=https\nhost=github.com\n\n")
      err
    end
  end

end
