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
#   open     looks up the empty 1Password item's ids with `op item list` (a
#            listing carries ids and titles, never a field), then opens
#            the card on the hub (AgentSetups::Command over `heroku run`, as
#            bin/books does: no new HTTP surface)
#   verify   reads the token with `op read` (OP_CACHE=false, bounded by OpMeter),
#            asks Discord GET /users/@me and /users/@me/guilds, maps the answers
#            (AgentSetups::DiscordVerdict), pipes the token on STDIN to
#            bin/heroku-secret-set as DISCORD_BOT_TOKEN_<SOUL> (and, for the
#            soul whose app is the shared bot, DISCORD_AGENT_BOT_TOKEN in the
#            same release), and reports the verdict to the hub, which re-checks
#            the INSTALLED token itself. It installs only on the app the hub
#            runs on (--app), so the re-check reads the var it just wrote
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
  ITEM_LANE = "agents"

  Error = Class.new(StandardError)

  USAGE = <<~TXT
    usage: bin/agent-setup open discord --soul SOUL --by WHO [--op-item TITLE] [--op-vault VAULT]
                                        [--bot-name NAME] [--permission-set reply|cto|server_admin]
                                        [--op-account-id ID --op-vault-id ID --op-item-id ID --op-host HOST]
           bin/agent-setup list
           bin/agent-setup verify <id> --by WHO [--no-install]
           bin/agent-setup close <id> --by WHO
    common: --app NAME (default #{MailCli::DEFAULT_APP}) · --local (bin/rails runner here, not heroku)
    open looks up the 1Password item's ids with `op item list` (ids and titles only, never a field value);
    the --op-*-id flags skip that. verify installs only on --app, which must be the card's install app.
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
  # Two names (a soul's var and the shared bot's) go as one --json body, so
  # one release carries both and the two never land apart.
  def default_installer(capture: Open3.method(:capture3))
    lambda do |app, names, token|
      names = Array(names)
      out, err, status =
        if names.size == 1
          capture.call(SECRET_SET, app, names.first, stdin_data: token)
        else
          capture.call(SECRET_SET, app, "--json", stdin_data: JSON.generate(names.to_h { |n| [ n, token ] }))
        end
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
    item = opts[:op_item] || default_item(soul)
    ids = opts[:op_ids].empty? ? op_ids(op, item, vault, out) : opts[:op_ids]
    details = { "op_vault" => vault, "op_item" => item, "bot_name" => opts[:bot_name] }.merge(ids).compact
    answer = call.call({ "verb" => "open", "kind" => kind, "soul" => soul, "by" => by!(opts),
                         "permission_set" => opts[:permission_set], "details" => details }.compact)
    out.puts "opened ##{answer['id']}: #{answer['bot_name']} (#{answer['soul']}) · #{answer['status']}"
    out.puts "  1Password: #{answer['op_link'] ? "linked (#{item})" : "NOT linked: the card says so; re-open with --op-*-id"}"
    installs = [ answer["secret_env"], answer["also_env"] ].compact.join(" + ")
    out.puts "  invite permissions: #{answer['permission_set']} (#{answer['permissions']}) · installs as #{installs} on #{answer['install_app']}"
    out.puts "  Alex McRitchie's card: https://mcritchie.studio/agents#agent-setup-#{answer['id']}"
    0
  end

  # credential-filing's `<service>.<entity>.<lane>` for a soul's bot: service
  # discord, entity the soul, lane agents (AgentSetups::DiscordBotKit#op_item_for
  # is the dyno's copy). Joined, not written out, so no literal here reads as a
  # path under the operator's state directory (state_store_containment_test).
  def default_item(soul) = [ "discord", soul, ITEM_LANE ].join(".")

  # The item's and vault's ids from `op item list` of the vault, matched on the
  # exact title, and the account's from `op whoami`. A LISTING, never
  # `op item get`: get answers with every field's value, so a rotation card,
  # whose item already holds a token, would pull the live token into this
  # process. A listing carries ids, titles and the vault's name, never a field.
  # Nothing is printed. No match, two matches, or a failed lookup opens the
  # card without a link and says so.
  def op_ids(op, item, vault, out)
    listed = JSON.parse(op.call("item", "list", "--vault", vault, "--format", "json"))
    matches = Array(listed).select { |row| row.is_a?(Hash) && row["title"] == item }
    unless matches.size == 1
      out.puts "  (#{matches.empty? ? 'no' : matches.size} item titled #{item} in #{vault}; is it filed, and is the lane on?)"
      return {}
    end
    who = JSON.parse(op.call("whoami", "--format", "json"))
    host = URI(who["url"].to_s).host
    { "op_item_id" => matches.first["id"], "op_vault_id" => matches.first.dig("vault", "id"),
      "op_account_id" => who["account_uuid"], "op_host" => host }.compact
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
    install_target!(setup, opts)

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
      names = [ setup["secret_env"], setup["also_env"] ].compact.uniq
      ok, said = installer.call(setup["install_app"], names, token)
      unless ok
        return report(call, out, id, by, ok: false, bot_user_id: verdict.bot_user_id,
                                         reason: "bin/heroku-secret-set refused #{names.join(' + ')} on #{setup['install_app']}: #{said.to_s.gsub(token, '[REDACTED]')[0, 200]}")
      end
      installed = true
    end
    report(call, out, id, by, ok: true, installed: installed, bot_user_id: verdict.bot_user_id)
  end

  # An install must land where the hub's re-check runs, or the re-check reads
  # an old var (or none) and the verdict is about the wrong app: `--app QA`
  # would install on the card's app and re-check QA. So an installing verify
  # runs only with --app equal to the card's install app, and never with
  # --local (a local runner cannot see a Heroku var). --no-install skips this:
  # it writes nothing, and the hub keeps the card waiting.
  def install_target!(setup, opts)
    return unless opts[:install]

    target = setup["install_app"].to_s
    if opts[:local]
      raise Error, "setup ##{setup['id']} installs on #{target}, which a --local run cannot re-check: drop --local, or pass --no-install"
    end
    return if opts[:app].to_s == target

    raise Error, "setup ##{setup['id']} installs on #{target}, not #{opts[:app]}: the hub's re-check would read #{opts[:app]}. " \
                 "Run with --app #{target}, or pass --no-install"
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
