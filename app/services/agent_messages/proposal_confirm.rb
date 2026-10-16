module AgentMessages
  # The owner's word on an open proposal, handled IN CODE before any model sees
  # it (docs/agents/system/agent-message-loop.md, "Proposals and confirm").
  #
  # DiscordIngest asks first: is this message in a thread (thread_key, channel,
  # guild, channel ref, as the THREAD layer scopes it) with a pending
  # AgentProposal, and is its text exactly `go`, `no` or `change: …` (trimmed,
  # any case, leading @-mentions ignored)? Only then does this class store it:
  #
  #   sender may not confirm (Audience#may?(:confirm_proposal), the person's
  #   role) → stored `held` with a `confirm_refused` event. Nothing posts, nothing runs.
  #   proposal past expires_at → `expired`; the reply says so.
  #   the word replies to a proposal that is no longer open (superseded, run,
  #   dropped) → nothing changes; the reply says so. A reply to a specific
  #   proposal's message never confirms a different one.
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
    LEADING_MENTIONS = /\A(?:\s*<@[!&]?\d+>)+/

    EXPIRED_TEXT = "That proposal expired after 24 hours, so nothing ran. Ask again and I will offer it fresh.".freeze
    DROPPED_TEXT = "Dropped. Nothing will run.".freeze
    CLOSED_TEXT = "That proposal is no longer open, so nothing ran. Reply to the newest one, or ask again.".freeze

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
      return refused!(attrs, person, source, audience) unless audience.may?(:confirm_proposal)
      return expired!(attrs, source) if @proposal.expired?(@now)
      return answered!(attrs, source, CLOSED_TEXT, nil, "proposal_closed", @intent.first.to_s) unless @proposal.status == "proposed"

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

    def refused!(attrs, person, source, audience)
      message = base(attrs, source, status: "held")
      message.record!("confirm_refused", actor: "board",
                                         detail: { "proposal_id" => @proposal.id, "role" => audience.role,
                                                   "person_id" => person&.id }.compact)
      [ message, [] ]
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
  end
end
