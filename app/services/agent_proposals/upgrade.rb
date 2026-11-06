module AgentProposals
  # Alex's upgrade proposal (docs/agents/system/agent-message-loop.md, "Packages
  # and upgrade proposals"): when a person in his chat asks to move to a package
  # tier, Alex ends his answer with a PROPOSAL block of kind `upgrade`, and the
  # owner approves or declines it on /admin/upgrade_proposals. Alex changes no
  # tier and charges nobody: an approval is Alex McRitchie's own click.
  #
  #   ===PROPOSAL===
  #   {"kind": "upgrade", "params": {"tier": "pro", "billing": "annual", "app": "my-app"}, "summary": "…"}
  #
  # WHERE. Only the soul `alex`, only on his chat threads (chat:alex:…, AgentChat:
  # the hub's /chat, the talk-to-agent modal on /packages, a satellite's chat).
  # Anywhere else the block is refused like any catalog miss: a
  # `proposal_refused` event, nothing stored, nothing shown.
  #
  # WHAT IS CHECKED, in code, never trusted from the model: the tier is one
  # PackagesBrief.upgrade_tiers names (every tier but the free one), billing is
  # monthly or annual, the app is a slug, the summary is short, and nothing else
  # is in params. The app is a NOTE for the owner: an approval applies the tier
  # only to an app the thread's signed-in user OWNS (an AppMembership row);
  # otherwise it records the owner's yes and he follows up by hand.
  #
  # The proposal is an AgentProposal row (kind `upgrade`, capability `tier`), so
  # the thread's newest offer and its status reach Alex's next answer as every
  # proposal's do (MemoryBundle#proposals_json). It lives TTL (14 days), and a
  # newer one in the thread supersedes it. No word in a thread settles it
  # (AgentProposal.word_settled), and AgentProposalJob never runs it.
  module Upgrade
    KIND = "upgrade".freeze
    CAPABILITY = "tier".freeze
    SOUL = "alex".freeze
    TTL = 14.days
    BILLING = %w[monthly annual].freeze
    PARAMS = %w[tier billing app].freeze
    APP_SLUG = /\A[a-z0-9][a-z0-9-]{0,59}\z/
    SUMMARY_LIMIT = 200
    USER_THREAD = /\Achat:alex:(\d{1,18})\z/
    # What the visitor reads under Alex's answer once the proposal is stored.
    SENT_LINE = "> Sent to Alex McRitchie: a request to move you to %<tier>s (%<billing>s). " \
                "Nothing changes and nobody is charged until he approves it.".freeze

    Verdict = Struct.new(:ok?, :reason, :params, :summary, keyword_init: true)

    module_function

    # Whether a parsed PROPOSAL block is an upgrade one (AgentMessage#complete!
    # sends those here, never to the catalog).
    def proposal?(raw) = raw.is_a?(Hash) && raw["kind"].to_s == KIND

    # The proposal check, with no writes.
    def validate(message, raw)
      return refuse("only Alex files upgrade proposals") unless message.soul_slug.to_s == SOUL
      return refuse("upgrade proposals are filed only in Alex's chat") unless AgentChat.thread?(message.thread_key)

      params = raw["params"].is_a?(Hash) ? raw["params"].transform_keys(&:to_s) : {}
      unknown = params.keys - PARAMS
      return refuse("unknown param(s) #{unknown.join(', ')}") if unknown.any?

      tier = params["tier"].to_s
      return refuse("tier #{tier[0, 30].inspect} is not one the packages sell") unless AgentMessages::PackagesBrief.upgrade_tiers.include?(tier)

      billing = params["billing"].to_s.presence || "monthly"
      return refuse("billing is monthly or annual") unless BILLING.include?(billing)

      app = params["app"].to_s.strip.downcase.presence
      return refuse("app must be an app slug") if app && !app.match?(APP_SLUG)

      summary = raw["summary"].to_s.squish.truncate(SUMMARY_LIMIT, separator: " ")
      Verdict.new(ok?: true, params: { "tier" => tier, "billing" => billing, "app" => app }.compact,
                  summary: summary.presence || "Move to #{tier}")
    end

    # Store the checked proposal, or record why not. Returns the proposal or nil.
    # Called inside AgentMessage#complete!'s transaction.
    def record_from!(message, raw, now: Time.current)
      verdict = validate(message, raw)
      unless verdict.ok?
        message.record!("proposal_refused", actor: "board", detail: { "reason" => verdict.reason, "capability" => KIND })
        return nil
      end

      AgentProposal.in_thread(message).pending.find_each do |older|
        older.settle!("rejected", by: "board", now: now, result: { "reason" => "superseded" })
      end
      proposal = AgentProposal.create!(thread_key: message.thread_key, channel: message.channel, guild_id: message.guild_id,
                                       channel_ref: message.channel_ref, soul_slug: message.soul_slug, person: message.person,
                                       source_message: message, kind: KIND, capability: CAPABILITY,
                                       params: verdict.params, summary: verdict.summary, expires_at: now + TTL)
      message.record!("proposed", actor: "board", detail: { "proposal_id" => proposal.id, "kind" => KIND,
                                                            "capability" => CAPABILITY })
      # After the answer's transaction commits, so the job always finds the row.
      ActiveRecord.after_all_transactions_commit { UpgradeProposalNoticeJob.perform_later(proposal.id) }
      proposal
    end

    def sent_line(proposal)
      format(SENT_LINE, tier: tier_name(proposal.params["tier"]), billing: proposal.params["billing"] || "monthly")
    end

    def tier_name(key) = WorkspacePackage.find(key)&.name || key.to_s.titleize

    # The signed-in hub user the thread belongs to (chat:alex:<user id>, built
    # in code by AgentChat.user_thread_key), or nil for a visitor or a person
    # with no hub user.
    def user_for(proposal)
      id = proposal.thread_key.to_s[USER_THREAD, 1]
      id && User.find_by(id: id)
    end

    # The app an approval may change: the proposal's app, owned by that user.
    def owned_app(proposal)
      slug = proposal.params["app"].presence
      user = user_for(proposal)
      return nil unless slug && user&.slug.present?
      return nil unless AppMembership.owners.exists?(app_slug: slug, user_slug: user.slug)

      App.find_by(slug: slug)
    end

    # The owner's yes. On an app the person owns, the tier is set; otherwise the
    # yes is recorded and the owner follows up. Either way nothing is charged.
    # Returns the settled proposal; raises AgentProposal::Closed when it is not open.
    def approve!(proposal, by:, now: Time.current)
      AgentProposal.transaction do
        proposal.lock!
        raise Closed, "that proposal is #{proposal.expired?(now) ? 'expired' : proposal.status}" unless open?(proposal, now)

        app = owned_app(proposal)
        result = { "approved_by" => by.to_s[0, 100], "tier" => proposal.params["tier"], "billing" => proposal.params["billing"] }
        if app
          result.merge!("app" => app.slug, "from" => app.package_tier, "applied" => true)
          app.update!(package_tier: proposal.params["tier"])
        else
          result.merge!("applied" => false, "follow_up" => "no app this person owns was named; set the tier by hand")
        end
        proposal.settle!("executed", by: by, now: now, result: result)
        proposal.source_message&.record!("proposal_executed", actor: by.to_s[0, 100],
                                                              detail: { "proposal_id" => proposal.id, "kind" => KIND, "applied" => result["applied"] })
      end
      proposal
    end

    def decline!(proposal, by:, now: Time.current)
      AgentProposal.transaction do
        proposal.lock!
        raise Closed, "that proposal is #{proposal.expired?(now) ? 'expired' : proposal.status}" unless open?(proposal, now)

        proposal.settle!("rejected", by: by, now: now, result: { "declined_by" => by.to_s[0, 100] })
      end
      proposal
    end

    def open?(proposal, now) = proposal.kind == KIND && proposal.status == "proposed" && !proposal.expired?(now)

    class Closed < StandardError; end

    def refuse(reason) = Verdict.new(ok?: false, reason: reason)
  end
end
