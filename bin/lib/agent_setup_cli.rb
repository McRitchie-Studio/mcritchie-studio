# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "securerandom"
require "uri"
require_relative "mail_cli"
require_relative "op_meter"
require_relative "../../lib/agent_setups/discord_verdict"

# bin/agent-setup: Steffon's half of a pending agent's setup (the Pending agents
# column of /agents; SOP docs/agents/agents/steffon/sops/agent-onboarding.md).
#
# THE SPLIT. The hub dyno holds no 1Password right, so the token is read, checked
# and installed HERE, on the Mac, in Steffon's lane:
#
#   open     looks up the empty 1Password item's ids (never a value), then opens
#            the card on the hub (AgentSetups::Command over `heroku run`, as
#            bin/books does: no new HTTP surface)
#   verify   reads the token with `op read` (OP_CACHE=false, bounded by OpMeter),
#            asks Discord GET /users/@me and /users/@me/guilds, maps the answers
#            (AgentSetups::DiscordVerdict), pipes the token on STDIN to
#            bin/heroku-secret-set as DISCORD_BOT_TOKEN_<SOUL>, and reports the
#            verdict to the hub, which re-checks the INSTALLED token itself
#   list     the open cards, and the last few finished
#   close    close a card (after the soul's first reply, or for a rotation)
#
# The token is never printed, never an argument, never in a message: it lives in
# one local variable and leaves only in an Authorization header and on a child's
# STDIN. Every seam (runner, op, http, installer) is injectable:
# test/lib/agent_setup_cli_test.rb drives it with fakes, no Rails, no network.
module AgentSetupCli
  TAG = "agent-setup"
  SERVICE = "AgentSetups::Command"
  DISCORD_API = "https://discord.com/api/v10"
  KINDS = { "discord" => "discord_bot", "discord_bot" => "discord_bot" }.freeze
  SECRET_SET = File.expand_path("../heroku-secret-set", __dir__)

  Error = Class.new(StandardError)

  USAGE = <<~TXT
    usage: bin/agent-setup open discord --soul SOUL --by WHO [--op-item TITLE] [--op-vault VAULT]
                                        [--bot-name NAME] [--permission-set reply|cto|server_admin]
                                        [--op-account-id ID --op-vault-id ID --op-item-id ID --op-host HOST]
           bin/agent-setup list
           bin/agent-setup verify <id> --by WHO [--no-install]
           bin/agent-setup close <id> --by WHO
    common: --app NAME (default #{MailCli::DEFAULT_APP}) · --local (bin/rails runner here, not heroku)
    open looks up the 1Password item's ids itself (no value is read); the --op-*-id flags skip that.
    SOP: docs/agents/agents/steffon/sops/agent-onboarding.md
  TXT

  module_function

  def default_options
    { app: MailCli::DEFAULT_APP, local: false, by: nil, soul: nil, op_item: nil, op_vault: nil, bot_name: nil,
      permission_set: nil, install: true, op_ids: {} }
  end

  # --- the seams -------------------------------------------------------------

  # `op` with OP_CACHE=false from the first attempt and OpMeter's deadline, so a
  # wedged cache daemon is never consulted and a hang cannot stall the run.
  # stderr is discarded: it can quote the reference.
  def default_op
    lambda do |*argv|
      OpMeter.popen(OpMeter::CACHE_BYPASS, [ "op", *argv ], via: "agent-setup", err: File::NULL).to_s
    end
  end

  # GET a Discord path with the bot's token: [status, parsed body or nil].
  # Any network fault is status 0; the token is in a header only.
  def default_http
    lambda do |path, token|
      uri = URI("#{DISCORD_API}#{path}")
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bot #{token}"
      req["User-Agent"] = "McRitchieStudio agent-setup (https://mcritchie.studio, 1)"
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |h| h.request(req) }
      [ res.code.to_i, (JSON.parse(res.body) rescue nil) ]
    rescue StandardError
      [ 0, nil ]
    end
  end

  # The token on STDIN to bin/heroku-secret-set, which prints only a status.
  def default_installer
    lambda do |app, name, token|
      out, err, status = Open3.capture3(SECRET_SET, app, name, stdin_data: token)
      [ status.success?, "#{out}#{err}".strip ]
    end
  end

  # --- the verbs -------------------------------------------------------------

  def run(verb, args, opts, runner: nil, op: nil, http: nil, installer: nil, out: $stdout, err: $stderr,
          token: SecureRandom.hex(8))
    runner ||= MailCli.heroku_runner(app: opts[:app], local: opts[:local])
    stray = args.drop(%w[open verify close].include?(verb) ? 1 : 0)
    raise Error, "unexpected argument(s): #{stray.join(' ')}" unless stray.empty?

    call = ->(request) { remote(runner, request, token) }
    case verb
    when "open" then open(args, opts, call, op || default_op, out)
    when "list" then list(call, out)
    when "verify" then verify(args, opts, call, op || default_op, http || default_http, installer || default_installer, out)
    when "close" then close(args, opts, call, out)
    else raise Error, "unknown verb #{verb.inspect}"
    end
  rescue Error => e
    err.puts "agent-setup: #{e.message}"
    usage = e.message.start_with?("unknown verb", "name", "say who", "unexpected")
    err.puts USAGE if usage
    usage ? 2 : 1
  end

  def remote(runner, request, token)
    stdout, stderr = runner.call(MailCli.runner_script(request, token, service: SERVICE, tag: TAG))
    answer = begin
      MailCli.extract(stdout, token, tag: TAG, service: SERVICE)
    rescue MailCli::Error => e
      raise Error, "#{e.message}\n#{(stdout.to_s + stderr.to_s).lines.last(15).join}"
    end
    raise Error, answer["error"] if answer["error"]

    answer
  end

  def open(args, opts, call, op, out)
    kind = KINDS[args.shift.to_s] or raise Error, "name the kind: discord"
    soul = opts[:soul].to_s.strip
    raise Error, "name the soul: --soul SOUL" if soul.empty?

    vault = opts[:op_vault] || "studio-agents"
    item = opts[:op_item] || "agents.discord.#{soul}"
    ids = opts[:op_ids].empty? ? op_ids(op, item, vault, out) : opts[:op_ids]
    details = { "op_vault" => vault, "op_item" => item, "bot_name" => opts[:bot_name] }.merge(ids).compact
    answer = call.call({ "verb" => "open", "kind" => kind, "soul" => soul, "by" => by!(opts),
                         "permission_set" => opts[:permission_set], "details" => details }.compact)
    out.puts "opened ##{answer['id']}: #{answer['bot_name']} (#{answer['soul']}) · #{answer['status']}"
    out.puts "  1Password: #{answer['op_link'] ? "linked (#{item})" : "NOT linked: the card says so; re-open with --op-*-id"}"
    out.puts "  invite permissions: #{answer['permission_set']} (#{answer['permissions']}) · installs as #{answer['secret_env']} on #{answer['install_app']}"
    out.puts "  Alex McRitchie's card: https://mcritchie.studio/agents#agent-setup-#{answer['id']}"
    0
  end

  # The item's and vault's ids from `op item get` (JSON parsed here, only the
  # two ids kept; nothing is printed), and the account's from `op whoami`.
  # A failed lookup opens the card without a link and says so.
  def op_ids(op, item, vault, out)
    got = JSON.parse(op.call("item", "get", item, "--vault", vault, "--format", "json"))
    who = JSON.parse(op.call("whoami", "--format", "json"))
    host = URI(who["url"].to_s).host
    { "op_item_id" => got["id"], "op_vault_id" => got.dig("vault", "id"), "op_account_id" => who["account_uuid"],
      "op_host" => host }.compact
  rescue JSON::ParserError, URI::InvalidURIError, TypeError
    out.puts "  (could not read #{item}'s ids from 1Password; is it filed, and is the lane on?)"
    {}
  end

  def list(call, out)
    answer = call.call({ "verb" => "list" })
    rows = answer["open"].map { |s| row(s) }
    out.puts(rows.empty? ? "(no open setups)" : rows)
    out.puts "finished:", answer["finished"].map { |s| row(s) } unless answer["finished"].to_a.empty?
    0
  end

  def row(s)
    done = s["steps"].count { |st| st["done_at"] }
    line = "  ##{s['id'].to_s.ljust(4)} #{s['soul'].ljust(14)} #{s['kind'].ljust(12)} #{s['status'].ljust(16)} steps #{done}/#{s['steps'].size}"
    s["status_reason"] ? "#{line}\n        #{s['status_reason']}" : line
  end

  def verify(args, opts, call, op, http, installer, out)
    id = setup_id!(args)
    by = by!(opts)
    setup = call.call({ "verb" => "show", "id" => id })
    unless %w[verifying needs_attention].include?(setup["status"])
      raise Error, "setup ##{id} is #{setup['status']}: verify runs after Alex McRitchie's Done (verifying or needs_attention)"
    end

    ref = "op://#{setup['op_vault_id'] || setup['op_vault']}/#{setup['op_item_id'] || setup['op_item']}/#{setup['op_field']}"
    token = op.call("read", ref).to_s.strip
    if token.empty?
      return report(call, out, id, by, ok: false,
                                       reason: "The 1Password field #{setup['op_field']} on #{setup['op_item']} is empty (or 1Password did not answer): paste the token there, then Done.")
    end

    me_status, me = http.call("/users/@me", token)
    guilds_status, guilds = setup["guild_id"] ? http.call("/users/@me/guilds", token) : [ nil, nil ]
    verdict = AgentSetups::DiscordVerdict.call(me_status: me_status, me: me, guilds_status: guilds_status, guilds: guilds,
                                               expected_id: setup["application_id"], expected_name: setup["bot_name"],
                                               guild_id: setup["guild_id"])
    return report(call, out, id, by, ok: false, reason: verdict.reason, bot_user_id: verdict.bot_user_id) unless verdict.ok?

    installed = false
    if opts[:install]
      ok, said = installer.call(setup["install_app"], setup["secret_env"], token)
      unless ok
        return report(call, out, id, by, ok: false, bot_user_id: verdict.bot_user_id,
                                         reason: "bin/heroku-secret-set refused #{setup['secret_env']} on #{setup['install_app']}: #{said.to_s.gsub(token, '[REDACTED]')[0, 200]}")
      end
      installed = true
    end
    report(call, out, id, by, ok: true, installed: installed, bot_user_id: verdict.bot_user_id)
  end

  def report(call, out, id, by, ok:, reason: nil, installed: false, bot_user_id: nil)
    answer = call.call({ "verb" => "report", "id" => id, "by" => by, "ok" => ok, "reason" => reason,
                         "installed" => installed, "bot_user_id" => bot_user_id }.compact)
    out.puts "##{id}: #{answer['status']}#{" · #{answer['status_reason']}" if answer['status_reason']}"
    answer["status"] == "ready" || (answer["status"] == "verifying" && ok) ? 0 : 1
  end

  def close(args, opts, call, out)
    answer = call.call({ "verb" => "close", "id" => setup_id!(args), "by" => by!(opts) })
    out.puts "##{answer['id']}: #{answer['status']}"
    0
  end

  def setup_id!(args)
    id = args.shift.to_s
    raise Error, "name the setup: its number from bin/agent-setup list" unless id.match?(/\A\d+\z/)

    id.to_i
  end

  def by!(opts) = opts[:by].to_s.strip.empty? ? raise(Error, "say who is running this: --by NAME") : opts[:by]
end
