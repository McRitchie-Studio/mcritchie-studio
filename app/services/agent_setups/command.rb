module AgentSetups
  # The dyno half of Steffon's `bin/agent-setup` (bin/lib/agent_setup_cli.rb),
  # as Books::Export is of bin/books: one request hash in, one JSON-able answer
  # out, run inside `heroku run … rails runner -` (or `bin/rails runner -` with
  # --local). It needs no HTTP endpoint: whoever can run it already holds the
  # Heroku lane, which is Steffon's (SOP
  # docs/agents/agents/steffon/sops/agent-onboarding.md).
  #
  #   open    open a setup with its kit's steps (the card appears on /agents)
  #   list    the open setups, and the last few finished
  #   show    one setup's public details, which verify needs
  #   report  verify's verdict: needs_attention with a reason, or, after an
  #           install, a re-check of the INSTALLED token from this dyno's own
  #           environment, then ready
  #   close   close a setup (after the soul's first reply, or for a rotation)
  #
  # No verb takes or answers a secret.
  module Command
    module_function

    def call(request)
      case request["verb"]
      when "open" then open(request)
      when "list" then list
      when "show" then summary(find(request))
      when "report" then report(find(request), request)
      when "close" then close(find(request), request)
      else { "error" => "unknown verb #{request['verb'].inspect}" }
      end
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, ArgumentError, KeyError => e
      { "error" => e.message }
    rescue ActiveRecord::RecordNotUnique
      { "error" => "a live #{request['kind']} setup for #{request['soul']} on that target is already open: close it first (bin/agent-setup close <id>)" }
    rescue StandardError => e
      ErrorLog.capture!(e)
      { "error" => "#{e.class}: #{e.message} (recorded in /error_logs)" }
    end

    def open(request)
      soul = request.fetch("soul").to_s
      raise ArgumentError, "no agent #{soul.inspect} on the board" unless Agent.exists?(slug: soul)

      kind = request.fetch("kind").to_s
      kit = Kits.fetch(kind)
      details = request["details"].to_h.stringify_keys.slice(*OPEN_DETAILS)
      if (set = request["permission_set"].presence)
        details["permission_set"] = set
        details["permissions"] = kit.permissions_for(set).to_s
      end
      target = request["target"].presence || kit.default_details(soul)["install_app"]
      setup = AgentSetup.open!(agent_slug: soul, kind: kind, target: target, opened_by: by!(request), details: details)
      summary(setup)
    end

    # The details `open` accepts from the CLI; everything else comes from the kit.
    OPEN_DETAILS = %w[bot_name guild_id guild_name op_vault op_item op_field op_account_id op_vault_id op_item_id op_host].freeze

    def list
      {
        "open" => AgentSetup.open_setups.includes(:steps).order(:created_at).map { |s| summary(s) },
        "finished" => AgentSetup.finished.includes(:steps).order(updated_at: :desc).limit(5).map { |s| summary(s) }
      }
    end

    def report(setup, request)
      by = by!(request)
      unless %w[verifying needs_attention].include?(setup.status)
        raise ArgumentError, "setup #{setup.id} is #{setup.status}: verify reports only on a setup waiting for it"
      end

      if request["bot_user_id"].to_s.match?(DiscordBotKit::SNOWFLAKE)
        setup.update!(details: setup.details.merge("bot_user_id" => request["bot_user_id"].to_s))
      end
      return attention(setup, "Steffon's verify: #{request['reason'].presence || 'failed, with no reason given'}") unless request["ok"] == true
      unless request["installed"] == true
        setup.await_verify!("#{by} verified the token with Discord; it is not installed yet.")
        return summary(setup)
      end

      check_installed(setup, by)
    end

    # The installed token, read from THIS dyno's environment (a one-off dyno
    # boots on the newest config), asked of Discord. The hub never stores it.
    #
    # Every answer moves the card: a refused token, a rate limit, a 5xx or an
    # unreachable Discord all land on needs_attention with the reason (and the
    # non-401 faults in /error_logs, targeted at the setup), so the card never
    # sits on "verifying" after a report, and verify can run again.
    def check_installed(setup, by)
      env = setup.detail(:secret_env)
      token = AgentMessages::DiscordBot.soul_token(setup.agent_slug)
      return attention(setup, "Steffon reported #{env} installed, but this dyno does not see it.") unless token
      if (mirror = mirror_mismatch(setup, token))
        return attention(setup, mirror)
      end

      me_status, me = begin
        [ 200, AgentMessages::DiscordBot.new(token: token).current_user ]
      rescue AgentMessages::DiscordBot::Unauthorized
        [ 401, nil ]
      rescue AgentMessages::DiscordBot::Error => e
        setup.log_error!(e, "re-check of the installed #{env}")
        return attention(setup, "The hub could not re-check the installed #{env} with Discord (#{recheck_fault(e)}); " \
                                "the token is installed. Run bin/agent-setup verify #{setup.id} again.")
      end
      verdict = DiscordVerdict.call(me_status: me_status, me: me, expected_id: DiscordBotKit.application_id(setup),
                                    expected_name: setup.detail(:bot_name))
      return attention(setup, "The installed #{env}: #{verdict.reason}") unless verdict.ok?

      setup.ready!(by: by, note: "Verified by #{by}; installed as #{env} on #{setup.detail(:install_app)}.")
      summary(setup)
    end

    # The soul whose app IS the shared bot installs its token twice in one
    # release (secret_env and also_env, DISCORD_AGENT_BOT_TOKEN): a portal reset
    # kills the old token at once, so the shared reader must move with it. The
    # two vars must hold the same token; compared here, never printed.
    def mirror_mismatch(setup, token)
      also = setup.detail(:also_env) or return nil
      mirrored = ENV[also].to_s.strip
      return nil if mirrored.present? && ActiveSupport::SecurityUtils.secure_compare(mirrored, token)

      "Steffon reported #{setup.detail(:secret_env)} and #{also} installed together, but on this dyno " \
        "#{also} #{mirrored.empty? ? 'is unset' : 'holds a different token'}: run bin/agent-setup verify #{setup.id} again."
    end

    def recheck_fault(error)
      case error
      when AgentMessages::DiscordBot::RateLimited then "rate-limited, 429"
      else error.message[/HTTP \d{3}/] || error.message[/unreachable/] || error.class.name.demodulize
      end
    end

    def close(setup, request)
      setup.close!(by: by!(request))
      summary(setup)
    end

    def attention(setup, reason)
      setup.needs_attention!(reason)
      summary(setup)
    end

    def find(request) = AgentSetup.includes(:steps).find(Integer(request.fetch("id").to_s))

    def by!(request)
      request["by"].to_s.strip.presence || raise(ArgumentError, "say who is running this: --by NAME")
    end

    def summary(setup)
      kit = setup.kit
      setup.details.to_h.slice(*%w[bot_name application_id bot_user_id guild_id guild_name permission_set permissions
                                   secret_env also_env install_app op_vault op_item op_field op_vault_id op_item_id])
           .merge("id" => setup.id, "soul" => setup.agent_slug, "kind" => setup.kind, "target" => setup.target,
                  "status" => setup.status, "status_reason" => setup.status_reason,
                  "op_link" => kit.respond_to?(:op_link) && kit.op_link(setup).present?,
                  "steps" => setup.steps.map { |s| { "key" => s.key, "done_by" => s.done_by, "done_at" => s.done_at&.iso8601 } })
    end
  end
end
