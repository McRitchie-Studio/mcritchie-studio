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
  # The proposal is an AgentProposal row (kind `upgrade`, capability `tier`). The
  # thread's newest one reaches Alex's next answer from code as the bundle's
  # packages.upgrade.open (open_json: tier, billing, app, and waiting, approved,
  # declined or expired), since Alex's chat has no proposal catalog to carry it.
  # When the owner settles it, Alex says so in the thread (post_outcome!). It lives TTL (14 days), and a
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
    # What the visitor reads under Alex's answer once the proposal is stored. Plain
    # text: the chat shows it as written, so no Markdown marker leads it.
    SENT_LINE = "Sent to Alex McRitchie: a request to move you to %<tier>s (%<billing>s). " \
                "Nothing changes and nobody is charged until he approves it.".freeze

    # What Alex says in the thread once the owner settles it (post_outcome!).
    # Code-written, from the stored tier and billing: never the model's words.
    APPROVED_APPLIED_LINE = "Good news: Alex McRitchie approved your move to %<tier>s (%<billing>s), and " \
                            "%<app>s is on %<tier>s now. He'll be in touch about getting set up and billing. " \
                            "Ask me anything in the meantime.".freeze
    APPROVED_LINE = "Good news: Alex McRitchie approved your request to move to %<tier>s (%<billing>s). " \
                    "He'll be in touch to set it up with you; nothing changes and nobody is charged until then. " \
                    "Ask me anything in the meantime.".freeze
    DECLINED_LINE = "Alex McRitchie looked at your request to move to %<tier>s and isn't approving it right now. " \
                    "Nothing has changed on your account. I'm happy to talk through the options with you here, " \
                    "or you can book a call with him: %<schedule>s".freeze
    OUTCOME_ACTOR = "upgrade-proposals".freeze

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
      post_outcome!(proposal, now: now)
      proposal
    end

    def decline!(proposal, by:, now: Time.current)
      AgentProposal.transaction do
        proposal.lock!
        raise Closed, "that proposal is #{proposal.expired?(now) ? 'expired' : proposal.status}" unless open?(proposal, now)

        proposal.settle!("rejected", by: by, now: now, result: { "declined_by" => by.to_s[0, 100] })
      end
      post_outcome!(proposal, now: now)
      proposal
    end

    # Alex tells the visitor, in the thread the proposal came from, what the owner
    # decided: one code-written web row, stored already answered (no dispatcher
    # claims it) and marked code_written, so the chat shows it as an agent turn
    # only (AgentChat::Turns) and it counts toward no visitor cap
    # (AgentChat::Caps). Idempotent per proposal (external_id). Best effort, after
    # the decision committed: a failure is an ErrorLog row and the decision
    # stands. Returns the row, or nil.
    def post_outcome!(proposal, now: Time.current)
      return nil unless proposal.channel == "web" && AgentChat.thread?(proposal.thread_key)

      external = "upgrade-proposal:#{proposal.id}:#{proposal.status}"
      existing = AgentMessage.find_by(channel: "web", external_id: external)
      return existing if existing

      source = proposal.source_message
      AgentMessage.transaction do
        message = AgentMessage.create!(
          channel: "web", external_id: external, channel_ref: proposal.channel_ref, thread_key: proposal.thread_key,
          guild_id: proposal.guild_id, author_ref: source&.author_ref, author_name: source&.author_name,
          person: proposal.person, content: "[upgrade proposal: #{outcome_word(proposal)}]", mentions: {}, sent_at: now,
          soul_slug: proposal.soul_slug, routed_by: "chat", status: "completed", completed_at: now,
          hold_released_at: now, hold_released_by: OUTCOME_ACTOR, action_summary: "upgrade proposal #{outcome_word(proposal)}",
          response_text: outcome_text(proposal), reply_posted_at: now, reply_status: "posted",
          envelope: { "via" => OUTCOME_ACTOR, "proposal_id" => proposal.id }, run_meta: { "code_written" => true }
        )
        message.update!(reply_nonce: "agentmsg-#{message.id}", reply_external_id: "web:#{message.id}")
        message.record!("completed", actor: OUTCOME_ACTOR, detail: { "proposal_id" => proposal.id, "outcome" => outcome_word(proposal) })
        message
      end
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = proposal
      log.target_name = "upgrade proposal #{proposal.id} outcome message"
      log.save!
      nil
    end

    def outcome_word(proposal) = proposal.status == "executed" ? "approved" : "declined"

    def outcome_text(proposal)
      params = proposal.params.to_h
      tier = tier_name(params["tier"])
      billing = params["billing"].presence || "monthly"
      if proposal.status == "executed"
        applied = proposal.result.to_h
        return format(APPROVED_APPLIED_LINE, tier: tier, billing: billing, app: applied["app"]) if applied["applied"] && applied["app"].present?

        format(APPROVED_LINE, tier: tier, billing: billing)
      else
        format(DECLINED_LINE, tier: tier, schedule: "https://#{ENV.fetch('APP_HOST', 'mcritchie.studio')}/schedule")
      end
    end

    # The thread's newest upgrade proposal as the next answer reads it, from code:
    # {"tier", "billing", "app", "state"} with state waiting, approved, declined or
    # expired; nil with none. A proposal a newer one superseded is never the newest.
    def open_json(message)
      proposal = AgentProposal.in_thread(message).where(kind: KIND)
                              .where("agent_proposals.created_at <= ?", message.created_at).order(id: :desc).first
      return nil unless proposal

      params = proposal.params.to_h
      { "tier" => params["tier"].to_s, "billing" => params["billing"].presence || "monthly", "app" => params["app"].presence,
        "state" => state_of(proposal, message.created_at) }.compact
    end

    def state_of(proposal, now)
      return "approved" if proposal.status == "executed"
      return "expired" if proposal.expired?(now)
      return "waiting" if proposal.status == "proposed"

      "declined"
    end

    def open?(proposal, now) = proposal.kind == KIND && proposal.status == "proposed" && !proposal.expired?(now)

    class Closed < StandardError; end

    def refuse(reason) = Verdict.new(ok?: false, reason: reason)
  end
end
