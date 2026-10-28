# frozen_string_literal: true

# [unit] bin/lib/agent_setup_cli.rb — Steffon's half of a pending agent's setup.
# No Heroku, no Rails, no 1Password, no Discord: the runner decodes the request
# the generated script carries and answers in the transport's own framing; op,
# Discord and the installer are fakes that record what they were handed. The
# token must reach only Discord's header and the installer's stdin: never the
# hub, the output or an error.
#
#   ruby -Itest test/lib/agent_setup_cli_test.rb

require "minitest/autorun"
require "base64"
require "stringio"
require_relative "../../bin/lib/agent_setup_cli"

class AgentSetupCliTest < Minitest::Test
  TOKEN = "t0k3n"
  BOT_TOKEN = "MTU2MDUxNjI2NDM3ODUwNzMzNA.GxYzAb.secretsecretsecretsecretsecretsecret"
  APP_ID = "1560516264378507334"
  GUILD = "1332466565203103744"

  SHOWN = {
    "id" => 7, "soul" => "mason", "kind" => "discord_bot", "status" => "verifying", "bot_name" => "Mason",
    "application_id" => APP_ID, "guild_id" => GUILD, "secret_env" => "DISCORD_BOT_TOKEN_MASON",
    "install_app" => "mcritchie-studio", "op_vault" => "studio-agents", "op_item" => "agents.discord.mason",
    "op_field" => "bot-token", "op_vault_id" => "v" * 26, "op_item_id" => "i" * 26, "steps" => []
  }.freeze

  def setup
    @requests = []
    @answers = {}
  end

  # Decodes the request out of the runner script and answers it the way the dyno would.
  def runner
    lambda do |script|
      request = JSON.parse(Base64.strict_decode64(script[/strict_decode64\("([^"]+)"\)/, 1]))
      @requests << request
      answer = @answers.fetch(request["verb"]) { { "error" => "no answer for #{request['verb']}" } }
      answer = answer.call(request) if answer.respond_to?(:call)
      prefix = "@@#{AgentSetupCli::TAG}:#{TOKEN}@@ "
      body = Base64.strict_encode64(JSON.generate(answer))
      [ "Running rails runner - on mcritchie-studio... up\n#{prefix}#{body}\n#{prefix}END\n", "" ]
    end
  end

  def op(read: BOT_TOKEN, item_json: nil)
    @op_calls = []
    lambda do |*argv|
      @op_calls << argv
      case argv.first
      when "read" then read
      when "item" then item_json || JSON.generate("id" => "i" * 26, "vault" => { "id" => "v" * 26 },
                                                  "fields" => [ { "id" => "bot-token", "value" => "LEAK-ME-NOT" } ])
      when "whoami" then JSON.generate("url" => "https://my.1password.com", "account_uuid" => "a" * 26, "user_type" => "SERVICE_ACCOUNT")
      end
    end
  end

  def http(me: { "id" => APP_ID, "bot" => true, "username" => "Mason" }, me_status: 200, guilds: [ { "id" => GUILD } ])
    @http_calls = []
    lambda do |path, token|
      @http_calls << [ path, token ]
      path == "/users/@me" ? [ me_status, me ] : [ 200, guilds ]
    end
  end

  def installer(ok: true, said: "200")
    @installs = []
    lambda do |app, name, token|
      @installs << [ app, name, token ]
      [ ok, said ]
    end
  end

  def run_cli(verb, args, op: self.op, http: self.http, installer: self.installer, **opts)
    @out = StringIO.new
    @err = StringIO.new
    AgentSetupCli.run(verb, args, AgentSetupCli.default_options.merge(opts), runner: runner, op: op, http: http,
                                                                              installer: installer, out: @out, err: @err, token: TOKEN)
  end

  def assert_token_never_left
    refute_includes @out.string + @err.string, BOT_TOKEN, "the token is printed nowhere"
    refute_includes JSON.generate(@requests), BOT_TOKEN, "the token never travels to the hub"
  end

  def report_request = @requests.find { |r| r["verb"] == "report" }

  def test_open_looks_up_only_the_item_ids_and_opens_the_card
    @answers["open"] = ->(req) { { "id" => 3, "soul" => req["soul"], "bot_name" => "Mason", "status" => "pending", "op_link" => true,
                                   "permission_set" => "reply", "permissions" => "274877975552",
                                   "secret_env" => "DISCORD_BOT_TOKEN_MASON", "install_app" => "mcritchie-studio" } }
    assert_equal 0, run_cli("open", %w[discord], soul: "mason", by: "steffon")

    sent = @requests.first
    assert_equal %w[open discord_bot mason steffon], sent.values_at("verb", "kind", "soul", "by")
    assert_equal({ "op_vault" => "studio-agents", "op_item" => "agents.discord.mason", "op_item_id" => "i" * 26,
                   "op_vault_id" => "v" * 26, "op_account_id" => "a" * 26, "op_host" => "my.1password.com" }, sent["details"])
    refute_includes JSON.generate(@requests) + @out.string, "LEAK-ME-NOT", "a field value in the item's JSON is dropped, never sent or printed"
    refute(@op_calls.any? { |argv| argv.first == "read" }, "open reads no secret")
    assert_includes @out.string, "opened #3"
  end

  def test_open_with_explicit_ids_skips_the_lookup
    @answers["open"] = { "id" => 4, "op_link" => true }
    ids = { "op_account_id" => "a" * 26, "op_vault_id" => "v" * 26, "op_item_id" => "i" * 26, "op_host" => "my.1password.com" }
    assert_equal 0, run_cli("open", %w[discord], soul: "mason", by: "steffon", op_ids: ids)
    assert_empty @op_calls
    assert_equal ids, @requests.first["details"].slice(*ids.keys)
  end

  def test_verify_reads_checks_installs_over_stdin_and_reports_ready
    @answers["show"] = SHOWN
    @answers["report"] = { "id" => 7, "status" => "ready", "status_reason" => "Verified by steffon." }
    assert_equal 0, run_cli("verify", %w[7], by: "steffon")

    assert_equal [ "read", "op://#{'v' * 26}/#{'i' * 26}/bot-token" ], @op_calls.first
    assert_equal [ [ "/users/@me", BOT_TOKEN ], [ "/users/@me/guilds", BOT_TOKEN ] ], @http_calls
    assert_equal [ [ "mcritchie-studio", "DISCORD_BOT_TOKEN_MASON", BOT_TOKEN ] ], @installs
    assert_equal({ "verb" => "report", "id" => 7, "by" => "steffon", "ok" => true, "installed" => true, "bot_user_id" => APP_ID }, report_request)
    assert_token_never_left
  end

  def test_verify_with_no_install_checks_and_installs_nothing
    @answers["show"] = SHOWN
    @answers["report"] = { "id" => 7, "status" => "verifying" }
    assert_equal 0, run_cli("verify", %w[7], by: "steffon", install: false)
    assert_empty @installs
    assert_equal false, report_request["installed"]
  end

  def test_verify_maps_a_token_from_another_application_to_a_reason_and_installs_nothing
    @answers["show"] = SHOWN
    @answers["report"] = ->(req) { { "id" => 7, "status" => "needs_attention", "status_reason" => req["reason"] } }
    other = { "id" => "1405042649479647293", "bot" => true, "username" => "Mason" }
    assert_equal 1, run_cli("verify", %w[7], by: "steffon", http: http(me: other))
    assert_empty @installs
    assert_equal false, report_request["ok"]
    assert_match(/belongs to bot 1405042649479647293, not the application #{APP_ID}/, report_request["reason"])
    assert_token_never_left
  end

  def test_verify_reports_an_empty_field_without_calling_discord
    @answers["show"] = SHOWN
    @answers["report"] = { "id" => 7, "status" => "needs_attention" }
    assert_equal 1, run_cli("verify", %w[7], by: "steffon", op: op(read: ""))
    assert_empty @http_calls
    assert_match(/bot-token on agents.discord.mason is empty/, report_request["reason"])
  end

  def test_verify_redacts_the_token_from_an_installer_refusal
    @answers["show"] = SHOWN
    @answers["report"] = ->(req) { { "id" => 7, "status" => "needs_attention", "status_reason" => req["reason"] } }
    assert_equal 1, run_cli("verify", %w[7], by: "steffon", installer: installer(ok: false, said: "refused #{BOT_TOKEN}"))
    assert_match(/heroku-secret-set refused DISCORD_BOT_TOKEN_MASON/, report_request["reason"])
    assert_token_never_left
  end

  def test_verify_refuses_a_card_still_on_alex_mcritchies_turn
    @answers["show"] = SHOWN.merge("status" => "pending")
    assert_equal 1, run_cli("verify", %w[7], by: "steffon")
    assert_empty @op_calls, "no read before Done"
    assert_match(/is pending: verify runs after/, @err.string)
  end

  def test_usage_errors_exit_2
    assert_equal 2, run_cli("verify", %w[7])
    assert_match(/say who is running this/, @err.string)
    assert_equal 2, run_cli("open", %w[slack], by: "steffon")
    assert_equal 2, run_cli("frob", [])
    assert_equal 2, run_cli("verify", %w[7 8], by: "steffon")
    assert_match(/unexpected argument/, @err.string)
    assert_empty @requests, "a stray positional is refused before any hub call"
  end
end
