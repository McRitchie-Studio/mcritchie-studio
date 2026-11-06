module AgentChat
  # How much a satellite chat answers and stores before the hub refuses with 429 (the
  # contract's "capped"; nothing is stored). The numbers are /build's
  # (config/agent_answerers.yml `public_intake`, BuildIntake.policy), so the
  # public costs the same wherever it chats:
  #
  #   signed out   :thread  rows on one anon thread, turns_per_request
  #                :ip      answers from one visitor IP (hashed) per hour, across
  #                         /build and every satellite (BuildIntake::Caps#public_cap)
  #                :daily   signed-out answers across all public intake per Denver day
  #   signed in    :rate    WebIngest::RATE_LIMIT messages in a thread per
  #                         WebIngest::RATE_WINDOW, as the hub's own web chat
  #   every post   :ip, :daily as above: every satellite answer is answered as
  #                the public (MemoryBundle#audience_person), so it spends the
  #                public budget. A made-up email with no hub User counts toward
  #                the daily total as a signed-out visitor does
  #                (BuildIntake::Caps#public_cap), so minting emails buys nothing.
  #
  # TWO COUNTS, because a row a soul will not answer is stored all the same (a
  # public row on any soul but the intake soul is `held`, Answerers#intake?):
  #
  #   answered  the budget /build shares (BuildIntake::Caps): no held row, so a
  #             held flood takes nothing from /build
  #   stored    this soul's chat rows of every status, on the same numbers and
  #             windows: :thread is this count, and :ip and :daily check it after
  #             the answered budget. It is per soul, so a held flood on Turf
  #             cannot shut Alex's chat, and the souls are a short list
  #             (config/agent_routes.yml), so the total stays bounded. On the
  #             intake soul it counts nothing the answered budget does not.
  #
  # A signed-in thread is the person's for good, so it takes a rolling rate, not a
  # lifetime count. Two posts racing at the edge may let one extra through; the
  # caps are a budget, not a lock.
  class Caps
    def initialize(policy: BuildIntake.policy, now: Time.current)
      @policy = policy
      @now = now
    end

    # nil when the message may be stored, else the cap's code.
    # A nil thread_key is an email with no person yet (Visitor#thread_key): the
    # first post, so no thread count applies.
    def check(soul:, thread_key:, signed_in:, ip_hash: nil)
      if signed_in
        limited = rate(thread_key)
        return limited if limited
      end
      return nil unless @policy
      return :thread if !signed_in && thread_key && on_thread(thread_key).count >= @policy.turns_per_request

      public_caps = BuildIntake::Caps.new(policy: @policy, now: @now)
      public_caps.public_cap(ip_hash) || public_caps.public_cap(ip_hash, rows: stored(soul))
    end

    # The line the app shows at `code`.
    def self.reply(code)
      case code
      when :thread then BuildIntake::Caps::REPLIES[:request_signed_out]
      when :rate then "That's a lot of messages in a short while. Give it a few minutes and try again."
      else BuildIntake::Caps::REPLIES[:busy]
      end
    end

    private

    def rate(thread_key)
      return nil unless thread_key

      recent = on_thread(thread_key).where("created_at > ?", @now - AgentMessages::WebIngest::RATE_WINDOW).count
      recent >= AgentMessages::WebIngest::RATE_LIMIT ? :rate : nil
    end

    # The visitor's own rows: a code-written row (Alex's word on an upgrade
    # proposal, AgentProposals::Upgrade.post_outcome!) is not theirs to count.
    def on_thread(thread_key)
      AgentMessage.where(channel: "web", thread_key: thread_key).where(VISITOR_ROWS)
    end

    VISITOR_ROWS = "NOT (agent_messages.run_meta @> '{\"code_written\": true}'::jsonb)".freeze

    def stored(soul)
      prefix = AgentChat.soul_prefix(soul)
      AgentMessage.where(channel: "web").where("left(agent_messages.thread_key, ?) = ?", prefix.length, prefix)
    end
  end
end
