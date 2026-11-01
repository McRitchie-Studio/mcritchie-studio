module AgentMessages
  # The owner's word on an open proposal, handled IN CODE before any model sees
  # it (docs/agents/system/agent-message-loop.md, "Proposals and confirm").
  #
  # DiscordIngest asks first: is this message in a thread (thread_key, channel,
  # guild, channel ref, as the THREAD layer scopes it) with a pending
  # AgentProposal, and is its text exactly `go`, `no` or `change: …` (trimmed,
  # any case, leading @-mentions ignored)? Only then does this class store it:
  #
  #   sender may not confirm → stored `held` with a `confirm_refused` event
  #   (its `reason` picks the line the chat shows, held_text). Nothing posts,
  #   nothing runs. Two kinds of sender may:
  #     - the owner role (Audience#may?(:confirm_proposal), the person's role,
  #       never anything the message says), on any thread, uncapped
  #     - an APP OWNER (Alex McRitchie, 2026-10-18), only through owner_verdict: on that
  #       app's own web CTO thread for that user (the same rule that answers
  #       them, Answerers#app_owner_thread?), on a proposal of a kind a client
  #       of the app may have built (OWNER_KINDS, checked again against the
  #       registry as that client), and while the app's owner meter
  #       (AgentUsage.owner_meter) is under its cap. At the cap the word is
  #       answered with AgentUsage's cap line, from code, and nothing changes.
  #   proposal past expires_at → `expired`; the reply says so.
  #   the word replies to a proposal that is no longer open (superseded, run,
  #   dropped) → nothing changes; the reply says so (still running, already
  #   ran, or nothing ran). A reply to a specific proposal's message never
  #   confirms a different one.
  #   go      → `confirmed`; AgentProposalJob runs it and posts the result.
  #   no      → `rejected`; the reply says it was dropped.
  #   change: → `rejected` (change requested) and the message goes to the soul
  #             like any other, the proposal in its context bundle
  #             (MemoryBundle "proposals"), so the soul can offer a revised one.
  #
  # Anything that is not exactly one of the three is not a confirm: it is routed
  # as usual, so "go ahead and also…" reaches the model, not the executor.
  class ProposalConfirm
    GO = /\Ago\z/i
    NO = /\Ano\z/i
    CHANGE = /\Achange:\s*(?<text>\S.*)\z/im
    # Discord's <@123>, <@!123>, <@&123> and Slack's <@U0ABC> or <@U0ABC|name>.
    LEADING_MENTIONS = /\A(?:\s*<@(?:[!&]?\d+|[UW][A-Z0-9]+(?:\|[^>]*)?)>)+/

    EXPIRED_TEXT = "That proposal expired after 24 hours, so nothing ran. Ask again and I will offer it fresh.".freeze
    DROPPED_TEXT = "Dropped. Nothing will run.".freeze
    CLOSED_TEXT = "That proposal is no longer open, so nothing ran. Reply to the newest one, or ask again.".freeze
    # A word on a proposal already confirmed: it IS running (or ran), so "nothing
    # ran" would be false. The word changes nothing either way.
    RUNNING_TEXT = "That proposal is already confirmed and running. Its result will post in this thread.".freeze
    RAN_TEXT = "That proposal already ran; its result is above. Nothing ran a second time.".freeze
    # A word on a confirmed proposal whose run went quiet past the claim's TTL: the
    # word re-queues it (the job's claim guard keeps it to one run).
    RETRY_TEXT = "That proposal was confirmed but its run went quiet, so I am starting it again. " \
                 "Its result will post in this thread.".freeze
    # What a refused (`held`) word shows in the web chat, by its event's reason.
    REFUSED_TEXT = "This account can't confirm or drop proposals in this chat, so nothing has run.".freeze
    KIND_REFUSED_TEXT = "Only the McRitchie team can confirm this kind of proposal, so nothing has run.".freeze
    # The proposal kinds an app owner may confirm on their own app's CTO thread:
    # a `change` opens a `designed` task in the app's own repo, which is what a
    # client's build is. Never `ask` (the catalog's queries read board and app
    # internals, min_audience team or owner) and never `operate` (SOPs).
    OWNER_KINDS = %w[change].freeze

    # The line a refused word shows (the `confirm_refused` event's detail).
    def self.held_text(detail)
      detail.to_h["reason"] == "kind" ? KIND_REFUSED_TEXT : REFUSED_TEXT
    end

    # [:go] / [:no] / [:change, "the change"] / nil.
    def self.intent(content)
      text = content.to_s.sub(LEADING_MENTIONS, "").strip
      return [ :go ] if text.match?(GO)
      return [ :no ] if text.match?(NO)

      match = CHANGE.match(text)
      match ? [ :change, match[:text].strip ] : nil
    end

    def initialize(proposal:, intent:, now: Time.current)
      @proposal = proposal
      @intent = intent
      @now = now
    end

    # Stores the message (inside the caller's savepoint) and returns
    # [message, jobs to enqueue once it is stored].
    def store!(attrs, person:, source:)
      audience = AgentProposal.audience_for(person)
      unless audience.may?(:confirm_proposal)
        verdict, detail = owner_verdict(attrs, person)
        return capped!(attrs, source, detail) if verdict == :capped
        return refused!(attrs, person, source, audience, reason: detail) unless verdict == :ok
      end
      return expired!(attrs, source) if @proposal.expired?(@now)
      return stalled!(attrs, source) if @intent.first == :go && stalled?
      return answered!(attrs, source, closed_text, nil, "proposal_closed", @intent.first.to_s) unless @proposal.status == "proposed"

      case @intent.first
      when :go then go!(attrs, source)
      when :no then answered!(attrs, source, DROPPED_TEXT, "rejected", "proposal_rejected", "no")
      when :change then change!(attrs, source)
      end
    end

    private

    def base(attrs, source, status:, response: nil)
      message = AgentMessage.create!(attrs.merge(soul_slug: @proposal.soul_slug, routed_by: "thread", status: status,
                                                 response_text: response,
                                                 completed_at: status == "completed" ? @now : nil))
      message.record!("received", actor: source, detail: { "author" => message.author_name })
      message.record!("routed", actor: "router", detail: { "matched" => "reply to proposal #{@proposal.id}",
                                                           "soul" => @proposal.soul_slug, "routed_by" => "thread" })
      message
    end

    def refused!(attrs, person, source, audience, reason:)
      message = base(attrs, source, status: "held")
      message.record!("confirm_refused", actor: "board",
                                         detail: { "proposal_id" => @proposal.id, "role" => audience.role,
                                                   "person_id" => person&.id, "reason" => reason }.compact)
      [ message, [] ]
    end

    # THE APP OWNER'S WORD. [:ok], [:capped, meter], or [:refused, reason], from
    # facts code wrote, never the message text:
    #   "not_app_owner"  not this app's own web CTO thread for this user, by
    #                    Answerers#app_owner_thread? (web channel, the key
    #                    web:<app>:<user id> built server-side, the app's CTO
    #                    soul, a live AppMembership owner row, a public or
    #                    client person), or the proposal is not on that thread
    #   "kind"           the proposal is not one OWNER_KINDS names, or the
    #                    registry would not let this owner, as the app's client,
    #                    request it now
    #   "no_app"         no App row to meter (fail closed)
    def owner_verdict(attrs, person)
      answerers = Answerers.current
      probe = AgentMessage.new(attrs.except(:person).merge(soul_slug: @proposal.soul_slug))
      return [ :refused, "not_app_owner" ] unless own_thread?(attrs) && answerers.app_owner_thread?(probe, person)
      return [ :refused, "kind" ] unless client_build?(answerers.audience_for(probe, person))

      app = App.find_by(slug: @proposal.channel_ref)
      return [ :refused, "no_app" ] unless app

      meter = AgentUsage.owner_meter(app, now: @now, answerers: answerers)
      meter.capped? ? [ :capped, meter ] : [ :ok ]
    end

    # The proposal is on the very web thread the word was sent in.
    def own_thread?(attrs)
      @proposal.channel == "web" && attrs[:channel].to_s == "web" && @proposal.guild_id.nil? &&
        @proposal.thread_key == attrs[:thread_key].to_s && @proposal.channel_ref == attrs[:channel_ref].to_s
    end

    # Whether this owner, as the app's client, could request this proposal now.
    def client_build?(audience)
      return false unless OWNER_KINDS.include?(@proposal.kind)

      client = AgentMailbox::Audience.new(role: audience["role"], client_domain: audience["client_domain"])
      AgentProposal.registry.validate(soul: @proposal.soul_slug, audience: client,
                                      proposal: { "kind" => @proposal.kind, "capability" => @proposal.capability,
                                                  "params" => @proposal.params, "summary" => @proposal.summary }).ok?
    end

    # The owner's word at the app's cap: answered with the cap line from code
    # (AgentMessage#usage_capped!, as a capped question is), the proposal untouched.
    def capped!(attrs, source, meter)
      message = base(attrs, source, status: "received")
      message.usage_capped!(meter, now: @now)
      message.record!("confirm_refused", actor: "board",
                                         detail: { "proposal_id" => @proposal.id, "reason" => "usage_cap",
                                                   "word" => @intent.first.to_s, "person_id" => message.person_id }.compact)
      [ message, [ [ AgentMessageReplyJob, message.id ] ] ]
    end

    def expired!(attrs, source)
      @proposal.settle!("expired", by: "board", now: @now) if @proposal.status == "proposed"
      answered!(attrs, source, EXPIRED_TEXT, nil, "proposal_expired", "expired")
    end

    # A deterministic answer: completed now, queued for the reply job.
    def answered!(attrs, source, text, new_status, event, word)
      message = base(attrs, source, status: "completed", response: text)
      message.update!(reply_status: "queued", reply_nonce: "agentmsg-#{message.id}")
      @proposal.settle!(new_status, by: settler(message), now: @now) if new_status
      message.record!(event, actor: "board", detail: { "proposal_id" => @proposal.id, "word" => word })
      [ message, [ [ AgentMessageReplyJob, message.id ] ] ]
    end

    def go!(attrs, source)
      message = base(attrs, source, status: "completed")
      message.update!(reply_nonce: "agentmsg-#{message.id}")
      @proposal.update!(status: "confirmed", confirm_message: message, settled_at: @now, settled_by: settler(message))
      message.record!("confirmed", actor: "board", detail: { "proposal_id" => @proposal.id, "kind" => @proposal.kind,
                                                             "capability" => @proposal.capability })
      [ message, [ [ AgentProposalJob, @proposal.id ] ] ]
    end

    def change!(attrs, source)
      message = base(attrs, source, status: "received")
      @proposal.settle!("rejected", by: settler(message), now: @now,
                                    result: { "reason" => "change requested", "change_message_id" => message.id })
      message.record!("proposal_rejected", actor: "board", detail: { "proposal_id" => @proposal.id, "word" => "change" })
      [ message, [] ]
    end

    def settler(message) = "person:#{message.person_id}"

    # Confirmed, and neither claimed nor confirmed within the job's claim TTL: its
    # run died or its job was lost. (The job's own recheck covers a death after
    # the claim; this covers anything that recheck missed.)
    def stalled?
      return false unless @proposal.status == "confirmed"

      stamp = @proposal.result.to_h["claimed_at"].presence
      since = stamp ? Time.zone.parse(stamp.to_s) : @proposal.settled_at
      since.nil? || since <= @now - AgentProposalJob::CLAIM_TTL
    rescue ArgumentError
      true
    end

    def stalled!(attrs, source)
      message, = answered!(attrs, source, RETRY_TEXT, nil, "proposal_closed", "#{@intent.first}: rerun")
      [ message, [ [ AgentMessageReplyJob, message.id ], [ AgentProposalJob, @proposal.id ] ] ]
    end

    # The reply to a word on a proposal that is not open, true to its status.
    def closed_text
      case @proposal.status
      when "confirmed" then RUNNING_TEXT
      when "executed" then RAN_TEXT
      else CLOSED_TEXT
      end
    end
  end
end
